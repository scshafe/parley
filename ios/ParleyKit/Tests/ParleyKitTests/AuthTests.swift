import XCTest
@testable import ParleyKit

private let issuer = "https://id.example.ts.net"
private let discoveryJSON = """
{"issuer":"\(issuer)","authorization_endpoint":"\(issuer)/authorize",
 "token_endpoint":"\(issuer)/api/oidc/token","end_session_endpoint":"\(issuer)/api/oidc/end-session",
 "scopes_supported":["openid","profile","email","groups","offline_access"],
 "code_challenge_methods_supported":["plain","S256"],"authorization_response_iss_parameter_supported":true}
"""

/// An unsigned JWT with these claims (the app never checks signatures).
func makeJWT(_ claims: [String: Any]) -> String {
    let header = base64URL(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
    let payload = base64URL(try! JSONSerialization.data(withJSONObject: claims))
    return "\(header).\(payload).c2ln"
}

private func form(_ req: URLRequest) -> [String: String] {
    let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
    var out: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        out[kv[0]] = kv.count > 1 ? kv[1] : ""
    }
    return out
}

private func json(_ obj: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: obj) }

/// A fake Pocket ID: discovery, and a token endpoint that issues access
/// tokens `access-<n>` and rotates refresh tokens `refresh-<n>`.
final class FakeIssuer: @unchecked Sendable {
    var tokenCalls = 0
    var refuseRefresh = false
    var rotate = true
    var nonce = ""
    var expiresIn = 3600
    var lastForm: [String: String] = [:]
    var advertiseRevocation = false
    var revoked: [String] = []

    func handle(_ req: URLRequest) -> (Int, [String: String], Data)? {
        let path = req.url?.path ?? ""
        if path == "/.well-known/openid-configuration" {
            var doc = discoveryJSON
            if advertiseRevocation {
                doc = doc.replacingOccurrences(of: "\"issuer\":", with: "\"revocation_endpoint\":\"\(issuer)/api/oidc/revoke\",\"issuer\":")
            }
            return (200, [:], Data(doc.utf8))
        }
        if path == "/api/oidc/revoke" {
            revoked.append(form(req)["token"] ?? "")
            return (200, [:], Data())
        }
        guard path == "/api/oidc/token" else { return nil }
        tokenCalls += 1
        let f = form(req)
        lastForm = f
        if f["grant_type"] == "refresh_token" && refuseRefresh {
            return (400, [:], json(["error": "invalid_grant"]))
        }
        var body: [String: Any] = [
            "access_token": "access-\(tokenCalls)", "token_type": "Bearer", "expires_in": expiresIn,
            "id_token": makeJWT(["iss": issuer, "aud": "parley-ios", "sub": "u-1", "nonce": nonce,
                                 "name": "Cole", "email": "cole@example.com"]),
        ]
        if f["grant_type"] == "authorization_code" || rotate { body["refresh_token"] = "refresh-\(tokenCalls)" }
        return (200, [:], json(body))
    }
}

final class OIDCTests: XCTestCase {
    var fake: FakeIssuer!
    var client: OIDCClient!
    let config = OIDCConfiguration(issuer: URL(string: issuer)!, clientID: "parley-ios",
                                   redirectURI: URL(string: "com.scshafe.parley://oauth/callback")!)

    override func setUp() {
        fake = FakeIssuer()
        let fake = self.fake!
        StubProtocol.seen = []
        StubProtocol.handler = { req in fake.handle(req) ?? (404, [:], Data()) }
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        client = OIDCClient(configuration: config, session: URLSession(configuration: c))
    }

    func testPKCEMatchesTheRFCExample() {
        // RFC 7636, appendix B.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let fresh = PKCE.generate()
        XCTAssertEqual(fresh.verifier.count, 86)
        XCTAssertNotEqual(fresh.verifier, PKCE.generate().verifier)
    }

    func testDiscoveryIsCheckedAgainstTheIssuer() async throws {
        let doc = try await client.discover()
        XCTAssertEqual(doc.tokenEndpoint.absoluteString, "\(issuer)/api/oidc/token")
        let other = OIDCClient(configuration: OIDCConfiguration(issuer: URL(string: "https://other.example")!,
                                                                clientID: "x", redirectURI: config.redirectURI),
                               session: URLSession(configuration: {
                                   let c = URLSessionConfiguration.ephemeral
                                   c.protocolClasses = [StubProtocol.self]
                                   return c
                               }()))
        StubProtocol.handler = { _ in (200, [:], Data(discoveryJSON.utf8)) }
        do {
            _ = try await other.discover()
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? OIDCError, .discovery("the discovery document names a different issuer"))
        }
    }

    func testDiscoveredEndpointsMustBeHTTPS() async {
        StubProtocol.handler = { _ in
            (200, [:], Data(discoveryJSON.replacingOccurrences(of: "\(issuer)/api/oidc/token",
                                                                  with: "http://id.example.ts.net/api/oidc/token").utf8))
        }
        do {
            _ = try await client.discover()
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? OIDCError, .discovery("the discovery document has an endpoint that is not https"))
        }
    }

    func testTheAuthorizationRequestCarriesPKCEAndTheScopes() async throws {
        let request = client.authorizationRequest(try await client.discover())
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(request.url.path, "/authorize")
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["client_id"], "parley-ios")
        XCTAssertEqual(q["redirect_uri"], "com.scshafe.parley://oauth/callback")
        XCTAssertEqual(q["scope"], "openid profile email offline_access")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["code_challenge"], request.pkce.challenge)
        XCTAssertEqual(q["state"], request.state)
        XCTAssertEqual(q["nonce"], request.nonce)

        var doc = try await client.discover()
        doc.scopesSupported = ["openid", "profile", "email"]
        let items2 = URLComponents(url: client.authorizationRequest(doc).url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items2.first { $0.name == "scope" }?.value, "openid profile email")
    }

    func testTheCallbackMustAnswerThisRequest() async throws {
        let request = client.authorizationRequest(try await client.discover())
        func cb(_ query: String) -> URL { URL(string: "com.scshafe.parley://oauth/callback?\(query)")! }
        XCTAssertEqual(try client.authorizationCode(from: cb("code=abc&state=\(request.state)&iss=\(issuer)"),
                                                    for: request), "abc")
        XCTAssertThrowsError(try client.authorizationCode(from: cb("code=abc&state=nope"), for: request)) {
            XCTAssertEqual($0 as? OIDCError, .callback("it does not belong to this sign-in"))
        }
        XCTAssertThrowsError(try client.authorizationCode(from: cb("code=abc&state=\(request.state)&iss=https://evil"),
                                                          for: request)) {
            XCTAssertEqual($0 as? OIDCError, .callback("it came from a different issuer"))
        }
        XCTAssertThrowsError(try client.authorizationCode(from: cb("error=access_denied&state=\(request.state)"),
                                                          for: request)) {
            XCTAssertEqual($0 as? OIDCError, .refused("access_denied"))
        }
        XCTAssertThrowsError(try client.authorizationCode(
            from: URL(string: "com.scshafe.parley://elsewhere?code=abc&state=\(request.state)")!, for: request))
    }

    func testTheCodeIsExchangedWithTheVerifierAndNoSecret() async throws {
        let request = client.authorizationRequest(try await client.discover())
        fake.nonce = request.nonce
        let tokens = try await client.exchange(code: "abc", for: request)
        XCTAssertEqual(fake.lastForm, [
            "grant_type": "authorization_code", "code": "abc", "client_id": "parley-ios",
            "redirect_uri": "com.scshafe.parley://oauth/callback", "code_verifier": request.pkce.verifier,
        ])
        XCTAssertEqual(tokens.accessToken, "access-1")
        XCTAssertEqual(tokens.refreshToken, "refresh-1")
        XCTAssertEqual(tokens.account, OIDCAccount(subject: "u-1", name: "Cole", email: "cole@example.com"))
        XCTAssertEqual(tokens.expiresAt.timeIntervalSinceNow, 3600, accuracy: 5)

        fake.nonce = "someone-else"
        do {
            _ = try await client.exchange(code: "abc", for: request)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? OIDCError, .token("the ID token does not belong to this sign-in"))
        }
    }

    func testRefreshKeepsAnUnrotatedRefreshTokenAndEndsOnARefusal() async throws {
        let start = OIDCTokens(accessToken: "a0", refreshToken: "r0", idToken: nil, expiresAt: Date(),
                               account: OIDCAccount(subject: "u-1", name: nil, email: nil))
        fake.rotate = false
        let kept = try await client.refresh(start)
        XCTAssertEqual(fake.lastForm, ["grant_type": "refresh_token", "refresh_token": "r0", "client_id": "parley-ios"])
        XCTAssertEqual(kept.refreshToken, "r0")
        fake.rotate = true
        let rotated = try await client.refresh(kept)
        XCTAssertEqual(rotated.refreshToken, "refresh-2")
        fake.refuseRefresh = true
        do {
            _ = try await client.refresh(rotated)
            XCTFail("expected sign-in required")
        } catch {
            XCTAssertEqual(error as? OIDCError, .signInRequired)
        }
    }
}

final class TokenSessionTests: XCTestCase {
    var fake: FakeIssuer!
    var oidc: OIDCClient!
    var session: URLSession!

    override func setUp() {
        fake = FakeIssuer()
        StubProtocol.seen = []
        let fake = self.fake!
        StubProtocol.handler = { req in fake.handle(req) ?? (404, [:], Data()) }
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: c)
        oidc = OIDCClient(configuration: OIDCConfiguration(issuer: URL(string: issuer)!, clientID: "parley-ios",
                                                           redirectURI: URL(string: "com.scshafe.parley://oauth/callback")!),
                          session: session)
    }

    private func tokens(expiresIn: TimeInterval) -> OIDCTokens {
        OIDCTokens(accessToken: "a0", refreshToken: "r0", idToken: nil, expiresAt: Date().addingTimeInterval(expiresIn),
                   account: OIDCAccount(subject: "u-1", name: "Cole", email: nil))
    }

    func testAFreshTokenIsUsedAsIsAndAnExpiringOneIsRefreshedOnce() async throws {
        let store = MemoryTokenStore(tokens(expiresIn: 600))
        let ts = TokenSession(client: oidc, store: store)
        let first = try await ts.currentToken()
        XCTAssertEqual(first, "a0")
        XCTAssertEqual(fake.tokenCalls, 0)

        await ts.signedIn(with: tokens(expiresIn: 30))  // inside the leeway
        async let a = ts.currentToken()
        async let b = ts.currentToken()
        async let c = ts.currentToken()
        let all = try await [a, b, c]
        XCTAssertEqual(Set(all), ["access-1"])
        XCTAssertEqual(fake.tokenCalls, 1, "concurrent callers share one refresh")
        XCTAssertEqual(store.load()?.refreshToken, "refresh-1", "the rotated refresh token is kept")
    }

    func testARejectedTokenIsRefreshedButANewerOneIsJustReturned() async throws {
        let ts = TokenSession(client: oidc, store: MemoryTokenStore(tokens(expiresIn: 600)))
        let retry = try await ts.tokenAfterRejection("a0")
        XCTAssertEqual(retry, "access-1")
        let again = try await ts.tokenAfterRejection("a0")
        XCTAssertEqual(again, "access-1", "already refreshed: no second refresh")
        XCTAssertEqual(fake.tokenCalls, 1)
    }

    func testARefusedRefreshEndsTheSession() async throws {
        fake.refuseRefresh = true
        let store = MemoryTokenStore(tokens(expiresIn: 0))
        let ts = TokenSession(client: oidc, store: store)
        let changes = ChangeLog()
        await ts.setOnChange { changes.append($0) }
        do {
            _ = try await ts.currentToken()
            XCTFail("expected sign-in required")
        } catch {
            XCTAssertEqual(error as? RelayError, .signInRequired)
        }
        let signedIn = await ts.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertNil(store.load())
        XCTAssertEqual(changes.all, [.signedOut])
    }

    func testTheRelayClientRetriesOnceWithAFreshToken() async throws {
        let fake = self.fake!
        StubProtocol.handler = { req in
            if let r = fake.handle(req) { return r }
            let auth = req.value(forHTTPHeaderField: "Authorization")
            if auth == "Bearer a0" { return (401, [:], Data()) }
            return (200, [:], Data(#"{"conversations":[]}"#.utf8))
        }
        let ts = TokenSession(client: oidc, store: MemoryTokenStore(tokens(expiresIn: 600)))
        let relay = RelayClient(baseURL: URL(string: "http://relay.test")!, auth: ts, session: session)
        let list = try await relay.listConversations()
        XCTAssertEqual(list, [])
        let relayCalls = StubProtocol.seen.filter { $0.url?.host == "relay.test" }
        XCTAssertEqual(relayCalls.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer a0", "Bearer access-1"])
    }

    func testAStaticTokenIsNotRetried() async {
        StubProtocol.handler = { _ in (401, [:], Data()) }
        let relay = RelayClient(baseURL: URL(string: "http://relay.test")!, auth: StaticBearer(token: "parley-dev"),
                                session: session)
        do {
            _ = try await relay.listConversations()
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? RelayError, .unauthorized)
        }
        XCTAssertEqual(StubProtocol.seen.count, 1)
    }

    func testTheEventStreamReopensWithAFreshTokenAfterA401() async throws {
        let fake = self.fake!
        let event = "id: 3\nevent: turn.updated\ndata: \(turnJSON.replacingOccurrences(of: "\n", with: ""))\n\n"
        StubProtocol.handler = { req in
            if let r = fake.handle(req) { return r }
            if req.value(forHTTPHeaderField: "Authorization") == "Bearer a0" { return (401, [:], Data()) }
            return (200, ["Content-Type": "text/event-stream"], Data(event.utf8))
        }
        let ts = TokenSession(client: oidc, store: MemoryTokenStore(tokens(expiresIn: 600)))
        let relay = RelayClient(baseURL: URL(string: "http://relay.test")!, auth: ts, session: session)
        var got: [RelayEvent] = []
        for try await e in relay.events(conversationID: "c_1", after: 0) { got.append(e) }
        XCTAssertEqual(got.map(\.id), [3])
        XCTAssertEqual(StubProtocol.seen.last?.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
    }

    func testNoSessionMeansSignInRequired() async {
        let ts = TokenSession(client: oidc, store: MemoryTokenStore())
        let relay = RelayClient(baseURL: URL(string: "http://relay.test")!, auth: ts, session: session)
        do {
            _ = try await relay.listConversations()
            XCTFail("expected sign-in required")
        } catch {
            XCTAssertEqual(error as? RelayError, .signInRequired)
        }
        XCTAssertTrue(StubProtocol.seen.isEmpty)
    }
}

extension TokenSessionTests {
    func testARelayThatKeepsRefusingIsNotRefreshedInALoop() async throws {
        let fake = self.fake!
        StubProtocol.handler = { req in fake.handle(req) ?? (401, [:], Data()) }
        let clock = Clock()
        let ts = TokenSession(client: oidc, store: MemoryTokenStore(tokens(expiresIn: 3600)), now: { clock.now })
        let relay = RelayClient(baseURL: URL(string: "https://relay.example.ts.net")!, auth: ts, session: session)
        for _ in 0..<3 {
            do {
                _ = try await relay.listConversations()
                XCTFail("expected unauthorized")
            } catch {
                XCTAssertEqual(error as? RelayError, .unauthorized)
            }
        }
        XCTAssertEqual(fake.tokenCalls, 1, "one refresh, then the 401 stands")
        clock.now += TokenSession.rejectionRefreshInterval + 1
        _ = try? await relay.listConversations()
        XCTAssertEqual(fake.tokenCalls, 2, "after the interval a rejection may refresh again")
    }

    func testSignOutRevokesTheRefreshTokenWhenTheIssuerOffersIt() async {
        fake.advertiseRevocation = true
        let store = MemoryTokenStore(tokens(expiresIn: 600))
        let ts = TokenSession(client: oidc, store: store)
        await ts.signOut()
        XCTAssertNil(store.load())
        XCTAssertEqual(fake.revoked, ["r0"])
    }

    func testSignOutWithoutARevocationEndpointJustForgets() async {
        let store = MemoryTokenStore(tokens(expiresIn: 600))
        let ts = TokenSession(client: oidc, store: store)
        await ts.signOut()
        XCTAssertNil(store.load())
        XCTAssertEqual(fake.revoked, [])
        XCTAssertEqual(fake.tokenCalls, 0)
    }

    func testTheSessionTokenGoesOnlyToHTTPSTailnetHosts() {
        func ok(_ u: String, _ suffix: String = ".example.ts.net") -> Bool {
            RelayConfiguration.allowsSessionToken(to: URL(string: u)!, hostSuffix: suffix)
        }
        XCTAssertTrue(ok("https://parley.example.ts.net"))
        XCTAssertTrue(ok("https://Parley.Example.ts.net:443/x", "example.ts.net"))
        XCTAssertFalse(ok("http://parley.example.ts.net"))
        XCTAssertFalse(ok("https://parley.example.ts.net.evil.com"))
        XCTAssertFalse(ok("https://evilexample.ts.net"))
        XCTAssertFalse(ok("https://example.ts.net"))
        XCTAssertFalse(ok("http://127.0.0.1:8765"))
        XCTAssertFalse(ok("https://parley.example.ts.net", ""))
    }

    func testRedirectsAreFollowedOnlyWithinTheOrigin() {
        let from = URL(string: "https://parley.example.ts.net/api/v1/x")
        XCTAssertTrue(SameOriginRedirects.allows(from: from, to: URL(string: "https://parley.example.ts.net/api/v1/y")))
        XCTAssertFalse(SameOriginRedirects.allows(from: from, to: URL(string: "https://evil.example/api")))
        XCTAssertFalse(SameOriginRedirects.allows(from: from, to: URL(string: "http://parley.example.ts.net/api/v1/y")))
        XCTAssertFalse(SameOriginRedirects.allows(from: from, to: URL(string: "https://parley.example.ts.net:8443/y")))
    }
}

final class Clock: @unchecked Sendable {
    var now = Date()
}

final class ChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TokenSession.Change] = []
    func append(_ c: TokenSession.Change) { lock.withLock { items.append(c) } }
    var all: [TokenSession.Change] { lock.withLock { items } }
}
