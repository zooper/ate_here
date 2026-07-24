import SwiftData
import SwiftUI
import UIKit

struct PhotoImportView: View {
    private enum Phase {
        case introduction
        case scanning
        case results
        case noResults
        case accessDenied
        case scanFailed
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Query private var importedPhotos: [VisitPhoto]
    @Query private var pendingPhotos: [PendingVisitPhoto]
    @Query private var ignoredPhotos: [IgnoredPhotoAsset]

    let placeSearchService: any PlaceSearchService
    let photoLibraryService: any PhotoLibraryService
    let photoAnalysisService: any PhotoAnalysisService
    let configuration: PhotoImportConfiguration

    @State private var phase: Phase = .introduction
    @State private var photoAccess: PhotoLibraryAccess = .notDetermined
    @State private var scanRequestID: UUID?
    @State private var candidates: [DetectedVisitCandidate] = []
    @State private var selectedCandidate: DetectedVisitCandidate?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Import Visits")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
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
        .task(id: scanRequestID) {
            await performScan()
        }
        .sheet(item: $selectedCandidate) { candidate in
            VisitEditorView(
                initialDraft: VisitDraft(candidate: candidate),
                placeSearchService: placeSearchService,
                photoLibraryService: photoLibraryService
            ) {
                candidates.removeAll { $0.id == candidate.id }
                if candidates.isEmpty {
                    phase = .noResults
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .introduction:
            introduction
        case .scanning:
            ProgressView("Looking for possible visits…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results:
            candidateList
        case .noResults:
            ContentUnavailableView {
                Label("No new visits found", systemImage: "checkmark.circle")
            } description: {
                Text("Try again after adding more photos or expanding your limited Photos selection.")
            } actions: {
                Button("Scan again", action: startScan)
                    .buttonStyle(.borderedProminent)
            }
        case .accessDenied:
            ContentUnavailableView {
                Label("Photos access is off", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text("Your journal still works. To scan for past visits, allow selected photos in Settings.")
            } actions: {
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
                .buttonStyle(.borderedProminent)
            }
        case .scanFailed:
            ContentUnavailableView {
                Label("Scan interrupted", systemImage: "arrow.clockwise.circle")
            } description: {
                Text("Ate Here couldn’t finish checking your photos. Your library wasn’t changed.")
            } actions: {
                Button("Try again", action: startScan)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var introduction: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(AlbumTheme.burgundy)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Find meals you photographed")
                        .font(.largeTitle.bold())

                    Text("Ate Here checks photo dates, locations, and small on-device previews from the last \(configuration.lookbackDays) days. Only photos with food or restaurant-related evidence are suggested for review.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    privacyPoint(
                        icon: "iphone",
                        title: "Analysis stays on this iPhone",
                        detail: "Photos and metadata aren’t uploaded or used for model training."
                    )
                    privacyPoint(
                        icon: "hand.raised",
                        title: "You stay in control",
                        detail: "Ate Here suggests possible visits. Nothing is saved until you confirm it."
                    )
                    privacyPoint(
                        icon: "photo.on.rectangle",
                        title: photoAccess == .limited ? "Selected photos only" : "Limited access supported",
                        detail: photoAccess == .limited
                            ? "Only the photos you already allowed are included."
                            : "You can choose selected photos when iOS asks for access."
                    )
                }

                Button("Scan the last \(configuration.lookbackDays) days", action: startScan)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("scanRecentPhotos")
            }
            .padding(24)
        }
    }

    private func privacyPoint(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .frame(width: 28)
                .foregroundStyle(AlbumTheme.burgundy)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var candidateList: some View {
        List {
            Section {
                ForEach(candidates) { candidate in
                    Button {
                        selectedCandidate = candidate
                    } label: {
                        CandidateRow(
                            candidate: candidate,
                            photoLibraryService: photoLibraryService
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("importCandidate")
                }
            } header: {
                Text("Possible visits")
            } footer: {
                Text("Review each group and choose the restaurant before saving.")
            }
        }
        .listStyle(.plain)
    }

    private func startScan() {
        phase = .scanning
        scanRequestID = UUID()
    }

    @MainActor
    private func performScan() async {
        guard scanRequestID != nil else { return }

        var access = photoLibraryService.authorizationStatus()
        if access == .notDetermined {
            access = await photoLibraryService.requestAuthorization()
        }
        photoAccess = access

        guard access == .full || access == .limited else {
            phase = .accessDenied
            return
        }

        let scanner = PhotoImportScanner(
            photoLibraryService: photoLibraryService,
            photoAnalysisService: photoAnalysisService,
            configuration: configuration
        )

        do {
            candidates = try await scanner.scan(
                excludingAssetIdentifiers: Set(
                    importedPhotos.map(\.assetLocalIdentifier)
                        + pendingPhotos.map(\.assetLocalIdentifier)
                        + ignoredPhotos.map(\.assetLocalIdentifier)
                )
            )
            try Task.checkCancellation()
            phase = candidates.isEmpty ? .noResults : .results
        } catch is CancellationError {
            return
        } catch {
            phase = .scanFailed
        }
    }
}

struct PendingVisitsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PendingVisit.visitedAt, order: .reverse) private var pendingVisits: [PendingVisit]

    let placeSearchService: any PlaceSearchService
    let photoLibraryService: any PhotoLibraryService

    @State private var selectedVisit: PendingVisit?
    @State private var persistenceError: Error?
    @State private var isSelecting = false
    @State private var selectedVisitIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if pendingVisits.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing waiting", systemImage: "checkmark.circle")
                    } description: {
                        Text("New food-related matches will appear here for you to review later.")
                    }
                } else {
                    List {
                        Section {
                            ForEach(pendingVisits) { pendingVisit in
                                pendingVisitRow(pendingVisit)
                            }
                        } header: {
                            Text("Ready when you are")
                        } footer: {
                            Text(
                                isSelecting
                                    ? "Choose two or more matches from the same outing."
                                    : "Open a match to confirm the restaurant. Dismiss removes it from future scans."
                            )
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(AlbumTheme.paper)
                }
            }
            .navigationTitle("Review Matches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AlbumTheme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isSelecting {
                        Button("Cancel", action: stopSelecting)
                    } else {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if !isSelecting, pendingVisits.count >= 2 {
                        Button("Select") {
                            isSelecting = true
                        }
                        .accessibilityIdentifier("selectPendingVisits")
                    }
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    if isSelecting {
                        Spacer()

                        Button(
                            selectedVisitIDs.isEmpty
                                ? "Merge"
                                : "Merge \(selectedVisitIDs.count)",
                            action: mergeSelectedVisits
                        )
                        .fontWeight(.semibold)
                        .disabled(selectedVisitIDs.count < 2)
                        .accessibilityIdentifier("mergePendingVisits")
                    }
                }
            }
        }
        .tint(AlbumTheme.burgundy)
        .sheet(item: $selectedVisit) { pendingVisit in
            VisitEditorView(
                initialDraft: VisitDraft(candidate: pendingVisit.candidate),
                placeSearchService: placeSearchService,
                photoLibraryService: photoLibraryService
            ) {
                completeReview(pendingVisit)
            }
        }
        .alert(
            "Review list couldn’t be updated",
            isPresented: Binding(
                get: { persistenceError != nil },
                set: { if !$0 { persistenceError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try again in a moment.")
        }
    }

    @ViewBuilder
    private func pendingVisitRow(_ pendingVisit: PendingVisit) -> some View {
        if isSelecting {
            Button {
                if selectedVisitIDs.contains(pendingVisit.id) {
                    selectedVisitIDs.remove(pendingVisit.id)
                } else {
                    selectedVisitIDs.insert(pendingVisit.id)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(
                        systemName: selectedVisitIDs.contains(pendingVisit.id)
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .font(.title3)
                    .foregroundStyle(AlbumTheme.burgundy)
                    .accessibilityHidden(true)

                    CandidateRow(
                        candidate: pendingVisit.candidate,
                        photoLibraryService: photoLibraryService,
                        showsDisclosureIndicator: false
                    )
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "Match from \(pendingVisit.visitedAt.formatted(date: .abbreviated, time: .shortened))"
            )
            .accessibilityValue(
                selectedVisitIDs.contains(pendingVisit.id) ? "Selected" : "Not selected"
            )
            .accessibilityIdentifier("selectPendingVisit-\(pendingVisit.id)")
        } else {
            Button {
                selectedVisit = pendingVisit
            } label: {
                CandidateRow(
                    candidate: pendingVisit.candidate,
                    photoLibraryService: photoLibraryService
                )
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing) {
                Button("Dismiss", role: .destructive) {
                    dismissMatch(pendingVisit)
                }
            }
            .accessibilityIdentifier("pendingVisit")
        }
    }

    private func stopSelecting() {
        selectedVisitIDs.removeAll()
        isSelecting = false
    }

    private func mergeSelectedVisits() {
        do {
            guard let mergedVisit = try PendingVisitMergeService.merge(
                visitIDs: selectedVisitIDs,
                from: pendingVisits,
                in: modelContext
            ) else {
                return
            }

            stopSelecting()
            selectedVisit = mergedVisit
        } catch {
            modelContext.rollback()
            persistenceError = error
        }
    }

    private func dismissMatch(_ pendingVisit: PendingVisit) {
        do {
            for photo in pendingVisit.photos {
                modelContext.insert(
                    IgnoredPhotoAsset(assetLocalIdentifier: photo.assetLocalIdentifier)
                )
            }
            modelContext.delete(pendingVisit)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            persistenceError = error
        }
    }

    private func completeReview(_ pendingVisit: PendingVisit) {
        do {
            modelContext.delete(pendingVisit)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            persistenceError = error
        }
    }
}

private struct CandidateRow: View {
    let candidate: DetectedVisitCandidate
    let photoLibraryService: any PhotoLibraryService
    var showsDisclosureIndicator = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PhotoMemoryStrip(
                assetIdentifiers: candidate.photos.map(\.assetLocalIdentifier),
                photoLibraryService: photoLibraryService,
                thumbnailSize: 62,
                limit: 4
            )

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.visitedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.headline)
                    Text("\(candidate.photos.count) photo\(candidate.photos.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if showsDisclosureIndicator {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }

            if !candidate.foodCategories.isEmpty {
                Text(candidate.foodCategories.prefix(3).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
    }
}
