import XCTest

final class AteHereUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEmptyJournalCanOpenNewVisit() throws {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(app.staticTexts["Your table is waiting"].waitForExistence(timeout: 3))
        app.buttons["Add your first visit"].tap()

        XCTAssertTrue(app.navigationBars["New Visit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["restaurantName"].exists)
        XCTAssertTrue(app.buttons["addVisitPhotos"].exists)
        XCTAssertFalse(app.buttons["saveVisit"].isEnabled)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Manual Visit Photo Picker"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testNewVisitCanOpenRestaurantSearch() throws {
        let app = makeApp()
        app.launch()

        app.buttons["Add your first visit"].tap()
        app.buttons["searchAppleMaps"].tap()

        XCTAssertTrue(app.navigationBars["Find Restaurant"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.searchFields.firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Find a restaurant"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Restaurant Search"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testPhotoImportExplainsPrivacyBeforeRequestingAccess() throws {
        let app = makeApp()
        app.launch()

        app.buttons["Import from Photos"].tap()

        XCTAssertTrue(app.navigationBars["Import Visits"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Find meals you photographed"].exists)
        XCTAssertTrue(app.staticTexts["Analysis stays on this iPhone"].exists)
        XCTAssertTrue(app.buttons["scanRecentPhotos"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Photo Import Privacy Introduction"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testAutomaticScanningCanBeConfiguredFromSettings() throws {
        let app = makeApp()
        app.launch()

        app.buttons["journalMenu"].tap()
        app.buttons["Settings"].tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.switches["automaticScanningToggle"].exists)
        XCTAssertTrue(app.switches["iCloudBackupToggle"].exists)
        XCTAssertTrue(app.staticTexts["Analysis stays on this iPhone"].exists)
        XCTAssertTrue(app.staticTexts["Photos are never uploaded"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Automatic Scanning Settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testHomeAreaCanBeConfiguredWithoutRequestingLocationFirst() throws {
        let app = makeApp()
        app.launch()

        app.buttons["journalMenu"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["setHomeArea"].waitForExistence(timeout: 2))
        app.buttons["setHomeArea"].tap()

        XCTAssertTrue(app.navigationBars["Home Area"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.otherElements["homeAreaMap"].exists)
        XCTAssertTrue(app.buttons["useCurrentHomeLocation"].exists)
        XCTAssertFalse(app.buttons["saveHomeArea"].isEnabled)
    }

    @MainActor
    func testPhotoMapHasDedicatedTabAndEmptyState() throws {
        let app = makeApp()
        app.launch()

        app.tabBars.buttons["Map"].tap()

        XCTAssertTrue(app.navigationBars["Photo Map"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["No geotagged photos"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Photo Map Empty State"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testCustomVisitCanBeSavedAndOpened() throws {
        let app = makeApp()
        app.launch()

        app.buttons["Add your first visit"].tap()
        app.textFields["restaurantName"].tap()
        app.textFields["restaurantName"].typeText("Neighborhood Bistro")
        app.buttons["saveVisit"].tap()

        XCTAssertTrue(app.staticTexts["Neighborhood Bistro"].waitForExistence(timeout: 2))

        let albumScreenshot = XCTAttachment(screenshot: app.screenshot())
        albumScreenshot.name = "Album Journal"
        albumScreenshot.lifetime = .keepAlways
        add(albumScreenshot)

        app.buttons["visitRow"].tap()
        XCTAssertTrue(app.navigationBars["Visit"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Neighborhood Bistro"].exists)

        let detailScreenshot = XCTAttachment(screenshot: app.screenshot())
        detailScreenshot.name = "Visit Memory"
        detailScreenshot.lifetime = .keepAlways
        add(detailScreenshot)
    }

    @MainActor
    func testTaggedVisitAppearsInFilteredPlacesIndex() throws {
        let app = makeApp()
        app.launch()

        app.buttons["Add your first visit"].tap()
        app.textFields["restaurantName"].tap()
        app.textFields["restaurantName"].typeText("Neighborhood Pizza")
        app.textFields["visitTagField"].tap()
        app.textFields["visitTagField"].typeText("Pizza")
        app.buttons["addVisitTag"].tap()
        app.buttons["saveVisit"].tap()

        XCTAssertTrue(app.staticTexts["Neighborhood Pizza"].waitForExistence(timeout: 2))
        app.tabBars.buttons["Places"].tap()

        XCTAssertTrue(app.navigationBars["Places"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["restaurantTagFilter-Pizza"].exists)
        app.buttons["restaurantTagFilter-Pizza"].tap()
        XCTAssertTrue(app.buttons["restaurantIndexRow"].exists)
        XCTAssertTrue(app.staticTexts["Neighborhood Pizza"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Pizza Restaurant Index"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testPendingMatchesCanBeSelectedAndMerged() throws {
        let app = makeApp()
        app.launchEnvironment["ATE_HERE_UI_TEST_PENDING_VISITS"] = "1"
        app.launch()

        app.buttons["Review 2 Matches"].tap()
        XCTAssertTrue(app.navigationBars["Review Matches"].waitForExistence(timeout: 2))
        app.buttons["selectPendingVisits"].tap()

        let firstMatch = app.buttons["selectPendingVisit-first-food-photo"]
        let secondMatch = app.buttons["selectPendingVisit-second-food-photo"]
        XCTAssertTrue(firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(secondMatch.exists)
        firstMatch.tap()
        secondMatch.tap()

        let selectionScreenshot = XCTAttachment(screenshot: app.screenshot())
        selectionScreenshot.name = "Select Matches to Merge"
        selectionScreenshot.lifetime = .keepAlways
        add(selectionScreenshot)

        XCTAssertTrue(app.buttons["mergePendingVisits"].isEnabled)
        app.buttons["mergePendingVisits"].tap()

        XCTAssertTrue(app.navigationBars["Review Visit"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testPendingMatchesCanAllBeDeleted() throws {
        let app = makeApp()
        app.launchEnvironment["ATE_HERE_UI_TEST_PENDING_VISITS"] = "1"
        app.launch()

        app.buttons["Review 2 Matches"].tap()
        XCTAssertTrue(app.navigationBars["Review Matches"].waitForExistence(timeout: 2))
        app.buttons["selectPendingVisits"].tap()
        app.buttons["selectAllPendingVisits"].tap()

        XCTAssertTrue(app.buttons["deleteSelectedPendingVisits"].isEnabled)
        app.buttons["deleteSelectedPendingVisits"].tap()
        XCTAssertTrue(app.buttons["Delete Matches"].waitForExistence(timeout: 2))
        app.buttons["Delete Matches"].tap()

        XCTAssertTrue(app.staticTexts["Nothing waiting"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testSavedJournalVisitsCanBeSelectedAndMerged() throws {
        let app = makeApp()
        app.launchEnvironment["ATE_HERE_UI_TEST_JOURNAL_MERGE"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["selectJournalVisits"].waitForExistence(timeout: 2))
        app.buttons["selectJournalVisits"].tap()

        let firstVisit = app.buttons[
            "selectJournalVisit-00000000-0000-0000-0000-000000000101"
        ]
        let secondVisit = app.buttons[
            "selectJournalVisit-00000000-0000-0000-0000-000000000102"
        ]
        XCTAssertTrue(firstVisit.waitForExistence(timeout: 2))
        XCTAssertTrue(secondVisit.exists)
        firstVisit.tap()
        secondVisit.tap()

        let selectionScreenshot = XCTAttachment(screenshot: app.screenshot())
        selectionScreenshot.name = "Select Journal Visits to Merge"
        selectionScreenshot.lifetime = .keepAlways
        add(selectionScreenshot)

        XCTAssertTrue(app.buttons["mergeJournalVisits"].isEnabled)
        app.buttons["mergeJournalVisits"].tap()
        XCTAssertTrue(app.alerts["Merge 2 visits?"].waitForExistence(timeout: 2))
        app.alerts.buttons["Merge Visits"].tap()

        XCTAssertTrue(app.staticTexts["2 meals remembered"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.buttons.matching(identifier: "visitRow").count, 2)
    }

    @MainActor
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ATE_HERE_UI_TESTING"] = "1"
        return app
    }
}
