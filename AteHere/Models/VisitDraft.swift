import CoreLocation
import Foundation

enum VisitTagRules {
    static let maximumTagCount = 20
    static let maximumTagLength = 30

    static func normalizedTag(_ value: String) -> String? {
        let collapsed = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty, collapsed.count <= maximumTagLength else {
            return nil
        }

        if let knownCategory = FoodCategory.allCases.first(where: {
            $0.rawValue.compare(collapsed, options: .caseInsensitive) == .orderedSame
        }) {
            return knownCategory.rawValue
        }

        return collapsed.prefix(1).uppercased() + collapsed.dropFirst()
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

struct VisitDraft: Equatable {
    var placeName: String = ""
    var applePlaceID: String?
    var resolvedMapPlaceName: String?
    var visitedAt: Date = .now
    var latitude: Double?
    var longitude: Double?
    var rating: Int?
    var notes: String = ""
    var foodCategories: [String] = []
    var photos: [VisitPhotoDraft] = []

    init(
        placeName: String = "",
        applePlaceID: String? = nil,
        resolvedMapPlaceName: String? = nil,
        visitedAt: Date = .now,
        latitude: Double? = nil,
        longitude: Double? = nil,
        rating: Int? = nil,
        notes: String = "",
        foodCategories: [String] = [],
        photos: [VisitPhotoDraft] = []
    ) {
        self.placeName = placeName
        self.applePlaceID = applePlaceID
        self.resolvedMapPlaceName = resolvedMapPlaceName
        self.visitedAt = visitedAt
        self.latitude = latitude
        self.longitude = longitude
        self.rating = rating
        self.notes = notes
        self.foodCategories = foodCategories
        self.photos = photos
    }

    init(visit: Visit) {
        self.init(
            placeName: visit.userDefinedPlaceName ?? "",
            applePlaceID: visit.applePlaceID,
            visitedAt: visit.visitedAt,
            latitude: visit.latitude,
            longitude: visit.longitude,
            rating: visit.rating,
            notes: visit.notes,
            foodCategories: visit.foodCategories,
            photos: visit.photos.map {
                VisitPhotoDraft(
                    assetLocalIdentifier: $0.assetLocalIdentifier,
                    capturedAt: $0.capturedAt,
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    classificationLabels: $0.classificationLabels,
                    isPrimary: $0.isPrimary
                )
            }
        )
    }

    init(candidate: DetectedVisitCandidate) {
        self.init(
            visitedAt: candidate.visitedAt,
            latitude: candidate.latitude,
            longitude: candidate.longitude,
            foodCategories: candidate.foodCategories,
            photos: candidate.photos
        )
    }

    var normalizedPlaceName: String {
        placeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedNotes: String {
        notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var persistedCustomPlaceName: String? {
        guard applePlaceID == nil, !normalizedPlaceName.isEmpty else { return nil }
        return normalizedPlaceName
    }

    var displayPlaceName: String? {
        if applePlaceID != nil {
            return resolvedMapPlaceName
        }
        return persistedCustomPlaceName
    }

    var canSave: Bool {
        applePlaceID != nil || !normalizedPlaceName.isEmpty
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func containsTag(_ tag: String) -> Bool {
        foodCategories.contains { VisitTagRules.matches($0, tag) }
    }

    @discardableResult
    mutating func addTag(_ value: String) -> Bool {
        guard foodCategories.count < VisitTagRules.maximumTagCount,
              let tag = VisitTagRules.normalizedTag(value),
              !containsTag(tag) else {
            return false
        }
        foodCategories.append(tag)
        return true
    }

    mutating func removeTag(_ tag: String) {
        foodCategories.removeAll { VisitTagRules.matches($0, tag) }
    }

    mutating func selectMapPlace(_ result: RestaurantSearchResult) {
        applePlaceID = result.placeID
        resolvedMapPlaceName = result.name
        placeName = ""
    }

    mutating func useCustomPlace() {
        applePlaceID = nil
        resolvedMapPlaceName = nil
    }

    @discardableResult
    mutating func addPhotoReferences(
        _ references: [VisitPhotoDraft],
        maximumCount: Int = 10
    ) -> Int {
        guard photos.count < maximumCount else { return 0 }

        var existingIdentifiers = Set(photos.map(\.assetLocalIdentifier))
        var addedCount = 0

        for reference in references where photos.count < maximumCount {
            guard existingIdentifiers.insert(reference.assetLocalIdentifier).inserted else {
                continue
            }
            photos.append(
                VisitPhotoDraft(
                    assetLocalIdentifier: reference.assetLocalIdentifier,
                    capturedAt: reference.capturedAt,
                    latitude: reference.latitude,
                    longitude: reference.longitude,
                    classificationLabels: reference.classificationLabels,
                    isPrimary: photos.isEmpty
                )
            )
            addedCount += 1
        }

        return addedCount
    }

    @discardableResult
    mutating func addManualPhotoAnalysis(
        _ analysis: ManualPhotoAnalysisResult,
        maximumCount: Int = 10,
        inferVisitMetadata: Bool
    ) -> Int {
        let addedCount = addPhotoReferences(
            analysis.photos,
            maximumCount: maximumCount
        )
        guard addedCount > 0 else { return 0 }

        var seenCategories = Set(foodCategories)
        foodCategories.append(
            contentsOf: analysis.foodCategories.filter {
                seenCategories.insert($0).inserted
            }
        )

        guard inferVisitMetadata else { return addedCount }
        if let visitedAt = analysis.visitedAt {
            self.visitedAt = visitedAt
        }
        if let latitude = analysis.latitude, let longitude = analysis.longitude {
            self.latitude = latitude
            self.longitude = longitude
        }
        return addedCount
    }
}
