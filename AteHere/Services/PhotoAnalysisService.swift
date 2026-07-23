import CoreGraphics
import Foundation
import Vision

enum FoodCategory: String, CaseIterable, Hashable, Sendable {
    case meal = "Food"
    case pizza = "Pizza"
    case burger = "Burger"
    case steak = "Steak"
    case sushi = "Sushi"
    case ramen = "Ramen"
    case pasta = "Pasta"
    case tacos = "Tacos"
    case indianFood = "Indian food"
    case chineseFood = "Chinese food"
    case seafood = "Seafood"
    case salad = "Salad"
    case coffee = "Coffee"
    case pastry = "Pastry"
    case dessert = "Dessert"
    case cocktails = "Cocktails"
    case beer = "Beer"
    case wine = "Wine"
    case menu = "Menu"
    case receipt = "Receipt"
    case restaurantInterior = "Restaurant interior"
}

struct ImageClassificationLabel: Equatable, Sendable {
    let identifier: String
    let confidence: Double
}

struct FoodClassification: Equatable, Sendable {
    let category: FoodCategory
    let confidence: Double
}

protocol PhotoAnalysisService: Sendable {
    func classifications(for image: CGImage) async throws -> [FoodClassification]
}

struct VisionPhotoAnalysisService: PhotoAnalysisService {
    func classifications(for image: CGImage) async throws -> [FoodClassification] {
        let labels = try await Task.detached(priority: .utility) {
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: image)
            try handler.perform([request])

            return (request.results ?? []).prefix(20).map {
                ImageClassificationLabel(
                    identifier: $0.identifier,
                    confidence: Double($0.confidence)
                )
            }
        }.value

        return FoodCategoryMapper.classifications(from: labels)
    }
}

enum FoodCategoryMapper {
    private static let tokens: [(FoodCategory, [String])] = [
        (.pizza, ["pizza"]),
        (.burger, ["burger", "hamburger"]),
        (.steak, ["steak"]),
        (.sushi, ["sushi", "sashimi"]),
        (.ramen, ["ramen"]),
        (.pasta, ["pasta", "spaghetti", "noodle"]),
        (.tacos, ["taco"]),
        (.indianFood, ["indian food", "curry"]),
        (.chineseFood, ["chinese food", "dim sum"]),
        (.seafood, ["seafood", "shellfish", "lobster", "shrimp"]),
        (.salad, ["salad"]),
        (.coffee, ["coffee", "espresso", "cappuccino", "latte"]),
        (.pastry, ["pastry", "croissant", "donut", "doughnut"]),
        (.dessert, ["dessert", "cake", "ice cream"]),
        (.cocktails, ["cocktail", "mixed drink"]),
        (.beer, ["beer", "ale", "lager"]),
        (.wine, ["wine"]),
        (.menu, ["menu"]),
        (.receipt, ["receipt"]),
        (.restaurantInterior, ["restaurant", "dining room", "dining table"]),
        (.meal, ["food", "meal", "dish", "cuisine", "beverage"]),
    ]

    static func classifications(
        from labels: [ImageClassificationLabel],
        minimumConfidence: Double = 0.12
    ) -> [FoodClassification] {
        var confidenceByCategory: [FoodCategory: Double] = [:]

        for label in labels where label.confidence >= minimumConfidence {
            let normalizedIdentifier = label.identifier.lowercased()

            for (category, categoryTokens) in tokens
            where categoryTokens.contains(where: normalizedIdentifier.contains) {
                confidenceByCategory[category] = max(
                    confidenceByCategory[category] ?? 0,
                    label.confidence
                )
            }
        }

        return confidenceByCategory
            .map { FoodClassification(category: $0.key, confidence: $0.value) }
            .sorted { $0.confidence > $1.confidence }
    }
}
