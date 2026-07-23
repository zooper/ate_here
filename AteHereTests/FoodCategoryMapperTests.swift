import Testing
@testable import AteHere

struct FoodCategoryMapperTests {
    @Test("Broad Vision labels map to useful food categories")
    func labelsMapToCategories() {
        let results = FoodCategoryMapper.classifications(
            from: [
                ImageClassificationLabel(identifier: "pepperoni pizza", confidence: 0.82),
                ImageClassificationLabel(identifier: "espresso coffee", confidence: 0.65),
                ImageClassificationLabel(identifier: "unrelated object", confidence: 0.95),
            ]
        )

        #expect(results.map(\.category) == [.pizza, .coffee])
    }

    @Test("Low confidence food labels are ignored")
    func lowConfidenceIsIgnored() {
        let results = FoodCategoryMapper.classifications(
            from: [ImageClassificationLabel(identifier: "sushi", confidence: 0.05)]
        )

        #expect(results.isEmpty)
    }
}
