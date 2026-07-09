import Foundation
import AuthenticationServices
import UIKit

/// Connects a Strava account (OAuth in a system web sheet) and uploads rides
/// as TCX activities. The API credentials come from Info.plist
/// (`StravaClientID` / `StravaClientSecret` — see docs/SETUP.md); tokens live
/// in the Keychain, never in UserDefaults.
final class StravaManager: NSObject, ObservableObject {

    enum UploadState: Equatable {
        case idle, uploading, done, failed
    }

    @Published private(set) var athleteName: String?
    @Published private(set) var connected = false
    /// Per-ride upload progress, keyed by RideSummary id.
    @Published private(set) var uploads: [UUID: UploadState] = [:]

    private let clientID = (Bundle.main.object(forInfoDictionaryKey: "StravaClientID") as? String) ?? ""
    private let clientSecret = (Bundle.main.object(forInfoDictionaryKey: "StravaClientSecret") as? String) ?? ""
    /// The scheme://host must match the API app's Authorization Callback
    /// Domain on strava.com (set it to "localhost").
    private let redirectURI = "cyclehud://localhost"

    /// Whether API credentials have been added to Info.plist at all.
    var configured: Bool { !clientID.isEmpty && !clientSecret.isEmpty }

    private var authSession: ASWebAuthenticationSession?

    private struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Double        // epoch seconds
        var athleteName: String?
    }
    private let keychainKey = "stravaTokens"

    override init() {
        super.init()
        if let tokens = loadTokens() {
            connected = true
            athleteName = tokens.athleteName
        }
    }

    // MARK: - Connect / disconnect

    func connect() {
        guard configured else { return }
        var comps = URLComponents(string: "https://www.strava.com/oauth/mobile/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "approval_prompt", value: "auto"),
            .init(name: "scope", value: "activity:write,read"),
        ]
        let session = ASWebAuthenticationSession(url: comps.url!,
                                                 callbackURLScheme: "cyclehud") { [weak self] url, _ in
            guard let self, let url,
                  let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "code" })?.value else { return }
            Task { await self.exchange(code: code) }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        session.start()
    }

    func disconnect() {
        Keychain.delete(keychainKey)
        connected = false
        athleteName = nil
        uploads = [:]
    }

    // MARK: - Upload

    /// Upload a ride as a TCX activity. Safe to call repeatedly; Strava
    /// de-duplicates identical uploads on its side.
    func upload(_ summary: RideSummary) async {
        guard let tcx = RideExporter.string(for: summary, format: .tcx) else {
            await setUpload(summary.id, .failed)
            return
        }
        await setUpload(summary.id, .uploading)
        guard let token = await validAccessToken() else {
            await setUpload(summary.id, .failed)
            return
        }
        var request = URLRequest(url: URL(string: "https://www.strava.com/api/v3/uploads")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let boundary = "cyclehud-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("data_type", "tcx")
        field("name", uploadName(for: summary))
        field("activity_type", "ride")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"ride.tcx\"\r\nContent-Type: application/xml\r\n\r\n".data(using: .utf8)!)
        body.append(tcx.data(using: .utf8)!)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            await setUpload(summary.id, ok ? .done : .failed)
            AppLog.shared.log("Strava upload \(ok ? "OK" : "FAILED (\((response as? HTTPURLResponse)?.statusCode ?? -1))")")
        } catch {
            AppLog.shared.log("Strava upload error: \(error.localizedDescription)")
            await setUpload(summary.id, .failed)
        }
    }

    func uploadState(_ id: UUID) -> UploadState { uploads[id] ?? .idle }

    @MainActor private func setUpload(_ id: UUID, _ state: UploadState) {
        uploads[id] = state
    }

    private func uploadName(for summary: RideSummary) -> String {
        let hour = Calendar.current.component(.hour, from: summary.date)
        switch hour {
        case 5..<12: return String(localized: "Morning ride", bundle: Lang.bundle)
        case 12..<17: return String(localized: "Afternoon ride", bundle: Lang.bundle)
        case 17..<21: return String(localized: "Evening ride", bundle: Lang.bundle)
        default: return String(localized: "Night ride", bundle: Lang.bundle)
        }
    }

    // MARK: - Tokens

    private func loadTokens() -> Tokens? {
        Keychain.get(keychainKey).flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) }
    }

    private func saveTokens(_ tokens: Tokens) {
        if let data = try? JSONEncoder().encode(tokens) { Keychain.set(data, key: keychainKey) }
    }

    private func exchange(code: String) async {
        guard let tokens = await tokenRequest(params: [
            "client_id": clientID, "client_secret": clientSecret,
            "code": code, "grant_type": "authorization_code",
        ]) else { return }
        saveTokens(tokens)
        await MainActor.run {
            connected = true
            athleteName = tokens.athleteName
        }
        AppLog.shared.log("Strava connected")
    }

    /// A fresh access token, refreshing via the refresh token when within
    /// 5 minutes of expiry. nil = not connected / refresh failed.
    private func validAccessToken() async -> String? {
        guard var tokens = loadTokens() else { return nil }
        if Date().timeIntervalSince1970 < tokens.expiresAt - 300 {
            return tokens.accessToken
        }
        guard let refreshed = await tokenRequest(params: [
            "client_id": clientID, "client_secret": clientSecret,
            "refresh_token": tokens.refreshToken, "grant_type": "refresh_token",
        ]) else { return nil }
        // Refresh responses carry no athlete block; keep the stored name.
        tokens = Tokens(accessToken: refreshed.accessToken,
                        refreshToken: refreshed.refreshToken,
                        expiresAt: refreshed.expiresAt,
                        athleteName: tokens.athleteName)
        saveTokens(tokens)
        return tokens.accessToken
    }

    private func tokenRequest(params: [String: String]) async -> Tokens? {
        var request = URLRequest(url: URL(string: "https://www.strava.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String,
              let expires = json["expires_at"] as? Double else {
            AppLog.shared.log("Strava token request failed")
            return nil
        }
        let athlete = json["athlete"] as? [String: Any]
        let name = [athlete?["firstname"] as? String, athlete?["lastname"] as? String]
            .compactMap { $0 }.joined(separator: " ")
        return Tokens(accessToken: access, refreshToken: refresh, expiresAt: expires,
                      athleteName: name.isEmpty ? nil : name)
    }
}

extension StravaManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

/// Minimal Keychain wrapper for the Strava tokens.
enum Keychain {
    static func set(_ data: Data, key: String) {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)
        return result as? Data
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
