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
}
