import Foundation

struct VisitClusteringConfiguration: Equatable, Sendable {
    var maximumTimeGap: TimeInterval = 90 * 60
    var maximumLocationGapMeters: Double = 250
}

struct VisitClusteringService: Sendable {
    let configuration: VisitClusteringConfiguration

    init(configuration: VisitClusteringConfiguration = .init()) {
        self.configuration = configuration
    }

    func clusters(from photos: [PhotoMetadata]) -> [[PhotoMetadata]] {
        let sortedPhotos = photos.sorted { $0.capturedAt < $1.capturedAt }
        guard let firstPhoto = sortedPhotos.first else { return [] }

        var clusters: [[PhotoMetadata]] = [[firstPhoto]]

        for photo in sortedPhotos.dropFirst() {
            guard let previousPhoto = clusters[clusters.count - 1].last else { continue }

            let timeGap = photo.capturedAt.timeIntervalSince(previousPhoto.capturedAt)
            let locationGap = photo.distance(to: previousPhoto)
            let hasLongTimeGap = timeGap > configuration.maximumTimeGap
            let hasMajorLocationChange = locationGap.map {
                $0 > configuration.maximumLocationGapMeters
            } ?? false

            if hasLongTimeGap || hasMajorLocationChange {
                clusters.append([photo])
            } else {
                clusters[clusters.count - 1].append(photo)
            }
        }

        return clusters
    }
}

