import Foundation
import AuthenticationServices
import AppKit
import CryptoKit
import Combine
import OSLog

private let log = Logger(subsystem: "com.bharath.QuicPeek", category: "PeecOAuth")

/// Peec's advertised OAuth metadata points `/authorize`, `/token`, `/register` at the root,
/// but the real endpoints live under `/mcp/`. Hard-coding until they fix the discovery doc.
private enum Endpoints {
    static let authorize    = URL(string: "https://api.peec.ai/mcp/authorize")!
    static let token        = URL(string: "https://api.peec.ai/mcp/token")!
    static let registration = URL(string: "https://api.peec.ai/mcp/register")!
}

@MainActor
final class PeecOAuth: NSObject, ObservableObject {
    static let shared = PeecOAuth()

    @Published private(set) var isConnected: Bool = false
    @Published private(set) var isConnecting: Bool = false
    @Published private(set) var lastError: String?

    private let redirectURI = "quicpeek://oauth-callback"
    private let callbackScheme = "quicpeek"
    private let defaults = UserDefaults.standard
    private var currentSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        migrateSecretsToKeychainIfNeeded()
        isConnected = accessToken != nil
    }

    /// One-time migration: move tokens/client_secret from UserDefaults to Keychain so upgrading
    /// users don't need to re-authorize. Safe to call on every launch.
    private func migrateSecretsToKeychainIfNeeded() {
        for key in ["peec.access_token", "peec.refresh_token", "peec.client_secret"] {
            if let legacy = defaults.string(forKey: key) {
                Keychain.set(legacy, forKey: key)
                defaults.removeObject(forKey: key)
                log.info("migrated \(key, privacy: .public) to keychain")
            }
        }
    }

    // MARK: Public API

    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        lastError = nil
        defer { isConnecting = false }

        log.info("connect() start")
        do {
            let clientID = try await ensureRegistered()
            let (code, verifier) = try await authorize(clientID: clientID)
            let token = try await exchange(clientID: clientID, code: code, verifier: verifier)
            store(token: token)
            isConnected = true
            log.info("connect() success")
        } catch {
            lastError = String(describing: error)
            isConnected = false
            log.error("connect() failed — \(String(describing: error), privacy: .public)")
        }
    }

    func disconnect() {
        accessToken = nil
        refreshToken = nil
        accessTokenExpiresAt = nil
        isConnected = false
    }

    /// Returns a non-expired access token, refreshing silently if needed.
    /// Throws if no tokens are available or the refresh itself fails.
    func validAccessToken() async throws -> String {
        guard let current = accessToken else { throw OAuthError.notConnected }
        if let expiresAt = accessTokenExpiresAt, expiresAt > Date() {
            return current
        }
        return try await refresh()
    }

    private func refresh() async throws -> String {
        guard let refresh = refreshToken, let clientID = cachedClientID else {
            throw OAuthError.notConnected
        }
        log.info("refreshing access token")

        var req = URLRequest(url: Endpoints.token)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": clientID,
        ]
        if let secret = cachedClientSecret {
            form["client_secret"] = secret
        }
        req.httpBody = form
            .map { "\($0.key)=\(Self.percentEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            log.error("refresh failed — clearing tokens")
            disconnect()
            throw OAuthError.refreshFailed(body: String(decoding: data, as: UTF8.self))
        }

        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        store(token: token)
        log.info("refresh ok")
        return token.accessToken
    }

    private func store(token: TokenResponse) {
        accessToken = token.accessToken
        if let newRefresh = token.refreshToken {
            refreshToken = newRefresh
        }
        if let expiresIn = token.expiresIn {
            accessTokenExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn) - 30)
        } else {
            accessTokenExpiresAt = nil
        }
    }

    // MARK: Token storage
    //
    // Secrets (access token, refresh token, client secret) live in Keychain. The client ID
    // is a public identifier and stays in UserDefaults alongside other preferences.

    var accessToken: String? {
        get { Keychain.get(forKey: "peec.access_token") }
        set { Keychain.set(newValue, forKey: "peec.access_token") }
    }

    private var refreshToken: String? {
        get { Keychain.get(forKey: "peec.refresh_token") }
        set { Keychain.set(newValue, forKey: "peec.refresh_token") }
    }

    private var cachedClientSecret: String? {
        get { Keychain.get(forKey: "peec.client_secret") }
        set { Keychain.set(newValue, forKey: "peec.client_secret") }
    }

    private var cachedClientID: String? {
        get { defaults.string(forKey: "peec.client_id") }
        set { defaults.set(newValue, forKey: "peec.client_id") }
    }

    private var accessTokenExpiresAt: Date? {
        get { defaults.object(forKey: "peec.access_token_expires_at") as? Date }
        set { defaults.set(newValue, forKey: "peec.access_token_expires_at") }
    }

    // MARK: Dynamic client registration

    private struct RegistrationResponse: Decodable {
        let clientID: String
        let clientSecret: String?
        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case clientSecret = "client_secret"
        }
    }

    private func ensureRegistered() async throws -> String {
        if let cached = cachedClientID { return cached }

        var req = URLRequest(url: Endpoints.registration)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "client_name": "QuicPeek",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OAuthError.registrationFailed(body: String(decoding: data, as: UTF8.self))
        }
        let decoded = try JSONDecoder().decode(RegistrationResponse.self, from: data)
        cachedClientID = decoded.clientID
        cachedClientSecret = decoded.clientSecret
        return decoded.clientID
    }

    // MARK: Authorization (browser + PKCE)

    private func authorize(clientID: String) async throws -> (code: String, verifier: String) {
        let verifier = Self.randomURLSafe(byteCount: 32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(byteCount: 16)

        var comps = URLComponents(url: Endpoints.authorize, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authURL = comps.url else { throw OAuthError.badAuthorizationURL }

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: OAuthError.userCancelled) }
            }
            session.presentationContextProvider = self
            self.currentSession = session
            session.start()
        }

        guard let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value,
              items.first(where: { $0.name == "state" })?.value == state else {
            throw OAuthError.missingAuthorizationCode
        }
        return (code, verifier)
    }

    // MARK: Token exchange

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private func exchange(clientID: String, code: String, verifier: String) async throws -> TokenResponse {
        var req = URLRequest(url: Endpoints.token)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "client_id": clientID,
            "redirect_uri": redirectURI,
        ]
        if let secret = cachedClientSecret {
            form["client_secret"] = secret
        }
        req.httpBody = form
            .map { "\($0.key)=\(Self.percentEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OAuthError.tokenExchangeFailed(body: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: Helpers

    private static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - Presentation context

extension PeecOAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        }
    }
}

// MARK: - Errors

enum OAuthError: LocalizedError {
    case notConnected
    case registrationFailed(body: String)
    case badAuthorizationURL
    case missingAuthorizationCode
    case userCancelled
    case tokenExchangeFailed(body: String)
    case refreshFailed(body: String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not signed in to Peec."
        case .registrationFailed(let body): return "Client registration failed: \(body)"
        case .badAuthorizationURL: return "Could not build the authorization URL."
        case .missingAuthorizationCode: return "Authorization callback did not include a code."
        case .userCancelled: return "Sign-in cancelled."
        case .tokenExchangeFailed(let body): return "Token exchange failed: \(body)"
        case .refreshFailed(let body): return "Token refresh failed: \(body)"
        }
    }
}
