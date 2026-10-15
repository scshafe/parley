import XCTest

/// Drives the app in the simulator against a dev relay (`parley-relay --dev`,
/// started by CI on 127.0.0.1:8765): send a turn, see it reach `ready`, open
/// the reader-player and see the highlight follow the audio.
final class ParleyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        app.launchEnvironment["PARLEY_UI_TESTING"] = "1"
        app.launchEnvironment["PARLEY_RELAY_URL"] = env["PARLEY_RELAY_URL"] ?? "http://127.0.0.1:8765"
        app.launchEnvironment["PARLEY_DEV_TOKEN"] = env["PARLEY_DEV_TOKEN"] ?? "parley-dev"
        app.launch()
        return app
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func probeValue(_ app: XCUIApplication) -> Int? {
        Int(app.staticTexts["highlightProbe"].value as? String ?? "")
    }

    func testATurnBecomesReadyAndTheHighlightFollowsTheAudio() throws {
        let app = launch()

        let newConversation = app.buttons["newConversation"]
        XCTAssertTrue(newConversation.waitForExistence(timeout: 20))
        newConversation.tap()

        let field = app.descendants(matching: .any)["composerField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("What should I cook tonight?")
        app.buttons["sendButton"].tap()

        // thinking -> speaking -> ready, followed over the relay's event stream.
        let play = app.buttons["playTurn-1"]
        XCTAssertTrue(play.waitForExistence(timeout: 90), "the turn never became ready")
        XCTAssertEqual(app.descendants(matching: .any)["turnState-1"].firstMatch.value as? String, "ready")
        screenshot(app, "conversation-ready")
        play.tap()

        // The reader-player loads the audio and timings and starts playing.
        let probe = app.staticTexts["highlightProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 20))
        var first: Int?
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let v = probeValue(app) { first = v; break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        let start = try XCTUnwrap(first, "the highlight never started")
        Thread.sleep(forTimeInterval: 2.5)
        let later = try XCTUnwrap(probeValue(app))
        XCTAssertGreaterThan(later, start, "the highlight did not advance with the audio")
        screenshot(app, "reader-highlight")

        // Tap a word to seek back to it.
        let firstWord = app.descendants(matching: .any)["word-0"].firstMatch
        XCTAssertTrue(firstWord.exists)
        firstWord.tap()
        let afterSeek = try XCTUnwrap(probeValue(app))
        XCTAssertLessThan(afterSeek, later, "tapping a word did not seek")

        // Speed cycles through 0.75x to 1.5x.
        let speed = app.buttons["speedButton"]
        XCTAssertEqual(speed.label, "Speed 1×")
        speed.tap()
        XCTAssertEqual(speed.label, "Speed 1.25×")

        // Pause stops the clock.
        app.buttons["playPauseButton"].tap()
        let paused = probeValue(app)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(probeValue(app), paused)
    }

    func testAnAttachmentIsShownBelowTheReply() throws {
        let app = launch()
        let newConversation = app.buttons["newConversation"]
        XCTAssertTrue(newConversation.waitForExistence(timeout: 20))
        newConversation.tap()
        let field = app.descendants(matching: .any)["composerField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Send me a link about bread")
        app.buttons["sendButton"].tap()
        let play = app.buttons["playTurn-1"]
        XCTAssertTrue(play.waitForExistence(timeout: 90))
        play.tap()
        XCTAssertTrue(app.descendants(matching: .any)["attachment"].firstMatch.waitForExistence(timeout: 20))
        screenshot(app, "reader-attachment")
    }
}
