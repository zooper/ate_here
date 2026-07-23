import CloudKit
import Foundation
import SwiftData

enum ICloudJournalBackupSettings {
    static let enabledKey = "icloudJournalBackupEnabled"
    static let lastBackupDateKey = "icloudJournalBackupLastDate"
}

struct JournalBackupMetadata: Equatable, Sendable {
    let createdAt: Date
    let visitCount: Int
}

struct JournalBackupArchive: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let createdAt: Date
    let visits: [VisitRecord]

    @MainActor
    init(visits: [Visit], createdAt: Date = .now) {
        version = Self.currentVersion
        self.createdAt = createdAt
        self.visits = visits
            .map(VisitRecord.init)
            .sorted { $0.visitedAt > $1.visitedAt }
    }

    init(version: Int, createdAt: Date, visits: [VisitRecord]) {
        self.version = version
        self.createdAt = createdAt
        self.visits = visits
    }

    struct VisitRecord: Codable, Equatable, Sendable {
        let id: UUID
        let visitedAt: Date
        let latitude: Double?
        let longitude: Double?
        let applePlaceID: String?
        let userDefinedPlaceName: String?
        let rating: Int?
        let notes: String
        let foodCategories: [String]
        let createdAt: Date
        let updatedAt: Date
        let photos: [PhotoRecord]

        @MainActor
        init(visit: Visit) {
            id = visit.id
            visitedAt = visit.visitedAt
            latitude = visit.latitude
            longitude = visit.longitude
            applePlaceID = visit.applePlaceID
            userDefinedPlaceName = visit.userDefinedPlaceName
            rating = visit.rating
            notes = visit.notes
            foodCategories = visit.foodCategories
            createdAt = visit.createdAt
            updatedAt = visit.updatedAt
            photos = visit.photos.map(PhotoRecord.init)
        }

        init(
            id: UUID,
            visitedAt: Date,
            latitude: Double? = nil,
            longitude: Double? = nil,
            applePlaceID: String? = nil,
            userDefinedPlaceName: String? = nil,
            rating: Int? = nil,
            notes: String = "",
            foodCategories: [String] = [],
            createdAt: Date,
            updatedAt: Date,
            photos: [PhotoRecord] = []
        ) {
            self.id = id
            self.visitedAt = visitedAt
            self.latitude = latitude
            self.longitude = longitude
            self.applePlaceID = applePlaceID
            self.userDefinedPlaceName = userDefinedPlaceName
            self.rating = rating
            self.notes = notes
            self.foodCategories = foodCategories
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.photos = photos
        }
    }

    struct PhotoRecord: Codable, Equatable, Sendable {
        let assetLocalIdentifier: String
        let capturedAt: Date?
        let latitude: Double?
        let longitude: Double?
        let classificationLabels: [String]
        let isPrimary: Bool

        @MainActor
        init(photo: VisitPhoto) {
            assetLocalIdentifier = photo.assetLocalIdentifier
            capturedAt = photo.capturedAt
            latitude = photo.latitude
            longitude = photo.longitude
            classificationLabels = photo.classificationLabels
            isPrimary = photo.isPrimary
        }

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
    }
}

enum JournalBackupError: LocalizedError {
    case iCloudUnavailable
    case unsupportedVersion
    case invalidArchive

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            "Sign in to iCloud in Settings, then try again."
        case .unsupportedVersion:
            "This backup was created by a newer version of Ate Here."
        case .invalidArchive:
            "The iCloud backup could not be read."
        }
    }
}

protocol JournalBackupService: Sendable {
    func isICloudAvailable() async throws -> Bool
    func metadata() async throws -> JournalBackupMetadata?
    func save(_ archive: JournalBackupArchive) async throws
    func load() async throws -> JournalBackupArchive?
}

actor CloudKitJournalBackupService: JournalBackupService {
    static let shared = CloudKitJournalBackupService()

    private static let containerIdentifier = "iCloud.io.jonsson.atehere"
    private static let recordType = "JournalBackup"
    private static let recordName = "primary-journal"
    private static let archiveField = "archive"
    private static let createdAtField = "createdAt"
    private static let visitCountField = "visitCount"

    private lazy var container = CKContainer(identifier: Self.containerIdentifier)

    private var database: CKDatabase {
        container.privateCloudDatabase
    }

    func isICloudAvailable() async throws -> Bool {
        try await container.accountStatus() == .available
    }

    func metadata() async throws -> JournalBackupMetadata? {
        guard let record = try await fetchRecord() else { return nil }
        guard let createdAt = record[Self.createdAtField] as? Date else {
            throw JournalBackupError.invalidArchive
        }
        let visitCount = (record[Self.visitCountField] as? NSNumber)?.intValue ?? 0
        return JournalBackupMetadata(createdAt: createdAt, visitCount: visitCount)
    }

    func save(_ archive: JournalBackupArchive) async throws {
        guard try await isICloudAvailable() else {
            throw JournalBackupError.iCloudUnavailable
        }

        let data = try JSONEncoder().encode(archive)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ateherebackup")
        try data.write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let record = try await fetchRecord() ?? CKRecord(
            recordType: Self.recordType,
            recordID: recordID
        )
        record[Self.archiveField] = CKAsset(fileURL: temporaryURL)
        record[Self.createdAtField] = archive.createdAt as CKRecordValue
        record[Self.visitCountField] = archive.visits.count as CKRecordValue
        _ = try await database.save(record)
    }

    func load() async throws -> JournalBackupArchive? {
        guard try await isICloudAvailable() else {
            throw JournalBackupError.iCloudUnavailable
        }
        guard let record = try await fetchRecord(),
              let asset = record[Self.archiveField] as? CKAsset,
              let fileURL = asset.fileURL
        else {
            return nil
        }

        let archive: JournalBackupArchive
        do {
            archive = try JSONDecoder().decode(
                JournalBackupArchive.self,
                from: Data(contentsOf: fileURL)
            )
        } catch {
            throw JournalBackupError.invalidArchive
        }
        guard archive.version <= JournalBackupArchive.currentVersion else {
            throw JournalBackupError.unsupportedVersion
        }
        return archive
    }

    private var recordID: CKRecord.ID {
        CKRecord.ID(recordName: Self.recordName)
    }

    private func fetchRecord() async throws -> CKRecord? {
        do {
            return try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }
}

@MainActor
enum JournalBackupOperations {
    @discardableResult
    static func backUp(
        context: ModelContext,
        service: any JournalBackupService = CloudKitJournalBackupService.shared,
        now: Date = .now
    ) async throws -> JournalBackupMetadata {
        let visits = try context.fetch(
            FetchDescriptor<Visit>(sortBy: [SortDescriptor(\Visit.visitedAt, order: .reverse)])
        )
        let archive = JournalBackupArchive(visits: visits, createdAt: now)
        try await service.save(archive)
        UserDefaults.standard.set(
            now.timeIntervalSince1970,
            forKey: ICloudJournalBackupSettings.lastBackupDateKey
        )
        return JournalBackupMetadata(createdAt: now, visitCount: visits.count)
    }

    @discardableResult
    static func restore(
        context: ModelContext,
        service: any JournalBackupService = CloudKitJournalBackupService.shared
    ) async throws -> Int {
        guard let archive = try await service.load() else { return 0 }
        return try merge(archive, into: context)
    }

    @discardableResult
    static func merge(_ archive: JournalBackupArchive, into context: ModelContext) throws -> Int {
        let localVisits = try context.fetch(FetchDescriptor<Visit>())
        let visitsByID = Dictionary(uniqueKeysWithValues: localVisits.map { ($0.id, $0) })
        var changedCount = 0

        for record in archive.visits {
            if let visit = visitsByID[record.id] {
                guard record.updatedAt > visit.updatedAt else { continue }
                apply(record, to: visit, in: context)
            } else {
                let visit = Visit(
                    id: record.id,
                    visitedAt: record.visitedAt,
                    latitude: record.latitude,
                    longitude: record.longitude,
                    applePlaceID: record.applePlaceID,
                    userDefinedPlaceName: record.userDefinedPlaceName,
                    rating: record.rating,
                    notes: record.notes,
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt
                )
                visit.foodCategories = record.foodCategories
                visit.photos = record.photos.map(makePhoto)
                context.insert(visit)
            }
            changedCount += 1
        }

        if changedCount > 0 {
            try context.save()
        }
        return changedCount
    }

    private static func apply(
        _ record: JournalBackupArchive.VisitRecord,
        to visit: Visit,
        in context: ModelContext
    ) {
        visit.visitedAt = record.visitedAt
        visit.latitude = record.latitude
        visit.longitude = record.longitude
        visit.applePlaceID = record.applePlaceID
        visit.userDefinedPlaceName = record.userDefinedPlaceName
        visit.rating = record.rating
        visit.notes = record.notes
        visit.foodCategories = record.foodCategories
        visit.createdAt = record.createdAt
        visit.updatedAt = record.updatedAt
        visit.photos.forEach(context.delete)
        visit.photos = record.photos.map(makePhoto)
    }

    private static func makePhoto(_ record: JournalBackupArchive.PhotoRecord) -> VisitPhoto {
        VisitPhoto(
            assetLocalIdentifier: record.assetLocalIdentifier,
            capturedAt: record.capturedAt,
            latitude: record.latitude,
            longitude: record.longitude,
            classificationLabels: record.classificationLabels,
            isPrimary: record.isPrimary
        )
    }
}
