// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
import XCTest
@testable import HoldfastCore

/// The installer runs its root script through Authorization Services and recovers the exit status from a marker line.
final class AdminRunnerTests: XCTestCase {
    func testParsesSuccessAndStripsMarker() {
        let result = HelperInstaller.parseAdminOutput("did a thing\n__HOLDFAST_EXIT:0\n")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "did a thing")
    }

    func testParsesFailureWithMessage() {
        let result = HelperInstaller.parseAdminOutput("The bundled helper is missing or is a symlink.\n__HOLDFAST_EXIT:4\n")
        XCTAssertEqual(result.status, 4)
        XCTAssertEqual(result.output, "The bundled helper is missing or is a symlink.")
    }

    func testMissingMarkerIsAFailure() {
        let result = HelperInstaller.parseAdminOutput("killed halfway")
        XCTAssertNotEqual(result.status, 0, "no marker means the script never reached its end")
        XCTAssertEqual(result.output, "killed halfway")
    }

    func testWrappedScriptShape() throws {
        // The script must stay valid shell once wrapped the way runAsAdmin wraps it.
        let script = HelperInstaller.installScript(sourceBinary: "/x/holdfastd", expectedTeamID: nil)
        let wrapped = "exec 2>&1\n( \(script)\n)\necho \"__HOLDFAST_EXIT:$?\""
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wrapped-\(UUID().uuidString).sh")
        try wrapped.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(ProcessRunner().run("/bin/sh", ["-n", file.path]).status, 0)
    }

    func testExecuteWithPrivilegesSymbolResolves() {
        XCTAssertNotNil(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AuthorizationExecuteWithPrivileges"),
                        "if macOS drops this call the installer needs a different mechanism")
    }
}
