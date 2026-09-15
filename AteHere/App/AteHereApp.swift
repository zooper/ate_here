import SwiftData
import SwiftUI

@main
struct AteHereApp: App {
    private let modelContainer: ModelContainer?

    init() {
        let isUITesting = ProcessInfo.processInfo.environment["ATE_HERE_UI_TESTING"] == "1"
        if isUITesting {
            HomeExclusionSettings.remove()
            UserDefaults.standard.set(
                false,
                forKey: AutomaticPhotoScanSettings.enabledKey
            )
            UserDefaults.standard.set(
                false,
                forKey: ICloudJournalBackupSettings.enabledKey
            )
        }
        let schema = Schema([
            Visit.self,
            VisitPhoto.self,
            PendingVisit.self,
            PendingVisitPhoto.self,
            IgnoredPhotoAsset.self,
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: isUITesting,
            cloudKitDatabase: .none
        )
        modelContainer = try? ModelContainer(
            for: schema,
            configurations: configuration
        )
        if isUITesting,
           ProcessInfo.processInfo.environment["ATE_HERE_UI_TEST_PENDING_VISITS"] == "1",
           let modelContainer {
            let context = modelContainer.mainContext
            let mealStart = Date(timeIntervalSince1970: 1_750_000_000)
            context.insert(
                PendingVisit(
                    candidate: Self.pendingVisitFixture(
                        id: "first-food-photo",
                        capturedAt: mealStart
                    )
                )
            )
            context.insert(
                PendingVisit(
                    candidate: Self.pendingVisitFixture(
                        id: "second-food-photo",
                        capturedAt: mealStart.addingTimeInterval(10 * 60)
                    )
                )
            )
            try? context.save()
        }
        if isUITesting,
           ProcessInfo.processInfo.environment["ATE_HERE_UI_TEST_JOURNAL_MERGE"] == "1",
           let modelContainer,
           let firstVisitID = UUID(
               uuidString: "00000000-0000-0000-0000-000000000101"
           ),
           let secondVisitID = UUID(
               uuidString: "00000000-0000-0000-0000-000000000102"
           ),
           let thirdVisitID = UUID(
               uuidString: "00000000-0000-0000-0000-000000000103"
           ) {
            let context = modelContainer.mainContext
            let mealStart = Date(timeIntervalSince1970: 1_750_000_000)
            context.insert(
                Self.journalVisitFixture(
                    id: firstVisitID,
                    placeName: "Satis Bistro",
                    visitedAt: mealStart
                )
            )
            context.insert(
                Self.journalVisitFixture(
                    id: secondVisitID,
                    placeName: "Satis Bistro",
                    visitedAt: mealStart.addingTimeInterval(10 * 60),
                    rating: 4
                )
            )
            context.insert(
                Self.journalVisitFixture(
                    id: thirdVisitID,
                    placeName: "Eataly",
                    visitedAt: mealStart.addingTimeInterval(-7 * 24 * 60 * 60)
                )
            )
            try? context.save()
        }
    }

    var body: some Scene {
        WindowGroup {
            if let modelContainer {
                AteHereRootView()
                    .modelContainer(modelContainer)
            } else {
                ContentUnavailableView {
                    Label("Journal unavailable", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("Ate Here couldn’t open its local journal. Close the app and try again.")
                }
            }
        }
        .backgroundTask(
            .appRefresh(AutomaticPhotoScanSettings.backgroundTaskIdentifier)
        ) {
            AutomaticPhotoScanScheduler.scheduleNext()
            await scanForPendingVisitsInBackground()
        }
    }

    @MainActor
    private func scanForPendingVisitsInBackground() async {
        guard
            UserDefaults.standard.bool(forKey: AutomaticPhotoScanSettings.enabledKey),
            let modelContainer
        else {
            return
        }

        let context = ModelContext(modelContainer)
        let service = AutomaticPhotoScanService(
            photoLibraryService: LivePhotoLibraryService(),
            photoAnalysisService: VisionPhotoAnalysisService(),
            homeExclusionRegion: HomeExclusionSettings.activeRegion()
        )
        _ = try? await service.scan(into: context)
    }

    private static func pendingVisitFixture(
        id: String,
        capturedAt: Date
    ) -> DetectedVisitCandidate {
        DetectedVisitCandidate(
            id: id,
            visitedAt: capturedAt,
            latitude: 40.7419,
            longitude: -73.9898,
            photos: [
                VisitPhotoDraft(
                    assetLocalIdentifier: id,
                    capturedAt: capturedAt,
                    latitude: 40.7419,
                    longitude: -73.9898,
                    classificationLabels: ["Pizza"],
                    isPrimary: true
                ),
            ],
            foodCategories: ["Pizza"]
        )
    }

    private static func journalVisitFixture(
        id: UUID,
        placeName: String,
        visitedAt: Date,
        rating: Int? = nil
    ) -> Visit {
        Visit(
            id: id,
            visitedAt: visitedAt,
            userDefinedPlaceName: placeName,
            rating: rating
        )
    }
}

private struct AteHereRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Visit.updatedAt, order: .reverse) private var visits: [Visit]
    @AppStorage(ICloudJournalBackupSettings.enabledKey)
    private var iCloudBackupEnabled = false

    var body: some View {
        AteHereTabView()
            .task(id: backupRevision) {
                guard iCloudBackupEnabled else { return }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                _ = try? await JournalBackupOperations.backUp(context: modelContext)
            }
    }

    private var backupRevision: String {
        guard iCloudBackupEnabled else { return "disabled" }
        return visits.map { visit in
            "\(visit.id.uuidString):\(visit.updatedAt.timeIntervalSince1970):\(visit.photos.count)"
        }
        .joined(separator: "|")
    }
}
