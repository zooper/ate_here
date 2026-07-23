import Foundation
import CoreLocation
import MapKit
import SwiftData
import Testing
@testable import AteHere

struct VisitDraftTests {
    @Test("A restaurant name is required")
    func restaurantNameIsRequired() {
        #expect(!VisitDraft(placeName: "   \n").canSave)
        #expect(VisitDraft(placeName: "Dama").canSave)
    }

    @Test("User-entered text is normalized before persistence")
    func textIsNormalized() {
        let draft = VisitDraft(
            placeName: "  Dama  ",
            notes: "\nLate dinner with friends.  "
        )

        #expect(draft.normalizedPlaceName == "Dama")
        #expect(draft.normalizedNotes == "Late dinner with friends.")
    }

    @Test("Selecting an Apple Maps place stores only its Place ID")
    func mapPlaceStoresOnlyIdentifier() {
        let result = RestaurantSearchResult(
            placeID: "apple-place-123",
            name: "Dama",
            subtitle: "Los Angeles, CA",
            latitude: 34.0,
            longitude: -118.0
        )
        var draft = VisitDraft(placeName: "Temporary custom name")

        draft.selectMapPlace(result)
        let visit = Visit(draft: draft)

        #expect(draft.canSave)
        #expect(draft.displayPlaceName == "Dama")
        #expect(visit.applePlaceID == "apple-place-123")
        #expect(visit.userDefinedPlaceName == nil)
    }

    @Test("A custom place clears the Apple Maps association")
    func customPlaceClearsMapAssociation() {
        var draft = VisitDraft(
            applePlaceID: "apple-place-123",
            resolvedMapPlaceName: "Dama"
        )

        draft.useCustomPlace()
        draft.placeName = "  My neighborhood spot  "
        let visit = Visit(draft: draft)

        #expect(visit.applePlaceID == nil)
        #expect(visit.userDefinedPlaceName == "My neighborhood spot")
    }

    @Test("Applying an edit updates the visit")
    func applyingEditUpdatesVisit() {
        let originalDate = Date(timeIntervalSince1970: 1_000)
        let editedDate = Date(timeIntervalSince1970: 2_000)
        let updateDate = Date(timeIntervalSince1970: 3_000)
        let visit = Visit(
            visitedAt: originalDate,
            userDefinedPlaceName: "Original"
        )

        visit.apply(
            VisitDraft(
                placeName: " Edited ",
                visitedAt: editedDate,
                rating: 4,
                notes: " Worth returning "
            ),
            now: updateDate
        )

        #expect(visit.userDefinedPlaceName == "Edited")
        #expect(visit.visitedAt == editedDate)
        #expect(visit.rating == 4)
        #expect(visit.notes == "Worth returning")
        #expect(visit.updatedAt == updateDate)
    }

    @MainActor
    @Test("Visits persist in a SwiftData container")
    func visitPersists() throws {
        let schema = Schema([Visit.self, VisitPhoto.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            configurations: configuration
        )
        let context = container.mainContext
        context.insert(
            Visit(
                visitedAt: Date(timeIntervalSince1970: 1_000),
                userDefinedPlaceName: "Dama",
                rating: 5
            )
        )
        try context.save()

        let visits = try context.fetch(FetchDescriptor<Visit>())

        #expect(visits.count == 1)
        #expect(visits.first?.userDefinedPlaceName == "Dama")
        #expect(visits.first?.rating == 5)
    }

    @MainActor
    @Test("Journal backup round-trips visit metadata without copying photo pixels")
    func journalBackupRoundTrips() throws {
        let visit = Visit(
            visitedAt: Date(timeIntervalSince1970: 1_000),
            latitude: 40.7419,
            longitude: -73.9898,
            applePlaceID: "apple-place-123",
            rating: 5,
            notes: "Great pizza"
        )
        visit.foodCategories = ["Pizza", "Date night"]
        visit.photos = [
            VisitPhoto(
                assetLocalIdentifier: "photo-reference",
                capturedAt: Date(timeIntervalSince1970: 900),
                latitude: 40.7419,
                longitude: -73.9898,
                classificationLabels: ["Pizza"],
                isPrimary: true
            )
        ]
        let archive = JournalBackupArchive(
            visits: [visit],
            createdAt: Date(timeIntervalSince1970: 2_000)
        )

        let data = try JSONEncoder().encode(archive)
        let restored = try JSONDecoder().decode(JournalBackupArchive.self, from: data)

        #expect(restored == archive)
        #expect(restored.visits.first?.foodCategories == ["Pizza", "Date night"])
        #expect(restored.visits.first?.photos.first?.assetLocalIdentifier == "photo-reference")
    }

    @MainActor
    @Test("Restoring a backup merges missing visits and keeps newer local edits")
    func journalBackupRestoreMergesSafely() throws {
        let schema = Schema([Visit.self, VisitPhoto.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = container.mainContext
        let existingID = UUID()
        let missingID = UUID()
        let localVisit = Visit(
            id: existingID,
            visitedAt: Date(timeIntervalSince1970: 1_000),
            userDefinedPlaceName: "Newer local name",
            createdAt: Date(timeIntervalSince1970: 500),
            updatedAt: Date(timeIntervalSince1970: 3_000)
        )
        context.insert(localVisit)
        try context.save()

        let archive = JournalBackupArchive(
            version: JournalBackupArchive.currentVersion,
            createdAt: Date(timeIntervalSince1970: 4_000),
            visits: [
                .init(
                    id: existingID,
                    visitedAt: Date(timeIntervalSince1970: 1_000),
                    userDefinedPlaceName: "Older backup name",
                    createdAt: Date(timeIntervalSince1970: 500),
                    updatedAt: Date(timeIntervalSince1970: 2_000)
                ),
                .init(
                    id: missingID,
                    visitedAt: Date(timeIntervalSince1970: 2_000),
                    userDefinedPlaceName: "Restored pizzeria",
                    foodCategories: ["Pizza"],
                    createdAt: Date(timeIntervalSince1970: 2_000),
                    updatedAt: Date(timeIntervalSince1970: 2_000),
                    photos: [.init(assetLocalIdentifier: "restored-photo", isPrimary: true)]
                ),
            ]
        )

        let changedCount = try JournalBackupOperations.merge(archive, into: context)
        let restoredVisits = try context.fetch(FetchDescriptor<Visit>())
        let visitsByID = Dictionary(uniqueKeysWithValues: restoredVisits.map { ($0.id, $0) })

        #expect(changedCount == 1)
        #expect(visitsByID[existingID]?.userDefinedPlaceName == "Newer local name")
        #expect(visitsByID[missingID]?.userDefinedPlaceName == "Restored pizzeria")
        #expect(visitsByID[missingID]?.foodCategories == ["Pizza"])
        #expect(visitsByID[missingID]?.photos.first?.assetLocalIdentifier == "restored-photo")
    }

    @Test("An imported candidate persists its local photo references and evidence")
    func importedCandidateCreatesVisit() {
        let capturedAt = Date(timeIntervalSince1970: 5_000)
        let candidate = DetectedVisitCandidate(
            id: "photo-1",
            visitedAt: capturedAt,
            latitude: 40.7128,
            longitude: -74.006,
            photos: [
                VisitPhotoDraft(
                    assetLocalIdentifier: "photo-1",
                    capturedAt: capturedAt,
                    latitude: 40.7128,
                    longitude: -74.006,
                    classificationLabels: ["Pizza"],
                    isPrimary: true
                )
            ],
            foodCategories: ["Pizza"]
        )
        var draft = VisitDraft(candidate: candidate)
        draft.placeName = "Neighborhood Pizza"

        let visit = Visit(draft: draft)

        #expect(visit.latitude == 40.7128)
        #expect(visit.longitude == -74.006)
        #expect(visit.foodCategories == ["Pizza"])
        #expect(visit.photos.map(\.assetLocalIdentifier) == ["photo-1"])
        #expect(visit.photos.first?.isPrimary == true)
    }

    @Test("A pending match preserves the candidate until review")
    func pendingVisitRoundTripsCandidate() {
        let capturedAt = Date(timeIntervalSince1970: 5_000)
        let candidate = DetectedVisitCandidate(
            id: "photo-1",
            visitedAt: capturedAt,
            latitude: 40.7128,
            longitude: -74.006,
            photos: [
                VisitPhotoDraft(
                    assetLocalIdentifier: "photo-1",
                    capturedAt: capturedAt,
                    latitude: 40.7128,
                    longitude: -74.006,
                    classificationLabels: ["Pizza"],
                    isPrimary: true
                )
            ],
            foodCategories: ["Pizza"]
        )

        let restored = PendingVisit(candidate: candidate).candidate

        #expect(restored == candidate)
    }

    @Test("Manually selected photos are deduplicated and keep their metadata")
    func manualPhotosAreAddedToDraft() {
        let capturedAt = Date(timeIntervalSince1970: 7_000)
        let reference = VisitPhotoDraft(
            assetLocalIdentifier: "gallery-photo",
            capturedAt: capturedAt,
            latitude: 40.7419,
            longitude: -73.9898,
            classificationLabels: [],
            isPrimary: false
        )
        var draft = VisitDraft(placeName: "Eataly")

        let firstAddedCount = draft.addPhotoReferences([reference])
        let duplicateAddedCount = draft.addPhotoReferences([reference])

        #expect(firstAddedCount == 1)
        #expect(duplicateAddedCount == 0)
        #expect(draft.photos.count == 1)
        #expect(draft.photos.first?.capturedAt == capturedAt)
        #expect(draft.photos.first?.latitude == 40.7419)
        #expect(draft.photos.first?.isPrimary == true)
    }

    @Test("Adding a gallery photo while editing persists its reference")
    func editedVisitAddsPhotoReference() {
        let visit = Visit(
            visitedAt: Date(timeIntervalSince1970: 1_000),
            userDefinedPlaceName: "Eataly"
        )
        var draft = VisitDraft(visit: visit)
        draft.addPhotoReferences([
            VisitPhotoDraft(
                assetLocalIdentifier: "gallery-photo",
                capturedAt: Date(timeIntervalSince1970: 900),
                latitude: nil,
                longitude: nil,
                classificationLabels: [],
                isPrimary: false
            )
        ])

        visit.apply(draft)

        #expect(visit.photos.map(\.assetLocalIdentifier) == ["gallery-photo"])
    }

    @Test("A manually selected photo supplies visit date, GPS, and food evidence")
    func manualPhotoAnalysisInfersVisitMetadata() {
        let capturedAt = Date(timeIntervalSince1970: 8_000)
        let analysis = ManualPhotoAnalysisResult(
            photos: [
                VisitPhotoDraft(
                    assetLocalIdentifier: "pizza-photo",
                    capturedAt: capturedAt,
                    latitude: 40.7417,
                    longitude: -73.9897,
                    classificationLabels: ["Pizza"],
                    isPrimary: false
                )
            ],
            visitedAt: capturedAt,
            latitude: 40.7417,
            longitude: -73.9897,
            foodCategories: ["Pizza"]
        )
        var draft = VisitDraft(visitedAt: Date(timeIntervalSince1970: 1_000))

        let addedCount = draft.addManualPhotoAnalysis(
            analysis,
            inferVisitMetadata: true
        )

        #expect(addedCount == 1)
        #expect(draft.visitedAt == capturedAt)
        #expect(draft.latitude == 40.7417)
        #expect(draft.longitude == -73.9897)
        #expect(draft.foodCategories == ["Pizza"])
        #expect(draft.photos.first?.classificationLabels == ["Pizza"])
        #expect(draft.photos.first?.isPrimary == true)
    }

    @Test("A photo without GPS does not erase an existing draft coordinate")
    func missingManualPhotoGPSIsSafe() {
        let analysis = ManualPhotoAnalysisResult(
            photos: [
                VisitPhotoDraft(
                    assetLocalIdentifier: "no-gps-photo",
                    capturedAt: nil,
                    latitude: nil,
                    longitude: nil,
                    classificationLabels: ["Sushi"],
                    isPrimary: false
                )
            ],
            visitedAt: nil,
            latitude: nil,
            longitude: nil,
            foodCategories: ["Sushi"]
        )
        var draft = VisitDraft(latitude: 40.0, longitude: -73.0)

        draft.addManualPhotoAnalysis(analysis, inferVisitMetadata: true)

        #expect(draft.latitude == 40.0)
        #expect(draft.longitude == -73.0)
        #expect(draft.foodCategories == ["Sushi"])
    }

    @Test("Tags can be normalized, added, deduplicated, and removed")
    func tagsCanBeEdited() {
        var draft = VisitDraft(foodCategories: ["Sushi"])

        let addedPizza = draft.addTag("  pizza  ")
        let addedDuplicatePizza = draft.addTag("PIZZA")
        let addedDateNight = draft.addTag("date   night")
        draft.removeTag("sUsHi")

        #expect(addedPizza)
        #expect(!addedDuplicatePizza)
        #expect(addedDateNight)
        #expect(draft.foodCategories == ["Pizza", "Date night"])
    }
}

struct RestaurantIndexTests {
    @Test("Restaurant filter offers only specific food and drink tags")
    func restaurantFilterExcludesContextAndCustomTags() {
        let taggedVisit = visit(
            placeID: "pizza-place",
            date: 1_000,
            rating: 5,
            tags: [
                "Pizza",
                "Beer",
                "Food",
                "Menu",
                "Receipt",
                "Restaurant interior",
                "Date night",
            ]
        )

        let entries = RestaurantIndex.entries(from: [taggedVisit])
        let tagCounts = RestaurantIndex.tagCounts(from: entries)

        #expect(entries.first?.tags == ["Beer", "Pizza"])
        #expect(tagCounts.map(\.tag) == ["Beer", "Pizza"])
    }

    @Test("Restaurants are grouped and filtered by tag without counting repeat visits twice")
    func restaurantsGroupAndFilterByTag() {
        let recentPizza = visit(
            placeID: "pizza-place",
            date: 3_000,
            rating: 5,
            tags: ["Pizza", "Date night"]
        )
        let olderPizza = visit(
            placeID: "pizza-place",
            date: 1_000,
            rating: 3,
            tags: ["Pizza"]
        )
        let sushi = visit(
            placeID: "sushi-place",
            date: 2_000,
            rating: 4,
            tags: ["Sushi"]
        )

        let allEntries = RestaurantIndex.entries(
            from: [olderPizza, sushi, recentPizza]
        )
        let pizzaEntries = RestaurantIndex.entries(
            from: [olderPizza, sushi, recentPizza],
            matching: "pizza"
        )
        let tagCounts = RestaurantIndex.tagCounts(from: allEntries)

        #expect(allEntries.count == 2)
        #expect(pizzaEntries.count == 1)
        #expect(pizzaEntries.first?.visitCount == 2)
        #expect(pizzaEntries.first?.representativeVisit === recentPizza)
        #expect(tagCounts.first(where: { $0.tag == "Pizza" })?.count == 1)
    }

    @Test("Restaurant index supports recent, visit-count, and rating sorts")
    func restaurantSortOrders() {
        let frequentlyVisited = visit(
            placeID: "frequent",
            date: 1_000,
            rating: 3,
            tags: ["Pizza"]
        )
        let frequentSecondVisit = visit(
            placeID: "frequent",
            date: 2_000,
            rating: 3,
            tags: ["Pizza"]
        )
        let newestAndHighestRated = visit(
            placeID: "newest",
            date: 4_000,
            rating: 5,
            tags: ["Sushi"]
        )
        let visits = [frequentlyVisited, frequentSecondVisit, newestAndHighestRated]

        let recent = RestaurantIndex.entries(from: visits, sortedBy: .mostRecent)
        let mostVisited = RestaurantIndex.entries(from: visits, sortedBy: .mostVisited)
        let highestRated = RestaurantIndex.entries(from: visits, sortedBy: .highestRated)

        #expect(recent.first?.representativeVisit.applePlaceID == "newest")
        #expect(mostVisited.first?.representativeVisit.applePlaceID == "frequent")
        #expect(highestRated.first?.representativeVisit.applePlaceID == "newest")
    }

    private func visit(
        placeID: String,
        date: TimeInterval,
        rating: Int,
        tags: [String]
    ) -> Visit {
        let visit = Visit(
            visitedAt: Date(timeIntervalSince1970: date),
            applePlaceID: placeID,
            rating: rating
        )
        visit.foodCategories = tags
        return visit
    }
}

struct RestaurantProximityRankingTests {
    @Test("Manual name searches do not exclude venues by Apple Maps category")
    @MainActor
    func manualSearchDoesNotUseRestaurantCategoryFilter() {
        let center = CLLocationCoordinate2D(latitude: 40.7419, longitude: -73.9898)
        let request = RestaurantSearchRequestFactory.manualSearch(
            query: "Restaurant X",
            near: center
        )

        #expect(request.naturalLanguageQuery == "Restaurant X")
        #expect(request.resultTypes == .pointOfInterest)
        #expect(request.pointOfInterestFilter == nil)
        #expect(request.region.center.latitude == center.latitude)
        #expect(request.region.center.longitude == center.longitude)
    }

    @Test("Restaurant addresses are trimmed for visit display")
    func addressIsNormalized() {
        let restaurant = result(
            id: "eataly",
            name: "Eataly NYC Flatiron",
            latitude: 40.7417,
            longitude: -73.9897,
            subtitle: "  200 Fifth Avenue, New York, NY  "
        )

        #expect(restaurant.displayAddress == "200 Fifth Avenue, New York, NY")
    }

    @Test("Nearby restaurant suggestions are ordered by photo distance")
    func nearestCandidateComesFirst() {
        let photoCoordinate = CLLocationCoordinate2D(
            latitude: 40.7419,
            longitude: -73.9898
        )
        let farther = result(
            id: "farther",
            name: "Farther Restaurant",
            latitude: 40.7484,
            longitude: -73.9857
        )
        let eataly = result(
            id: "eataly",
            name: "Eataly NYC Flatiron",
            latitude: 40.7417,
            longitude: -73.9897
        )

        let ranked = RestaurantProximityRanking.rank(
            [farther, eataly],
            near: photoCoordinate,
            limit: 5
        )

        #expect(ranked.map(\.placeID) == ["eataly", "farther"])
    }

    @Test("Nearby suggestions are capped")
    func suggestionsAreCapped() {
        let photoCoordinate = CLLocationCoordinate2D(latitude: 40.7419, longitude: -73.9898)
        let candidates = (0..<8).map { index in
            result(
                id: "place-\(index)",
                name: "Place \(index)",
                latitude: 40.7419 + Double(index) * 0.0001,
                longitude: -73.9898
            )
        }

        let ranked = RestaurantProximityRanking.rank(
            candidates,
            near: photoCoordinate,
            limit: 5
        )

        #expect(ranked.count == 5)
    }

    private func result(
        id: String,
        name: String,
        latitude: Double,
        longitude: Double,
        subtitle: String? = nil,
        placeKind: RestaurantPlaceKind = .restaurant,
        foodHints: Set<FoodCategory> = []
    ) -> RestaurantSearchResult {
        RestaurantSearchResult(
            placeID: id,
            name: name,
            subtitle: subtitle,
            latitude: latitude,
            longitude: longitude,
            placeKind: placeKind,
            foodHints: foodHints
        )
    }
}

struct RestaurantCandidateRankingTests {
    private let photoCoordinate = CLLocationCoordinate2D(
        latitude: 40.7419,
        longitude: -73.9898
    )

    @Test("A pizza restaurant outranks a closer generic restaurant for a pizza photo")
    func pizzaCompatibilityOutranksSmallDistanceDifference() {
        let generic = result(
            id: "generic",
            name: "The Dining Room",
            latitude: 40.7419,
            longitude: -73.9898
        )
        let pizza = result(
            id: "pizza",
            name: "Joe's Pizza",
            latitude: 40.7425,
            longitude: -73.9898
        )

        let ranked = RestaurantCandidateRanking.rank(
            [generic, pizza],
            near: photoCoordinate,
            foodCategories: [.pizza],
            limit: 5
        )

        #expect(ranked.map(\.result.placeID) == ["pizza", "generic"])
        #expect(ranked.first?.matchPercentage != nil)
    }

    @Test("Apple Maps food search relevance can boost a restaurant with an ambiguous name")
    func mapFoodHintBoostsAmbiguousName() {
        let eataly = result(
            id: "eataly",
            name: "Eataly NYC Flatiron",
            latitude: 40.7422,
            longitude: -73.9898,
            foodHints: [.pizza]
        )
        let generic = result(
            id: "generic",
            name: "The Dining Room",
            latitude: 40.7419,
            longitude: -73.9898
        )

        let ranked = RestaurantCandidateRanking.rank(
            [generic, eataly],
            near: photoCoordinate,
            foodCategories: [.pizza],
            limit: 5
        )

        #expect(ranked.first?.result.placeID == "eataly")
        #expect((ranked.first?.score.foodCompatibilityScore ?? 0) > 0.9)
    }

    @Test("Negative evidence lowers a bakery for a savory pizza photo")
    func bakeryReceivesNegativeEvidence() {
        let bakery = result(
            id: "bakery",
            name: "Corner Bakery",
            latitude: 40.7419,
            longitude: -73.9898,
            placeKind: .bakery
        )
        let pizza = result(
            id: "pizza",
            name: "Neighborhood Pizza",
            latitude: 40.7428,
            longitude: -73.9898
        )

        let ranked = RestaurantCandidateRanking.rank(
            [bakery, pizza],
            near: photoCoordinate,
            foodCategories: [.pizza],
            limit: 5
        )

        #expect(ranked.first?.result.placeID == "pizza")
        #expect(ranked.last?.score.negativeEvidenceScore ?? 0 > 0)
    }

    @Test("Missing food evidence keeps distance ordering and hides the match percentage")
    func noFoodEvidenceFallsBackToDistance() {
        let nearby = result(
            id: "nearby",
            name: "Nearby",
            latitude: 40.7419,
            longitude: -73.9898
        )
        let fartherPizza = result(
            id: "pizza",
            name: "Pizza Place",
            latitude: 40.75,
            longitude: -73.9898
        )

        let ranked = RestaurantCandidateRanking.rank(
            [fartherPizza, nearby],
            near: photoCoordinate,
            foodCategories: [.meal, .menu],
            limit: 5
        )

        #expect(ranked.map(\.result.placeID) == ["nearby", "pizza"])
        #expect(ranked.allSatisfy { $0.matchPercentage == nil })
    }

    @Test("Match scores are bounded and rounded to five percent steps")
    func matchScoresAvoidFalsePrecision() {
        let pizza = result(
            id: "pizza",
            name: "Pizza Place",
            latitude: 40.743,
            longitude: -73.9898
        )

        let matchPercentage = RestaurantCandidateRanking.rank(
            [pizza],
            near: photoCoordinate,
            foodCategories: [.pizza],
            limit: 1
        ).first?.matchPercentage

        #expect(matchPercentage != nil)
        #expect((0...95).contains(matchPercentage ?? -1))
        #expect((matchPercentage ?? -1).isMultiple(of: 5))
    }

    private func result(
        id: String,
        name: String,
        latitude: Double,
        longitude: Double,
        placeKind: RestaurantPlaceKind = .restaurant,
        foodHints: Set<FoodCategory> = []
    ) -> RestaurantSearchResult {
        RestaurantSearchResult(
            placeID: id,
            name: name,
            subtitle: nil,
            latitude: latitude,
            longitude: longitude,
            placeKind: placeKind,
            foodHints: foodHints
        )
    }
}

struct VisitPhotoMapMarkerTests {
    @Test("Photo map markers use each photo's GPS coordinate")
    func markersUsePhotoCoordinates() {
        let visit = Visit(
            visitedAt: Date(timeIntervalSince1970: 1_000),
            userDefinedPlaceName: "Eataly"
        )
        visit.photos = [
            VisitPhoto(
                assetLocalIdentifier: "located-photo",
                latitude: 40.7417,
                longitude: -73.9897,
                isPrimary: true
            ),
            VisitPhoto(assetLocalIdentifier: "missing-location"),
            VisitPhoto(
                assetLocalIdentifier: "invalid-location",
                latitude: 200,
                longitude: -73.9897
            ),
        ]

        let markers = VisitPhotoMapMarker.markers(from: [visit])

        #expect(markers.map(\.assetIdentifier) == ["located-photo"])
        #expect(markers.first?.coordinate.latitude == 40.7417)
        #expect(markers.first?.coordinate.longitude == -73.9897)
        #expect(markers.first?.visit === visit)
    }
}
