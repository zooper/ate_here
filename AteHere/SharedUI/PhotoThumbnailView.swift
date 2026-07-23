import SwiftUI
import UIKit

struct PhotoThumbnailView: View {
    let assetIdentifier: String
    let photoLibraryService: any PhotoLibraryService
    var size: CGFloat = 64
    var cornerRadius: CGFloat = 10

    @State private var image: UIImage?
    @State private var isUnavailable = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityLabel("Visit photo")
            } else if isUnavailable {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Photo unavailable")
            } else {
                ProgressView()
                    .accessibilityLabel("Loading photo")
            }
        }
        .frame(width: size, height: size)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .clipped()
        .task(id: assetIdentifier) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        do {
            image = try await photoLibraryService.image(
                for: assetIdentifier,
                targetSize: CGSize(width: size * 2, height: size * 2)
            )
            isUnavailable = false
        } catch {
            image = nil
            isUnavailable = true
        }
    }
}

struct PhotoMemoryStrip: View {
    let assetIdentifiers: [String]
    let photoLibraryService: any PhotoLibraryService
    var thumbnailSize: CGFloat = 64
    var limit = 4
    var onSelect: ((String) -> Void)?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(assetIdentifiers.prefix(limit).enumerated()), id: \.element) { index, identifier in
                    if let onSelect {
                        Button {
                            onSelect(identifier)
                        } label: {
                            PhotoThumbnailView(
                                assetIdentifier: identifier,
                                photoLibraryService: photoLibraryService,
                                size: thumbnailSize
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View photo \(index + 1) of \(assetIdentifiers.count)")
                    } else {
                        PhotoThumbnailView(
                            assetIdentifier: identifier,
                            photoLibraryService: photoLibraryService,
                            size: thumbnailSize
                        )
                    }
                }

                if assetIdentifiers.count > limit {
                    if let onSelect {
                        Button {
                            onSelect(assetIdentifiers[limit])
                        } label: {
                            morePhotosLabel
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View \(assetIdentifiers.count - limit) more photos")
                    } else {
                        morePhotosLabel
                            .accessibilityLabel("\(assetIdentifiers.count - limit) more photos")
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var morePhotosLabel: some View {
        Text("+\(assetIdentifiers.count - limit)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: thumbnailSize, height: thumbnailSize)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
