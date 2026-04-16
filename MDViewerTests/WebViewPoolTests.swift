import XCTest
@testable import MDViewer

final class WebViewPoolTests: XCTestCase {

    func testDequeueReturnsViewWhenPoolHasCapacity() {
        let pool = WebViewPool(capacity: 1)
        let view = pool.dequeue()
        XCTAssertNotNil(view, "Pool with capacity 1 should return a view on first dequeue")
    }

    func testDequeueReturnsNilWhenPoolExhausted() {
        let pool = WebViewPool(capacity: 1)
        _ = pool.dequeue()
        let second = pool.dequeue()
        XCTAssertNil(second, "Pool should return nil when exhausted (before async replenish)")
    }

    func testDequeueReturnsDifferentInstances() {
        let pool = WebViewPool(capacity: 2)
        let first = pool.dequeue()
        let second = pool.dequeue()
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertFalse(first === second, "Each dequeue should return a distinct WebContentView instance")
    }

    func testPoolReplenishesAfterDequeue() {
        let pool = WebViewPool(capacity: 1)
        _ = pool.dequeue() // Triggers async replenish

        let expectation = expectation(description: "Pool replenishes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let view = pool.dequeue()
            XCTAssertNotNil(view, "Pool should have replenished after async dispatch")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)
    }

    func testDiscardTriggersReplenishment() {
        let pool = WebViewPool(capacity: 1)
        let view = pool.dequeue()!

        // Discard the dequeued view (simulating crash)
        pool.discard(view)

        let expectation = expectation(description: "Pool replenishes after discard")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let replacement = pool.dequeue()
            XCTAssertNotNil(replacement, "Pool should replenish after discard")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)
    }
}
