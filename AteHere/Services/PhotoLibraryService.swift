import Photos
import UIKit

enum PhotoLibraryAccess: Equatable, Sendable {
    case notDetermined
    case limited
    case full
    case denied
    case restricted
}

enum PhotoLibraryServiceError: Error {
    case assetUnavailable
    case imageUnavailable
}

enum PhotoImageContentMode: Sendable {
    case fill
    case fit
}

protocol PhotoLibraryService: Sendable {
    @MainActor
    func authorizationStatus() -> PhotoLibraryAccess

    @MainActor
    func requestAuthorization() async -> PhotoLibraryAccess

    @MainActor
    func recentPhotos(
        since startDate: Date,
        excludingAssetIdentifiers: Set<String>,
        limit: Int
    ) -> [PhotoMetadata]

    @MainActor
    func photoReferences(forAssetIdentifiers identifiers: [String]) -> [VisitPhotoDraft]

    @MainActor
    func accessiblePhotoReferences(limit: Int) -> [VisitPhotoDraft]

    @MainActor
    func image(
        for assetIdentifier: String,
        targetSize: CGSize,
        contentMode: PhotoImageContentMode
    ) async throws -> UIImage
}

extension PhotoLibraryService {
    @MainActor
    func image(for assetIdentifier: String, targetSize: CGSize) async throws -> UIImage {
        try await image(for: assetIdentifier, targetSize: targetSize, contentMode: .fill)
    }
}

struct LivePhotoLibraryService: PhotoLibraryService {
    @MainActor
    func authorizationStatus() -> PhotoLibraryAccess {
        mapAuthorizationStatus(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    @MainActor
    func requestAuthorization() async -> PhotoLibraryAccess {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return mapAuthorizationStatus(status)
    }

    @MainActor
    func recentPhotos(
        since startDate: Date,
        excludingAssetIdentifiers: Set<String>,
        limit: Int
    ) -> [PhotoMetadata] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@", startDate as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        options.includeHiddenAssets = false

        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var photos: [PhotoMetadata] = []
        photos.reserveCapacity(assets.count)

        assets.enumerateObjects { asset, _, _ in
            guard let capturedAt = asset.creationDate,
                  !asset.mediaSubtypes.contains(.photoScreenshot),
                  !excludingAssetIdentifiers.contains(asset.localIdentifier) else {
                return
            }

            photos.append(
                PhotoMetadata(
                    assetIdentifier: asset.localIdentifier,
                    capturedAt: capturedAt,
                    latitude: asset.location?.coordinate.latitude,
                    longitude: asset.location?.coordinate.longitude
                )
            )
        }

        return photos
    }

    @MainActor
    func photoReferences(forAssetIdentifiers identifiers: [String]) -> [VisitPhotoDraft] {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetsByIdentifier: [String: PHAsset] = [:]
        assets.enumerateObjects { asset, _, _ in
            assetsByIdentifier[asset.localIdentifier] = asset
        }

        return identifiers.compactMap { identifier in
            assetsByIdentifier[identifier].map(photoReference)
        }
    }

    @MainActor
    func accessiblePhotoReferences(limit: Int) -> [VisitPhotoDraft] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        options.includeHiddenAssets = false

        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var references: [VisitPhotoDraft] = []
        references.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            references.append(photoReference(asset))
        }
        return references
    }

    @MainActor
    func image(
        for assetIdentifier: String,
        targetSize: CGSize,
        contentMode: PhotoImageContentMode
    ) async throws -> UIImage {
        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetIdentifier],
            options: nil
        )
        guard let asset = assets.firstObject else {
            throw PhotoLibraryServiceError.assetUnavailable
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode == .fill ? .aspectFill : .aspectFit,
                options: options
            ) { image, info in
                let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                guard !isDegraded else { return }

                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: PhotoLibraryServiceError.imageUnavailable)
                }
            }
        }
    }

    private func mapAuthorizationStatus(_ status: PHAuthorizationStatus) -> PhotoLibraryAccess {
        switch status {
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .authorized:
            .full
        case .limited:
            .limited
        @unknown default:
            .denied
        }
    }

    private func photoReference(_ asset: PHAsset) -> VisitPhotoDraft {
        VisitPhotoDraft(
            assetLocalIdentifier: asset.localIdentifier,
            capturedAt: asset.creationDate,
            latitude: asset.location?.coordinate.latitude,
            longitude: asset.location?.coordinate.longitude,
            classificationLabels: [],
            isPrimary: false
        )
    }
}
