import Foundation

struct RemoteProfile: Codable {
    let id: UUID
    let epfNo: String
    let name: String
    let branch: String
    let role: EmployeeRole
    let permissions: [String]?
}
struct EmployeeAccount: Decodable, Identifiable {
    let id: UUID
    let epfNo: String
    let name: String
    let branchID: Int?
    let branch: String
    let role: EmployeeRole
    let hasLogin: Bool
    let isActive: Bool
}
struct CreateEmployeeBody: Encodable {
    let epfNo: String
    let name: String
    let identityNo: String
    let password: String
    let role: EmployeeRole
    let branchID: Int?
}
struct CreatedEmployee: Decodable { let id: UUID; let epfNo: String }
struct UpdateEmployeeBody: Encodable {
    let role: EmployeeRole
    let branchID: Int?
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(role, forKey: .role)
        if let branchID { try values.encode(branchID, forKey: .branchID) }
        else { try values.encodeNil(forKey: .branchID) }
    }
    private enum CodingKeys: String, CodingKey { case role, branchID }
}
struct PermissionDefinition: Decodable, Identifiable { let id: String; let title: String; let description: String }
struct RolePermission: Decodable { let role: EmployeeRole; let permissions: [String] }
struct PermissionDirectory: Decodable { let permissions: [PermissionDefinition]; let roles: [RolePermission] }
struct PermissionBody: Encodable { let permissions: [String] }
struct BranchLocation: Decodable, Identifiable { let id: Int; let name: String; let address: String; let coordinate: Coordinate? }
struct NIBMCampus: Decodable, Identifiable { let id: String; let name: String; let address: String }
struct BranchDirectory: Decodable { let branches: [BranchLocation]; let campuses: [NIBMCampus]; let sourceURL: String }
struct BranchLocationBody: Encodable { let address: String; let coordinate: Coordinate }
struct LoginResponse: Decodable { let token: String; let profile: RemoteProfile }
struct MachineSync: Decodable, Identifiable {
    var id: String { code }
    let code: String
    let name: String
    let lastSyncedAt: Date?
    let lastError: String?
}
struct RemoteSnapshot: Decodable {
    let profile: RemoteProfile
    let state: SavedState
    let approvals: [LeaveRequest]
    let punches: [Punch]
    let sync: [MachineSync]
}
struct RemoteAttendanceMonth: Decodable {
    let month: String
    let timeZone: String
    let method: String
    let punches: [Punch]
}
struct LoginBody: Encodable { let epfNo: String; let password: String }
struct LeaveBody: Encodable { let type: LeaveType; let start: Date; let end: Date; let halfDay: Bool; let reason: String; let attachment: Attachment? }
struct DecisionBody: Encodable { let approve: Bool; let reason: String }
struct TicketBody: Encodable {
    let title: String; let description: String; let category: String; let priority: String
    let room: String; let assetID: String; let coordinate: Coordinate?; let photo: Attachment?
}
struct CommentBody: Encodable { let text: String }
struct FingerprintResult: Decodable {
    let inserted: Int
    let duplicates: Int
    let unmapped: Int
    let received: Int
}
struct MachineAdminStatus: Decodable, Identifiable {
    var id: String { code }
    let code: String
    let name: String
    let lastSyncedAt: Date?
    let lastError: String?
    let total: Int
    let unmapped: Int
    let usesEPFNumbers: Bool?
    let ipAddress: String?
    let port: Int?
    let model: String?
}
struct UnmappedMachineUser: Decodable, Identifiable {
    var id: String { epfNo }
    let epfNo: String
    let count: Int
}
struct MachineMappingBody: Encodable { let epfNo: String }

enum APIError: LocalizedError {
    case invalidURL, server(Int, String), invalidResponse, sessionChanged
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a valid backend URL, for example http://localhost:8080 on the simulator."
        case .server(_, let reason): return reason
        case .invalidResponse: return "The backend returned an unexpected response. Check that its URL is correct."
        case .sessionChanged: return "The session changed. Sign in and try again."
        }
    }
}

/// Tokens live only in memory. The API owns identity, permissions and all remote writes.
@MainActor
final class APIClient {
    let baseURL: URL
    var token: String?
    init(baseURL: String) throws {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw APIError.invalidURL }
        self.baseURL = url
    }
    static func encode<T: Encodable>(_ body: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return try encoder.encode(body)
    }
    func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, queryItems: [URLQueryItem] = []) async throws -> T {
        let data = try await send(path, method: method, body: body, queryItems: queryItems)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(T.self, from: data) }
        catch { throw APIError.invalidResponse }
    }
    func send(_ path: String, method: String = "POST", body: Data? = nil, queryItems: [URLQueryItem] = []) async throws -> Data {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { throw APIError.invalidURL }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.timeoutInterval = path == "api/machines/sync" ? 90 : 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let reason: String }
            let reason = (try? JSONDecoder().decode(Failure.self, from: data).reason) ?? "The backend rejected the request (\(response.statusCode))."
            throw APIError.server(response.statusCode, reason)
        }
        return data
    }
}
