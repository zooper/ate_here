import MapKit
import SwiftData
import SwiftUI

struct VisitDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let visit: Visit
    let placeSearchService: any PlaceSearchService
    let photoLibraryService: any PhotoLibraryService

    @State private var isEditing = false
    @State private var isConfirmingDeletion = false
    @State private var resolvedPlace: RestaurantSearchResult?
    @State private var placeResolutionFailed = false
    @State private var deleteError: Error?
    @State private var selectedPhoto: SelectedVisitPhoto?

    init(
        visit: Visit,
        placeSearchService: any PlaceSearchService = MapKitPlaceSearchService(),
        photoLibraryService: any PhotoLibraryService = LivePhotoLibraryService()
    ) {
        self.visit = visit
        self.placeSearchService = placeSearchService
        self.photoLibraryService = photoLibraryService
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero

                VStack(alignment: .leading, spacing: 30) {
                    memoryHeader

                    if !visit.notes.isEmpty {
                        notesSection
                    }

                    if !visit.foodCategories.isEmpty {
                        foodSection
                    }

                    if !visit.photos.isEmpty {
                        photosSection
                    }

                    if let resolvedPlace {
                        mapSection(resolvedPlace)
                    } else if placeResolutionFailed {
                        placeUnavailableMessage
                    }

                    deleteButton
                }
                .padding(.horizontal, 22)
                .padding(.top, 26)
                .padding(.bottom, 44)
            }
        }
        .background(AlbumTheme.paper)
        .scrollIndicators(.hidden)
        .navigationTitle("Visit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AlbumTheme.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") {
                    isEditing = true
                }
            }
        }
        .tint(AlbumTheme.burgundy)
        .sheet(isPresented: $isEditing) {
            VisitEditorView(
                visit: visit,
                placeSearchService: placeSearchService,
                photoLibraryService: photoLibraryService
            )
        }
        .fullScreenCover(item: $selectedPhoto) { selection in
            VisitPhotoViewer(
                assetIdentifiers: sortedPhotoIdentifiers,
                initialAssetIdentifier: selection.id,
                photoLibraryService: photoLibraryService
            )
        }
        .confirmationDialog(
            "Delete this visit?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Visit", role: .destructive, action: deleteVisit)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the visit and its app-owned data from this device.")
        }
        .alert(
            "Visit couldn’t be deleted",
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            ),
            presenting: deleteError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { _ in
            Text("Your journal wasn’t changed. Try again.")
        }
        .task(id: visit.applePlaceID) {
            await resolvePlace()
        }
    }

    private var hero: some View {
        GeometryReader { proxy in
            if let primaryPhotoIdentifier {
                Button {
                    selectedPhoto = SelectedVisitPhoto(id: primaryPhotoIdentifier)
                } label: {
                    PhotoThumbnailView(
                        assetIdentifier: primaryPhotoIdentifier,
                        photoLibraryService: photoLibraryService,
                        size: max(proxy.size.width, 330),
                        cornerRadius: 0
                    )
                    .frame(width: proxy.size.width, height: 330)
                    .clipped()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View visit photo full screen")
            } else {
                ZStack {
                    AlbumTheme.leather

                    VStack(spacing: 14) {
                        Image(systemName: "fork.knife")
                            .font(.system(size: 42, weight: .light))
                        Text("A meal remembered")
                            .font(.system(.headline, design: .serif))
                    }
                    .foregroundStyle(AlbumTheme.leatherFoil)
                }
                .frame(width: proxy.size.width, height: 330)
            }
        }
        .frame(height: 330)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AlbumTheme.brass)
                .frame(height: 4)
        }
    }

    private var memoryHeader: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("VISIT MEMORY")
                .font(.caption2.monospaced().weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(AlbumTheme.brass)

            Text(displayPlaceName)
                .font(.system(.largeTitle, design: .serif).weight(.semibold))
                .foregroundStyle(AlbumTheme.ink)
                .accessibilityAddTraits(.isHeader)

            if let displayAddress {
                Text(displayAddress)
                    .font(.subheadline)
                    .foregroundStyle(AlbumTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(visit.visitedAt.formatted(date: .long, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(AlbumTheme.mutedInk)

            if let rating = visit.rating {
                HStack(spacing: 5) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= rating ? "star.fill" : "star")
                            .foregroundStyle(AlbumTheme.brass)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rated \(rating) out of 5")
            }

            Rectangle()
                .fill(AlbumTheme.brass.opacity(0.55))
                .frame(height: 1)
                .padding(.top, 5)
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("What I remember")

            Text(visit.notes)
                .font(.system(.body, design: .serif))
                .foregroundStyle(AlbumTheme.ink)
                .lineSpacing(5)
        }
    }

    private var foodSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("At the table")

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(visit.foodCategories, id: \.self) { category in
                        Text(category)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AlbumTheme.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(AlbumTheme.photoPaper)
                            .clipShape(Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(AlbumTheme.paperEdge, lineWidth: 1)
                            }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("From this visit")

            PhotoMemoryStrip(
                assetIdentifiers: sortedPhotoIdentifiers,
                photoLibraryService: photoLibraryService,
                thumbnailSize: 102,
                limit: 6,
                onSelect: { identifier in
                    selectedPhoto = SelectedVisitPhoto(id: identifier)
                }
            )
        }
    }

    private func mapSection(_ place: RestaurantSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("Where it happened")

            Map(
                initialPosition: .region(
                    MKCoordinateRegion(
                        center: place.coordinate,
                        latitudinalMeters: 800,
                        longitudinalMeters: 800
                    )
                ),
                interactionModes: []
            ) {
                Marker(place.name, coordinate: place.coordinate)
                    .tint(AlbumTheme.burgundy)
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AlbumTheme.paperEdge, lineWidth: 1)
            }
            .accessibilityLabel("Static map showing \(place.name)")
        }
    }

    private var placeUnavailableMessage: some View {
        Label(
            "This Apple Maps place can’t be loaded. Edit the visit to choose another restaurant.",
            systemImage: "exclamationmark.triangle"
        )
        .font(.subheadline)
        .foregroundStyle(AlbumTheme.mutedInk)
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            isConfirmingDeletion = true
        } label: {
            Label("Delete Visit", systemImage: "trash")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(AlbumTheme.burgundy)
        .padding(.top, 8)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(.title3, design: .serif).weight(.semibold))
            .foregroundStyle(AlbumTheme.ink)
    }

    private var displayPlaceName: String {
        if let customName = visit.userDefinedPlaceName {
            return customName
        }
        if let resolvedPlace {
            return resolvedPlace.name
        }
        return placeResolutionFailed ? "Place unavailable" : "Loading restaurant…"
    }

    private var displayAddress: String? {
        resolvedPlace?.displayAddress
    }

    private var primaryPhotoIdentifier: String? {
        visit.photos.first(where: \.isPrimary)?.assetLocalIdentifier
            ?? sortedPhotoIdentifiers.first
    }

    private var sortedPhotoIdentifiers: [String] {
        visit.photos.sorted {
            if $0.isPrimary != $1.isPrimary {
                return $0.isPrimary
            }
            return ($0.capturedAt ?? .distantPast) < ($1.capturedAt ?? .distantPast)
        }
        .map(\.assetLocalIdentifier)
    }

    private func deleteVisit() {
        do {
            modelContext.delete(visit)
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            deleteError = error
        }
    }

    @MainActor
    private func resolvePlace() async {
        guard let placeID = visit.applePlaceID else { return }

        do {
            let result = try await placeSearchService.resolvePlace(identifier: placeID)
            try Task.checkCancellation()
            resolvedPlace = result
            placeResolutionFailed = result == nil
        } catch is CancellationError {
            return
        } catch {
            placeResolutionFailed = true
        }
    }
}

private struct SelectedVisitPhoto: Identifiable {
    let id: String
}

private struct VisitPhotoViewer: View {
    @Environment(\.dismiss) private var dismiss

    let assetIdentifiers: [String]
    let photoLibraryService: any PhotoLibraryService

    @State private var selectedAssetIdentifier: String

    init(
        assetIdentifiers: [String],
        initialAssetIdentifier: String,
        photoLibraryService: any PhotoLibraryService
    ) {
        self.assetIdentifiers = assetIdentifiers
        self.photoLibraryService = photoLibraryService
        _selectedAssetIdentifier = State(initialValue: initialAssetIdentifier)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selectedAssetIdentifier) {
                ForEach(assetIdentifiers, id: \.self) { identifier in
                    FullSizePhotoView(
                        assetIdentifier: identifier,
                        photoLibraryService: photoLibraryService
                    )
                    .tag(identifier)
                }
            }
            .tabViewStyle(
                .page(indexDisplayMode: assetIdentifiers.count > 1 ? .automatic : .never)
            )

            VStack {
                HStack {
                    if assetIdentifiers.count > 1 {
                        Text(photoPositionLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.55), in: Capsule())
                    }

                    Spacer()

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel("Close photo viewer")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()
            }
        }
        .statusBarHidden()
    }

    private var photoPositionLabel: String {
        let index = assetIdentifiers.firstIndex(of: selectedAssetIdentifier) ?? 0
        return "\(index + 1) of \(assetIdentifiers.count)"
    }
}

private struct FullSizePhotoView: View {
    let assetIdentifier: String
    let photoLibraryService: any PhotoLibraryService

    @State private var image: UIImage?
    @State private var isUnavailable = false

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("Visit photo")
                } else if isUnavailable {
                    ContentUnavailableView(
                        "Photo unavailable",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text(
                            "This photo may have been removed or is no longer shared with Ate Here."
                        )
                    )
                    .foregroundStyle(.white)
                } else {
                    ProgressView()
                        .tint(.white)
                        .accessibilityLabel("Loading full-size photo")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: assetIdentifier) {
                await loadImage(for: proxy.size)
            }
        }
    }

    @MainActor
    private func loadImage(for availableSize: CGSize) async {
        let scale = UIScreen.main.scale
        let targetSize = CGSize(
            width: max(availableSize.width * scale, 1),
            height: max(availableSize.height * scale, 1)
        )

        do {
            image = try await photoLibraryService.image(
                for: assetIdentifier,
                targetSize: targetSize,
                contentMode: .fit
            )
            isUnavailable = false
        } catch is CancellationError {
            return
        } catch {
            image = nil
            isUnavailable = true
        }
    }
}
