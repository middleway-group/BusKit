import XCTest
@testable import BusKit

final class MessageSearchTests: XCTestCase {
    private func msg(_ id: String, subject: String, seq: Int64 = 0) -> MessageItem {
        MessageItem(messageId: id, body: "", contentType: "", enqueuedTime: Date(), properties: [:],
                    sequenceNumber: seq, deliveryCount: 0, expiresAt: Date(), subject: subject,
                    correlationId: "", replyTo: "", toAddress: "", sessionId: "", partitionKey: "")
    }

    private var sample: [MessageItem] {
        [msg("ABC-100", subject: "Order Created", seq: 1),
         msg("xyz-200", subject: "invoice abc", seq: 2),
         msg("ABC-300", subject: "", seq: 3)]
    }

    func testEmptyQueryReturnsAll() {
        XCTAssertEqual(filter(messages: sample, query: "", scope: .all).count, 3)
        XCTAssertEqual(filter(messages: sample, query: "   ", scope: .subject).count, 3)
    }

    func testMessageIDScope() {
        let r = filter(messages: sample, query: "abc", scope: .messageID)
        XCTAssertEqual(r.map(\.sequenceNumber), [1, 3])
    }

    func testSubjectScope() {
        let r = filter(messages: sample, query: "abc", scope: .subject)
        XCTAssertEqual(r.map(\.sequenceNumber), [2])
    }

    func testAllScopeMatchesEitherField() {
        let r = filter(messages: sample, query: "abc", scope: .all)
        XCTAssertEqual(r.map(\.sequenceNumber), [1, 2, 3])
    }

    func testCaseInsensitiveContains() {
        XCTAssertEqual(filter(messages: sample, query: "ORDER cre", scope: .subject).count, 1)
        XCTAssertEqual(filter(messages: sample, query: "-200", scope: .messageID).count, 1)
    }

    func testNoMatches() {
        XCTAssertTrue(filter(messages: sample, query: "nothing", scope: .all).isEmpty)
    }
}
