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
