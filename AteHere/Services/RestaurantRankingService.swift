import CoreLocation
import Foundation

struct RestaurantCandidateScore: Equatable, Sendable {
    let placeID: String
    let distanceScore: Double
    let foodCompatibilityScore: Double
    let categoryScore: Double
    let negativeEvidenceScore: Double
    let totalScore: Double
    let hasFoodEvidence: Bool
}

struct RankedRestaurantCandidate: Identifiable, Equatable, Sendable {
    let result: RestaurantSearchResult
    let score: RestaurantCandidateScore

    var id: String { result.id }

    /// A coarse heuristic match, not a calibrated statistical confidence.
    var matchPercentage: Int? {
        guard score.hasFoodEvidence else { return nil }
        let percentage = Int((score.totalScore * 100 / 5).rounded()) * 5
        return min(95, max(0, percentage))
    }
}

enum RestaurantCandidateRanking {
    enum Configuration {
        static let relevantDistance: CLLocationDistance = 750
        static let distanceWeight = 0.30
        static let foodCompatibilityWeight = 0.55
        static let categoryWeight = 0.15
        static let mismatchedBusinessPenalty = 0.20
    }

    static func rank(
        _ candidates: [RestaurantSearchResult],
        near coordinate: CLLocationCoordinate2D,
        foodCategories: [FoodCategory],
        limit: Int
    ) -> [RankedRestaurantCandidate] {
        let scoredCandidates = candidates.map { candidate in
            RankedRestaurantCandidate(
                result: candidate,
                score: score(
                    candidate,
                    near: coordinate,
                    foodCategories: foodCategories
                )
            )
        }

        return Array(
            scoredCandidates.sorted { lhs, rhs in
                if lhs.score.totalScore == rhs.score.totalScore {
                    return lhs.result.distance(from: coordinate) < rhs.result.distance(from: coordinate)
                }
                return lhs.score.totalScore > rhs.score.totalScore
            }.prefix(limit)
        )
    }

    static func score(
        _ candidate: RestaurantSearchResult,
        near coordinate: CLLocationCoordinate2D,
        foodCategories: [FoodCategory]
    ) -> RestaurantCandidateScore {
        let evidence = meaningfulEvidence(from: foodCategories)
        let distance = candidate.distance(from: coordinate)
        let distanceScore = max(0, 1 - distance / Configuration.relevantDistance)

        guard !evidence.isEmpty else {
            return RestaurantCandidateScore(
                placeID: candidate.placeID,
                distanceScore: distanceScore,
                foodCompatibilityScore: 0,
                categoryScore: 0,
                negativeEvidenceScore: 0,
                totalScore: distanceScore,
                hasFoodEvidence: false
            )
        }

        let foodScore = evidence.map {
            foodCompatibility(of: candidate, with: $0)
        }.max() ?? 0
        let placeCategoryScore = evidence.map {
            categoryCompatibility(of: candidate.placeKind, with: $0)
        }.max() ?? 0
        let negativeEvidence = mismatchPenalty(
            for: candidate.placeKind,
            foodCategories: evidence
        )
        let totalScore = min(
            1,
            max(
                0,
                distanceScore * Configuration.distanceWeight
                    + foodScore * Configuration.foodCompatibilityWeight
                    + placeCategoryScore * Configuration.categoryWeight
                    - negativeEvidence
            )
        )

        return RestaurantCandidateScore(
            placeID: candidate.placeID,
            distanceScore: distanceScore,
            foodCompatibilityScore: foodScore,
            categoryScore: placeCategoryScore,
            negativeEvidenceScore: negativeEvidence,
            totalScore: totalScore,
            hasFoodEvidence: true
        )
    }

    static func meaningfulEvidence(from categories: [FoodCategory]) -> [FoodCategory] {
        var seen = Set<FoodCategory>()
        return categories.filter { category in
            guard category.isRestaurantFoodEvidence else { return false }
            return seen.insert(category).inserted
        }
    }

    private static func foodCompatibility(
        of candidate: RestaurantSearchResult,
        with foodCategory: FoodCategory
    ) -> Double {
        if candidate.foodHints.contains(foodCategory) {
            return 1
        }

        let normalizedName = candidate.name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        if foodCategory.restaurantNameKeywords.contains(where: normalizedName.contains) {
            return 1
        }

        switch candidate.placeKind {
        case .restaurant:
            return foodCategory.isSavoryMeal ? 0.35 : 0.25
        case .cafe:
            return [.coffee, .pastry, .dessert].contains(foodCategory) ? 0.65 : 0.08
        case .bakery:
            return [.pastry, .dessert, .coffee].contains(foodCategory) ? 0.75 : 0.03
        case .brewery:
            return foodCategory == .beer ? 0.9 : 0.08
        case .winery:
            return foodCategory == .wine ? 0.9 : 0.08
        case .foodMarket:
            return 0.18
        case .other:
            return 0
        }
    }

    private static func categoryCompatibility(
        of placeKind: RestaurantPlaceKind,
        with foodCategory: FoodCategory
    ) -> Double {
        switch placeKind {
        case .restaurant:
            return foodCategory.isSavoryMeal ? 1 : 0.55
        case .cafe:
            return [.coffee, .pastry, .dessert].contains(foodCategory) ? 1 : 0.15
        case .bakery:
            return [.pastry, .dessert].contains(foodCategory) ? 1 : 0.1
        case .brewery:
            return foodCategory == .beer ? 1 : 0.1
        case .winery:
            return foodCategory == .wine ? 1 : 0.1
        case .foodMarket:
            return 0.25
        case .other:
            return 0
        }
    }

    private static func mismatchPenalty(
        for placeKind: RestaurantPlaceKind,
        foodCategories: [FoodCategory]
    ) -> Double {
        let hasSavoryFood = foodCategories.contains(where: \.isSavoryMeal)
        guard hasSavoryFood else { return 0 }

        switch placeKind {
        case .cafe, .bakery, .brewery, .winery, .other:
            return Configuration.mismatchedBusinessPenalty
        case .restaurant, .foodMarket:
            return 0
        }
    }
}

extension FoodCategory {
    var isRestaurantFoodEvidence: Bool {
        switch self {
        case .meal, .menu, .receipt, .restaurantInterior:
            return false
        default:
            return true
        }
    }

    var isSavoryMeal: Bool {
        switch self {
        case .pizza, .burger, .steak, .sushi, .ramen, .pasta, .tacos,
             .indianFood, .chineseFood, .seafood, .salad:
            return true
        default:
            return false
        }
    }

    var mapSearchQuery: String? {
        switch self {
        case .pizza: "pizza restaurant"
        case .burger: "burger restaurant"
        case .steak: "steakhouse"
        case .sushi: "sushi restaurant"
        case .ramen: "ramen restaurant"
        case .pasta: "Italian restaurant"
        case .tacos: "taco restaurant"
        case .indianFood: "Indian restaurant"
        case .chineseFood: "Chinese restaurant"
        case .seafood: "seafood restaurant"
        case .salad: "salad restaurant"
        case .coffee: "coffee shop"
        case .pastry: "bakery"
        case .dessert: "dessert shop"
        case .cocktails: "cocktail bar"
        case .beer: "brewery"
        case .wine: "wine bar"
        case .meal, .menu, .receipt, .restaurantInterior: nil
        }
    }

    fileprivate var restaurantNameKeywords: [String] {
        switch self {
        case .pizza: ["pizza", "pizzeria", "italian", "trattoria"]
        case .burger: ["burger", "hamburger", "grill"]
        case .steak: ["steak", "steakhouse", "chophouse", "grill"]
        case .sushi: ["sushi", "sashimi", "japanese", "izakaya"]
        case .ramen: ["ramen", "noodle", "japanese"]
        case .pasta: ["pasta", "italian", "trattoria"]
        case .tacos: ["taco", "taqueria", "mexican"]
        case .indianFood: ["indian", "curry", "tandoor"]
        case .chineseFood: ["chinese", "dim sum", "szechuan", "sichuan", "cantonese"]
        case .seafood: ["seafood", "fish", "oyster", "lobster"]
        case .salad: ["salad", "healthy"]
        case .coffee: ["coffee", "cafe", "espresso"]
        case .pastry: ["bakery", "pastry", "patisserie", "donut"]
        case .dessert: ["dessert", "ice cream", "gelato", "cake"]
        case .cocktails: ["cocktail", "bar", "lounge"]
        case .beer: ["brewery", "beer", "taproom", "pub"]
        case .wine: ["wine", "winery", "enoteca"]
        case .meal, .menu, .receipt, .restaurantInterior: []
        }
    }
}
