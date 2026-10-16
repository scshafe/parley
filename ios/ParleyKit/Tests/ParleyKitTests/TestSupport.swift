import Foundation
@testable import ParleyKit

/// A fixed bearer token, for tests of the relay client on its own (the app
/// itself only ever sends the signed-in session's token).
struct StaticBearer: BearerProvider {
    let token: String

    func currentToken() async throws -> String {
        guard !token.isEmpty else { throw RelayError.notConfigured }
        return token
    }

    func tokenAfterRejection(_ rejected: String) async throws -> String? { nil }
}
