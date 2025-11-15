import XCTest

final class MeetingRecorderUITests: XCTestCase {

  override func setUpWithError() throws {
    // Put setup code here. This method is called before the invocation of each test method in the class.

    // In UI tests it is usually best to stop immediately when a failure occurs.
    continueAfterFailure = false

    // In UI tests it's important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
  }

  override func tearDownWithError() throws {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
  }

  func testLaunchPerformance() throws {
    if #available(macOS 10.15, *) {
      // This measures how long it takes to launch your application.
      measure(metrics: [XCTApplicationLaunchMetric()]) {
        XCUIApplication().launch()
      }
    }
  }

  func testMainWindowExists() throws {
    let app = XCUIApplication()
    app.launch()

    // Verify main window appears
    XCTAssertTrue(app.windows.firstMatch.exists)
    XCTFail("Placeholder UI test - needs implementation")
  }
}
