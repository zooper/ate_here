import CoreLocation
import Photos
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct VisitEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query private var persistedPhotos: [VisitPhoto]

    private let visit: Visit?
    private let placeSearchService: any PlaceSearchService
    private let photoLibraryService: any PhotoLibraryService
    private let photoAnalysisService: any PhotoAnalysisService
    private let onSaved: (() -> Void)?
    private let isImportReview: Bool

    @State private var draft: VisitDraft
    @State private var isPresentingRestaurantSearch = false
    @State private var placeResolutionFailed = false
    @State private var saveError: Error?
    @State private var nearbySuggestions: [RestaurantSearchResult] = []
    @State private var isLoadingNearbySuggestions = false
    @State private var didLoadNearbySuggestions = false
    @State private var nearbySuggestionsFailed = false
    @State private var isPresentingPhotoPicker = false
    @State private var isPresentingLimitedPhotoPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var photoAuthorizationRequestID: UUID?
    @State private var isShowingPhotoAccessAlert = false
    @State private var isShowingPhotoAttachmentAlert = false
    @State private var pendingPhotoReferences: [VisitPhotoDraft] = []
    @State private var photoAttachmentRequestID: UUID?
    @State private var isAnalyzingSelectedPhotos = false

    private let maximumAttachedPhotoCount = 10

    init(
        visit: Visit? = nil,
        initialDraft: VisitDraft? = nil,
        placeSearchService: any PlaceSearchService = MapKitPlaceSearchService(),
        photoLibraryService: any PhotoLibraryService = LivePhotoLibraryService(),
        photoAnalysisService: any PhotoAnalysisService = VisionPhotoAnalysisService(),
        onSaved: (() -> Void)? = nil
    ) {
        self.visit = visit
        self.placeSearchService = placeSearchService
        self.photoLibraryService = photoLibraryService
        self.photoAnalysisService = photoAnalysisService
        self.onSaved = onSaved
        isImportReview = visit == nil && initialDraft?.photos.isEmpty == false
        _draft = State(initialValue: initialDraft ?? visit.map(VisitDraft.init) ?? VisitDraft())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if draft.applePlaceID != nil {
                        selectedMapPlace
                    } else {
                        if showsPhotoBasedSuggestions {
                            nearbySuggestionContent
                        }

                        Button {
                            isPresentingRestaurantSearch = true
                        } label: {
                            Label(
                                draft.coordinate == nil ? "Search Apple Maps" : "More restaurants",
                                systemImage: "map"
                            )
                        }
                        .accessibilityIdentifier("searchAppleMaps")

                        TextField("Custom place name", text: $draft.placeName)
                            .textContentType(.organizationName)
                            .accessibilityIdentifier("restaurantName")
                    }
                } header: {
                    Text("Restaurant")
                } footer: {
                    if draft.applePlaceID == nil {
                        if showsPhotoBasedSuggestions {
                            Text("Suggestions use on-device food labels and the photo location. Match scores are a heuristic, not certainty. Confirm the restaurant before saving.")
                        } else if hasAttachedPhotoEvidence, draft.coordinate == nil {
                            Text("This photo has no available location. Search Apple Maps, or enter a custom place.")
                        } else {
                            Text("Search Apple Maps, or enter a place that isn’t listed.")
                        }
                    }
                }

                Section("Visit") {
                    DatePicker(
                        "Date and time",
                        selection: $draft.visitedAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )

                    Picker("Rating", selection: $draft.rating) {
                        Text("Not rated").tag(Int?.none)
                        ForEach(1...5, id: \.self) { value in
                            Text("\(value) star\(value == 1 ? "" : "s")").tag(Int?.some(value))
                        }
                    }
                }

                Section {
                    if !draft.photos.isEmpty {
                        PhotoMemoryStrip(
                            assetIdentifiers: draft.photos.map(\.assetLocalIdentifier),
                            photoLibraryService: photoLibraryService,
                            thumbnailSize: 72,
                            limit: 4
                        )
                    }

                    if isAnalyzingSelectedPhotos {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Reading photo location and food…")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(action: beginPhotoSelection) {
                        Label(
                            draft.photos.isEmpty ? "Choose from Photos" : "Add more photos",
                            systemImage: "photo.badge.plus"
                        )
                    }
                    .disabled(remainingPhotoSlots == 0 || isAnalyzingSelectedPhotos)
                    .accessibilityIdentifier("addVisitPhotos")
                } header: {
                    Text("Photos")
                } footer: {
                    Text(photoSectionFooter)
                }

                Section {
                    VisitTagEditor(tags: $draft.foodCategories)
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Ate Here suggests food tags from the photos. Add your own or remove any that don’t fit.")
                }

                Section("Notes") {
                    TextField("What do you want to remember?", text: $draft.notes, axis: .vertical)
                        .lineLimit(4...8)
                        .accessibilityIdentifier("visitNotes")
                }
            }
            .navigationTitle(isImportReview ? "Review Visit" : (visit == nil ? "New Visit" : "Edit Visit"))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $isPresentingRestaurantSearch) {
                RestaurantSearchView(
                    placeSearchService: placeSearchService,
                    searchCenter: draft.coordinate,
                    foodCategories: detectedFoodCategories
                ) { result in
                    draft.selectMapPlace(result)
                    placeResolutionFailed = false
                }
            }
            .sheet(isPresented: $isPresentingLimitedPhotoPicker) {
                LimitedLibraryPhotoPickerView { identifiers in
                    isPresentingLimitedPhotoPicker = false
                    attachPhotos(withIdentifiers: identifiers)
                }
                .ignoresSafeArea()
            }
            .photosPicker(
                isPresented: $isPresentingPhotoPicker,
                selection: $selectedPhotoItems,
                maxSelectionCount: max(1, remainingPhotoSlots),
                selectionBehavior: .ordered,
                matching: .images,
                preferredItemEncoding: .current,
                photoLibrary: .shared()
            )
            .onChange(of: selectedPhotoItems) { _, items in
                guard !items.isEmpty else { return }
                selectedPhotoItems = []
                attachPhotos(withIdentifiers: items.compactMap(\.itemIdentifier))
            }
            .task(id: draft.applePlaceID) {
                await resolveSelectedPlaceIfNeeded()
            }
            .task(id: photoSuggestionContext) {
                await reloadNearbySuggestionsForCurrentPhotos()
            }
            .task(id: photoAuthorizationRequestID) {
                await requestPhotoAuthorizationIfNeeded()
            }
            .task(id: photoAttachmentRequestID) {
                await analyzePendingPhotoReferences()
            }
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
                    .disabled(!draft.canSave)
                    .accessibilityIdentifier("saveVisit")
                }
            }
            .alert(
                "Visit couldn’t be saved",
                isPresented: Binding(
                    get: { saveError != nil },
                    set: { if !$0 { saveError = nil } }
                ),
                presenting: saveError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { _ in
                Text("Check the visit details and try again.")
            }
            .alert("Photos access is needed", isPresented: $isShowingPhotoAccessAlert) {
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Allow selected or full Photos access to attach gallery photos to a visit.")
            }
            .alert("Photo couldn’t be attached", isPresented: $isShowingPhotoAttachmentAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The photo may already belong to another visit or no longer be available in Photos.")
            }
        }
    }

    private var remainingPhotoSlots: Int {
        max(0, maximumAttachedPhotoCount - draft.photos.count)
    }

    private var hasAttachedPhotoEvidence: Bool {
        visit == nil && !draft.photos.isEmpty
    }

    private var showsPhotoBasedSuggestions: Bool {
        hasAttachedPhotoEvidence && draft.coordinate != nil
    }

    private var photoSuggestionContext: PhotoSuggestionContext? {
        guard showsPhotoBasedSuggestions,
              let latitude = draft.latitude,
              let longitude = draft.longitude,
              draft.applePlaceID == nil else {
            return nil
        }
        return PhotoSuggestionContext(
            latitude: latitude,
            longitude: longitude,
            foodCategories: draft.foodCategories,
            photoIdentifiers: draft.photos.map(\.assetLocalIdentifier)
        )
    }

    private var detectedFoodCategories: [FoodCategory] {
        draft.foodCategories.compactMap(FoodCategory.init(rawValue:))
    }

    private var photoSectionFooter: String {
        if remainingPhotoSlots == 0 {
            return "This visit has the maximum of \(maximumAttachedPhotoCount) photos. Ate Here stores only PhotoKit references; the photo files remain in your library."
        }
        return "Choose up to \(maximumAttachedPhotoCount) photos. Ate Here stores only PhotoKit references; the photo files remain in your library."
    }

    private var selectedMapPlace: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedMapPlaceTitle)
                        .foregroundStyle(.primary)
                    Text("Apple Maps place")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(AlbumTheme.burgundy)
            }

            HStack {
                Button("Change restaurant") {
                    isPresentingRestaurantSearch = true
                }

                Spacer()

                Button("Use custom name") {
                    draft.useCustomPlace()
                    placeResolutionFailed = false
                }
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var nearbySuggestionContent: some View {
        if isLoadingNearbySuggestions {
            HStack(spacing: 10) {
                ProgressView()
                Text("Finding restaurants near the photo…")
                    .foregroundStyle(.secondary)
            }
        } else if !nearbySuggestions.isEmpty, let coordinate = draft.coordinate {
            let rankedSuggestions = RestaurantCandidateRanking.rank(
                nearbySuggestions,
                near: coordinate,
                foodCategories: detectedFoodCategories,
                limit: 5
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(suggestionHeading)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(rankedSuggestions) { rankedCandidate in
                    Button {
                        draft.selectMapPlace(rankedCandidate.result)
                        placeResolutionFailed = false
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(rankedCandidate.result.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                if let subtitle = rankedCandidate.result.subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                if let matchPercentage = rankedCandidate.matchPercentage {
                                    Text("\(matchPercentage)% match")
                                        .font(.caption.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(AlbumTheme.burgundy)
                                }

                                Text(distanceLabel(rankedCandidate.result.distance(from: coordinate)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(suggestionAccessibilityLabel(rankedCandidate))
                }
            }
        } else if nearbySuggestionsFailed {
            Label("Nearby suggestions are unavailable. You can still search Apple Maps.", systemImage: "wifi.exclamationmark")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if didLoadNearbySuggestions {
            Label("No nearby restaurants found", systemImage: "mappin.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var suggestionHeading: String {
        guard let category = detectedFoodCategories.first(where: \.isRestaurantFoodEvidence) else {
            return "Near the photo"
        }
        return "Matches \(category.rawValue.lowercased()) in the photo"
    }

    private func suggestionAccessibilityLabel(
        _ rankedCandidate: RankedRestaurantCandidate
    ) -> String {
        var parts = [rankedCandidate.result.name]
        if let subtitle = rankedCandidate.result.subtitle, !subtitle.isEmpty {
            parts.append(subtitle)
        }
        if let matchPercentage = rankedCandidate.matchPercentage {
            parts.append("\(matchPercentage) percent photo and location match")
        }
        if let coordinate = draft.coordinate {
            parts.append(distanceLabel(rankedCandidate.result.distance(from: coordinate)))
        }
        return parts.joined(separator: ", ")
    }

    private var selectedMapPlaceTitle: String {
        if let name = draft.resolvedMapPlaceName {
            return name
        }
        return placeResolutionFailed ? "Place unavailable" : "Loading restaurant…"
    }

    private func save() {
        guard draft.canSave else { return }

        do {
            if let visit {
                visit.apply(draft)
            } else {
                modelContext.insert(Visit(draft: draft))
            }
            try modelContext.save()
            onSaved?()
            dismiss()
        } catch {
            modelContext.rollback()
            saveError = error
        }
    }

    private func beginPhotoSelection() {
        guard remainingPhotoSlots > 0 else { return }

        switch photoLibraryService.authorizationStatus() {
        case .full:
            isPresentingPhotoPicker = true
        case .limited:
            isPresentingLimitedPhotoPicker = true
        case .notDetermined:
            photoAuthorizationRequestID = UUID()
        case .denied, .restricted:
            isShowingPhotoAccessAlert = true
        }
    }

    @MainActor
    private func requestPhotoAuthorizationIfNeeded() async {
        guard photoAuthorizationRequestID != nil else { return }
        photoAuthorizationRequestID = nil

        let access = await photoLibraryService.requestAuthorization()
        switch access {
        case .full:
            isPresentingPhotoPicker = true
        case .limited:
            let references = photoLibraryService.accessiblePhotoReferences(
                limit: remainingPhotoSlots
            )
            queuePhotoReferencesForAnalysis(references)
        case .notDetermined, .denied, .restricted:
            isShowingPhotoAccessAlert = true
        }
    }

    private func attachPhotos(withIdentifiers identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        let references = photoLibraryService.photoReferences(
            forAssetIdentifiers: identifiers
        )
        queuePhotoReferencesForAnalysis(references)
    }

    private func queuePhotoReferencesForAnalysis(_ references: [VisitPhotoDraft]) {
        let otherVisitPhotoIdentifiers: Set<String> = Set(
            persistedPhotos.compactMap { photo -> String? in
                guard photo.visit?.id != visit?.id else { return nil }
                return photo.assetLocalIdentifier
            }
        )
        let availableReferences = references.filter {
            !otherVisitPhotoIdentifiers.contains($0.assetLocalIdentifier)
                && !draft.photos.map(\.assetLocalIdentifier).contains($0.assetLocalIdentifier)
        }
        let referencesToAnalyze = Array(availableReferences.prefix(remainingPhotoSlots))
        guard !referencesToAnalyze.isEmpty else {
            if !references.isEmpty {
                isShowingPhotoAttachmentAlert = true
            }
            return
        }

        pendingPhotoReferences = referencesToAnalyze
        photoAttachmentRequestID = UUID()
    }

    @MainActor
    private func analyzePendingPhotoReferences() async {
        guard photoAttachmentRequestID != nil, !pendingPhotoReferences.isEmpty else {
            return
        }

        let references = pendingPhotoReferences
        let shouldInferVisitMetadata = visit == nil && draft.photos.isEmpty
        isAnalyzingSelectedPhotos = true

        let analysis = await ManualPhotoAnalysisService(
            photoLibraryService: photoLibraryService,
            photoAnalysisService: photoAnalysisService
        ).analyze(references)
        guard !Task.isCancelled else { return }

        let addedCount = draft.addManualPhotoAnalysis(
            analysis,
            maximumCount: maximumAttachedPhotoCount,
            inferVisitMetadata: shouldInferVisitMetadata
        )
        pendingPhotoReferences = []
        photoAttachmentRequestID = nil
        isAnalyzingSelectedPhotos = false

        if addedCount == 0 {
            isShowingPhotoAttachmentAlert = true
        }
    }

    @MainActor
    private func reloadNearbySuggestionsForCurrentPhotos() async {
        guard photoSuggestionContext != nil else { return }
        nearbySuggestions = []
        didLoadNearbySuggestions = false
        nearbySuggestionsFailed = false
        await loadNearbySuggestionsIfNeeded()
    }

    @MainActor
    private func loadNearbySuggestionsIfNeeded() async {
        guard showsPhotoBasedSuggestions,
              let coordinate = draft.coordinate,
              !didLoadNearbySuggestions,
              !isLoadingNearbySuggestions else {
            return
        }

        isLoadingNearbySuggestions = true
        nearbySuggestionsFailed = false

        do {
            nearbySuggestions = try await placeSearchService.nearbyRestaurants(
                near: coordinate,
                foodCategories: detectedFoodCategories
            )
            try Task.checkCancellation()
            didLoadNearbySuggestions = true
            isLoadingNearbySuggestions = false
        } catch is CancellationError {
            return
        } catch {
            nearbySuggestions = []
            didLoadNearbySuggestions = true
            isLoadingNearbySuggestions = false
            nearbySuggestionsFailed = true
        }
    }

    private func distanceLabel(_ distance: CLLocationDistance) -> String {
        if distance < 1_000 {
            return "\(Int(distance.rounded())) m"
        }
        return String(format: "%.1f km", distance / 1_000)
    }

    @MainActor
    private func resolveSelectedPlaceIfNeeded() async {
        guard let placeID = draft.applePlaceID,
              draft.resolvedMapPlaceName == nil else {
            return
        }

        do {
            let result = try await placeSearchService.resolvePlace(identifier: placeID)
            try Task.checkCancellation()
            draft.resolvedMapPlaceName = result?.name
            placeResolutionFailed = result == nil
        } catch is CancellationError {
            return
        } catch {
            placeResolutionFailed = true
        }
    }
}

private struct PhotoSuggestionContext: Hashable {
    let latitude: Double
    let longitude: Double
    let foodCategories: [String]
    let photoIdentifiers: [String]
}

private struct VisitTagEditor: View {
    @Binding var tags: [String]
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if tags.isEmpty {
                Label("No tags yet", systemImage: "tag")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(tags, id: \.self) { tag in
                            Button {
                                remove(tag)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(tag)
                                    Image(systemName: "xmark")
                                        .font(.caption2.weight(.bold))
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AlbumTheme.ink)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(AlbumTheme.photoPaper)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(AlbumTheme.paperEdge, lineWidth: 1)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(tag) tag")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            HStack(spacing: 10) {
                TextField("Add a tag", text: $newTag)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit(addNewTag)
                    .accessibilityIdentifier("visitTagField")

                Button("Add", action: addNewTag)
                    .font(.subheadline.weight(.semibold))
                    .disabled(!canAddNewTag)
                    .accessibilityIdentifier("addVisitTag")
            }

            Menu {
                ForEach(commonTags, id: \.self) { tag in
                    Button(tag) {
                        add(tag)
                    }
                }
            } label: {
                Label("Choose a food tag", systemImage: "tag.fill")
                    .font(.subheadline)
            }
            .disabled(commonTags.isEmpty || tags.count >= VisitTagRules.maximumTagCount)
        }
    }

    private var normalizedNewTag: String? {
        VisitTagRules.normalizedTag(newTag)
    }

    private var canAddNewTag: Bool {
        guard tags.count < VisitTagRules.maximumTagCount,
              let normalizedNewTag else {
            return false
        }
        return !tags.contains { VisitTagRules.matches($0, normalizedNewTag) }
    }

    private var commonTags: [String] {
        FoodCategory.allCases
            .filter(\.isRestaurantFoodEvidence)
            .map(\.rawValue)
            .filter { candidate in
                !tags.contains { VisitTagRules.matches($0, candidate) }
            }
    }

    private func addNewTag() {
        guard let tag = normalizedNewTag else { return }
        add(tag)
        newTag = ""
    }

    private func add(_ tag: String) {
        guard tags.count < VisitTagRules.maximumTagCount,
              !tags.contains(where: { VisitTagRules.matches($0, tag) }) else {
            return
        }
        tags.append(tag)
    }

    private func remove(_ tag: String) {
        tags.removeAll { VisitTagRules.matches($0, tag) }
    }
}

private struct LimitedLibraryPhotoPickerView: UIViewControllerRepresentable {
    let onSelection: @MainActor ([String]) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(onSelection: onSelection)
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {}

    @MainActor
    final class Controller: UIViewController {
        private let onSelection: @MainActor ([String]) -> Void
        private var didPresentPicker = false

        init(onSelection: @escaping @MainActor ([String]) -> Void) {
            self.onSelection = onSelection
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !didPresentPicker else { return }
            didPresentPicker = true

            Task { @MainActor in
                let identifiers = await PHPhotoLibrary.shared().presentLimitedLibraryPicker(
                    from: self
                )
                onSelection(identifiers)
            }
        }
    }
}
