@testable import RizeDesktop
import XCTest

/// Exercises `UserDefaultsSyncCursorStore` against an isolated
/// `UserDefaults` suite (never the shared `.standard` domain, so runs never
/// leak state into each other or a real app installation), per
/// `documentation/sync-protocol.md` §Pull.
final class SyncCursorStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.rizeclone.desktop.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testCurrentCursorIsNilBeforeAnyIsSaved() {
        let store = UserDefaultsSyncCursorStore(defaults: defaults)

        XCTAssertNil(store.currentCursor())
    }

    func testSaveThenReadCursorRoundTrips() throws {
        let store = UserDefaultsSyncCursorStore(defaults: defaults)

        try store.save("cursor-1")

        XCTAssertEqual(store.currentCursor(), "cursor-1")
    }

    func testSavingANewCursorOverwritesThePrevious() throws {
        let store = UserDefaultsSyncCursorStore(defaults: defaults)
        try store.save("cursor-1")

        try store.save("cursor-2")

        XCTAssertEqual(store.currentCursor(), "cursor-2")
    }
}
