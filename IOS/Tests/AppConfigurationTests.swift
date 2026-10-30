import XCTest
@testable import NIBMOneDomain

final class AppConfigurationTests: XCTestCase {
    func testPublicEnvironmentValuesAreLoaded() throws {
        let value = try AppConfiguration.parse("# App settings\nAPI_BASE_URL=\"http://192.168.12.90:8080\"\nUSE_MYSQL_BACKEND=false\n")
        XCTAssertEqual(value.apiBaseURL, "http://192.168.12.90:8080")
        XCTAssertFalse(value.useMySQLBackend)
    }
    func testWindowsLineEndingsAndBOM() throws {
        let value = try AppConfiguration.parse("\u{feff}API_BASE_URL=https://example.test\r\nUSE_MYSQL_BACKEND=true\r\n")
        XCTAssertEqual(value.apiBaseURL, "https://example.test")
        XCTAssertTrue(value.useMySQLBackend)
    }
    func testCredentialsAndInvalidSettingsAreRejected() {
        for text in ["API_BASE_URL=ftp://host", "API_BASE_URL=http://user:secret@host", "API_BASE_URL=http://host\nDATABASE_PASSWORD=secret", "API_BASE_URL=http://host\nUSE_MYSQL_BACKEND=maybe"] {
            XCTAssertThrowsError(try AppConfiguration.parse(text))
        }
    }
    func testChangedEnvironmentRefreshesSavedDefaultsWithoutResettingManualOverridesOnEveryLaunch() {
        let name = "NIBMOneConfigTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = AppConfiguration(apiBaseURL: "http://first.test", useMySQLBackend: true)
        AppConfiguration.apply(first, to: defaults)
        defaults.set("http://manual.test", forKey: "backendURL")
        AppConfiguration.apply(first, to: defaults)
        XCTAssertEqual(defaults.string(forKey: "backendURL"), "http://manual.test")
        AppConfiguration.apply(AppConfiguration(apiBaseURL: "http://second.test", useMySQLBackend: false), to: defaults)
        XCTAssertEqual(defaults.string(forKey: "backendURL"), "http://second.test")
        XCTAssertFalse(defaults.bool(forKey: "useMySQLBackend"))
    }
}
