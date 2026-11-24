import Foundation
import Testing
@testable import Pine

@Suite("ACP shared JSON-RPC contract")
struct ACPSharedWireContractTests {
    @Test func stringRequestIDsUseExactUTF8AndKeepConnectionCachesIndependent() throws {
        let composed = CodexAppServerRequestID.string("Café")
        let decomposed = CodexAppServerRequestID.string("Cafe\u{301}")
        #expect(composed != decomposed)
        #expect(Set([composed, decomposed, .integer(7), .string("7")]).count == 4)
        var connection = CodexAppServerConnection()
        try connection.initialize { _ in }
        _ = try connection.receive(
            .response(.integer(0), result: .object(["userAgent": .string("fixture")])),
            connection: connection.identity, write: { _ in }
        )
        for identifier in [composed, decomposed] {
            #expect(try connection.receive(
                .request(identifier, method: "fixture/request", params: .object([:])),
                connection: connection.identity, write: { _ in }
            ) == .serverRequest(identifier, method: "fixture/request", params: .object([:])))
        }
        var responses: [Data] = []
        for identifier in [composed, decomposed] {
            try connection.answer(identifier, result: .object([:])) { responses.append($0) }
        }
        let responseIDs = try responses.map { data -> Data in
            guard case .response(.string(let identifier), _) = try CodexAppServerMessage(data: data) else {
                throw CodexAppServerWireError.invalidEnvelope
            }
            return Data(identifier.utf8)
        }
        #expect(Set(responseIDs) == Set([Data("Café".utf8), Data("Cafe\u{301}".utf8)]))
        #expect(connection.phase == .ready)
    }
}
