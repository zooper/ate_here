import Foundation
import SwiftData

@Model
final class Visit {
    @Attribute(.unique) var id: UUID
    var visitedAt: Date
    var latitude: Double?
    var longitude: Double?
    var applePlaceID: String?
    var userDefinedPlaceName: String?
    var rating: Int?
    var notes: String
    var foodCategories: [String]
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \VisitPhoto.visit)
    var photos: [VisitPhoto]

    init(
        id: UUID = UUID(),
        visitedAt: Date,
        latitude: Double? = nil,
        longitude: Double? = nil,
        applePlaceID: String? = nil,
        userDefinedPlaceName: String? = nil,
        rating: Int? = nil,
        notes: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.visitedAt = visitedAt
        self.latitude = latitude
        self.longitude = longitude
        self.applePlaceID = applePlaceID
        self.userDefinedPlaceName = userDefinedPlaceName
        self.rating = rating
        self.notes = notes
        self.foodCategories = []
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.photos = []
    }

    convenience init(draft: VisitDraft) {
        self.init(
            visitedAt: draft.visitedAt,
            latitude: draft.latitude,
            longitude: draft.longitude,
            applePlaceID: draft.applePlaceID,
            userDefinedPlaceName: draft.persistedCustomPlaceName,
            rating: draft.rating,
            notes: draft.normalizedNotes
        )
        foodCategories = draft.foodCategories
        photos = draft.photos.map(VisitPhoto.init)
    }

    func apply(_ draft: VisitDraft, now: Date = .now) {
        visitedAt = draft.visitedAt
        latitude = draft.latitude
        longitude = draft.longitude
        applePlaceID = draft.applePlaceID
        userDefinedPlaceName = draft.persistedCustomPlaceName
        rating = draft.rating
        notes = draft.normalizedNotes
        foodCategories = draft.foodCategories
        let existingPhotoIdentifiers = Set(photos.map(\.assetLocalIdentifier))
        for photo in draft.photos
        where !existingPhotoIdentifiers.contains(photo.assetLocalIdentifier) {
            photos.append(VisitPhoto(draft: photo))
        }
        updatedAt = now
    }

    func absorb(_ other: Visit, now: Date = .now) {
        let existingPhotoIdentifiers = Set(photos.map(\.assetLocalIdentifier))
        for photo in other.photos
        where !existingPhotoIdentifiers.contains(photo.assetLocalIdentifier) {
            photo.visit = self
            photos.append(photo)
        }

        visitedAt = min(visitedAt, other.visitedAt)
        createdAt = min(createdAt, other.createdAt)
        if applePlaceID == nil, userDefinedPlaceName == nil {
            applePlaceID = other.applePlaceID
            userDefinedPlaceName = other.userDefinedPlaceName
        }
        if rating == nil {
            rating = other.rating
        }
        notes = Self.mergedNotes(notes, other.notes)
        foodCategories = Array(
            Set(foodCategories).union(other.foodCategories)
        ).sorted()
        updateLocation(fallbackVisit: other)
        normalizePrimaryPhoto()
        updatedAt = now
    }

    private func updateLocation(fallbackVisit: Visit) {
        let locatedPhotos = photos.compactMap { photo -> (Double, Double)? in
            guard let latitude = photo.latitude, let longitude = photo.longitude else {
                return nil
            }
            return (latitude, longitude)
        }
        guard !locatedPhotos.isEmpty else {
            if latitude == nil || longitude == nil {
                latitude = fallbackVisit.latitude
                longitude = fallbackVisit.longitude
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

    private static func mergedNotes(_ first: String, _ second: String) -> String {
        var notes: [String] = []
        for note in [first, second] {
            let normalized = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty, !notes.contains(normalized) {
                notes.append(normalized)
            }
        }
        return notes.joined(separator: "\n\n")
    }
}

@MainActor
enum VisitMergeService {
    static func merge(
        visitIDs: Set<UUID>,
        from visits: [Visit],
        in modelContext: ModelContext,
        now: Date = .now
    ) throws -> Visit? {
        let selectedVisits = visits
            .filter { visitIDs.contains($0.id) }
            .sorted { $0.visitedAt < $1.visitedAt }
        guard selectedVisits.count >= 2, let target = selectedVisits.first else {
            return nil
        }

        for visit in selectedVisits.dropFirst() {
            target.absorb(visit, now: now)
            modelContext.delete(visit)
        }
        try modelContext.save()
        return target
    }
}
