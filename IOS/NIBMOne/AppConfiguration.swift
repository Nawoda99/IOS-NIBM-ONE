import Foundation

struct AppConfiguration: Equatable {
    let apiBaseURL: String
    let useMySQLBackend: Bool

    enum ConfigurationError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }

    static let fallback = AppConfiguration(apiBaseURL: "http://localhost:8080", useMySQLBackend: true)
    private static let bundled: (configuration: AppConfiguration, issue: String?) = {
        do {
            guard let url = Bundle.main.resourceURL?.appendingPathComponent(".env") else {
                throw ConfigurationError.invalid("The app configuration is unavailable. Set the backend URL below.")
            }
            return (try parse(String(contentsOf: url, encoding: .utf8)), nil)
        } catch {
            return (fallback, "Check IOS/.env and rebuild the app, or set the backend URL below.")
        }
    }()
    static var current: AppConfiguration { bundled.configuration }
    static var loadIssue: String? { bundled.issue }

    static func parse(_ text: String) throws -> AppConfiguration {
        var values: [String: String] = [:]
        let whitespace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: whitespace)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let separator = line.firstIndex(of: "=") else { throw ConfigurationError.invalid("Use KEY=value lines in IOS/.env.") }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            guard ["API_BASE_URL", "USE_MYSQL_BACKEND"].contains(key) else {
                throw ConfigurationError.invalid("IOS/.env supports only API_BASE_URL and USE_MYSQL_BACKEND. Keep credentials in backend/.env.")
            }
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2 && ((value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'"))) { value = String(value.dropFirst().dropLast()) }
            values[key] = value
        }
        guard let address = values["API_BASE_URL"], let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ConfigurationError.invalid("Set a valid HTTP(S) API_BASE_URL in IOS/.env.")
        }
        let mode = (values["USE_MYSQL_BACKEND"] ?? "true").lowercased()
        guard ["true", "false"].contains(mode) else { throw ConfigurationError.invalid("USE_MYSQL_BACKEND must be true or false.") }
        return AppConfiguration(apiBaseURL: address, useMySQLBackend: mode == "true")
    }

    static func apply(_ configuration: AppConfiguration, to defaults: UserDefaults) {
        let signature = "\(configuration.apiBaseURL)|\(configuration.useMySQLBackend)"
        guard defaults.string(forKey: "appEnvironmentSignature") != signature else { return }
        defaults.set(configuration.apiBaseURL, forKey: "backendURL")
        defaults.set(configuration.useMySQLBackend, forKey: "useMySQLBackend")
        defaults.set(signature, forKey: "appEnvironmentSignature")
    }
    static func installBundledDefaults() {
        if loadIssue == nil { apply(current, to: .standard) }
        else { UserDefaults.standard.register(defaults: ["backendURL": fallback.apiBaseURL, "useMySQLBackend": fallback.useMySQLBackend]) }
    }
}
