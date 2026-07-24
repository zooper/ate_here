import Foundation
import SwiftData
import Testing
import UIKit
@testable import AteHere

struct VisitClusteringServiceTests {
    private let service = VisitClusteringService()

    @Test("Nearby photos within ninety minutes form one visit")
    func nearbyPhotosStayTogether() {
        let photos = [
            photo("one", minute: 0, latitude: 40.7128, longitude: -74.0060),
            photo("two", minute: 45, latitude: 40.7129, longitude: -74.0061),
        ]

        #expect(service.clusters(from: photos).map(\.count) == [2])
    }

    @Test("A long time gap splits visits")
    func timeGapSplitsVisits() {
        let photos = [
            photo("one", minute: 0),
            photo("two", minute: 91),
        ]

        #expect(service.clusters(from: photos).map(\.count) == [1, 1])
    }

    @Test("A major location change splits visits")
    func locationChangeSplitsVisits() {
        let photos = [
            photo("one", minute: 0, latitude: 40.7128, longitude: -74.0060),
            photo("two", minute: 10, latitude: 40.7306, longitude: -73.9866),
        ]

        #expect(service.clusters(from: photos).map(\.count) == [1, 1])
    }

    @Test("Missing coordinates do not exclude a photo")
    func missingCoordinatesStayEligible() {
        let photos = [
            photo("one", minute: 0, latitude: 40.7128, longitude: -74.0060),
            photo("two", minute: 20),
        ]

        #expect(service.clusters(from: photos).map(\.count) == [2])
    }

    private func photo(
        _ id: String,
        minute: TimeInterval,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) -> PhotoMetadata {
        PhotoMetadata(
            assetIdentifier: id,
            capturedAt: Date(timeIntervalSince1970: minute * 60),
            latitude: latitude,
            longitude: longitude
        )
    }
}

struct PhotoImportScannerFilteringTests {
    @MainActor
    @Test("Clusters without food evidence are excluded")
    func nonFoodClusterIsExcluded() async throws {
        let photos = [
            photo("dog", minute: 0),
            photo("scenery", minute: 10),
        ]
        let scanner = PhotoImportScanner(
            photoLibraryService: StubPhotoLibraryService(
                photos: photos,
                foodAssetIdentifiers: []
            ),
            photoAnalysisService: ImageWidthPhotoAnalysisService()
        )

        let candidates = try await scanner.scan(
            excludingAssetIdentifiers: [],
            now: Date(timeIntervalSince1970: 20 * 60)
        )

        #expect(candidates.isEmpty)
    }

    @MainActor
    @Test("Only food-matching photos appear in an imported candidate")
    func onlyMatchingPhotosAreIncluded() async throws {
        let photos = [
            photo("food", minute: 0),
            photo("dog", minute: 10),
        ]
        let scanner = PhotoImportScanner(
            photoLibraryService: StubPhotoLibraryService(
                photos: photos,
                foodAssetIdentifiers: ["food"]
            ),
            photoAnalysisService: ImageWidthPhotoAnalysisService()
        )

        let candidates = try await scanner.scan(
            excludingAssetIdentifiers: [],
            now: Date(timeIntervalSince1970: 20 * 60)
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?.photos.map(\.assetLocalIdentifier) == ["food"])
        #expect(candidates.first?.foodCategories == ["Pizza"])
    }

    private func photo(_ id: String, minute: TimeInterval) -> PhotoMetadata {
        PhotoMetadata(
            assetIdentifier: id,
            capturedAt: Date(timeIntervalSince1970: minute * 60),
            latitude: 40.7419,
            longitude: -73.9898
        )
    }
}

struct AutomaticPhotoScanServiceTests {
    @Test("Home exclusion contains nearby candidates but not distant or unlocated candidates")
    func homeExclusionUsesCandidateLocation() {
        let region = HomeExclusionRegion(
            latitude: 40.7419,
            longitude: -73.9898,
            radiusMeters: 200
        )
        let nearby = candidate(latitude: 40.7420, longitude: -73.9897)
        let distant = candidate(latitude: 40.7520, longitude: -73.9898)
        let unlocated = candidate(latitude: nil, longitude: nil)

        #expect(region.contains(nearby))
        #expect(!region.contains(distant))
        #expect(!region.contains(unlocated))
    }

    @Test("Home exclusion settings round-trip locally and respect the enabled state")
    func homeExclusionSettingsRoundTrip() throws {
        let suiteName = "HomeExclusionSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let region = HomeExclusionRegion(
            latitude: 40.7419,
            longitude: -73.9898,
            radiusMeters: 300
        )

        HomeExclusionSettings.save(region, userDefaults: defaults)

        #expect(HomeExclusionSettings.configuredRegion(userDefaults: defaults) == region)
        #expect(HomeExclusionSettings.activeRegion(userDefaults: defaults) == region)

        defaults.set(false, forKey: HomeExclusionSettings.enabledKey)
        #expect(HomeExclusionSettings.activeRegion(userDefaults: defaults) == nil)

        HomeExclusionSettings.remove(userDefaults: defaults)
        #expect(HomeExclusionSettings.configuredRegion(userDefaults: defaults) == nil)
    }

    @Test("Later automatic scans start near the previous scan instead of rescanning thirty days")
    func laterScanUsesWatermark() {
        let now = Date(timeIntervalSince1970: 10_000)
        let lastScan = Date(timeIntervalSince1970: 8_000)

        let startDate = AutomaticPhotoScanSettings.scanStartDate(
            now: now,
            lastScanDate: lastScan,
            lookbackDays: 30
        )

        #expect(startDate == lastScan.addingTimeInterval(-60))
    }

    @MainActor
    @Test("Automatic scanning stores a food match in the review inbox")
    func scanStoresPendingVisit() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let photo = PhotoMetadata(
            assetIdentifier: "food",
            capturedAt: Date(timeIntervalSince1970: 60),
            latitude: 40.7419,
            longitude: -73.9898
        )
        let service = AutomaticPhotoScanService(
            photoLibraryService: StubPhotoLibraryService(
                photos: [photo],
                foodAssetIdentifiers: ["food"]
            ),
            photoAnalysisService: ImageWidthPhotoAnalysisService()
        )

        let addedCount = try await service.scan(
            into: context,
            now: Date(timeIntervalSince1970: 120)
        )
        let pendingVisits = try context.fetch(FetchDescriptor<PendingVisit>())

        #expect(addedCount == 1)
        #expect(pendingVisits.count == 1)
        #expect(pendingVisits.first?.photos.map(\.assetLocalIdentifier) == ["food"])
        #expect(pendingVisits.first?.foodCategories == ["Pizza"])
    }

    @MainActor
    @Test("A later photo from the same meal extends the pending visit")
    func laterPhotoExtendsPendingVisit() async throws {
        let defaults = UserDefaults.standard
        let lastScanKey = AutomaticPhotoScanSettings.lastScanDateKey
        let originalLastScanDate = defaults.object(forKey: lastScanKey)
        defaults.removeObject(forKey: lastScanKey)
        defer {
            if let originalLastScanDate {
                defaults.set(originalLastScanDate, forKey: lastScanKey)
            } else {
                defaults.removeObject(forKey: lastScanKey)
            }
        }

        let container = try makeContainer()
        let context = container.mainContext
        let mealStart = Date(timeIntervalSince1970: 10_000)
        let library = MutableStubPhotoLibraryService(
            photos: [
                PhotoMetadata(
                    assetIdentifier: "first-food-photo",
                    capturedAt: mealStart,
                    latitude: 40.7419,
                    longitude: -73.9898
                ),
            ]
        )
        let service = AutomaticPhotoScanService(
            photoLibraryService: library,
            photoAnalysisService: ImageWidthPhotoAnalysisService()
        )

        let firstAddedCount = try await service.scan(
            into: context,
            now: mealStart.addingTimeInterval(60)
        )
        library.photos.append(
            PhotoMetadata(
                assetIdentifier: "second-food-photo",
                capturedAt: mealStart.addingTimeInterval(10 * 60),
                latitude: 40.7419,
                longitude: -73.9898
            )
        )
        let secondAddedCount = try await service.scan(
            into: context,
            now: mealStart.addingTimeInterval(11 * 60)
        )
        let pendingVisits = try context.fetch(FetchDescriptor<PendingVisit>())

        #expect(firstAddedCount == 1)
        #expect(secondAddedCount == 0)
        #expect(pendingVisits.count == 1)
        #expect(
            Set(pendingVisits.first?.photos.map(\.assetLocalIdentifier) ?? [])
                == ["first-food-photo", "second-food-photo"]
        )
    }

    @MainActor
    @Test("Existing split suggestions from one meal are coalesced")
    func existingSplitSuggestionsAreCoalesced() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let mealStart = Date(timeIntervalSince1970: 20_000)
        context.insert(
            PendingVisit(
                candidate: foodCandidate(
                    id: "first-food-photo",
                    capturedAt: mealStart
                )
            )
        )
        context.insert(
            PendingVisit(
                candidate: foodCandidate(
                    id: "second-food-photo",
                    capturedAt: mealStart.addingTimeInterval(10 * 60)
                )
            )
        )
        try context.save()
        let service = AutomaticPhotoScanService(
            photoLibraryService: MutableStubPhotoLibraryService(photos: []),
            photoAnalysisService: ImageWidthPhotoAnalysisService()
        )

        let addedCount = try await service.scan(
            into: context,
            now: mealStart.addingTimeInterval(24 * 60 * 60)
        )
        let pendingVisits = try context.fetch(FetchDescriptor<PendingVisit>())

        #expect(addedCount == 0)
        #expect(pendingVisits.count == 1)
        #expect(
            Set(pendingVisits.first?.photos.map(\.assetLocalIdentifier) ?? [])
                == ["first-food-photo", "second-food-photo"]
        )
    }

    @MainActor
    @Test("A manual merge combines the selected suggestions regardless of distance")
    func manualMergeCombinesSelectedSuggestions() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let first = PendingVisit(
            candidate: foodCandidate(
                id: "restaurant-photo",
                capturedAt: Date(timeIntervalSince1970: 30_000),
                latitude: 40.7419,
                longitude: -73.9898,
                foodCategory: "Pizza"
            )
        )
        let second = PendingVisit(
            candidate: foodCandidate(
                id: "late-photo",
                capturedAt: Date(timeIntervalSince1970: 30_000 + 4 * 60 * 60),
                latitude: 40.8519,
                longitude: -73.8898,
                foodCategory: "Dessert"
            )
        )
        let untouched = PendingVisit(
            candidate: foodCandidate(
                id: "another-visit",
                capturedAt: Date(timeIntervalSince1970: 60_000),
                latitude: 41.0,
                longitude: -74.0,
                foodCategory: "Sushi"
            )
        )
        context.insert(first)
        context.insert(second)
        context.insert(untouched)
        try context.save()

        let mergedVisit = try PendingVisitMergeService.merge(
            visitIDs: [first.id, second.id],
            from: [first, second, untouched],
            in: context
        )
        let pendingVisits = try context.fetch(FetchDescriptor<PendingVisit>())

        #expect(mergedVisit === first)
        #expect(pendingVisits.count == 2)
        #expect(
            Set(mergedVisit?.photos.map(\.assetLocalIdentifier) ?? [])
                == ["restaurant-photo", "late-photo"]
        )
        #expect(mergedVisit?.foodCategories == ["Dessert", "Pizza"])
        #expect(pendingVisits.contains { $0.id == untouched.id })
        #expect(mergedVisit?.photos.filter(\.isPrimary).count == 1)
    }

    @MainActor
    @Test("Automatic scanning does not suggest food photographed at home")
    func homeFoodIsNotSuggested() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let photo = PhotoMetadata(
            assetIdentifier: "home-food",
            capturedAt: Date(timeIntervalSince1970: 60),
            latitude: 40.7419,
            longitude: -73.9898
        )
        let service = AutomaticPhotoScanService(
            photoLibraryService: StubPhotoLibraryService(
                photos: [photo],
                foodAssetIdentifiers: ["home-food"]
            ),
            photoAnalysisService: ImageWidthPhotoAnalysisService(),
            homeExclusionRegion: HomeExclusionRegion(
                latitude: 40.7419,
                longitude: -73.9898,
                radiusMeters: 200
            )
        )

        let addedCount = try await service.scan(
            into: context,
            now: Date(timeIntervalSince1970: 120)
        )
        let pendingVisits = try context.fetch(FetchDescriptor<PendingVisit>())

        #expect(addedCount == 0)
        #expect(pendingVisits.isEmpty)
    }

    @MainActor
    @Test("Enabling a home area removes existing home suggestions only")
    func existingHomeSuggestionsAreRemoved() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(
            PendingVisit(
                candidate: candidate(latitude: 40.7419, longitude: -73.9898)
            )
        )
        context.insert(
            PendingVisit(
                candidate: candidate(latitude: 40.7520, longitude: -73.9898)
            )
        )
        try context.save()
        let region = HomeExclusionRegion(
            latitude: 40.7419,
            longitude: -73.9898,
            radiusMeters: 200
        )

        let removedCount = try AutomaticPhotoScanService.removePendingVisits(
            inside: region,
            from: context
        )
        let remainingVisits = try context.fetch(FetchDescriptor<PendingVisit>())

        #expect(removedCount == 1)
        #expect(remainingVisits.count == 1)
        #expect(remainingVisits.first?.latitude == 40.7520)
    }

    @MainActor
    @Test("Dismissed photos stay out of later automatic scans")
    func ignoredPhotoIsNotSuggestedAgain() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(IgnoredPhotoAsset(assetLocalIdentifier: "food"))
        try context.save()
        let photo = PhotoMetadata(
            assetIdentifier: "food",
            capturedAt: Date(timeIntervalSince1970: 60),
            latitude: 40.7419,
            longitude: -73.9898
        )
        let service = AutomaticPhotoScanService(
            photoLibraryService: StubPhotoLibraryService(
                photos: [photo],
                foodAssetIdentifiers: ["food"]
            ),
            photoAnalysisService: ImageWidthPhotoAnalysisService()
        )

        let addedCount = try await service.scan(
            into: context,
            now: Date(timeIntervalSince1970: 120)
        )
        let pendingVisits = try context.fetch(FetchDescriptor<PendingVisit>())

        #expect(addedCount == 0)
        #expect(pendingVisits.isEmpty)
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Visit.self,
            VisitPhoto.self,
            PendingVisit.self,
            PendingVisitPhoto.self,
            IgnoredPhotoAsset.self,
        ])
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        )
    }

    private func candidate(
        latitude: Double?,
        longitude: Double?
    ) -> DetectedVisitCandidate {
        DetectedVisitCandidate(
            id: UUID().uuidString,
            visitedAt: .now,
            latitude: latitude,
            longitude: longitude,
            photos: [],
            foodCategories: ["Pizza"]
        )
    }

    private func foodCandidate(
        id: String,
        capturedAt: Date,
        latitude: Double = 40.7419,
        longitude: Double = -73.9898,
        foodCategory: String = "Pizza"
    ) -> DetectedVisitCandidate {
        DetectedVisitCandidate(
            id: id,
            visitedAt: capturedAt,
            latitude: latitude,
            longitude: longitude,
            photos: [
                VisitPhotoDraft(
                    assetLocalIdentifier: id,
                    capturedAt: capturedAt,
                    latitude: latitude,
                    longitude: longitude,
                    classificationLabels: [foodCategory],
                    isPrimary: true
                ),
            ],
            foodCategories: [foodCategory]
        )
    }
}

private struct StubPhotoLibraryService: PhotoLibraryService {
    let photos: [PhotoMetadata]
    let foodAssetIdentifiers: Set<String>

    @MainActor
    func authorizationStatus() -> PhotoLibraryAccess {
        .full
    }

    @MainActor
    func requestAuthorization() async -> PhotoLibraryAccess {
        .full
    }

    @MainActor
    func recentPhotos(
        since startDate: Date,
        excludingAssetIdentifiers: Set<String>,
        limit: Int
    ) -> [PhotoMetadata] {
        Array(
            photos
                .filter {
                    $0.capturedAt >= startDate
                        && !excludingAssetIdentifiers.contains($0.assetIdentifier)
                }
                .sorted { $0.capturedAt > $1.capturedAt }
                .prefix(limit)
        )
    }

    @MainActor
    func photoReferences(forAssetIdentifiers identifiers: [String]) -> [VisitPhotoDraft] {
        photos
            .filter { identifiers.contains($0.assetIdentifier) }
            .map(photoReference)
    }

    @MainActor
    func accessiblePhotoReferences(limit: Int) -> [VisitPhotoDraft] {
        Array(photos.prefix(limit)).map(photoReference)
    }

    @MainActor
    func image(
        for assetIdentifier: String,
        targetSize: CGSize,
        contentMode: PhotoImageContentMode
    ) async throws -> UIImage {
        let side = foodAssetIdentifiers.contains(assetIdentifier) ? 10.0 : 20.0
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format
        ).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    private func photoReference(_ photo: PhotoMetadata) -> VisitPhotoDraft {
        VisitPhotoDraft(
            assetLocalIdentifier: photo.assetIdentifier,
            capturedAt: photo.capturedAt,
            latitude: photo.latitude,
            longitude: photo.longitude,
            classificationLabels: [],
            isPrimary: false
        )
    }
}

private struct ImageWidthPhotoAnalysisService: PhotoAnalysisService {
    func classifications(for image: CGImage) async throws -> [FoodClassification] {
        guard image.width == 10 else { return [] }
        return [FoodClassification(category: .pizza, confidence: 0.9)]
    }
}

@MainActor
private final class MutableStubPhotoLibraryService: PhotoLibraryService {
    var photos: [PhotoMetadata]

    init(photos: [PhotoMetadata]) {
        self.photos = photos
    }

    func authorizationStatus() -> PhotoLibraryAccess {
        .full
    }

    func requestAuthorization() async -> PhotoLibraryAccess {
        .full
    }

    func recentPhotos(
        since startDate: Date,
        excludingAssetIdentifiers: Set<String>,
        limit: Int
    ) -> [PhotoMetadata] {
        Array(
            photos
                .filter {
                    $0.capturedAt >= startDate
                        && !excludingAssetIdentifiers.contains($0.assetIdentifier)
                }
                .sorted { $0.capturedAt > $1.capturedAt }
                .prefix(limit)
        )
    }

    func photoReferences(forAssetIdentifiers identifiers: [String]) -> [VisitPhotoDraft] {
        photos
            .filter { identifiers.contains($0.assetIdentifier) }
            .map(photoReference)
    }

    func accessiblePhotoReferences(limit: Int) -> [VisitPhotoDraft] {
        Array(photos.prefix(limit)).map(photoReference)
    }

    func image(
        for assetIdentifier: String,
        targetSize: CGSize,
        contentMode: PhotoImageContentMode
    ) async throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(
            size: CGSize(width: 10, height: 10),
            format: format
        ).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
    }

    private func photoReference(_ photo: PhotoMetadata) -> VisitPhotoDraft {
        VisitPhotoDraft(
            assetLocalIdentifier: photo.assetIdentifier,
            capturedAt: photo.capturedAt,
            latitude: photo.latitude,
            longitude: photo.longitude,
            classificationLabels: [],
            isPrimary: false
        )
    }
}
