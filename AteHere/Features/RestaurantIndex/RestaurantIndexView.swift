import SwiftData
import SwiftUI

enum RestaurantIndexSort: String, CaseIterable, Identifiable {
    case mostRecent = "Most recent"
    case mostVisited = "Most visited"
    case highestRated = "Highest rated"

    var id: Self { self }
}

struct RestaurantIndexEntry: Identifiable {
    let id: String
    let visits: [Visit]
    let tags: [String]

    var representativeVisit: Visit { visits[0] }
    var visitCount: Int { visits.count }
    var mostRecentVisit: Date { representativeVisit.visitedAt }

    var averageRating: Double? {
        let ratings = visits.compactMap(\.rating)
        guard !ratings.isEmpty else { return nil }
        return Double(ratings.reduce(0, +)) / Double(ratings.count)
    }
}

enum RestaurantIndex {
    static func entries(
        from visits: [Visit],
        matching tag: String? = nil,
        sortedBy sort: RestaurantIndexSort = .mostRecent
    ) -> [RestaurantIndexEntry] {
        let grouped = Dictionary(grouping: visits, by: restaurantKey)
        let entries = grouped.map { key, groupedVisits in
            let sortedVisits = groupedVisits.sorted { $0.visitedAt > $1.visitedAt }
            var seenTags = Set<String>()
            let tags = sortedVisits
                .flatMap(\.foodCategories)
                .compactMap(VisitTagRules.normalizedTag)
                .filter { tag in
                    let key = tag.folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: .current
                    )
                    return seenTags.insert(key).inserted
                }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

            return RestaurantIndexEntry(
                id: key,
                visits: sortedVisits,
                tags: tags
            )
        }
        let filtered = entries.filter { entry in
            guard let tag else { return true }
            return entry.tags.contains { VisitTagRules.matches($0, tag) }
        }

        return filtered.sorted { lhs, rhs in
            switch sort {
            case .mostRecent:
                return lhs.mostRecentVisit > rhs.mostRecentVisit
            case .mostVisited:
                if lhs.visitCount == rhs.visitCount {
                    return lhs.mostRecentVisit > rhs.mostRecentVisit
                }
                return lhs.visitCount > rhs.visitCount
            case .highestRated:
                let lhsRating = lhs.averageRating ?? -1
                let rhsRating = rhs.averageRating ?? -1
                if lhsRating == rhsRating {
                    return lhs.mostRecentVisit > rhs.mostRecentVisit
                }
                return lhsRating > rhsRating
            }
        }
    }

    static func tagCounts(from entries: [RestaurantIndexEntry]) -> [(tag: String, count: Int)] {
        var counts: [String: (displayName: String, count: Int)] = [:]
        for entry in entries {
            for tag in entry.tags {
                let key = tag.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                let existing = counts[key]
                counts[key] = (existing?.displayName ?? tag, (existing?.count ?? 0) + 1)
            }
        }
        return counts.values
            .map { ($0.displayName, $0.count) }
            .sorted { $0.tag.localizedCaseInsensitiveCompare($1.tag) == .orderedAscending }
    }

    private static func restaurantKey(for visit: Visit) -> String {
        if let placeID = visit.applePlaceID {
            return "apple:\(placeID)"
        }
        let customName = visit.userDefinedPlaceName ?? visit.id.uuidString
        return "custom:\(customName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))"
    }
}

struct RestaurantIndexView: View {
    @Query(sort: \Visit.visitedAt, order: .reverse) private var visits: [Visit]

    let placeSearchService: any PlaceSearchService
    let photoLibraryService: any PhotoLibraryService

    @State private var selectedTag: String?
    @State private var sortOrder: RestaurantIndexSort = .mostRecent

    init(
        placeSearchService: any PlaceSearchService = MapKitPlaceSearchService(),
        photoLibraryService: any PhotoLibraryService = LivePhotoLibraryService()
    ) {
        self.placeSearchService = placeSearchService
        self.photoLibraryService = photoLibraryService
    }

    var body: some View {
        NavigationStack {
            Group {
                if visits.isEmpty {
                    emptyIndex
                } else {
                    indexContent
                }
            }
            .navigationTitle("Places")
            .navigationBarTitleDisplayMode(visits.isEmpty ? .large : .inline)
            .toolbarBackground(AlbumTheme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .tint(AlbumTheme.burgundy)
    }

    private var indexContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                indexHeader
                tagIndex

                HStack {
                    Text(resultCountLabel)
                        .font(.system(.headline, design: .serif).weight(.semibold))
                        .foregroundStyle(AlbumTheme.ink)

                    Spacer()

                    Menu {
                        Picker("Sort restaurants", selection: $sortOrder) {
                            ForEach(RestaurantIndexSort.allCases) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                    } label: {
                        Label(sortOrder.rawValue, systemImage: "arrow.up.arrow.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AlbumTheme.ink)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(AlbumTheme.photoPaper)
                            .clipShape(Capsule())
                            .overlay {
                                Capsule().stroke(AlbumTheme.paperEdge, lineWidth: 1)
                            }
                    }
                }

                if filteredEntries.isEmpty {
                    ContentUnavailableView {
                        Label("No \(selectedTag ?? "matching") places", systemImage: "tag.slash")
                    } description: {
                        Text("Remove the filter or add this tag to a visit.")
                    } actions: {
                        Button("Show all places") {
                            selectedTag = nil
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    ForEach(filteredEntries) { entry in
                        NavigationLink {
                            VisitDetailView(
                                visit: entry.representativeVisit,
                                placeSearchService: placeSearchService,
                                photoLibraryService: photoLibraryService
                            )
                        } label: {
                            RestaurantIndexCard(
                                entry: entry,
                                placeSearchService: placeSearchService,
                                photoLibraryService: photoLibraryService
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("restaurantIndexRow")
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 36)
        }
        .background(AlbumTheme.paper)
        .scrollIndicators(.hidden)
    }

    private var indexHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("RESTAURANT INDEX")
                .font(.caption2.monospaced().weight(.semibold))
                .tracking(1.6)
                .foregroundStyle(AlbumTheme.leatherFoil)

            Text("Find a table by\nwhat you ate")
                .font(.system(.title, design: .serif).weight(.semibold))
                .foregroundStyle(AlbumTheme.leatherText)

            Rectangle()
                .fill(AlbumTheme.leatherFoil.opacity(0.72))
                .frame(height: 1)

            Text("\(allEntries.count) place\(allEntries.count == 1 ? "" : "s") · \(tagCounts.count) tag\(tagCounts.count == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(AlbumTheme.leatherText.opacity(0.82))
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AlbumTheme.leather)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AlbumTheme.leatherFoil.opacity(0.58), lineWidth: 1)
                .padding(6)
        }
    }

    private var tagIndex: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                tagButton(title: "All", count: allEntries.count, tag: nil)
                ForEach(tagCounts, id: \.tag) { item in
                    tagButton(title: item.tag, count: item.count, tag: item.tag)
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Filter places by tag")
    }

    private func tagButton(title: String, count: Int, tag: String?) -> some View {
        let isSelected = selectedTag.map { selected in
            tag.map { VisitTagRules.matches(selected, $0) } ?? false
        } ?? (tag == nil)

        return Button {
            selectedTag = tag
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .opacity(0.72)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSelected ? AlbumTheme.leatherText : AlbumTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isSelected ? AlbumTheme.burgundy : AlbumTheme.photoPaper)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSelected ? AlbumTheme.leatherFoil : AlbumTheme.brass.opacity(0.55))
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("restaurantTagFilter-\(title)")
        .accessibilityLabel("\(title), \(count) places")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var allEntries: [RestaurantIndexEntry] {
        RestaurantIndex.entries(from: visits)
    }

    private var filteredEntries: [RestaurantIndexEntry] {
        RestaurantIndex.entries(
            from: visits,
            matching: selectedTag,
            sortedBy: sortOrder
        )
    }

    private var tagCounts: [(tag: String, count: Int)] {
        RestaurantIndex.tagCounts(from: allEntries)
    }

    private var resultCountLabel: String {
        let count = filteredEntries.count
        if let selectedTag {
            return "\(count) \(selectedTag) place\(count == 1 ? "" : "s")"
        }
        return "All places"
    }

    private var emptyIndex: some View {
        ContentUnavailableView {
            Label("No places yet", systemImage: "text.book.closed")
        } description: {
            Text("Restaurants appear here after you save your first visit.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AlbumTheme.paper)
    }
}

private struct RestaurantIndexCard: View {
    let entry: RestaurantIndexEntry
    let placeSearchService: any PlaceSearchService
    let photoLibraryService: any PhotoLibraryService

    @State private var resolvedPlaceName: String?
    @State private var placeResolutionFailed = false

    var body: some View {
        HStack(spacing: 15) {
            Group {
                if let photoIdentifier = primaryPhotoIdentifier {
                    PhotoThumbnailView(
                        assetIdentifier: photoIdentifier,
                        photoLibraryService: photoLibraryService,
                        size: 92,
                        cornerRadius: 4
                    )
                } else {
                    ZStack {
                        AlbumTheme.leatherHighlight
                        Image(systemName: "fork.knife")
                            .foregroundStyle(AlbumTheme.leatherFoil)
                    }
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .overlay { AlbumCornerMounts().padding(1) }

            VStack(alignment: .leading, spacing: 7) {
                Text(displayPlaceName)
                    .font(.system(.headline, design: .serif).weight(.semibold))
                    .foregroundStyle(AlbumTheme.ink)
                    .lineLimit(2)

                if !entry.tags.isEmpty {
                    Text(entry.tags.prefix(3).joined(separator: " · "))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AlbumTheme.burgundy)
                        .lineLimit(1)
                }

                HStack(spacing: 7) {
                    Text("\(entry.visitCount) visit\(entry.visitCount == 1 ? "" : "s")")
                    if let rating = entry.averageRating {
                        Text("•")
                        Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(AlbumTheme.mutedInk)

                Text(entry.mostRecentVisit, format: .dateTime.month(.abbreviated).day().year())
                    .font(.caption2)
                    .foregroundStyle(AlbumTheme.mutedInk)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AlbumTheme.mutedInk)
        }
        .padding(11)
        .background(AlbumTheme.photoPaper)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AlbumTheme.paperEdge, lineWidth: 1)
        }
        .task(id: entry.representativeVisit.applePlaceID) {
            await resolvePlaceName()
        }
        .accessibilityElement(children: .combine)
    }

    private var primaryPhotoIdentifier: String? {
        entry.representativeVisit.photos.first(where: \.isPrimary)?.assetLocalIdentifier
            ?? entry.representativeVisit.photos.first?.assetLocalIdentifier
    }

    private var displayPlaceName: String {
        if let customName = entry.representativeVisit.userDefinedPlaceName {
            return customName
        }
        if let resolvedPlaceName {
            return resolvedPlaceName
        }
        return placeResolutionFailed ? "Place unavailable" : "Loading restaurant…"
    }

    @MainActor
    private func resolvePlaceName() async {
        guard let placeID = entry.representativeVisit.applePlaceID else { return }
        do {
            let place = try await placeSearchService.resolvePlace(identifier: placeID)
            try Task.checkCancellation()
            resolvedPlaceName = place?.name
            placeResolutionFailed = place == nil
        } catch is CancellationError {
            return
        } catch {
            placeResolutionFailed = true
        }
    }
}
