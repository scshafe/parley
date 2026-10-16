import CryptoKit
import Foundation

/// Signing in with Pocket ID: OpenID Connect's authorization code flow with
/// PKCE (S256) for a public client (no secret), a custom-scheme redirect, and
/// refresh tokens. The app shows the authorization URL in an
/// `ASWebAuthenticationSession` and hands the callback URL back here; the rest
/// (discovery, the code exchange, refreshing, the ID token's checks) is plain
/// Foundation and unit tested.
public struct OIDCConfiguration: Equatable, Sendable {
    public var issuer: URL
    public var clientID: String
    public var redirectURI: URL
    public var scopes: [String]

    public static let defaultScopes = ["openid", "profile", "email", "offline_access"]

    public init(issuer: URL, clientID: String, redirectURI: URL, scopes: [String] = OIDCConfiguration.defaultScopes) {
        self.issuer = issuer
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    /// The redirect URI's scheme, which the web authentication session waits for.
    public var callbackScheme: String { redirectURI.scheme ?? "" }

    /// The issuer as the discovery document and the ID token spell it (no trailing slash).
    public var issuerString: String {
        var s = issuer.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

public enum OIDCError: Error, Equatable, LocalizedError {
    /// The discovery document is missing, for another issuer, or unusable.
    case discovery(String)
    /// The callback does not belong to this sign-in, or carries no code.
    case callback(String)
    /// The identity provider refused the sign-in (`error=` on the callback).
    case refused(String)
    /// The token endpoint refused the code or answered something unusable.
    case token(String)
    /// The refresh token is no longer accepted: sign in again.
    case signInRequired
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .discovery(let what): return "Sign-in is not available: \(what)."
        case .callback(let what): return "The sign-in did not complete: \(what)."
        case .refused(let code): return "Pocket ID refused the sign-in (\(code))."
        case .token(let what): return "Pocket ID did not issue tokens: \(what)."
        case .signInRequired: return "Your sign-in has ended. Sign in again."
        case .transport(let what): return "Pocket ID could not be reached (\(what))."
        }
    }
}

/// The parts of the issuer's `/.well-known/openid-configuration` the app uses.
public struct OIDCDiscovery: Decodable, Equatable, Sendable {
    public var issuer: String
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var endSessionEndpoint: URL?
    public var scopesSupported: [String]?
    public var codeChallengeMethodsSupported: [String]?

    public init(issuer: String, authorizationEndpoint: URL, tokenEndpoint: URL, endSessionEndpoint: URL? = nil,
                scopesSupported: [String]? = nil, codeChallengeMethodsSupported: [String]? = nil) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.endSessionEndpoint = endSessionEndpoint
        self.scopesSupported = scopesSupported
        self.codeChallengeMethodsSupported = codeChallengeMethodsSupported
    }
}

/// A PKCE verifier and its S256 challenge (RFC 7636).
public struct PKCE: Equatable, Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        challenge = PKCE.s256(verifier)
    }

    /// 64 random bytes as base64url: an 86-character verifier.
    public static func generate() -> PKCE {
        PKCE(verifier: randomURLSafe(bytes: 64))
    }

    public static func s256(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

/// One sign-in attempt: the URL to open, and what its callback must match.
public struct AuthorizationRequest: Equatable, Sendable {
    public let url: URL
    public let state: String
    public let nonce: String
    public let pkce: PKCE
    public let redirectURI: URL
    public let tokenEndpoint: URL
    public let issuer: String
}

/// Who is signed in, from the ID token's claims (for display only).
public struct OIDCAccount: Codable, Equatable, Sendable {
    public var subject: String
    public var name: String?
    public var email: String?

    public var label: String { name ?? email ?? subject }
}

/// The tokens a sign-in holds. The app keeps them in the Keychain.
public struct OIDCTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var expiresAt: Date
    public var account: OIDCAccount?

    public init(accessToken: String, refreshToken: String?, idToken: String?, expiresAt: Date, account: OIDCAccount?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.account = account
    }
}

/// The issuer's endpoints, called over HTTPS with `URLSession`.
public final class OIDCClient: @unchecked Sendable {
    public let configuration: OIDCConfiguration
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cached: OIDCDiscovery?

    public init(configuration: OIDCConfiguration, session: URLSession = .shared,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.session = session
        self.now = now
    }

    // MARK: Discovery

    public func discover() async throws -> OIDCDiscovery {
        if let cached = lock.withLock({ cached }) { return cached }
        let url = configuration.issuer.appendingPathComponent(".well-known/openid-configuration")
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let (data, response) = try await load(req)
        guard response.statusCode == 200 else {
            throw OIDCError.discovery("the issuer answered HTTP \(response.statusCode)")
        }
        guard let doc = try? ParleyJSON.decoder.decode(OIDCDiscovery.self, from: data) else {
            throw OIDCError.discovery("the issuer's discovery document could not be read")
        }
        guard doc.issuer == configuration.issuerString else {
            throw OIDCError.discovery("the discovery document names a different issuer")
        }
        for endpoint in [doc.authorizationEndpoint, doc.tokenEndpoint] {
            guard let scheme = endpoint.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
                throw OIDCError.discovery("the discovery document has an unusable endpoint")
            }
        }
        if let methods = doc.codeChallengeMethodsSupported, !methods.contains("S256") {
            throw OIDCError.discovery("the issuer does not support PKCE S256")
        }
        lock.withLock { cached = doc }
        return doc
    }

    // MARK: Signing in

    /// A fresh authorization request (new state, nonce and PKCE verifier).
    /// `offline_access` is asked for only if the issuer lists it.
    public func authorizationRequest(_ discovery: OIDCDiscovery) -> AuthorizationRequest {
        let pkce = PKCE.generate()
        let state = randomURLSafe(bytes: 32)
        let nonce = randomURLSafe(bytes: 32)
        var scopes = configuration.scopes
        if let supported = discovery.scopesSupported {
            scopes = scopes.filter { $0 != "offline_access" || supported.contains($0) }
        }
        var components = URLComponents(url: discovery.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        // URLComponents leaves "+" alone, which a form decoder reads as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return AuthorizationRequest(url: components.url!, state: state, nonce: nonce, pkce: pkce,
                                    redirectURI: configuration.redirectURI, tokenEndpoint: discovery.tokenEndpoint,
                                    issuer: discovery.issuer)
    }

    /// The authorization code from the callback URL, after checking that the
    /// callback answers `request` (redirect, state, and `iss` when present).
    public func authorizationCode(from callback: URL, for request: AuthorizationRequest) throws -> String {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == request.redirectURI.scheme?.lowercased(),
              parts.host?.lowercased() == request.redirectURI.host?.lowercased(),
              parts.path == request.redirectURI.path else {
            throw OIDCError.callback("it came back to an unexpected address")
        }
        var params: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            if params[item.name] != nil { throw OIDCError.callback("it repeats \(item.name)") }
            params[item.name] = item.value ?? ""
        }
        guard params["state"] == request.state else {
            throw OIDCError.callback("it does not belong to this sign-in")
        }
        if let iss = params["iss"], iss != request.issuer {
            throw OIDCError.callback("it came from a different issuer")
        }
        if let error = params["error"] {
            throw OIDCError.refused(sanitized(error))
        }
        guard let code = params["code"], !code.isEmpty else {
            throw OIDCError.callback("it carries no code")
        }
        return code
    }

    /// Exchange the code (with the PKCE verifier) for tokens.
    public func exchange(code: String, for request: AuthorizationRequest) async throws -> OIDCTokens {
        let (status, body) = try await postForm(request.tokenEndpoint, [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": request.redirectURI.absoluteString,
            "client_id": configuration.clientID,
            "code_verifier": request.pkce.verifier,
        ])
        guard status == 200 else {
            throw OIDCError.token("the token endpoint answered HTTP \(status)\(Self.errorCode(body).map { " (\($0))" } ?? "")")
        }
        return try tokens(from: body, issuer: request.issuer, nonce: request.nonce, previous: nil)
    }

    // MARK: Refreshing

    /// New tokens for `tokens` from its refresh token. A refused refresh
    /// token (400 or 401) is `OIDCError.signInRequired`. If the issuer does
    /// not rotate the refresh token, the old one is kept.
    public func refresh(_ tokens: OIDCTokens) async throws -> OIDCTokens {
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else { throw OIDCError.signInRequired }
        let discovery = try await discover()
        let (status, body) = try await postForm(discovery.tokenEndpoint, [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": configuration.clientID,
        ])
        if status == 400 || status == 401 { throw OIDCError.signInRequired }
        guard status == 200 else { throw OIDCError.token("the token endpoint answered HTTP \(status)") }
        return try self.tokens(from: body, issuer: discovery.issuer, nonce: nil, previous: tokens)
    }

    // MARK: Token responses

    private struct TokenResponse: Decodable {
        var accessToken: String?
        var tokenType: String?
        var expiresIn: Double?
        var refreshToken: String?
        var idToken: String?
    }

    func tokens(from data: Data, issuer: String, nonce: String?, previous: OIDCTokens?) throws -> OIDCTokens {
        guard let body = try? ParleyJSON.decoder.decode(TokenResponse.self, from: data) else {
            throw OIDCError.token("its answer could not be read")
        }
        guard let access = body.accessToken, !access.isEmpty else { throw OIDCError.token("no access token") }
        if let type = body.tokenType, type.lowercased() != "bearer" {
            throw OIDCError.token("not a bearer token")
        }
        var account = previous?.account
        if let idToken = body.idToken {
            guard let claims = JWT.claims(idToken) else { throw OIDCError.token("the ID token is not a JWT") }
            guard claims["iss"] as? String == issuer, JWT.audiences(claims).contains(configuration.clientID) else {
                throw OIDCError.token("the ID token is for a different issuer or client")
            }
            if let nonce, claims["nonce"] as? String != nonce {
                throw OIDCError.token("the ID token does not belong to this sign-in")
            }
            if let subject = claims["sub"] as? String {
                if let previous = previous?.account, previous.subject != subject {
                    throw OIDCError.token("the refreshed ID token is for someone else")
                }
                let name = (claims["name"] as? String) ?? (claims["display_name"] as? String)
                    ?? (claims["preferred_username"] as? String)
                account = OIDCAccount(subject: subject, name: name?.nilIfEmpty, email: (claims["email"] as? String)?.nilIfEmpty)
            }
        } else if nonce != nil {
            throw OIDCError.token("no ID token")
        }
        let issued = now()
        let lifetime: TimeInterval
        if let expiresIn = body.expiresIn, expiresIn > 0 {
            lifetime = expiresIn
        } else if let exp = JWT.claims(access)?["exp"] as? Double {
            lifetime = max(0, exp - issued.timeIntervalSince1970)
        } else {
            lifetime = 300
        }
        return OIDCTokens(accessToken: access, refreshToken: body.refreshToken ?? previous?.refreshToken,
                          idToken: body.idToken ?? previous?.idToken, expiresAt: issued.addingTimeInterval(lifetime),
                          account: account)
    }

    // MARK: HTTP

    private func load(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw OIDCError.transport("no HTTP answer") }
            return (data, http)
        } catch let error as OIDCError {
            throw error
        } catch {
            throw OIDCError.transport((error as NSError).localizedDescription)
        }
    }

    private func postForm(_ url: URL, _ fields: [String: String]) async throws -> (Int, Data) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data(formEncode(fields).utf8)
        req.timeoutInterval = 20
        let (data, response) = try await load(req)
        return (response.statusCode, data)
    }

    static func errorCode(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = obj["error"] as? String else { return nil }
        return sanitized(code)
    }
}

/// Reading a JWT's claims without checking its signature. The app checks only
/// the ID token it got straight from the token endpoint over TLS (OIDC Core
/// 3.1.3.7) and uses its claims for display; the relay's door verifies the
/// access token.
public enum JWT {
    public static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let data = base64URLDecode(String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func audiences(_ claims: [String: Any]) -> [String] {
        if let one = claims["aud"] as? String { return [one] }
        return (claims["aud"] as? [String]) ?? []
    }
}

// MARK: Helpers

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func base64URLDecode(_ text: String) -> Data? {
    var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s.append("=") }
    return Data(base64Encoded: s)
}

/// Random bytes from the system's CSPRNG, as base64url.
func randomURLSafe(bytes count: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    return base64URL(Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
}

/// RFC 3986's unreserved characters, ASCII only.
let unreservedASCII = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

func formEncode(_ fields: [String: String]) -> String {
    let allowed = unreservedASCII
    return fields.sorted { $0.key < $1.key }.map { key, value in
        let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(k)=\(v)"
    }.joined(separator: "&")
}

/// An error code from the identity provider, safe to show: letters, digits, `_` and `-`.
func sanitized(_ code: String) -> String {
    String(code.unicodeScalars.filter { $0 != "." && $0 != "~" && unreservedASCII.contains($0) }
        .prefix(64).map(Character.init))
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
