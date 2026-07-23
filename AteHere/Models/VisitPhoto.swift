import Foundation
import SwiftData

@Model
final class VisitPhoto {
    @Attribute(.unique) var assetLocalIdentifier: String
    var capturedAt: Date?
    var latitude: Double?
    var longitude: Double?
    var classificationLabels: [String]
    var isPrimary: Bool
    var visit: Visit?

    init(
        assetLocalIdentifier: String,
        capturedAt: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        classificationLabels: [String] = [],
        isPrimary: Bool = false
    ) {
        self.assetLocalIdentifier = assetLocalIdentifier
        self.capturedAt = capturedAt
        self.latitude = latitude
        self.longitude = longitude
        self.classificationLabels = classificationLabels
        self.isPrimary = isPrimary
    }

    convenience init(draft: VisitPhotoDraft) {
        self.init(
            assetLocalIdentifier: draft.assetLocalIdentifier,
            capturedAt: draft.capturedAt,
            latitude: draft.latitude,
            longitude: draft.longitude,
            classificationLabels: draft.classificationLabels,
            isPrimary: draft.isPrimary
        )
    }
}

