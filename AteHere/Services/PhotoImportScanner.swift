import BackgroundTasks
import CoreLocation
import Foundation
import SwiftData
import UIKit

struct HomeExclusionRegion: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let radiusMeters: CLLocationDistance

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isValid: Bool {
        CLLocationCoordinate2DIsValid(coordinate)
            && latitude.isFinite
            && longitude.isFinite
            && radiusMeters.isFinite
            && radiusMeters > 0
    }

    func contains(_ candidate: DetectedVisitCandidate) -> Bool {
        guard isValid,
              let candidateLatitude = candidate.latitude,
              let candidateLongitude = candidate.longitude else {
            return false
        }
        let candidateCoordinate = CLLocationCoordinate2D(
            latitude: candidateLatitude,
            longitude: candidateLongitude
        )
        guard CLLocationCoordinate2DIsValid(candidateCoordinate) else {
            return false
        }

        return CLLocation(latitude: latitude, longitude: longitude).distance(
            from: CLLocation(
                latitude: candidateLatitude,
                longitude: candidateLongitude
            )
        ) <= radiusMeters
    }
}

enum HomeExclusionSettings {
    static let enabledKey = "homePhotoExclusionEnabled"
    static let hasLocationKey = "homePhotoExclusionHasLocation"
    static let latitudeKey = "homePhotoExclusionLatitude"
    static let longitudeKey = "homePhotoExclusionLongitude"
    static let radiusKey = "homePhotoExclusionRadiusMeters"
    static let defaultRadiusMeters: CLLocationDistance = 200
    static let availableRadii: [CLLocationDistance] = [100, 200, 300]

    static func configuredRegion(
        userDefaults: UserDefaults = .standard
    ) -> HomeExclusionRegion? {
        guard userDefaults.bool(forKey: hasLocationKey) else { return nil }

        let storedRadius = userDefaults.double(forKey: radiusKey)
        let region = HomeExclusionRegion(
            latitude: userDefaults.double(forKey: latitudeKey),
            longitude: userDefaults.double(forKey: longitudeKey),
            radiusMeters: storedRadius > 0 ? storedRadius : defaultRadiusMeters
        )
        return region.isValid ? region : nil
    }

    static func activeRegion(
        userDefaults: UserDefaults = .standard
    ) -> HomeExclusionRegion? {
        guard userDefaults.bool(forKey: enabledKey) else { return nil }
        return configuredRegion(userDefaults: userDefaults)
    }

    static func save(
        _ region: HomeExclusionRegion,
        userDefaults: UserDefaults = .standard
    ) {
        guard region.isValid else { return }
        userDefaults.set(region.latitude, forKey: latitudeKey)
        userDefaults.set(region.longitude, forKey: longitudeKey)
        userDefaults.set(region.radiusMeters, forKey: radiusKey)
        userDefaults.set(true, forKey: hasLocationKey)
        userDefaults.set(true, forKey: enabledKey)
    }

    static func remove(userDefaults: UserDefaults = .standard) {
        userDefaults.set(false, forKey: enabledKey)
        userDefaults.removeObject(forKey: hasLocationKey)
        userDefaults.removeObject(forKey: latitudeKey)
        userDefaults.removeObject(forKey: longitudeKey)
        userDefaults.removeObject(forKey: radiusKey)
    }
}

struct PhotoImportScanner: Sendable {
    let photoLibraryService: any PhotoLibraryService
    let photoAnalysisService: any PhotoAnalysisService
    let clusteringService: VisitClusteringService
    let configuration: PhotoImportConfiguration

    init(
        photoLibraryService: any PhotoLibraryService,
        photoAnalysisService: any PhotoAnalysisService,
        clusteringService: VisitClusteringService = .init(),
        configuration: PhotoImportConfiguration = .init()
    ) {
        self.photoLibraryService = photoLibraryService
        self.photoAnalysisService = photoAnalysisService
        self.clusteringService = clusteringService
        self.configuration = configuration
    }

    @MainActor
    func scan(
        excludingAssetIdentifiers: Set<String>,
        now: Date = .now,
        startingAt requestedStartDate: Date? = nil
    ) async throws -> [DetectedVisitCandidate] {
        let lookbackStartDate = Calendar.current.date(
            byAdding: .day,
            value: -configuration.lookbackDays,
            to: now
        ) ?? now
        let startDate = max(requestedStartDate ?? lookbackStartDate, lookbackStartDate)
        let photos = photoLibraryService.recentPhotos(
            since: startDate,
            excludingAssetIdentifiers: excludingAssetIdentifiers,
            limit: configuration.maximumAssets
        )
        let clusters = clusteringService.clusters(from: photos)
        var candidates: [DetectedVisitCandidate] = []

        for cluster in clusters {
            try Task.checkCancellation()
            let analyzedPhotos = await analyze(cluster: cluster)
            let matchingPhotos = analyzedPhotos.filter {
                !$0.classificationLabels.isEmpty
            }

            guard !matchingPhotos.isEmpty else {
                continue
            }

            let candidatePhotos = matchingPhotos.enumerated().map { index, photo in
                VisitPhotoDraft(
                    assetLocalIdentifier: photo.assetLocalIdentifier,
                    capturedAt: photo.capturedAt,
                    latitude: photo.latitude,
                    longitude: photo.longitude,
                    classificationLabels: photo.classificationLabels,
                    isPrimary: index == 0
                )
            }
            let coordinates = candidatePhotos.compactMap { photo -> CLLocationCoordinate2D? in
                guard let latitude = photo.latitude, let longitude = photo.longitude else {
                    return nil
                }
                return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
            let latitude = coordinates.isEmpty ? nil :
                coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count)
            let longitude = coordinates.isEmpty ? nil :
                coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count)
            let foodCategories = Array(
                Set(candidatePhotos.flatMap(\.classificationLabels))
            ).sorted()
            let visitedAt = candidatePhotos.compactMap(\.capturedAt).min() ?? cluster[0].capturedAt

            candidates.append(
                DetectedVisitCandidate(
                    id: candidatePhotos[0].assetLocalIdentifier,
                    visitedAt: visitedAt,
                    latitude: latitude,
                    longitude: longitude,
                    photos: candidatePhotos,
                    foodCategories: foodCategories
                )
            )
        }

        return candidates.sorted { $0.visitedAt > $1.visitedAt }
    }

    @MainActor
    private func analyze(cluster: [PhotoMetadata]) async -> [VisitPhotoDraft] {
        var labelsByIdentifier: [String: [String]] = [:]

        for photo in cluster.prefix(configuration.maximumPhotosAnalyzedPerCluster) {
            guard !Task.isCancelled else { break }

            do {
                let image = try await photoLibraryService.image(
                    for: photo.assetIdentifier,
                    targetSize: CGSize(width: 256, height: 256)
                )
                guard let cgImage = image.cgImage else { continue }

                let classifications = try await photoAnalysisService.classifications(for: cgImage)
                labelsByIdentifier[photo.assetIdentifier] = classifications
                    .prefix(3)
                    .map(\.category.rawValue)
            } catch {
                continue
            }
        }

        return cluster.enumerated().map { index, photo in
            VisitPhotoDraft(
                assetLocalIdentifier: photo.assetIdentifier,
                capturedAt: photo.capturedAt,
                latitude: photo.latitude,
                longitude: photo.longitude,
                classificationLabels: labelsByIdentifier[photo.assetIdentifier] ?? [],
                isPrimary: index == 0
            )
        }
    }
}

enum AutomaticPhotoScanSettings {
    static let enabledKey = "automaticPhotoScanningEnabled"
    static let lastScanDateKey = "automaticPhotoScanningLastScanDate"
    static let backgroundTaskIdentifier = "io.jonsson.atehere.photo-refresh"
    private static let incrementalScanOverlap: TimeInterval = 60

    static func scanStartDate(
        now: Date,
        lastScanDate: Date?,
        lookbackDays: Int,
        calendar: Calendar = .current
    ) -> Date {
        let lookbackStartDate = calendar.date(
            byAdding: .day,
            value: -lookbackDays,
            to: now
        ) ?? now
        guard let lastScanDate, lastScanDate <= now else {
            return lookbackStartDate
        }
        return max(
            lookbackStartDate,
            lastScanDate.addingTimeInterval(-incrementalScanOverlap)
        )
    }
}

@MainActor
struct AutomaticPhotoScanService {
    let photoLibraryService: any PhotoLibraryService
    let photoAnalysisService: any PhotoAnalysisService
    var configuration: PhotoImportConfiguration = .init()
    var homeExclusionRegion: HomeExclusionRegion?

    @discardableResult
    static func removePendingVisits(
        inside region: HomeExclusionRegion,
        from modelContext: ModelContext
    ) throws -> Int {
        let pendingVisits = try modelContext.fetch(FetchDescriptor<PendingVisit>())
        let homeVisits = pendingVisits.filter { region.contains($0.candidate) }
        for pendingVisit in homeVisits {
            modelContext.delete(pendingVisit)
        }
        if !homeVisits.isEmpty {
            try modelContext.save()
        }
        return homeVisits.count
    }

    func scan(into modelContext: ModelContext, now: Date = .now) async throws -> Int {
        let access = photoLibraryService.authorizationStatus()
        guard access == .full || access == .limited else { return 0 }

        let importedPhotos = try modelContext.fetch(FetchDescriptor<VisitPhoto>())
        let pendingVisits = try modelContext.fetch(FetchDescriptor<PendingVisit>())
        let ignoredPhotos = try modelContext.fetch(FetchDescriptor<IgnoredPhotoAsset>())
        let excludedIdentifiers = Set(
            importedPhotos.map(\.assetLocalIdentifier)
                + pendingVisits.flatMap { $0.photos.map(\.assetLocalIdentifier) }
                + ignoredPhotos.map(\.assetLocalIdentifier)
        )
        var activePendingVisits = coalesce(
            pendingVisits,
            in: modelContext
        )
        var didChangePendingVisits = activePendingVisits.count != pendingVisits.count

        let scanner = PhotoImportScanner(
            photoLibraryService: photoLibraryService,
            photoAnalysisService: photoAnalysisService,
            configuration: configuration
        )
        let lastScanDate = UserDefaults.standard.object(
            forKey: AutomaticPhotoScanSettings.lastScanDateKey
        ) as? Date
        let candidates = try await scanner.scan(
            excludingAssetIdentifiers: excludedIdentifiers,
            now: now,
            startingAt: AutomaticPhotoScanSettings.scanStartDate(
                now: now,
                lastScanDate: lastScanDate,
                lookbackDays: configuration.lookbackDays
            )
        )
        let suggestedCandidates = candidates.filter { candidate in
            guard let homeExclusionRegion else { return true }
            return !homeExclusionRegion.contains(candidate)
        }

        var addedCount = 0
        for candidate in suggestedCandidates {
            if let pendingVisit = activePendingVisits.first(where: {
                candidatesBelongToSameVisit($0.candidate, candidate)
            }) {
                pendingVisit.absorb(candidate)
            } else {
                let pendingVisit = PendingVisit(candidate: candidate, detectedAt: now)
                modelContext.insert(pendingVisit)
                activePendingVisits.append(pendingVisit)
                addedCount += 1
            }
            didChangePendingVisits = true
        }
        if didChangePendingVisits {
            try modelContext.save()
        }
        UserDefaults.standard.set(now, forKey: AutomaticPhotoScanSettings.lastScanDateKey)
        return addedCount
    }

    private func coalesce(
        _ pendingVisits: [PendingVisit],
        in modelContext: ModelContext
    ) -> [PendingVisit] {
        var survivors = pendingVisits.sorted { $0.visitedAt < $1.visitedAt }
        var targetIndex = 0

        while targetIndex < survivors.count {
            var candidateIndex = targetIndex + 1
            while candidateIndex < survivors.count {
                let target = survivors[targetIndex]
                let candidate = survivors[candidateIndex]
                if candidatesBelongToSameVisit(target.candidate, candidate.candidate) {
                    target.absorb(candidate)
                    modelContext.delete(candidate)
                    survivors.remove(at: candidateIndex)
                } else {
                    candidateIndex += 1
                }
            }
            targetIndex += 1
        }

        return survivors
    }

    private func candidatesBelongToSameVisit(
        _ first: DetectedVisitCandidate,
        _ second: DetectedVisitCandidate
    ) -> Bool {
        let photos = candidateMetadata(first) + candidateMetadata(second)
        return VisitClusteringService().clusters(from: photos).count == 1
    }

    private func candidateMetadata(
        _ candidate: DetectedVisitCandidate
    ) -> [PhotoMetadata] {
        let metadata = candidate.photos.compactMap { photo -> PhotoMetadata? in
            guard let capturedAt = photo.capturedAt else { return nil }
            return PhotoMetadata(
                assetIdentifier: photo.assetLocalIdentifier,
                capturedAt: capturedAt,
                latitude: photo.latitude,
                longitude: photo.longitude
            )
        }
        guard metadata.isEmpty else { return metadata }

        return [
            PhotoMetadata(
                assetIdentifier: candidate.id,
                capturedAt: candidate.visitedAt,
                latitude: candidate.latitude,
                longitude: candidate.longitude
            ),
        ]
    }
}

enum AutomaticPhotoScanScheduler {
    static func scheduleNext() {
        guard UserDefaults.standard.bool(
            forKey: AutomaticPhotoScanSettings.enabledKey
        ) else {
            cancel()
            return
        }

        BGTaskScheduler.shared.cancel(
            taskRequestWithIdentifier: AutomaticPhotoScanSettings.backgroundTaskIdentifier
        )
        let request = BGAppRefreshTaskRequest(
            identifier: AutomaticPhotoScanSettings.backgroundTaskIdentifier
        )
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(
            taskRequestWithIdentifier: AutomaticPhotoScanSettings.backgroundTaskIdentifier
        )
    }
}
