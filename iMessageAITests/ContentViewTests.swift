import XCTest
@testable import iMessageAI

final class ReadRepliesFileTests: XCTestCase {

    private func writeTempJSON(_ dict: [String: Any]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(UUID().uuidString + ".json")
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFullValidPayload() throws {
        let url = try writeTempJSON([
            "Happy": "Hey!",
            "Sad": "Meh",
            "Reply": "",
            "sender": "+15551234567",
            "message": "Hi there",
            "time": "1.23",
        ])
        let parsed = ContentView.readRepliesFile(at: url)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.sender, "+15551234567")
        XCTAssertEqual(parsed?.message, "Hi there")
        XCTAssertEqual(parsed?.replyValue, "")
        XCTAssertEqual(parsed?.timeValue, "1.23")
        XCTAssertEqual(parsed?.repliesDict, ["Happy": "Hey!", "Sad": "Meh"])
    }

    func testReplyKeySelected() throws {
        let url = try writeTempJSON([
            "Happy": "Hey!",
            "Reply": "Happy",
            "sender": "+1555",
            "message": "Hello",
            "time": "0.50",
        ])
        let parsed = ContentView.readRepliesFile(at: url)
        XCTAssertEqual(parsed?.replyValue, "Happy")
    }

    func testRefreshState() throws {
        let url = try writeTempJSON([
            "Reply": "Refresh",
            "sender": "+1555",
            "message": "Hello",
            "time": "0.50",
        ])
        let parsed = ContentView.readRepliesFile(at: url)
        XCTAssertEqual(parsed?.replyValue, "Refresh")
        XCTAssertTrue(parsed?.repliesDict.isEmpty ?? false)
    }

    func testIgnoreState() throws {
        let url = try writeTempJSON([
            "Reply": "Ignore",
            "sender": "+1555",
            "message": "Hello",
            "time": "0.50",
        ])
        let parsed = ContentView.readRepliesFile(at: url)
        XCTAssertEqual(parsed?.replyValue, "Ignore")
    }

    func testTimeAsNumber() throws {
        let url = try writeTempJSON([
            "Reply": "",
            "sender": "",
            "message": "",
            "time": 2.5,
        ])
        let parsed = ContentView.readRepliesFile(at: url)
        XCTAssertEqual(parsed?.timeValue, "2.5")
    }

    func testTimeAsInt() throws {
        let url = try writeTempJSON([
            "Reply": "",
            "sender": "",
            "message": "",
            "time": 3,
        ])
        let parsed = ContentView.readRepliesFile(at: url)
        XCTAssertFalse(parsed?.timeValue.isEmpty ?? true)
    }

    func testMissingSenderAndMessage() throws {
        let url = try writeTempJSON([
            "Happy": "Hey!",
            "Reply": "",
        ])
        let parsed = ContentView.readRepliesFile(at: url)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.sender, "")
        XCTAssertEqual(parsed?.message, "")
        XCTAssertEqual(parsed?.repliesDict, ["Happy": "Hey!"])
    }

    func testNestedRepliesDict() throws {
        let url = try writeTempJSON([
            "Reply": "",
            "sender": "",
            "message": "",
            "time": "",
            "replies": ["Happy": "Hey!", "Sad": "Meh"],
        ])
        let parsed = ContentView.readRepliesFile(at: url)
        XCTAssertEqual(parsed?.repliesDict["Happy"], "Hey!")
        XCTAssertEqual(parsed?.repliesDict["Sad"], "Meh")
    }

    func testTopLevelOverridesNested() throws {
        let url = try writeTempJSON([
            "Happy": "Top-level",
            "Reply": "",
            "sender": "",
            "message": "",
            "time": "",
            "replies": ["Happy": "Nested"],
        ])
        let parsed = ContentView.readRepliesFile(at: url)
        XCTAssertEqual(parsed?.repliesDict["Happy"], "Top-level")
    }

    func testNonexistentFile() {
        let url = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).json")
        XCTAssertNil(ContentView.readRepliesFile(at: url))
    }

    func testLowercaseReplyFallback() throws {
        let url = try writeTempJSON([
            "reply": "fallback_value",
            "sender": "",
            "message": "",
            "time": "",
        ])
        let parsed = ContentView.readRepliesFile(at: url)
        XCTAssertEqual(parsed?.replyValue, "fallback_value")
    }

    func testEmptyJSON() throws {
        let url = try writeTempJSON([:])
        let parsed = ContentView.readRepliesFile(at: url)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.sender, "")
        XCTAssertEqual(parsed?.message, "")
        XCTAssertEqual(parsed?.replyValue, "")
        XCTAssertTrue(parsed?.repliesDict.isEmpty ?? false)
    }
}
