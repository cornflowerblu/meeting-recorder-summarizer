import XCTest

/// UI tests for consent dialogs and recording indicator
///
/// Tests verify:
/// - First-run consent flow
/// - Per-session consent before recording
/// - Recording indicator visibility and behavior
/// - Indicator persistence during recording
///
/// ## Running Tests
///
/// ```bash
/// swift test --filter ConsentAndIndicatorUITests
/// ```
///
/// Note: UI tests require the app to be built and launched in a test environment
final class ConsentAndIndicatorUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Consent Flow Tests

    func testFirstRunConsentDialogAppears() throws {
        // Given - Fresh app installation (simulate by clearing UserDefaults)
        app.launchArguments = ["--reset-user-defaults"]
        app.launch()

        // Then - Consent dialog should appear
        XCTAssertTrue(
            app.staticTexts["Screen Recording Consent"].exists,
            "First-run consent dialog should appear"
        )

        XCTAssertTrue(
            app.staticTexts["Your screen will be recorded"].exists,
            "Consent warning message should be visible"
        )

        // Verify privacy information is present
        XCTAssertTrue(
            app.staticTexts["Only you can access your recordings"].exists,
            "Privacy statement should be visible"
        )
    }

    func testPerSessionConsentBeforeRecording() throws {
        // Given - App is launched and user navigates to record tab
        let recordTab = app.tabBars.buttons["Record"]
        XCTAssertTrue(recordTab.waitForExistence(timeout: 2))
        recordTab.tap()

        // When - User clicks "Start Recording" button
        let startButton = app.buttons["Start Recording"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 2))
        startButton.tap()

        // Then - Consent dialog should appear
        XCTAssertTrue(
            app.staticTexts["Confirm Recording"].waitForExistence(timeout: 2),
            "Per-session consent dialog should appear before recording"
        )

        // Verify consent checkbox is unchecked by default
        let consentCheckbox = app.checkBoxes["I understand and consent"]
        XCTAssertTrue(consentCheckbox.exists)
        XCTAssertEqual(consentCheckbox.value as? Int, 0, "Checkbox should be unchecked by default")

        // Verify "Start Recording" button is disabled until consent given
        let confirmButton = app.buttons["Start Recording"]
        XCTAssertFalse(confirmButton.isEnabled, "Start button should be disabled without consent")
    }

    func testConsentRejectionPreventsRecording() throws {
        // Given - Consent dialog is displayed
        let recordTab = app.tabBars.buttons["Record"]
        recordTab.tap()

        let startButton = app.buttons["Start Recording"]
        startButton.tap()

        // Wait for consent dialog
        XCTAssertTrue(app.staticTexts["Confirm Recording"].waitForExistence(timeout: 2))

        // When - User clicks "Cancel"
        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.exists)
        cancelButton.tap()

        // Then - Consent dialog should dismiss
        XCTAssertFalse(
            app.staticTexts["Confirm Recording"].exists,
            "Consent dialog should be dismissed"
        )

        // Recording should NOT start
        XCTAssertFalse(
            app.staticTexts["Recording"].exists,
            "Recording state should remain idle"
        )

        // Recording indicator should NOT appear
        XCTAssertFalse(
            app.windows["Recording Indicator"].exists,
            "Recording indicator should not appear if consent rejected"
        )
    }

    func testConsentAcceptanceAllowsRecording() throws {
        // Given - Consent dialog is displayed
        let recordTab = app.tabBars.buttons["Record"]
        recordTab.tap()

        let startButton = app.buttons["Start Recording"]
        startButton.tap()

        // Wait for consent dialog
        XCTAssertTrue(app.staticTexts["Confirm Recording"].waitForExistence(timeout: 2))

        // When - User checks consent checkbox and clicks "Start Recording"
        let consentCheckbox = app.checkBoxes["I understand and consent"]
        consentCheckbox.tap()

        let confirmButton = app.buttons["Start Recording"]
        XCTAssertTrue(confirmButton.isEnabled, "Start button should be enabled after consent")
        confirmButton.tap()

        // Then - Consent dialog should dismiss
        XCTAssertFalse(
            app.staticTexts["Confirm Recording"].exists,
            "Consent dialog should be dismissed"
        )

        // Recording should start
        XCTAssertTrue(
            app.staticTexts["Recording"].waitForExistence(timeout: 3),
            "Recording state should show 'Recording'"
        )
    }

    // MARK: - Recording Indicator Tests

    func testRecordingIndicatorAppearsDuringRecording() throws {
        // Given - User has started recording (with consent)
        startRecordingWithConsent()

        // Then - Recording indicator window should appear
        let indicator = app.windows["Recording Indicator"]
        XCTAssertTrue(
            indicator.waitForExistence(timeout: 3),
            "Recording indicator window should appear when recording starts"
        )

        // Verify indicator contains red dot
        XCTAssertTrue(
            indicator.images["Recording Dot"].exists,
            "Indicator should show red recording dot"
        )

        // Verify indicator shows elapsed time
        XCTAssertTrue(
            indicator.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "\\d{2}:\\d{2}")).firstMatch.exists,
            "Indicator should display elapsed time in MM:SS format"
        )
    }

    func testIndicatorShowsElapsedTime() throws {
        // Given - Recording is active
        startRecordingWithConsent()

        let indicator = app.windows["Recording Indicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 3))

        // Get initial time display
        let timeLabel = indicator.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "\\d{2}:\\d{2}")).firstMatch
        let initialTime = timeLabel.label

        // When - Wait 2 seconds
        sleep(2)

        // Then - Time should have updated
        let updatedTime = timeLabel.label
        XCTAssertNotEqual(
            initialTime,
            updatedTime,
            "Elapsed time should update (was \(initialTime), now \(updatedTime))"
        )
    }

    func testIndicatorCannotBeDismissedDuringRecording() throws {
        // Given - Recording is active with indicator visible
        startRecordingWithConsent()

        let indicator = app.windows["Recording Indicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 3))

        // When - User tries to close indicator window (if close button exists)
        if indicator.buttons[XCUIIdentifierCloseWindow].exists {
            // Then - Close button should be disabled or hidden
            XCTAssertFalse(
                indicator.buttons[XCUIIdentifierCloseWindow].isEnabled,
                "Close button should be disabled during recording"
            )
        }

        // Indicator should remain visible
        sleep(1)
        XCTAssertTrue(
            indicator.exists,
            "Indicator should remain visible and cannot be dismissed"
        )
    }

    func testIndicatorDisappearsAfterStop() throws {
        // Given - Recording is active with indicator visible
        startRecordingWithConsent()

        let indicator = app.windows["Recording Indicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 3))

        // When - User stops recording
        let recordTab = app.tabBars.buttons["Record"]
        recordTab.tap()

        let stopButton = app.buttons["Stop Recording"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 2))
        stopButton.tap()

        // Then - Indicator should disappear
        XCTAssertFalse(
            indicator.waitForExistence(timeout: 2),
            "Recording indicator should disappear after stopping"
        )

        // Recording state should show "Stopped"
        XCTAssertTrue(
            app.staticTexts["Stopped"].waitForExistence(timeout: 2),
            "Recording state should show 'Stopped'"
        )
    }

    func testIndicatorIsDraggable() throws {
        // Given - Recording is active with indicator visible
        startRecordingWithConsent()

        let indicator = app.windows["Recording Indicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 3))

        // Get initial position
        let initialFrame = indicator.frame

        // When - User drags indicator to new position
        let startPoint = indicator.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let endPoint = startPoint.withOffset(CGVector(dx: 100, dy: 50))

        startPoint.press(forDuration: 0.1, thenDragTo: endPoint)

        // Then - Indicator position should have changed
        sleep(1)  // Allow animation to complete
        let newFrame = indicator.frame

        XCTAssertNotEqual(
            initialFrame.origin.x,
            newFrame.origin.x,
            accuracy: 10,
            "Indicator X position should have changed"
        )

        XCTAssertNotEqual(
            initialFrame.origin.y,
            newFrame.origin.y,
            accuracy: 10,
            "Indicator Y position should have changed"
        )
    }

    func testIndicatorPositionPersistsAcrossLaunches() throws {
        // Given - Recording is active and indicator has been moved
        startRecordingWithConsent()

        let indicator = app.windows["Recording Indicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 3))

        // Move indicator to specific position
        let startPoint = indicator.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let endPoint = startPoint.withOffset(CGVector(dx: 100, dy: 50))
        startPoint.press(forDuration: 0.1, thenDragTo: endPoint)

        sleep(1)
        let movedFrame = indicator.frame

        // Stop recording
        app.tabBars.buttons["Record"].tap()
        app.buttons["Stop Recording"].tap()

        // When - Start new recording
        sleep(1)
        startRecordingWithConsent()

        // Then - Indicator should appear at saved position
        let newIndicator = app.windows["Recording Indicator"]
        XCTAssertTrue(newIndicator.waitForExistence(timeout: 3))

        let newFrame = newIndicator.frame

        XCTAssertEqual(
            movedFrame.origin.x,
            newFrame.origin.x,
            accuracy: 5,
            "Indicator should remember X position"
        )

        XCTAssertEqual(
            movedFrame.origin.y,
            newFrame.origin.y,
            accuracy: 5,
            "Indicator should remember Y position"
        )
    }

    // MARK: - Helper Methods

    /// Starts recording with consent flow completed
    private func startRecordingWithConsent() {
        // Navigate to Record tab
        let recordTab = app.tabBars.buttons["Record"]
        if recordTab.waitForExistence(timeout: 2) {
            recordTab.tap()
        }

        // Click Start Recording
        let startButton = app.buttons["Start Recording"]
        if startButton.waitForExistence(timeout: 2) {
            startButton.tap()
        }

        // Handle consent dialog
        let consentDialog = app.staticTexts["Confirm Recording"]
        if consentDialog.waitForExistence(timeout: 2) {
            // Check consent checkbox
            let checkbox = app.checkBoxes["I understand and consent"]
            if checkbox.exists {
                checkbox.tap()
            }

            // Confirm
            let confirmButton = app.buttons["Start Recording"]
            if confirmButton.exists && confirmButton.isEnabled {
                confirmButton.tap()
            }
        }

        // Wait for recording to start
        _ = app.staticTexts["Recording"].waitForExistence(timeout: 3)
    }
}
