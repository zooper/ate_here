import CoreLocation
import MapKit

enum RestaurantPlaceKind: String, Equatable, Sendable {
    case restaurant
    case cafe
    case bakery
    case foodMarket
    case brewery
    case winery
    case other
}

struct RestaurantSearchResult: Identifiable, Equatable, Sendable {
    let placeID: String
    let name: String
    let subtitle: String?
    let latitude: Double
    let longitude: Double
    let placeKind: RestaurantPlaceKind
    let foodHints: Set<FoodCategory>

    init(
        placeID: String,
        name: String,
        subtitle: String?,
        latitude: Double,
        longitude: Double,
        placeKind: RestaurantPlaceKind = .restaurant,
        foodHints: Set<FoodCategory> = []
    ) {
        self.placeID = placeID
        self.name = name
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
        self.placeKind = placeKind
        self.foodHints = foodHints
    }

    var id: String { placeID }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayAddress: String? {
        guard let address = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else {
            return nil
        }
        return address
    }

    func distance(from coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude).distance(
            from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        )
    }

    func adding(foodHints additionalHints: Set<FoodCategory>) -> RestaurantSearchResult {
        RestaurantSearchResult(
            placeID: placeID,
            name: name,
            subtitle: subtitle,
            latitude: latitude,
            longitude: longitude,
            placeKind: placeKind,
            foodHints: foodHints.union(additionalHints)
        )
    }
}

enum RestaurantProximityRanking {
    static func rank(
        _ candidates: [RestaurantSearchResult],
        near coordinate: CLLocationCoordinate2D,
        limit: Int
    ) -> [RestaurantSearchResult] {
        Array(
            candidates
                .sorted { $0.distance(from: coordinate) < $1.distance(from: coordinate) }
                .prefix(limit)
        )
    }
}

protocol PlaceSearchService: Sendable {
    @MainActor
    func nearbyRestaurants(
        near coordinate: CLLocationCoordinate2D,
        foodCategories: [FoodCategory]
    ) async throws -> [RestaurantSearchResult]

    @MainActor
    func searchRestaurants(
        matching query: String,
        near coordinate: CLLocationCoordinate2D?,
        foodCategories: [FoodCategory]
    ) async throws -> [RestaurantSearchResult]

    @MainActor
    func resolvePlace(identifier: String) async throws -> RestaurantSearchResult?
}

extension PlaceSearchService {
    @MainActor
    func nearbyRestaurants(
        near coordinate: CLLocationCoordinate2D
    ) async throws -> [RestaurantSearchResult] {
        try await nearbyRestaurants(near: coordinate, foodCategories: [])
    }

    @MainActor
    func searchRestaurants(
        matching query: String,
        near coordinate: CLLocationCoordinate2D?
    ) async throws -> [RestaurantSearchResult] {
        try await searchRestaurants(
            matching: query,
            near: coordinate,
            foodCategories: []
        )
    }
}

enum RestaurantSearchRequestFactory {
    private static let manualSearchRegionSize: CLLocationDistance = 10_000

    @MainActor
    static func manualSearch(
        query: String,
        near coordinate: CLLocationCoordinate2D?
    ) -> MKLocalSearch.Request {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .pointOfInterest

        // A manual name search must not inherit the strict category filter used
        // for automatic nearby matching. Apple Maps may classify valid dining
        // venues as hotels, nightlife, food halls, or another POI category.
        if let coordinate {
            request.region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: manualSearchRegionSize,
                longitudinalMeters: manualSearchRegionSize
            )
        }

        return request
    }
}

struct MapKitPlaceSearchService: PlaceSearchService {
    private let nearbySearchRadius: CLLocationDistance = 750

    @MainActor
    func nearbyRestaurants(
        near coordinate: CLLocationCoordinate2D,
        foodCategories: [FoodCategory]
    ) async throws -> [RestaurantSearchResult] {
        let request = MKLocalPointsOfInterestRequest(
            center: coordinate,
            radius: nearbySearchRadius
        )
        request.pointOfInterestFilter = restaurantPointOfInterestFilter

        let response = try await MKLocalSearch(request: request).start()
        var results = uniqueResults(from: response.mapItems)

        for foodCategory in RestaurantCandidateRanking
            .meaningfulEvidence(from: foodCategories)
            .prefix(2) {
            guard let query = foodCategory.mapSearchQuery else { continue }
            try Task.checkCancellation()

            do {
                let categoryResults = try await searchMapItems(
                    matching: query,
                    near: coordinate,
                    regionSize: nearbySearchRadius * 2
                )
                results = merging(
                    results,
                    with: uniqueResults(
                        from: Array(categoryResults.prefix(5)),
                        foodHints: [foodCategory]
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The general nearby search is still useful if a category search fails.
            }
        }

        return RestaurantCandidateRanking.rank(
            results,
            near: coordinate,
            foodCategories: foodCategories,
            limit: 10
        ).map(\.result)
    }

    @MainActor
    func searchRestaurants(
        matching query: String,
        near coordinate: CLLocationCoordinate2D?,
        foodCategories: [FoodCategory]
    ) async throws -> [RestaurantSearchResult] {
        let request = RestaurantSearchRequestFactory.manualSearch(
            query: query,
            near: coordinate
        )

        let response = try await MKLocalSearch(request: request).start()
        // MapKit orders natural-language results by text relevance. Preserve
        // that ordering for explicit user searches; photo-based scoring is for
        // automatic suggestions, not for overriding the name the user typed.
        return uniqueResults(from: response.mapItems)
    }

    private var restaurantPointOfInterestFilter: MKPointOfInterestFilter {
        MKPointOfInterestFilter(
            including: [.restaurant, .cafe, .bakery, .foodMarket, .brewery, .winery]
        )
    }

    @MainActor
    private func uniqueResults(
        from mapItems: [MKMapItem],
        foodHints: Set<FoodCategory> = []
    ) -> [RestaurantSearchResult] {
        var seenIdentifiers = Set<String>()

        return mapItems.compactMap { mapItem in
            guard let result = makeResult(from: mapItem),
                  seenIdentifiers.insert(result.placeID).inserted else {
                return nil
            }
            return result.adding(foodHints: foodHints)
        }
    }

    @MainActor
    private func searchMapItems(
        matching query: String,
        near coordinate: CLLocationCoordinate2D,
        regionSize: CLLocationDistance
    ) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .pointOfInterest
        request.pointOfInterestFilter = restaurantPointOfInterestFilter
        request.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: regionSize,
            longitudinalMeters: regionSize
        )
        return try await MKLocalSearch(request: request).start().mapItems
    }

    private func merging(
        _ primary: [RestaurantSearchResult],
        with additional: [RestaurantSearchResult]
    ) -> [RestaurantSearchResult] {
        var results = primary
        var indexByPlaceID = Dictionary(
            uniqueKeysWithValues: primary.enumerated().map { ($0.element.placeID, $0.offset) }
        )

        for result in additional {
            if let index = indexByPlaceID[result.placeID] {
                results[index] = results[index].adding(foodHints: result.foodHints)
            } else {
                indexByPlaceID[result.placeID] = results.count
                results.append(result)
            }
        }
        return results
    }

    @MainActor
    func resolvePlace(identifier: String) async throws -> RestaurantSearchResult? {
        guard let mapItemIdentifier = MKMapItem.Identifier(rawValue: identifier) else {
            return nil
        }

        let request = MKMapItemRequest(mapItemIdentifier: mapItemIdentifier)
        let mapItem = try await request.mapItem
        return makeResult(from: mapItem)
    }

    @MainActor
    private func makeResult(from mapItem: MKMapItem) -> RestaurantSearchResult? {
        guard let identifier = mapItem.identifier?.rawValue,
              let name = mapItem.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }

        let coordinate: CLLocationCoordinate2D
        let subtitle: String?

        if #available(iOS 26.0, *) {
            coordinate = mapItem.location.coordinate
            subtitle = mapItem.addressRepresentations?.fullAddress(
                includingRegion: false,
                singleLine: true
            )
        } else {
            coordinate = mapItem.placemark.coordinate
            subtitle = mapItem.placemark.title
        }

        return RestaurantSearchResult(
            placeID: identifier,
            name: name,
            subtitle: subtitle,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            placeKind: placeKind(for: mapItem.pointOfInterestCategory)
        )
    }

    private func placeKind(
        for category: MKPointOfInterestCategory?
    ) -> RestaurantPlaceKind {
        switch category {
        case .restaurant: .restaurant
        case .cafe: .cafe
        case .bakery: .bakery
        case .foodMarket: .foodMarket
        case .brewery: .brewery
        case .winery: .winery
        default: .other
        }
    }
}
