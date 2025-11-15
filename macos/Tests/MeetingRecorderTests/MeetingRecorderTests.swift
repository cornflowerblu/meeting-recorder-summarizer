import XCTest

@testable import MeetingRecorder

final class MeetingRecorderTests: XCTestCase {

  override func setUpWithError() throws {
    // Put setup code here. This method is called before the invocation of each test method in the class.
  }

  override func tearDownWithError() throws {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
  }

  func testConfigSharedReturnsValidInstance() throws {
    // Test that Config.shared returns a non-nil instance with expected properties
    let config = Config.shared
    
    XCTAssertNotNil(config)
    XCTAssertEqual(config.chunkDurationSeconds, 60.0)
    XCTAssertEqual(config.maxRecordingDurationHours, 8.0)
    XCTAssertFalse(config.awsRegion.isEmpty)
  }

  func testPerformanceExample() throws {
    // This is an example of a performance test case.
    self.measure {
      // Put the code you want to measure the time of here.
    }
  }
}
