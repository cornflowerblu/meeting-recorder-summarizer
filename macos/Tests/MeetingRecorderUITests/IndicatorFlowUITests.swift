import XCTest
import SwiftUI
@testable import MeetingRecorder

@MainActor
final class IndicatorFlowUITests: XCTestCase {
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        
        // Configure test environment
        continueAfterFailure = false
        
        app = XCUIApplication()
        
        // Set launch arguments for testing
        app.launchArguments = [
            "-testing",
            "-skip-permissions-check", // For UI tests, we'll mock permissions
            "-use-mock-services"
        ]
        
        app.launch()
    }
    
    override func tearDownWithError() throws {
        app.terminate()
        app = nil
        
        try super.tearDownWithError()
    }
    
    // MARK: - Consent Flow Tests
    
    func testConsentViewDisplaysOnFirstLaunch() throws {
        // Given: First app launch (clean install)
        // When: App starts
        
        // Then: Consent view should be displayed
        let consentView = app.otherElements["consent_view"]
        XCTAssertTrue(consentView.waitForExistence(timeout: 3.0))
        
        // Verify consent content is present
        let titleLabel = app.staticTexts["consent_title"]
        XCTAssertTrue(titleLabel.exists)
        XCTAssertEqual(titleLabel.label, "Screen Recording Permission")
        
        let descriptionText = app.staticTexts["consent_description"]
        XCTAssertTrue(descriptionText.exists)
        XCTAssertTrue(descriptionText.label.contains("record your screen"))
        
        // Verify privacy policy link exists
        let privacyLink = app.links["privacy_policy_link"]
        XCTAssertTrue(privacyLink.exists)
        
        // Verify buttons are present
        let allowButton = app.buttons["allow_recording_button"]
        let cancelButton = app.buttons["cancel_recording_button"]
        
        XCTAssertTrue(allowButton.exists)
        XCTAssertTrue(cancelButton.exists)
        XCTAssertEqual(allowButton.label, "Allow Screen Recording")
        XCTAssertEqual(cancelButton.label, "Cancel")
    }
    
    func testConsentAllowButtonRequestsPermissions() throws {
        // Given: Consent view is displayed
        let consentView = app.otherElements["consent_view"]
        XCTAssertTrue(consentView.waitForExistence(timeout: 3.0))
        
        // When: User taps Allow button
        let allowButton = app.buttons["allow_recording_button"]
        allowButton.tap()
        
        // Then: System permission dialog should appear (in real usage)
        // For UI tests, we mock this behavior and verify the app responds appropriately
        
        // Verify app shows loading/processing state
        let loadingIndicator = app.activityIndicators["permission_loading"]
        XCTAssertTrue(loadingIndicator.waitForExistence(timeout: 2.0))
        
        // Wait for permission check to complete
        let mainView = app.otherElements["main_app_view"]
        XCTAssertTrue(mainView.waitForExistence(timeout: 5.0))
        
        // Verify consent view is dismissed
        XCTAssertFalse(consentView.exists)
    }
    
    func testConsentCancelButtonDismissesApp() throws {
        // Given: Consent view is displayed
        let consentView = app.otherElements["consent_view"]
        XCTAssertTrue(consentView.waitForExistence(timeout: 3.0))
        
        // When: User taps Cancel button
        let cancelButton = app.buttons["cancel_recording_button"]
        cancelButton.tap()
        
        // Then: App should show cancellation confirmation or exit gracefully
        let confirmationDialog = app.alerts["consent_cancellation_alert"]
        
        if confirmationDialog.waitForExistence(timeout: 2.0) {
            // If confirmation dialog appears, verify and dismiss
            let confirmButton = confirmationDialog.buttons["exit_app_button"]
            XCTAssertTrue(confirmButton.exists)
            confirmButton.tap()
        }
        
        // Verify app handles cancellation (either exits or shows alternative flow)
        // In test environment, we expect a specific behavior
        let alternativeView = app.otherElements["permission_denied_view"]
        XCTAssertTrue(alternativeView.waitForExistence(timeout: 3.0))
    }
    
    func testConsentSkippedWhenPermissionsAlreadyGranted() throws {
        // Given: App with previously granted permissions
        app.terminate()
        
        // Launch with permission-granted state
        app.launchArguments.append("-permissions-granted")
        app.launch()
        
        // When: App starts
        
        // Then: Should skip consent and go directly to main app
        let mainView = app.otherElements["main_app_view"]
        XCTAssertTrue(mainView.waitForExistence(timeout: 3.0))
        
        let consentView = app.otherElements["consent_view"]
        XCTAssertFalse(consentView.exists)
    }
    
    // MARK: - Recording Indicator Tests
    
    func testRecordingIndicatorAppearsOnStart() throws {
        // Given: App is ready for recording
        setupAppForRecording()
        
        // When: Starting a recording
        let recordButton = app.buttons["start_recording_button"]
        recordButton.tap()
        
        // Then: Recording indicator should appear
        let indicator = app.otherElements["recording_indicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 3.0))
        
        // Verify indicator is visible and positioned correctly
        XCTAssertTrue(indicator.isHittable)
        
        let indicatorFrame = indicator.frame
        let screenFrame = app.windows.firstMatch.frame
        
        // Indicator should be in top-right corner area
        XCTAssertGreaterThan(indicatorFrame.minX, screenFrame.width * 0.7)
        XCTAssertLessThan(indicatorFrame.minY, screenFrame.height * 0.3)
    }
    
    func testRecordingIndicatorShowsElapsedTime() throws {
        // Given: Recording is in progress
        setupAppForRecording()
        startRecording()
        
        let indicator = app.otherElements["recording_indicator"]
        XCTAssertTrue(indicator.exists)
        
        // When: Time passes
        let timeLabel = indicator.staticTexts["recording_time_label"]
        XCTAssertTrue(timeLabel.waitForExistence(timeout: 2.0))
        
        // Verify initial time display
        let initialTime = timeLabel.label
        XCTAssertTrue(initialTime.contains("00:"))
        
        // Wait and verify time updates
        sleep(2)
        app.windows.firstMatch.tap() // Refresh UI
        
        let updatedTime = timeLabel.label
        XCTAssertNotEqual(initialTime, updatedTime)
        XCTAssertTrue(updatedTime.contains("00:"))
    }
    
    func testRecordingIndicatorShowsRecordingStatus() throws {
        // Given: Recording is in progress
        setupAppForRecording()
        startRecording()
        
        let indicator = app.otherElements["recording_indicator"]
        
        // When: Checking indicator content
        
        // Then: Should show recording status
        let statusDot = indicator.otherElements["recording_status_dot"]
        XCTAssertTrue(statusDot.exists)
        
        let statusLabel = indicator.staticTexts["recording_status_label"]
        XCTAssertTrue(statusLabel.exists)
        XCTAssertEqual(statusLabel.label, "Recording")
        
        // Verify visual feedback (red recording dot)
        // Note: Color testing is limited in XCTest, but we can verify element exists
        XCTAssertTrue(statusDot.isHittable)
    }
    
    func testRecordingIndicatorControlsStopRecording() throws {
        // Given: Recording is in progress
        setupAppForRecording()
        startRecording()
        
        let indicator = app.otherElements["recording_indicator"]
        XCTAssertTrue(indicator.exists)
        
        // When: Clicking stop button in indicator
        let stopButton = indicator.buttons["stop_recording_button"]
        XCTAssertTrue(stopButton.exists)
        stopButton.tap()
        
        // Then: Recording should stop
        let confirmationDialog = app.alerts["stop_recording_confirmation"]
        if confirmationDialog.waitForExistence(timeout: 2.0) {
            let confirmButton = confirmationDialog.buttons["confirm_stop_button"]
            confirmButton.tap()
        }
        
        // Verify indicator disappears
        XCTAssertTrue(indicator.waitForNonExistence(timeout: 3.0))
        
        // Verify main app shows post-recording state
        let postRecordingView = app.otherElements["post_recording_view"]
        XCTAssertTrue(postRecordingView.waitForExistence(timeout: 3.0))
    }
    
    func testRecordingIndicatorPersistsAcrossAppStates() throws {
        // Given: Recording is in progress
        setupAppForRecording()
        startRecording()
        
        let indicator = app.otherElements["recording_indicator"]
        XCTAssertTrue(indicator.exists)
        
        // When: App loses focus and regains it
        app.activate()
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        
        sleep(1)
        
        app.activate()
        
        // Then: Indicator should still be visible
        XCTAssertTrue(indicator.exists)
        
        let timeLabel = indicator.staticTexts["recording_time_label"]
        XCTAssertTrue(timeLabel.exists)
        XCTAssertTrue(timeLabel.label.contains("00:"))
    }
    
    func testRecordingIndicatorAccessibility() throws {
        // Given: Recording is in progress
        setupAppForRecording()
        startRecording()
        
        let indicator = app.otherElements["recording_indicator"]
        XCTAssertTrue(indicator.exists)
        
        // When: Checking accessibility features
        
        // Then: Indicator should be accessible
        XCTAssertTrue(indicator.isAccessibilityElement)
        XCTAssertNotNil(indicator.accessibilityLabel)
        XCTAssertTrue(indicator.accessibilityLabel!.contains("Recording"))
        
        // Verify child elements have proper accessibility
        let timeLabel = indicator.staticTexts["recording_time_label"]
        XCTAssertNotNil(timeLabel.accessibilityValue)
        
        let stopButton = indicator.buttons["stop_recording_button"]
        XCTAssertNotNil(stopButton.accessibilityLabel)
        XCTAssertTrue(stopButton.accessibilityLabel!.contains("Stop"))
    }
    
    // MARK: - Integration Flow Tests
    
    func testCompleteConsentToRecordingFlow() throws {
        // Given: Fresh app launch requiring consent
        let consentView = app.otherElements["consent_view"]
        XCTAssertTrue(consentView.waitForExistence(timeout: 3.0))
        
        // When: User grants consent
        let allowButton = app.buttons["allow_recording_button"]
        allowButton.tap()
        
        // Wait for permission processing
        let mainView = app.otherElements["main_app_view"]
        XCTAssertTrue(mainView.waitForExistence(timeout: 5.0))
        
        // Start recording
        let recordButton = app.buttons["start_recording_button"]
        recordButton.tap()
        
        // Then: Full flow should work seamlessly
        let indicator = app.otherElements["recording_indicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 3.0))
        
        // Verify recording actually started
        let timeLabel = indicator.staticTexts["recording_time_label"]
        XCTAssertTrue(timeLabel.waitForExistence(timeout: 2.0))
        
        // Clean up - stop recording
        let stopButton = indicator.buttons["stop_recording_button"]
        stopButton.tap()
        
        let confirmationDialog = app.alerts["stop_recording_confirmation"]
        if confirmationDialog.waitForExistence(timeout: 2.0) {
            confirmationDialog.buttons["confirm_stop_button"].tap()
        }
    }
    
    func testConsentRejectionPreventsRecording() throws {
        // Given: Consent view is displayed
        let consentView = app.otherElements["consent_view"]
        XCTAssertTrue(consentView.waitForExistence(timeout: 3.0))
        
        // When: User rejects consent
        let cancelButton = app.buttons["cancel_recording_button"]
        cancelButton.tap()
        
        // Handle any confirmation dialog
        let confirmationDialog = app.alerts["consent_cancellation_alert"]
        if confirmationDialog.waitForExistence(timeout: 2.0) {
            confirmationDialog.buttons["exit_app_button"].tap()
        }
        
        // Then: Recording functionality should be unavailable
        let permissionDeniedView = app.otherElements["permission_denied_view"]
        XCTAssertTrue(permissionDeniedView.waitForExistence(timeout: 3.0))
        
        // Verify no record button is available
        let recordButton = app.buttons["start_recording_button"]
        XCTAssertFalse(recordButton.exists)
        
        // Verify explanatory message is shown
        let explanationText = app.staticTexts["permission_required_explanation"]
        XCTAssertTrue(explanationText.exists)
        XCTAssertTrue(explanationText.label.contains("permission"))
    }
    
    // MARK: - Helper Methods
    
    private func setupAppForRecording() {
        // Wait for main app view to be ready
        let mainView = app.otherElements["main_app_view"]
        if !mainView.waitForExistence(timeout: 5.0) {
            // If consent is still showing, grant it
            let consentView = app.otherElements["consent_view"]
            if consentView.exists {
                let allowButton = app.buttons["allow_recording_button"]
                allowButton.tap()
                
                XCTAssertTrue(mainView.waitForExistence(timeout: 5.0))
            }
        }
        
        // Ensure permissions are granted for testing
        let recordButton = app.buttons["start_recording_button"]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 3.0))
    }
    
    private func startRecording() {
        let recordButton = app.buttons["start_recording_button"]
        recordButton.tap()
        
        // Wait for recording to actually start
        let indicator = app.otherElements["recording_indicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 3.0))
    }
}

// MARK: - Accessibility Identifiers Extension

// This should be implemented in the actual UI components
extension String {
    static let consentView = "consent_view"
    static let consentTitle = "consent_title"
    static let consentDescription = "consent_description"
    static let privacyPolicyLink = "privacy_policy_link"
    static let allowRecordingButton = "allow_recording_button"
    static let cancelRecordingButton = "cancel_recording_button"
    static let permissionLoading = "permission_loading"
    static let mainAppView = "main_app_view"
    static let consentCancellationAlert = "consent_cancellation_alert"
    static let exitAppButton = "exit_app_button"
    static let permissionDeniedView = "permission_denied_view"
    static let startRecordingButton = "start_recording_button"
    static let recordingIndicator = "recording_indicator"
    static let recordingTimeLabel = "recording_time_label"
    static let recordingStatusDot = "recording_status_dot"
    static let recordingStatusLabel = "recording_status_label"
    static let stopRecordingButton = "stop_recording_button"
    static let stopRecordingConfirmation = "stop_recording_confirmation"
    static let confirmStopButton = "confirm_stop_button"
    static let postRecordingView = "post_recording_view"
    static let permissionRequiredExplanation = "permission_required_explanation"
}
