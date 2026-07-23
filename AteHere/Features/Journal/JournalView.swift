import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import UIKit

enum AlbumTheme {
    static let leather = adaptive(light: 0x1F352D, dark: 0x09110F)
    static let leatherHighlight = adaptive(light: 0x365548, dark: 0x1A2D27)
    static let leatherText = adaptive(light: 0xFFFDF7, dark: 0xF5ECD8)
    static let paper = adaptive(light: 0xF2E7D0, dark: 0x151B18)
    static let paperEdge = adaptive(light: 0xA9946F, dark: 0x68766E)
    static let photoPaper = adaptive(light: 0xFFFDF7, dark: 0x222A26)
    static let ink = adaptive(light: 0x211D18, dark: 0xF5ECD8)
    static let mutedInk = adaptive(light: 0x574D40, dark: 0xC7BBA4)
    static let brass = adaptive(light: 0x765019, dark: 0xE8BC70)
    static let leatherFoil = adaptive(light: 0xE2C184, dark: 0xF0C97F)
    static let mount = adaptive(light: 0x16130F, dark: 0x050806)
    static let burgundy = adaptive(light: 0x7A2832, dark: 0xF2A9AF)

    private static func adaptive(light: Int, dark: Int) -> Color {
        Color(
            uiColor: UIColor { traits in
                makeColor(traits.userInterfaceStyle == .dark ? dark : light)
            }
        )
    }

    private static func makeColor(_ hexadecimal: Int) -> UIColor {
        UIColor(
            red: CGFloat((hexadecimal >> 16) & 0xFF) / 255,
            green: CGFloat((hexadecimal >> 8) & 0xFF) / 255,
            blue: CGFloat(hexadecimal & 0xFF) / 255,
            alpha: 1
        )
    }
}

struct JournalView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Visit.visitedAt, order: .reverse) private var visits: [Visit]
    @Query(sort: \PendingVisit.visitedAt, order: .reverse) private var pendingVisits: [PendingVisit]
    @AppStorage(AutomaticPhotoScanSettings.enabledKey)
    private var automaticScanningEnabled = false

    private let placeSearchService: any PlaceSearchService
    private let photoLibraryService: any PhotoLibraryService
    private let photoAnalysisService: any PhotoAnalysisService

    @State private var isPresentingNewVisit = false
    @State private var isPresentingPhotoImport = false
    @State private var isPresentingPendingVisits = false
    @State private var isPresentingSettings = false
    @State private var automaticScanRequestID = UUID()
    @State private var isAutomaticScanRunning = false

    init(
        placeSearchService: any PlaceSearchService = MapKitPlaceSearchService(),
        photoLibraryService: any PhotoLibraryService = LivePhotoLibraryService(),
        photoAnalysisService: any PhotoAnalysisService = VisionPhotoAnalysisService()
    ) {
        self.placeSearchService = placeSearchService
        self.photoLibraryService = photoLibraryService
        self.photoAnalysisService = photoAnalysisService
    }

    var body: some View {
        NavigationStack {
            Group {
                if visits.isEmpty {
                    emptyJournal
                } else {
                    albumJournal
                }
            }
            .navigationTitle("Ate Here")
            .navigationBarTitleDisplayMode(visits.isEmpty ? .large : .inline)
            .toolbarBackground(AlbumTheme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            isPresentingNewVisit = true
                        } label: {
                            Label("Add visit", systemImage: "square.and.pencil")
                        }

                        Button {
                            isPresentingPhotoImport = true
                        } label: {
                            Label("Import recent photos", systemImage: "photo.on.rectangle.angled")
                        }

                        if !pendingVisits.isEmpty {
                            Button {
                                isPresentingPendingVisits = true
                            } label: {
                                Label(
                                    "Review \(pendingVisits.count) match\(pendingVisits.count == 1 ? "" : "es")",
                                    systemImage: "tray.full"
                                )
                            }
                        }

                        Divider()

                        Button {
                            isPresentingSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isPresentingNewVisit) {
                VisitEditorView(
                    placeSearchService: placeSearchService,
                    photoLibraryService: photoLibraryService
                )
            }
            .sheet(isPresented: $isPresentingPhotoImport) {
                PhotoImportView(
                    placeSearchService: placeSearchService,
                    photoLibraryService: photoLibraryService,
                    photoAnalysisService: photoAnalysisService,
                    configuration: .init()
                )
            }
            .sheet(isPresented: $isPresentingPendingVisits) {
                PendingVisitsView(
                    placeSearchService: placeSearchService,
                    photoLibraryService: photoLibraryService
                )
            }
            .sheet(isPresented: $isPresentingSettings) {
                JournalSettingsView(photoLibraryService: photoLibraryService)
            }
        }
        .tint(AlbumTheme.burgundy)
        .task(id: automaticScanRequestID) {
            await runAutomaticScanIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                automaticScanRequestID = UUID()
            case .background:
                AutomaticPhotoScanScheduler.scheduleNext()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onChange(of: automaticScanningEnabled) { _, enabled in
            if enabled {
                automaticScanRequestID = UUID()
            } else {
                AutomaticPhotoScanScheduler.cancel()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .automaticPhotoScanRequested)) { _ in
            automaticScanRequestID = UUID()
        }
    }

    private var emptyJournal: some View {
        ContentUnavailableView {
            Label("Your table is waiting", systemImage: "fork.knife")
        } description: {
            Text("Add a restaurant visit to begin your private journal.")
        } actions: {
            Button("Add your first visit") {
                isPresentingNewVisit = true
            }
            .buttonStyle(.borderedProminent)

            Button("Import from Photos") {
                isPresentingPhotoImport = true
            }
            .accessibilityIdentifier("importFromPhotos")

            if !pendingVisits.isEmpty {
                Button("Review \(pendingVisits.count) Matches") {
                    isPresentingPendingVisits = true
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AlbumTheme.paper)
        .accessibilityIdentifier("emptyJournal")
    }

    private var albumJournal: some View {
        ScrollView {
            LazyVStack(spacing: 30) {
                AlbumCoverHeader(visits: visits)

                if !pendingVisits.isEmpty {
                    ReviewInboxBanner(
                        count: pendingVisits.count,
                        isScanning: isAutomaticScanRunning
                    ) {
                        isPresentingPendingVisits = true
                    }
                }

                ForEach(albumMonths) { month in
                    AlbumMonthPage(
                        month: month,
                        placeSearchService: placeSearchService,
                        photoLibraryService: photoLibraryService
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 36)
        }
        .background(AlbumTheme.paper)
        .scrollIndicators(.hidden)
    }

    private var albumMonths: [AlbumMonth] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: visits) { visit in
            let components = calendar.dateComponents([.year, .month], from: visit.visitedAt)
            return calendar.date(from: components) ?? calendar.startOfDay(for: visit.visitedAt)
        }

        return grouped.map { monthStart, visits in
            AlbumMonth(
                monthStart: monthStart,
                visits: visits.sorted { $0.visitedAt > $1.visitedAt }
            )
        }
        .sorted { $0.monthStart > $1.monthStart }
    }

    @MainActor
    private func runAutomaticScanIfNeeded() async {
        guard automaticScanningEnabled, !isAutomaticScanRunning else { return }

        isAutomaticScanRunning = true
        defer { isAutomaticScanRunning = false }

        let service = AutomaticPhotoScanService(
            photoLibraryService: photoLibraryService,
            photoAnalysisService: photoAnalysisService,
            homeExclusionRegion: HomeExclusionSettings.activeRegion()
        )
        _ = try? await service.scan(into: modelContext)
        AutomaticPhotoScanScheduler.scheduleNext()
    }
}

private struct ReviewInboxBanner: View {
    let count: Int
    let isScanning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "tray.full")
                    .font(.title2)
                    .foregroundStyle(AlbumTheme.leatherFoil)
                    .frame(width: 42, height: 42)
                    .background(AlbumTheme.leather)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(count) new match\(count == 1 ? "" : "es")")
                        .font(.system(.headline, design: .serif).weight(.semibold))
                    Text("Waiting for you to review")
                        .font(.caption)
                        .foregroundStyle(AlbumTheme.mutedInk)
                }

                Spacer()

                if isScanning {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AlbumTheme.mutedInk)
                }
            }
            .foregroundStyle(AlbumTheme.ink)
            .padding(16)
            .background(AlbumTheme.photoPaper)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AlbumTheme.paperEdge, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reviewMatches")
    }
}

private struct JournalSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query(sort: \Visit.visitedAt, order: .reverse) private var visits: [Visit]
    @AppStorage(AutomaticPhotoScanSettings.enabledKey)
    private var automaticScanningEnabled = false
    @AppStorage(HomeExclusionSettings.enabledKey)
    private var homeExclusionEnabled = false
    @AppStorage(HomeExclusionSettings.hasLocationKey)
    private var hasHomeLocation = false
    @AppStorage(HomeExclusionSettings.radiusKey)
    private var homeExclusionRadius = HomeExclusionSettings.defaultRadiusMeters
    @AppStorage(ICloudJournalBackupSettings.enabledKey)
    private var iCloudBackupEnabled = false
    @AppStorage(ICloudJournalBackupSettings.lastBackupDateKey)
    private var lastBackupTimeInterval = 0.0

    let photoLibraryService: any PhotoLibraryService
    private let backupService: any JournalBackupService = CloudKitJournalBackupService.shared

    @State private var photoAccess: PhotoLibraryAccess = .notDetermined
    @State private var permissionRequestID: UUID?
    @State private var isShowingAccessAlert = false
    @State private var backupEnableRequestID: UUID?
    @State private var backupOperationRequest: BackupOperation?
    @State private var existingBackup: JournalBackupMetadata?
    @State private var isShowingExistingBackupAlert = false
    @State private var isShowingRestoreConfirmation = false
    @State private var backupErrorMessage: String?
    @State private var backupNotice: String?
    @State private var isBackupOperationRunning = false
    @State private var isPresentingHomeAreaPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Automatic photo scanning", isOn: $automaticScanningEnabled)
                        .accessibilityIdentifier("automaticScanningToggle")
                } header: {
                    Text("Photo matching")
                } footer: {
                    Text("When on, Ate Here checks for new food-related photos whenever you open the app and asks iOS for occasional background refresh time. iOS decides when background refresh runs.")
                }

                if automaticScanningEnabled {
                    Section("Review inbox") {
                        Label("Matches wait for your approval", systemImage: "tray.full")
                        Label("Nothing becomes a visit automatically", systemImage: "hand.raised")

                        Button("Scan now") {
                            NotificationCenter.default.post(
                                name: .automaticPhotoScanRequested,
                                object: nil
                            )
                        }
                    }

                    if UIApplication.shared.backgroundRefreshStatus != .available {
                        Section {
                            Label(
                                "Background App Refresh is off. Ate Here will still scan when you open it.",
                                systemImage: "clock.badge.exclamationmark"
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    if hasHomeLocation {
                        Toggle(
                            "Ignore photos taken at home",
                            isOn: $homeExclusionEnabled
                        )
                        .accessibilityIdentifier("homeExclusionToggle")

                        Picker("Home area radius", selection: $homeExclusionRadius) {
                            ForEach(HomeExclusionSettings.availableRadii, id: \.self) { radius in
                                Text("\(Int(radius)) m").tag(radius)
                            }
                        }

                        Button("Adjust Home Area") {
                            isPresentingHomeAreaPicker = true
                        }
                        .accessibilityIdentifier("adjustHomeArea")

                        Button("Remove Home Area", role: .destructive) {
                            HomeExclusionSettings.remove()
                            hasHomeLocation = false
                            homeExclusionEnabled = false
                            homeExclusionRadius = HomeExclusionSettings.defaultRadiusMeters
                        }
                    } else {
                        Button {
                            isPresentingHomeAreaPicker = true
                        } label: {
                            Label("Set Home Area", systemImage: "house")
                        }
                        .accessibilityIdentifier("setHomeArea")
                    }
                } header: {
                    Text("Home area")
                } footer: {
                    Text("Automatic scans ignore located photo groups inside this area. Manual photo import still includes them, and photos without GPS remain eligible.")
                }

                Section {
                    Toggle("Back up journal to iCloud", isOn: iCloudBackupBinding)
                        .accessibilityIdentifier("iCloudBackupToggle")
                        .disabled(isBackupOperationRunning)

                    if iCloudBackupEnabled {
                        Label(backupStatusText, systemImage: "checkmark.icloud")
                            .foregroundStyle(.secondary)

                        Button("Back Up Now") {
                            backupOperationRequest = .backUp
                        }
                        .disabled(isBackupOperationRunning)

                        Button("Restore from iCloud") {
                            isShowingRestoreConfirmation = true
                        }
                        .disabled(isBackupOperationRunning)
                    }

                    if isBackupOperationRunning {
                        HStack {
                            ProgressView()
                            Text("Contacting iCloud…")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let backupNotice {
                        Text(backupNotice)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Journal backup")
                } footer: {
                    Text("When enabled, Ate Here stores visit dates, restaurant references, notes, ratings, tags, coordinates, and photo references in your private iCloud database. Original photos are never uploaded. Turning this off stops future backups but keeps the last backup in iCloud.")
                }

                Section("Privacy") {
                    Label("Analysis stays on this iPhone", systemImage: "iphone")
                    Label("Photos are never uploaded", systemImage: "icloud.slash")
                    Label("iCloud backup is optional", systemImage: "lock.icloud")
                    Label(
                        photoAccess == .limited ? "Selected photos only" : "Limited Photos access supported",
                        systemImage: "photo.on.rectangle"
                    )
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .tint(AlbumTheme.burgundy)
        .task {
            photoAccess = photoLibraryService.authorizationStatus()
        }
        .task(id: permissionRequestID) {
            await configureAutomaticScanningIfNeeded()
        }
        .task(id: backupEnableRequestID) {
            await prepareToEnableICloudBackup()
        }
        .task(id: backupOperationRequest) {
            guard let operation = backupOperationRequest else { return }
            await performBackupOperation(operation)
            backupOperationRequest = nil
        }
        .sheet(isPresented: $isPresentingHomeAreaPicker) {
            HomeAreaPickerView(
                initialRegion: HomeExclusionSettings.configuredRegion()
            ) { region in
                HomeExclusionSettings.save(region)
                removePendingHomeSuggestions(inside: region)
                hasHomeLocation = true
                homeExclusionEnabled = true
                homeExclusionRadius = region.radiusMeters
            }
        }
        .onChange(of: automaticScanningEnabled) { _, enabled in
            if enabled {
                UserDefaults.standard.removeObject(
                    forKey: AutomaticPhotoScanSettings.lastScanDateKey
                )
                permissionRequestID = UUID()
            } else {
                AutomaticPhotoScanScheduler.cancel()
            }
        }
        .onChange(of: homeExclusionEnabled) { _, enabled in
            guard enabled, let region = HomeExclusionSettings.activeRegion() else {
                return
            }
            removePendingHomeSuggestions(inside: region)
        }
        .onChange(of: homeExclusionRadius) { _, _ in
            guard homeExclusionEnabled,
                  let region = HomeExclusionSettings.activeRegion() else {
                return
            }
            removePendingHomeSuggestions(inside: region)
        }
        .alert("Photos access is needed", isPresented: $isShowingAccessAlert) {
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(url)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow selected or full Photos access to use automatic scanning.")
        }
        .alert("An iCloud backup already exists", isPresented: $isShowingExistingBackupAlert) {
            Button("Restore and Enable") {
                backupOperationRequest = .restoreAndEnable
            }
            Button("Replace iCloud Backup", role: .destructive) {
                backupOperationRequest = .replaceAndEnable
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let existingBackup {
                Text("The backup from \(existingBackup.createdAt.formatted(date: .abbreviated, time: .shortened)) contains \(existingBackup.visitCount) visit\(existingBackup.visitCount == 1 ? "" : "s"). Restore merges it with this iPhone; newer local edits are kept.")
            }
        }
        .confirmationDialog(
            "Restore your iCloud backup?",
            isPresented: $isShowingRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore and Merge") {
                backupOperationRequest = .restore
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Missing visits and newer backed-up versions will be restored. Existing newer visits on this iPhone will not be deleted.")
        }
        .alert(
            "iCloud Backup Unavailable",
            isPresented: Binding(
                get: { backupErrorMessage != nil },
                set: { if !$0 { backupErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(backupErrorMessage ?? "Try again later.")
        }
    }

    private var iCloudBackupBinding: Binding<Bool> {
        Binding(
            get: { iCloudBackupEnabled },
            set: { enabled in
                backupNotice = nil
                if enabled {
                    backupEnableRequestID = UUID()
                } else {
                    iCloudBackupEnabled = false
                }
            }
        )
    }

    private var backupStatusText: String {
        guard lastBackupTimeInterval > 0 else {
            return "Waiting for first backup"
        }
        let date = Date(timeIntervalSince1970: lastBackupTimeInterval)
        return "Last backed up \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    @MainActor
    private func prepareToEnableICloudBackup() async {
        guard backupEnableRequestID != nil, !iCloudBackupEnabled else { return }

        isBackupOperationRunning = true
        defer { isBackupOperationRunning = false }
        do {
            guard try await backupService.isICloudAvailable() else {
                throw JournalBackupError.iCloudUnavailable
            }
            existingBackup = try await backupService.metadata()
            if existingBackup != nil {
                isShowingExistingBackupAlert = true
            } else {
                iCloudBackupEnabled = true
                let metadata = try await JournalBackupOperations.backUp(
                    context: modelContext,
                    service: backupService
                )
                backupNotice = "Backed up \(metadata.visitCount) visit\(metadata.visitCount == 1 ? "" : "s")."
            }
        } catch {
            backupErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func performBackupOperation(_ operation: BackupOperation) async {
        isBackupOperationRunning = true
        backupNotice = nil
        defer { isBackupOperationRunning = false }

        do {
            switch operation {
            case .backUp:
                let metadata = try await JournalBackupOperations.backUp(
                    context: modelContext,
                    service: backupService
                )
                backupNotice = "Backed up \(metadata.visitCount) visit\(metadata.visitCount == 1 ? "" : "s")."
            case .restore:
                let changedCount = try await JournalBackupOperations.restore(
                    context: modelContext,
                    service: backupService
                )
                backupNotice = restoreNotice(changedCount: changedCount)
            case .restoreAndEnable:
                let changedCount = try await JournalBackupOperations.restore(
                    context: modelContext,
                    service: backupService
                )
                iCloudBackupEnabled = true
                _ = try await JournalBackupOperations.backUp(
                    context: modelContext,
                    service: backupService
                )
                backupNotice = restoreNotice(changedCount: changedCount)
            case .replaceAndEnable:
                iCloudBackupEnabled = true
                let metadata = try await JournalBackupOperations.backUp(
                    context: modelContext,
                    service: backupService
                )
                backupNotice = "Replaced the iCloud backup with \(metadata.visitCount) visit\(metadata.visitCount == 1 ? "" : "s") from this iPhone."
            }
        } catch {
            if operation == .restoreAndEnable || operation == .replaceAndEnable {
                iCloudBackupEnabled = false
            }
            backupErrorMessage = error.localizedDescription
        }
    }

    private func restoreNotice(changedCount: Int) -> String {
        if changedCount == 0 {
            return "Your journal is already up to date."
        }
        return "Restored \(changedCount) visit\(changedCount == 1 ? "" : "s") from iCloud."
    }

    private func removePendingHomeSuggestions(inside region: HomeExclusionRegion) {
        _ = try? AutomaticPhotoScanService.removePendingVisits(
            inside: region,
            from: modelContext
        )
    }

    @MainActor
    private func configureAutomaticScanningIfNeeded() async {
        guard permissionRequestID != nil, automaticScanningEnabled else { return }

        var access = photoLibraryService.authorizationStatus()
        if access == .notDetermined {
            access = await photoLibraryService.requestAuthorization()
        }
        photoAccess = access

        guard access == .full || access == .limited else {
            automaticScanningEnabled = false
            isShowingAccessAlert = true
            return
        }

        AutomaticPhotoScanScheduler.scheduleNext()
        NotificationCenter.default.post(name: .automaticPhotoScanRequested, object: nil)
    }

    private enum BackupOperation: Hashable {
        case backUp
        case restore
        case restoreAndEnable
        case replaceAndEnable
    }
}

private extension Notification.Name {
    static let automaticPhotoScanRequested = Notification.Name(
        "io.jonsson.atehere.automatic-photo-scan-requested"
    )
}

private struct HomeAreaPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (HomeExclusionRegion) -> Void

    @StateObject private var locationProvider = HomeLocationProvider()
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var radiusMeters: CLLocationDistance
    @State private var cameraPosition: MapCameraPosition
    @State private var locationRequestID: UUID?
    @State private var isRequestingLocation = false
    @State private var locationErrorMessage: String?

    init(
        initialRegion: HomeExclusionRegion?,
        onSave: @escaping (HomeExclusionRegion) -> Void
    ) {
        self.onSave = onSave
        _selectedCoordinate = State(initialValue: initialRegion?.coordinate)
        _radiusMeters = State(
            initialValue: initialRegion?.radiusMeters
                ?? HomeExclusionSettings.defaultRadiusMeters
        )

        if let initialRegion {
            _cameraPosition = State(
                initialValue: .region(
                    MKCoordinateRegion(
                        center: initialRegion.coordinate,
                        latitudinalMeters: 1_200,
                        longitudinalMeters: 1_200
                    )
                )
            )
        } else {
            _cameraPosition = State(
                initialValue: .userLocation(
                    followsHeading: false,
                    fallback: .automatic
                )
            )
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Map(position: $cameraPosition) {
                        UserAnnotation()
                        if let selectedCoordinate {
                            MapCircle(
                                center: selectedCoordinate,
                                radius: radiusMeters
                            )
                            .foregroundStyle(AlbumTheme.burgundy.opacity(0.18))
                        }
                    }
                    .onMapCameraChange(frequency: .onEnd) { context in
                        guard cameraPosition.positionedByUser else { return }
                        selectedCoordinate = context.region.center
                    }

                    Image(systemName: "house.circle.fill")
                        .font(.system(size: 38))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(AlbumTheme.photoPaper, AlbumTheme.burgundy)
                        .shadow(color: AlbumTheme.ink.opacity(0.28), radius: 4, y: 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier("homeAreaMap")

                VStack(alignment: .leading, spacing: 16) {
                    Text("Move the map until the house marks home. The shaded circle is the area automatic scans will ignore.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        locationRequestID = UUID()
                    } label: {
                        HStack {
                            Label("Use Current Location", systemImage: "location.fill")
                            Spacer()
                            if isRequestingLocation {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isRequestingLocation)
                    .accessibilityIdentifier("useCurrentHomeLocation")

                    Picker("Home area radius", selection: $radiusMeters) {
                        ForEach(HomeExclusionSettings.availableRadii, id: \.self) { radius in
                            Text("\(Int(radius)) m").tag(radius)
                        }
                    }
                    .pickerStyle(.segmented)

                    Label(
                        "This coordinate stays on this iPhone and is not included in journal backups.",
                        systemImage: "lock"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(AlbumTheme.paper)
            }
            .navigationTitle("Home Area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(selectedCoordinate == nil)
                    .accessibilityIdentifier("saveHomeArea")
                }
            }
        }
        .tint(AlbumTheme.burgundy)
        .task(id: locationRequestID) {
            guard locationRequestID != nil else { return }
            isRequestingLocation = true
            defer { isRequestingLocation = false }

            do {
                let coordinate = try await locationProvider.currentLocation()
                try Task.checkCancellation()
                selectedCoordinate = coordinate
                cameraPosition = .region(
                    MKCoordinateRegion(
                        center: coordinate,
                        latitudinalMeters: 1_200,
                        longitudinalMeters: 1_200
                    )
                )
                locationErrorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                locationErrorMessage = error.localizedDescription
            }
        }
        .alert(
            "Location unavailable",
            isPresented: Binding(
                get: { locationErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        locationErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(locationErrorMessage ?? "Try again or move the map manually.")
        }
    }

    private func save() {
        guard let selectedCoordinate else { return }
        onSave(
            HomeExclusionRegion(
                latitude: selectedCoordinate.latitude,
                longitude: selectedCoordinate.longitude,
                radiusMeters: radiusMeters
            )
        )
        dismiss()
    }
}

@MainActor
private final class HomeLocationProvider: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentLocation() async throws -> CLLocationCoordinate2D {
        guard continuation == nil else {
            throw HomeLocationError.requestAlreadyRunning
        }
        guard CLLocationManager.locationServicesEnabled() else {
            throw HomeLocationError.servicesDisabled
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            requestLocationForCurrentAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        requestLocationForCurrentAuthorization()
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else {
            finish(throwing: HomeLocationError.locationUnavailable)
            return
        }
        finish(returning: location.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(throwing: error)
    }

    private func requestLocationForCurrentAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(throwing: HomeLocationError.permissionDenied)
        @unknown default:
            finish(throwing: HomeLocationError.locationUnavailable)
        }
    }

    private func finish(returning coordinate: CLLocationCoordinate2D) {
        continuation?.resume(returning: coordinate)
        continuation = nil
    }

    private func finish(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

private enum HomeLocationError: LocalizedError {
    case locationUnavailable
    case permissionDenied
    case requestAlreadyRunning
    case servicesDisabled

    var errorDescription: String? {
        switch self {
        case .locationUnavailable:
            "Your location couldn’t be determined. Move the map manually or try again."
        case .permissionDenied:
            "Location access is off for Ate Here. Move the map manually, or allow access in Settings."
        case .requestAlreadyRunning:
            "A location request is already in progress."
        case .servicesDisabled:
            "Location Services are turned off. Move the map manually, or enable them in Settings."
        }
    }
}

private struct AlbumMonth: Identifiable {
    let monthStart: Date
    let visits: [Visit]

    var id: Date { monthStart }
}

private struct AlbumCoverHeader: View {
    let visits: [Visit]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PRIVATE DINING JOURNAL")
                        .font(.caption2.monospaced().weight(.semibold))
                        .tracking(1.6)
                        .foregroundStyle(AlbumTheme.leatherFoil)

                    Text("Meals worth\nremembering")
                        .font(.system(.largeTitle, design: .serif).weight(.semibold))
                        .foregroundStyle(AlbumTheme.leatherText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "fork.knife")
                    .font(.title2.weight(.light))
                    .foregroundStyle(AlbumTheme.leatherFoil)
                    .padding(12)
                    .overlay {
                        Circle()
                            .stroke(AlbumTheme.leatherFoil.opacity(0.78), lineWidth: 1)
                    }
                    .accessibilityHidden(true)
            }

            Rectangle()
                .fill(AlbumTheme.leatherFoil.opacity(0.78))
                .frame(height: 1)

            HStack {
                Label(
                    "\(visits.count) meal\(visits.count == 1 ? "" : "s") remembered",
                    systemImage: "photo.on.rectangle.angled"
                )

                Spacer()

                Text(dateRange)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(AlbumTheme.leatherText.opacity(0.82))
        }
        .padding(24)
        .background(AlbumTheme.leather)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AlbumTheme.leatherFoil.opacity(0.65), lineWidth: 1)
                .padding(7)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: AlbumTheme.ink.opacity(0.18), radius: 10, y: 6)
        .accessibilityElement(children: .combine)
    }

    private var dateRange: String {
        guard let newest = visits.map(\.visitedAt).max(),
              let oldest = visits.map(\.visitedAt).min() else {
            return ""
        }

        let calendar = Calendar.current
        let oldestYear = calendar.component(.year, from: oldest)
        let newestYear = calendar.component(.year, from: newest)
        return oldestYear == newestYear ? "\(newestYear)" : "\(oldestYear)–\(newestYear)"
    }
}

private struct AlbumMonthPage: View {
    let month: AlbumMonth
    let placeSearchService: any PlaceSearchService
    let photoLibraryService: any PhotoLibraryService

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(month.monthStart, format: .dateTime.month(.wide))
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(AlbumTheme.ink)

                Text(month.monthStart, format: .dateTime.year())
                    .font(.caption.monospaced())
                    .foregroundStyle(AlbumTheme.mutedInk)

                Rectangle()
                    .fill(AlbumTheme.brass.opacity(0.55))
                    .frame(height: 1)
            }

            LazyVGrid(columns: columns, alignment: .center, spacing: 24) {
                ForEach(Array(month.visits.enumerated()), id: \.element.id) { index, visit in
                    NavigationLink {
                        VisitDetailView(
                            visit: visit,
                            placeSearchService: placeSearchService,
                            photoLibraryService: photoLibraryService
                        )
                    } label: {
                        AlbumVisitCard(
                            visit: visit,
                            placeSearchService: placeSearchService,
                            photoLibraryService: photoLibraryService,
                            rotation: index.isMultiple(of: 2) ? -0.7 : 0.6
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("visitRow")
                }
            }
        }
    }
}

private struct AlbumVisitCard: View {
    let visit: Visit
    let placeSearchService: any PlaceSearchService
    let photoLibraryService: any PhotoLibraryService
    let rotation: Double

    @State private var resolvedPlaceName: String?
    @State private var placeResolutionFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                if let primaryPhotoIdentifier {
                    GeometryReader { proxy in
                        PhotoThumbnailView(
                            assetIdentifier: primaryPhotoIdentifier,
                            photoLibraryService: photoLibraryService,
                            size: proxy.size.width,
                            cornerRadius: 2
                        )
                    }
                    .aspectRatio(1, contentMode: .fit)
                } else {
                    ZStack {
                        AlbumTheme.leatherHighlight
                        Image(systemName: "fork.knife")
                            .font(.title.weight(.light))
                            .foregroundStyle(AlbumTheme.leatherFoil)
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                }

                AlbumCornerMounts()
            }

            Text(displayPlaceName)
                .font(.system(.headline, design: .serif).weight(.semibold))
                .foregroundStyle(AlbumTheme.ink)
                .lineLimit(2)

            HStack(spacing: 7) {
                Text(visit.visitedAt, format: .dateTime.day().month(.abbreviated))

                if let rating = visit.rating {
                    Text("•")
                    Label("\(rating)", systemImage: "star.fill")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.caption)
            .foregroundStyle(AlbumTheme.mutedInk)
        }
        .padding(9)
        .padding(.bottom, 3)
        .background(AlbumTheme.photoPaper)
        .rotationEffect(.degrees(rotation))
        .shadow(color: AlbumTheme.ink.opacity(0.16), radius: 4, y: 3)
        .task(id: visit.applePlaceID) {
            await resolvePlaceName()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var primaryPhotoIdentifier: String? {
        visit.photos.first(where: \.isPrimary)?.assetLocalIdentifier
            ?? visit.photos.sorted {
                ($0.capturedAt ?? .distantPast) < ($1.capturedAt ?? .distantPast)
            }.first?.assetLocalIdentifier
    }

    private var displayPlaceName: String {
        if let customName = visit.userDefinedPlaceName {
            return customName
        }
        if let resolvedPlaceName {
            return resolvedPlaceName
        }
        return placeResolutionFailed ? "Place unavailable" : "Loading restaurant…"
    }

    private var accessibilitySummary: String {
        var parts = [
            displayPlaceName,
            visit.visitedAt.formatted(date: .long, time: .omitted),
        ]
        if let rating = visit.rating {
            parts.append("Rated \(rating) out of 5")
        }
        return parts.joined(separator: ", ")
    }

    @MainActor
    private func resolvePlaceName() async {
        guard let placeID = visit.applePlaceID else { return }

        do {
            let result = try await placeSearchService.resolvePlace(identifier: placeID)
            try Task.checkCancellation()
            resolvedPlaceName = result?.name
            placeResolutionFailed = result == nil
        } catch is CancellationError {
            return
        } catch {
            placeResolutionFailed = true
        }
    }
}

struct AlbumCornerMounts: View {
    var body: some View {
        VStack {
            HStack {
                AlbumCornerMount()
                    .fill(AlbumTheme.mount.opacity(0.82))
                    .frame(width: 17, height: 17)
                Spacer()
                AlbumCornerMount()
                    .fill(AlbumTheme.mount.opacity(0.82))
                    .frame(width: 17, height: 17)
                    .rotationEffect(.degrees(90))
            }
            Spacer()
            HStack {
                AlbumCornerMount()
                    .fill(AlbumTheme.mount.opacity(0.82))
                    .frame(width: 17, height: 17)
                    .rotationEffect(.degrees(-90))
                Spacer()
                AlbumCornerMount()
                    .fill(AlbumTheme.mount.opacity(0.82))
                    .frame(width: 17, height: 17)
                    .rotationEffect(.degrees(180))
            }
        }
        .padding(-1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct AlbumCornerMount: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#Preview("Empty journal") {
    JournalView()
        .modelContainer(for: [Visit.self, VisitPhoto.self], inMemory: true)
}
