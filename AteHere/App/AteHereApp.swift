import SwiftData
import SwiftUI

@main
struct AteHereApp: App {
    private let modelContainer: ModelContainer?

    init() {
        let isUITesting = ProcessInfo.processInfo.environment["ATE_HERE_UI_TESTING"] == "1"
        if isUITesting {
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
            photoAnalysisService: VisionPhotoAnalysisService()
        )
        _ = try? await service.scan(into: context)
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
                guard iCloudBackupEnabled, !visits.isEmpty else { return }
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
