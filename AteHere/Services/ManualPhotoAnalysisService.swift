import Foundation
import UIKit

struct ManualPhotoAnalysisResult: Equatable, Sendable {
    let photos: [VisitPhotoDraft]
    let visitedAt: Date?
    let latitude: Double?
    let longitude: Double?
    let foodCategories: [String]
}

struct ManualPhotoAnalysisService: Sendable {
    let photoLibraryService: any PhotoLibraryService
    let photoAnalysisService: any PhotoAnalysisService
    var maximumPhotosAnalyzed = 3

    @MainActor
    func analyze(_ references: [VisitPhotoDraft]) async -> ManualPhotoAnalysisResult {
        var classificationsByIdentifier: [String: [String]] = [:]

        for reference in references.prefix(maximumPhotosAnalyzed) {
            guard !Task.isCancelled else { break }

            do {
                let image = try await photoLibraryService.image(
                    for: reference.assetLocalIdentifier,
                    targetSize: CGSize(width: 256, height: 256)
                )
                guard let cgImage = image.cgImage else { continue }

                let classifications = try await photoAnalysisService.classifications(for: cgImage)
                classificationsByIdentifier[reference.assetLocalIdentifier] = classifications
                    .prefix(3)
                    .map(\.category.rawValue)
            } catch {
                // GPS and capture time remain useful when image analysis is unavailable.
                continue
            }
        }

        let analyzedPhotos = references.map { reference in
            VisitPhotoDraft(
                assetLocalIdentifier: reference.assetLocalIdentifier,
                capturedAt: reference.capturedAt,
                latitude: reference.latitude,
                longitude: reference.longitude,
                classificationLabels: classificationsByIdentifier[
                    reference.assetLocalIdentifier
                ] ?? reference.classificationLabels,
                isPrimary: reference.isPrimary
            )
        }
        let coordinates = analyzedPhotos.compactMap { photo -> (Double, Double)? in
            guard let latitude = photo.latitude, let longitude = photo.longitude else {
                return nil
            }
            return (latitude, longitude)
        }
        let latitude = coordinates.isEmpty
            ? nil
            : coordinates.map(\.0).reduce(0, +) / Double(coordinates.count)
        let longitude = coordinates.isEmpty
            ? nil
            : coordinates.map(\.1).reduce(0, +) / Double(coordinates.count)
        var seenCategories = Set<String>()
        let foodCategories = analyzedPhotos
            .flatMap(\.classificationLabels)
            .filter { seenCategories.insert($0).inserted }

        return ManualPhotoAnalysisResult(
            photos: analyzedPhotos,
            visitedAt: analyzedPhotos.compactMap(\.capturedAt).min(),
            latitude: latitude,
            longitude: longitude,
            foodCategories: foodCategories
        )
    }
}
