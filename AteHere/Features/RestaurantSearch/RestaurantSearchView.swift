import MapKit
import SwiftUI

struct RestaurantSearchView: View {
    @Environment(\.dismiss) private var dismiss

    let placeSearchService: any PlaceSearchService
    let searchCenter: CLLocationCoordinate2D?
    let foodCategories: [FoodCategory]
    let onSelect: (RestaurantSearchResult) -> Void

    init(
        placeSearchService: any PlaceSearchService,
        searchCenter: CLLocationCoordinate2D? = nil,
        foodCategories: [FoodCategory] = [],
        onSelect: @escaping (RestaurantSearchResult) -> Void
    ) {
        self.placeSearchService = placeSearchService
        self.searchCenter = searchCenter
        self.foodCategories = foodCategories
        self.onSelect = onSelect
    }

    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var searchRequestID: UUID?
    @State private var nearbyRequestID: UUID?
    @State private var results: [RestaurantSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var didAttemptNearbySearch = false

    var body: some View {
        NavigationStack {
            Group {
                if isSearching {
                    ProgressView("Searching Apple Maps…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Search unavailable", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try again", action: retrySearch)
                            .buttonStyle(.borderedProminent)
                    }
                } else if results.isEmpty {
                    ContentUnavailableView {
                        Label("Find a restaurant", systemImage: "map")
                    } description: {
                        Text(emptyStateMessage)
                    }
                } else {
                    searchResults
                }
            }
            .navigationTitle("Find Restaurant")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Name, city, or neighborhood"
            )
            .onSubmit(of: .search, submitSearch)
            .task(id: searchRequestID) {
                await performSearch()
            }
            .task(id: nearbyRequestID) {
                await performNearbySearch()
            }
            .task {
                guard searchCenter != nil, nearbyRequestID == nil else { return }
                nearbyRequestID = UUID()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .tint(AlbumTheme.burgundy)
    }

    private var emptyStateMessage: String {
        if submittedQuery.isEmpty {
            if searchCenter != nil, didAttemptNearbySearch {
                return "No restaurants were found near the photo. Search by name or enter a custom place."
            }
            return searchCenter == nil
                ? "Search by restaurant name. Add a city or neighborhood when the name is common."
                : "Looking for restaurants near the photo location."
        }
        return "No matching restaurants were found. Try a broader search or enter a custom place."
    }

    private var searchResults: some View {
        let rankedResults = displayedResults

        return VStack(spacing: 0) {
            Map {
                ForEach(rankedResults) { rankedCandidate in
                    Marker(
                        rankedCandidate.result.name,
                        coordinate: rankedCandidate.result.coordinate
                    )
                        .tint(AlbumTheme.burgundy)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .frame(height: 230)
            .accessibilityLabel("Map of restaurant search results")

            List(rankedResults) { rankedCandidate in
                Button {
                    onSelect(rankedCandidate.result)
                    dismiss()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rankedCandidate.result.name)
                                .font(.headline)
                                .foregroundStyle(.primary)

                            if let subtitle = rankedCandidate.result.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }

                        Spacer()

                        if let searchCenter {
                            VStack(alignment: .trailing, spacing: 2) {
                                if let matchPercentage = rankedCandidate.matchPercentage {
                                    Text("\(matchPercentage)% match")
                                        .font(.caption.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(AlbumTheme.burgundy)
                                }

                                Text(distanceLabel(rankedCandidate.result.distance(from: searchCenter)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: rankedCandidate))
            }
            .listStyle(.plain)
        }
    }

    private var displayedResults: [RankedRestaurantCandidate] {
        // An explicit name search should retain Apple Maps' text-relevance
        // order. Only automatic nearby suggestions use photo-based ranking.
        guard submittedQuery.isEmpty, let searchCenter else {
            return unscoredResults
        }
        return RestaurantCandidateRanking.rank(
            results,
            near: searchCenter,
            foodCategories: foodCategories,
            limit: results.count
        )
    }

    private var unscoredResults: [RankedRestaurantCandidate] {
        results.map { result in
            RankedRestaurantCandidate(
                result: result,
                score: RestaurantCandidateScore(
                    placeID: result.placeID,
                    distanceScore: 0,
                    foodCompatibilityScore: 0,
                    categoryScore: 0,
                    negativeEvidenceScore: 0,
                    totalScore: 0,
                    hasFoodEvidence: false
                )
            )
        }
    }

    private func accessibilityLabel(
        for rankedCandidate: RankedRestaurantCandidate
    ) -> String {
        var parts = [rankedCandidate.result.name]
        if let subtitle = rankedCandidate.result.subtitle, !subtitle.isEmpty {
            parts.append(subtitle)
        }
        if let matchPercentage = rankedCandidate.matchPercentage {
            parts.append("\(matchPercentage) percent photo and location match")
        }
        if let searchCenter {
            parts.append(distanceLabel(rankedCandidate.result.distance(from: searchCenter)))
        }
        return parts.joined(separator: ", ")
    }

    private func submitSearch() {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return }

        submittedQuery = normalizedQuery
        searchRequestID = UUID()
    }

    private func retrySearch() {
        if submittedQuery.isEmpty, searchCenter != nil {
            nearbyRequestID = UUID()
        } else {
            searchRequestID = UUID()
        }
    }

    @MainActor
    private func performNearbySearch() async {
        guard nearbyRequestID != nil, let searchCenter else { return }

        isSearching = true
        errorMessage = nil

        do {
            let newResults = try await placeSearchService.nearbyRestaurants(
                near: searchCenter,
                foodCategories: foodCategories
            )
            try Task.checkCancellation()
            submittedQuery = ""
            results = newResults
            didAttemptNearbySearch = true
            isSearching = false
        } catch is CancellationError {
            return
        } catch {
            results = []
            didAttemptNearbySearch = true
            isSearching = false
            errorMessage = "Check your connection and try nearby suggestions again."
        }
    }

    @MainActor
    private func performSearch() async {
        guard searchRequestID != nil, !submittedQuery.isEmpty else { return }

        isSearching = true
        errorMessage = nil

        do {
            let newResults = try await placeSearchService.searchRestaurants(
                matching: submittedQuery,
                near: searchCenter,
                foodCategories: foodCategories
            )
            try Task.checkCancellation()
            results = newResults
            isSearching = false
        } catch is CancellationError {
            return
        } catch {
            results = []
            isSearching = false
            errorMessage = "Check your connection and search again."
        }
    }

    private func distanceLabel(_ distance: CLLocationDistance) -> String {
        if distance < 1_000 {
            return "\(Int(distance.rounded())) m from photo"
        }
        return String(format: "%.1f km from photo", distance / 1_000)
    }
}
