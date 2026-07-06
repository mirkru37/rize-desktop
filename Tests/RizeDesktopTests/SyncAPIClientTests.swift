@testable import RizeDesktop
import XCTest

/// Exercises `RemoteSyncAPIClient` against a `FakeHTTPTransport` — no real
/// network — covering request shaping (authorized headers, query items) and
/// response validation for both sync endpoints, per
/// `documentation/sync-protocol.md` §Push and §Pull.
final class SyncAPIClientTests: XCTestCase {
    private func makeClient(transport: FakeHTTPTransport) -> RemoteSyncAPIClient {
        RemoteSyncAPIClient(transport: transport, baseURLProvider: FixedBaseURLProvider())
    }

    private func makePushItem() -> SyncPushItemDTO {
        SyncPushItemDTO(
            entityType: "activity_event",
            data: ActivityEventPushDataDTO(
                eventID: UUID(),
                startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                endedAt: Date(timeIntervalSince1970: 1_800_000_600),
                appBundleID: "com.acme.Editor",
                windowTitle: nil,
                precision: "exact",
                deleted: false
            )
        )
    }

    // MARK: - pushEvents

    func testPushEventsSendsAuthorizedPostAndDecodesResults() async throws {
        let transport = FakeHTTPTransport()
        // Wire shape per documentation/sync-protocol.md §Push Response schema.
        let responseBody = Data("""
        {
          "results": [
            { "index": 0, "entity_type": "activity_event", "event_id": "evt-1", "status": "applied", "server_seq": 1 }
          ]
        }
        """.utf8)
        await transport.setOutcome(.success(HTTPResponse(statusCode: 200, body: responseBody)))
        let client = makeClient(transport: transport)

        let results = try await client.pushEvents(
            [makePushItem()],
            deviceID: "device-1",
            accessToken: "access-token-1"
        )

        XCTAssertEqual(results.first?.status, .applied)
        let request = await transport.lastRequest
        XCTAssertEqual(request?.method, .post)
        XCTAssertEqual(request?.path, "/sync/events")
        XCTAssertEqual(request?.headers["Authorization"], "Bearer access-token-1")
    }

    func testPushEventsWithUnauthorizedResponseThrows() async throws {
        let transport = FakeHTTPTransport()
        try await transport.setOutcome(.success(HTTPResponse(statusCode: 401, body: makeProblemData())))
        let client = makeClient(transport: transport)

        do {
            _ = try await client.pushEvents([makePushItem()], deviceID: "device-1", accessToken: "expired")
            XCTFail("expected pushEvents to throw")
        } catch APIError.unauthorized {
            // expected
        }
    }

    func testPushEventsWithUndecodableBodyThrowsDecodingFailed() async throws {
        let transport = FakeHTTPTransport()
        await transport.setOutcome(.success(HTTPResponse(statusCode: 200, body: Data("not json".utf8))))
        let client = makeClient(transport: transport)

        do {
            _ = try await client.pushEvents([makePushItem()], deviceID: "device-1", accessToken: "access-token-1")
            XCTFail("expected pushEvents to throw")
        } catch APIError.decodingFailed {
            // expected
        }
    }

    // MARK: - fetchChanges

    func testFetchChangesWithCursorSendsAuthorizedGetWithQueryItems() async throws {
        let transport = FakeHTTPTransport()
        // Wire shape per documentation/sync-protocol.md §Pull Response schema.
        let responseBody = Data("""
        { "changes": {}, "next_cursor": "cursor-2", "has_more": false }
        """.utf8)
        await transport.setOutcome(.success(HTTPResponse(statusCode: 200, body: responseBody)))
        let client = makeClient(transport: transport)

        let response = try await client.fetchChanges(cursor: "cursor-1", limit: 200, accessToken: "access-token-1")

        XCTAssertEqual(response.nextCursor, "cursor-2")
        let request = await transport.lastRequest
        XCTAssertEqual(request?.method, .get)
        XCTAssertEqual(request?.path, "/sync/changes")
        XCTAssertEqual(request?.headers["Authorization"], "Bearer access-token-1")
        let queryNames = request?.queryItems.map(\.name) ?? []
        XCTAssertTrue(queryNames.contains("cursor"))
        XCTAssertTrue(queryNames.contains("limit"))
    }

    func testFetchChangesWithNoCursorOmitsCursorQueryItem() async throws {
        let transport = FakeHTTPTransport()
        let responseBody = Data("""
        { "changes": {}, "next_cursor": "", "has_more": false }
        """.utf8)
        await transport.setOutcome(.success(HTTPResponse(statusCode: 200, body: responseBody)))
        let client = makeClient(transport: transport)

        _ = try await client.fetchChanges(cursor: nil, limit: 200, accessToken: "access-token-1")

        let request = await transport.lastRequest
        let queryNames = request?.queryItems.map(\.name) ?? []
        XCTAssertFalse(queryNames.contains("cursor"))
    }

    func testFetchChangesWithServerErrorThrows() async throws {
        let transport = FakeHTTPTransport()
        try await transport.setOutcome(.success(HTTPResponse(statusCode: 503, body: makeProblemData(status: 503))))
        let client = makeClient(transport: transport)

        do {
            _ = try await client.fetchChanges(cursor: nil, limit: 200, accessToken: "access-token-1")
            XCTFail("expected fetchChanges to throw")
        } catch let APIError.server(status, _) {
            XCTAssertEqual(status, 503)
        }
    }
}
