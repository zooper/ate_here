import CoreLocation
import Foundation
import SwiftData

struct PhotoMetadata: Identifiable, Equatable, Sendable {
    let assetIdentifier: String
    let capturedAt: Date
    let latitude: Double?
    let longitude: Double?

    var id: String { assetIdentifier }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func distance(to other: PhotoMetadata) -> CLLocationDistance? {
        guard let coordinate, let otherCoordinate = other.coordinate else { return nil }
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(
                from: CLLocation(
                    latitude: otherCoordinate.latitude,
                    longitude: otherCoordinate.longitude
                )
            )
    }
}

struct VisitPhotoDraft: Equatable, Sendable {
    let assetLocalIdentifier: String
    let capturedAt: Date?
    let latitude: Double?
    let longitude: Double?
    let classificationLabels: [String]
    let isPrimary: Bool
}

struct DetectedVisitCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let visitedAt: Date
    let latitude: Double?
    let longitude: Double?
    let photos: [VisitPhotoDraft]
    let foodCategories: [String]
}

struct PhotoImportConfiguration: Equatable, Sendable {
    var lookbackDays = 30
    var maximumAssets = 500
    var maximumPhotosAnalyzedPerCluster = 3
}

@Model
final class PendingVisit {
    @Attribute(.unique) var id: String
    var visitedAt: Date
    var latitude: Double?
    var longitude: Double?
    var foodCategories: [String]
    var detectedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \PendingVisitPhoto.pendingVisit)
    var photos: [PendingVisitPhoto]

    init(candidate: DetectedVisitCandidate, detectedAt: Date = .now) {
        id = candidate.id
        visitedAt = candidate.visitedAt
        latitude = candidate.latitude
        longitude = candidate.longitude
        foodCategories = candidate.foodCategories
        self.detectedAt = detectedAt
        photos = candidate.photos.map(PendingVisitPhoto.init)
    }

    func absorb(_ candidate: DetectedVisitCandidate) {
        let existingIdentifiers = Set(photos.map(\.assetLocalIdentifier))
        for draft in candidate.photos
        where !existingIdentifiers.contains(draft.assetLocalIdentifier) {
            photos.append(PendingVisitPhoto(draft: draft))
        }

        visitedAt = min(visitedAt, candidate.visitedAt)
        foodCategories = Array(
            Set(foodCategories).union(candidate.foodCategories)
        ).sorted()
        updateLocation(
            fallbackLatitude: candidate.latitude,
            fallbackLongitude: candidate.longitude
        )
        normalizePrimaryPhoto()
    }

    func absorb(_ other: PendingVisit) {
        let existingIdentifiers = Set(photos.map(\.assetLocalIdentifier))
        for photo in other.photos
        where !existingIdentifiers.contains(photo.assetLocalIdentifier) {
            photo.pendingVisit = self
            photos.append(photo)
        }

        visitedAt = min(visitedAt, other.visitedAt)
        detectedAt = min(detectedAt, other.detectedAt)
        foodCategories = Array(
            Set(foodCategories).union(other.foodCategories)
        ).sorted()
        updateLocation(
            fallbackLatitude: other.latitude,
            fallbackLongitude: other.longitude
        )
        normalizePrimaryPhoto()
    }

    var candidate: DetectedVisitCandidate {
        DetectedVisitCandidate(
            id: id,
            visitedAt: visitedAt,
            latitude: latitude,
            longitude: longitude,
            photos: photos.map(\.draft),
            foodCategories: foodCategories
        )
    }

    private func updateLocation(
        fallbackLatitude: Double?,
        fallbackLongitude: Double?
    ) {
        let locatedPhotos = photos.compactMap { photo -> (Double, Double)? in
            guard let latitude = photo.latitude, let longitude = photo.longitude else {
                return nil
            }
            return (latitude, longitude)
        }
        guard !locatedPhotos.isEmpty else {
            if latitude == nil || longitude == nil {
                latitude = fallbackLatitude
                longitude = fallbackLongitude
            }
            return
        }

        latitude = locatedPhotos.map(\.0).reduce(0, +) / Double(locatedPhotos.count)
        longitude = locatedPhotos.map(\.1).reduce(0, +) / Double(locatedPhotos.count)
    }

    private func normalizePrimaryPhoto() {
        guard let primaryPhoto = photos.min(by: {
            ($0.capturedAt ?? .distantFuture) < ($1.capturedAt ?? .distantFuture)
        }) else {
            return
        }

        for photo in photos {
            photo.isPrimary = photo === primaryPhoto
        }
    }
}

@Model
final class PendingVisitPhoto {
    @Attribute(.unique) var assetLocalIdentifier: String
    var capturedAt: Date?
    var latitude: Double?
    var longitude: Double?
    var classificationLabels: [String]
    var isPrimary: Bool
    var pendingVisit: PendingVisit?

    init(draft: VisitPhotoDraft) {
        assetLocalIdentifier = draft.assetLocalIdentifier
        capturedAt = draft.capturedAt
        latitude = draft.latitude
        longitude = draft.longitude
        classificationLabels = draft.classificationLabels
        isPrimary = draft.isPrimary
    }

    var draft: VisitPhotoDraft {
        VisitPhotoDraft(
            assetLocalIdentifier: assetLocalIdentifier,
            capturedAt: capturedAt,
            latitude: latitude,
            longitude: longitude,
            classificationLabels: classificationLabels,
            isPrimary: isPrimary
        )
    }
}

@Model
final class IgnoredPhotoAsset {
    @Attribute(.unique) var assetLocalIdentifier: String
    var ignoredAt: Date

    init(assetLocalIdentifier: String, ignoredAt: Date = .now) {
        self.assetLocalIdentifier = assetLocalIdentifier
        self.ignoredAt = ignoredAt
    }
}

@MainActor
enum PendingVisitMergeService {
    static func merge(
        visitIDs: Set<String>,
        from pendingVisits: [PendingVisit],
        in modelContext: ModelContext
    ) throws -> PendingVisit? {
        let selectedVisits = pendingVisits.filter { visitIDs.contains($0.id) }
        guard selectedVisits.count >= 2,
              let target = selectedVisits.min(by: {
                  $0.visitedAt < $1.visitedAt
              }) else {
            return nil
        }

        for pendingVisit in selectedVisits where pendingVisit !== target {
            target.absorb(pendingVisit)
            modelContext.delete(pendingVisit)
        }
        try modelContext.save()
        return target
    }
}
