import CoreLocation
import MapKit
import SwiftData
import SwiftUI

struct AteHereTabView: View {
    private let placeSearchService: any PlaceSearchService
    private let photoLibraryService: any PhotoLibraryService
    private let photoAnalysisService: any PhotoAnalysisService

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
        TabView {
            JournalView(
                placeSearchService: placeSearchService,
                photoLibraryService: photoLibraryService,
                photoAnalysisService: photoAnalysisService
            )
            .tabItem {
                Label("Journal", systemImage: "book.closed")
            }

            VisitMapView(
                placeSearchService: placeSearchService,
                photoLibraryService: photoLibraryService
            )
            .tabItem {
                Label("Map", systemImage: "map")
            }

            RestaurantIndexView(
                placeSearchService: placeSearchService,
                photoLibraryService: photoLibraryService
            )
            .tabItem {
                Label("Places", systemImage: "text.book.closed")
            }
        }
        .tint(AlbumTheme.burgundy)
    }
}

struct VisitMapView: View {
    @Query(sort: \Visit.visitedAt, order: .reverse) private var visits: [Visit]

    let placeSearchService: any PlaceSearchService
    let photoLibraryService: any PhotoLibraryService

    @State private var cameraPosition: MapCameraPosition = .automatic

    init(
        placeSearchService: any PlaceSearchService = MapKitPlaceSearchService(),
        photoLibraryService: any PhotoLibraryService = LivePhotoLibraryService()
    ) {
        self.placeSearchService = placeSearchService
        self.photoLibraryService = photoLibraryService
    }

    var body: some View {
        NavigationStack {
            Group {
                if markers.isEmpty {
                    ContentUnavailableView {
                        Label("No geotagged photos", systemImage: "photo.badge.exclamationmark")
                    } description: {
                        Text("Photos with a saved location will appear here after you add or confirm a visit.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AlbumTheme.paper)
                } else {
                    photoMap
                }
            }
            .navigationTitle("Photo Map")
            .toolbarBackground(AlbumTheme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private var photoMap: some View {
        Map(position: $cameraPosition) {
            ForEach(markers) { marker in
                Annotation(
                    marker.visitDisplayName,
                    coordinate: marker.coordinate,
                    anchor: .bottom
                ) {
                    NavigationLink {
                        VisitDetailView(
                            visit: marker.visit,
                            placeSearchService: placeSearchService,
                            photoLibraryService: photoLibraryService
                        )
                    } label: {
                        PhotoMapPin(
                            assetIdentifier: marker.assetIdentifier,
                            photoLibraryService: photoLibraryService
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "Open visit from \(marker.visit.visitedAt.formatted(date: .abbreviated, time: .omitted))"
                    )
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .overlay(alignment: .topLeading) {
            Label(
                "\(markers.count) geotagged photo\(markers.count == 1 ? "" : "s")",
                systemImage: "photo.on.rectangle"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(AlbumTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(AlbumTheme.photoPaper.opacity(0.96))
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(AlbumTheme.paperEdge, lineWidth: 1)
            }
            .shadow(color: AlbumTheme.mount.opacity(0.18), radius: 5, y: 2)
            .padding(12)
        }
        .accessibilityIdentifier("photoMap")
    }

    private var markers: [VisitPhotoMapMarker] {
        VisitPhotoMapMarker.markers(from: visits)
    }
}

struct VisitPhotoMapMarker: Identifiable {
    let assetIdentifier: String
    let coordinate: CLLocationCoordinate2D
    let visit: Visit

    var id: String { assetIdentifier }

    var visitDisplayName: String {
        visit.userDefinedPlaceName ?? "Restaurant visit"
    }

    static func markers(from visits: [Visit]) -> [VisitPhotoMapMarker] {
        visits.flatMap { visit in
            visit.photos.compactMap { photo in
                guard
                    let latitude = photo.latitude,
                    let longitude = photo.longitude,
                    latitude.isFinite,
                    longitude.isFinite,
                    (-90...90).contains(latitude),
                    (-180...180).contains(longitude)
                else {
                    return nil
                }

                return VisitPhotoMapMarker(
                    assetIdentifier: photo.assetLocalIdentifier,
                    coordinate: CLLocationCoordinate2D(
                        latitude: latitude,
                        longitude: longitude
                    ),
                    visit: visit
                )
            }
        }
    }
}

private struct PhotoMapPin: View {
    let assetIdentifier: String
    let photoLibraryService: any PhotoLibraryService

    var body: some View {
        VStack(spacing: -3) {
            PhotoThumbnailView(
                assetIdentifier: assetIdentifier,
                photoLibraryService: photoLibraryService,
                size: 52,
                cornerRadius: 9
            )
            .padding(4)
            .background(AlbumTheme.photoPaper)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(AlbumTheme.burgundy, lineWidth: 2)
            }
            .shadow(color: AlbumTheme.mount.opacity(0.28), radius: 5, y: 3)

            Image(systemName: "arrowtriangle.down.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(AlbumTheme.burgundy)
        }
    }
}
