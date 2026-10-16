import XCTest

/// Drives the app in the simulator against a dev relay (`parley-relay --dev`,
/// started by CI on 127.0.0.1:8765), through the app's UI-test seam (a fake
/// signed-in session; `Parley/UITestSeam.swift`): the login screen, then send
/// a turn, see it reach `ready`, open the reader-player and see the highlight
/// follow the audio.
final class ParleyUITests: XCTestCase {
    private var relayURL: String {
        ProcessInfo.processInfo.environment["PARLEY_UI_TEST_RELAY_URL"] ?? "http://127.0.0.1:8765"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(signedIn: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        app.launchEnvironment["PARLEY_UI_TESTING"] = "1"
        app.launchEnvironment["PARLEY_UI_TEST_RELAY_URL"] = relayURL
        app.launchEnvironment["PARLEY_UI_TEST_ACCESS_TOKEN"] = env["PARLEY_UI_TEST_ACCESS_TOKEN"] ?? "parley-dev"
        app.launchEnvironment["PARLEY_UI_TEST_SIGNED_IN"] = signedIn ? "1" : "0"
        app.launch()
        return app
    }

    /// Replace a text field's contents: tap at its right end (the caret goes
    /// after the text), delete it all, type the new text.
    private func replaceText(of field: XCUIElement, with text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        if !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 4))
        }
        field.typeText(text)
    }

    func testTheLoginScreenChecksTheRelayThenOpensTheConversations() throws {
        let app = launch(signedIn: false)
        XCTAssertTrue(app.staticTexts["loginTitle"].waitForExistence(timeout: 20))
        let field = app.textFields["loginRelayURL"]
        XCTAssertTrue(field.exists)
        XCTAssertEqual(field.value as? String, relayURL, "the relay field is not prefilled")
        let button = app.buttons["loginButton"]
        XCTAssertEqual(button.label, "Sign in")
        screenshot(app, "login")

        // A relay outside the build's host suffix is refused before any sign-in.
        replaceText(of: field, with: "https://relay.example.com")
        button.tap()
        let error = app.descendants(matching: .any)["loginError"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("only to a relay under"), error.label)
        XCTAssertFalse(app.staticTexts["loginAccount"].exists, "it signed in for a refused relay")

        // Plain http to another host is refused too.
        replaceText(of: field, with: "http://parley.example.org")
        button.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("https://"), error.label)

        // A relay that does not answer: signed in, but the screen stays and says so.
        replaceText(of: field, with: "http://127.0.0.1:9")
        button.tap()
        let signedIn = app.staticTexts["loginAccount"].waitForExistence(timeout: 30)
        screenshot(app, "login-relay-check")
        XCTAssertTrue(signedIn, "not signed in after the relay check")
        XCTAssertTrue(error.waitForExistence(timeout: 30))
        XCTAssertTrue(error.label.contains("did not answer"), error.label)
        XCTAssertEqual(button.label, "Try again")
        screenshot(app, "login-relay-unreachable")

        // The right relay: on to the conversations.
        replaceText(of: field, with: relayURL)
        button.tap()
        XCTAssertTrue(app.buttons["newConversation"].waitForExistence(timeout: 30))

        // Settings shows the account; signing out returns to the login screen.
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["accountLabel"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["tokenField"].firstMatch.exists)
        screenshot(app, "settings")
        app.buttons["signOutButton"].tap()
        XCTAssertTrue(app.buttons["loginButton"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["loginButton"].label, "Sign in")
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
