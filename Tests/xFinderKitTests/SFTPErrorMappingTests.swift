import XCTest
import Citadel
@testable import xFinderKit

final class SFTPErrorMappingTests: XCTestCase {
    func message(_ error: Error) -> String {
        SFTPFileSystem.mapOpenSFTPError(error).localizedDescription
    }

    func testRejectedSubsystemExplainsHowToEnableSFTP() {
        let text = message(SFTPError.subsystemRejected)
        XCTAssertTrue(text.contains("does not offer SFTP"), text)
        XCTAssertTrue(text.contains("Subsystem sftp"), text)
    }

    func testMissingReplyIsReportedAsNoAnswer() {
        XCTAssertTrue(message(SFTPError.missingResponse).contains("did not answer"))
    }

    func testOtherErrorsKeepTheirDescription() {
        XCTAssertTrue(message(RemoteError.timeout).contains("could not be started"))
    }
}
