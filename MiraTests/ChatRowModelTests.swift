import XCTest
@testable import Mira

final class ChatRowModelTests: XCTestCase {
    private func message(_ role: MessageRole, at date: Date, text: String = "Hello") -> ChatMessage {
        var message = ChatMessage(role: role, text: text)
        message.createdAt = date
        return message
    }

    func testConsecutiveMessagesShareGroupAndOnlyLastHasTail() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = ChatRowModel.build([
            message(.user, at: date), message(.user, at: date.addingTimeInterval(20))
        ], running: false)
        XCTAssertEqual(rows.map(\.startsGroup), [true, false])
        XCTAssertEqual(rows.map(\.tail), [false, true])
        XCTAssertNil(rows[0].status)
        XCTAssertEqual(rows[1].status, "已送达")
    }

    func testSpeakerChangeStartsNewGroup() {
        let date = Date()
        let rows = ChatRowModel.build([
            message(.user, at: date), message(.assistant, at: date.addingTimeInterval(1))
        ], running: false)
        XCTAssertTrue(rows[1].startsGroup)
        XCTAssertTrue(rows[0].tail)
        XCTAssertEqual(rows[0].status, "已读")
    }

    func testTwoMinuteGapStartsNewGroup() {
        let date = Date()
        let rows = ChatRowModel.build([
            message(.assistant, at: date), message(.assistant, at: date.addingTimeInterval(120))
        ], running: false)
        XCTAssertTrue(rows[0].tail)
        XCTAssertTrue(rows[1].startsGroup)
    }

    func testMidnightAlwaysShowsDateEvenWithinFifteenMinutes() throws {
        let day = Calendar.current.startOfDay(for: Date())
        let rows = ChatRowModel.build([
            message(.user, at: day.addingTimeInterval(-30)),
            message(.assistant, at: day.addingTimeInterval(30))
        ], running: false)
        XCTAssertTrue(rows[1].showTimestamp)
    }

    func testTextlessToolResultsAreHiddenButAttachmentsRemain() {
        let date = Date()
        var attachment = message(.tool, at: date)
        attachment.attachments = [Attachment(kind: .file, fileName: "note.txt",
                                             mimeType: "text/plain", storedName: "note.txt")]
        let rows = ChatRowModel.build([message(.tool, at: date), attachment], running: false)
        XCTAssertEqual(rows.map(\.id), [attachment.id])
    }

    func testEmptyStreamingAssistantRemainsVisible() {
        var streaming = message(.assistant, at: Date(), text: "")
        streaming.isStreaming = true
        XCTAssertEqual(ChatRowModel.build([streaming], running: true).count, 1)
        streaming.isStreaming = false
        XCTAssertTrue(ChatRowModel.build([streaming], running: false).isEmpty)
    }
}
