import Foundation
import XeniaCore
import Testing
import UserNotifications
@testable import Xenia

@Suite("Notifications")
struct NotificationTests {
    private static func message(direct: Bool = false, ping: Bool = false) -> IncomingMessage {
        IncomingMessage(
            roomId: "!book:localhost", roomName: direct ? "Maya Okafor" : "Book Club", isDirect: direct,
            senderName: direct ? nil : "Maya", body: .text(text: "Chapter 3 tonight?"), isPing: ping,
            timestampMs: 1_790_000_000_000, avatarUrl: nil, avatarSeed: "!book:localhost",
            senderId: "@maya:localhost", senderFullName: "Maya Okafor", senderAvatarUrl: "mxc://localhost/maya",
            picture: nil, eventId: "$event"
        )
    }

    @Test("A group message names the group, then who wrote")
    func group() {
        let content = NotificationContent.make(Self.message(), preferences: .init())
        #expect(content.title == "Book Club")
        #expect(content.subtitle == "Maya")
        #expect(content.body == "Chapter 3 tonight?")
        #expect(content.threadIdentifier == "!book:localhost")
        #expect(content.categoryIdentifier == NotificationContent.category)
    }

    @Test("A chat's title is the person, with no subtitle")
    func direct() {
        let content = NotificationContent.make(Self.message(direct: true), preferences: .init())
        #expect(content.title == "Maya Okafor")
        #expect(content.subtitle.isEmpty)
    }

    @Test("With previews off, nothing says who wrote or what")
    func privatePreviews() {
        let content = NotificationContent.make(Self.message(), preferences: .init(showPreviews: false))
        #expect(content.title == "Xenia")
        #expect(content.subtitle.isEmpty)
        #expect(content.body == "New Message")
        #expect(content.userInfo["senderID"] == nil)
        #expect(content.userInfo["senderName"] == nil)
        // Still enough to open the conversation and clear it once read.
        #expect(content.userInfo["roomID"] as? String == "!book:localhost")
        #expect(content.threadIdentifier == "!book:localhost")
    }

    @Test("Mentions are Time Sensitive only while that setting is on", arguments: [
        (true, true, UNNotificationInterruptionLevel.timeSensitive),
        (true, false, .active),
        (false, true, .active),
    ])
    func timeSensitive(ping: Bool, setting: Bool, level: UNNotificationInterruptionLevel) {
        let content = NotificationContent.make(Self.message(ping: ping), preferences: .init(mentionsTimeSensitive: setting))
        #expect(content.interruptionLevel == level)
    }

    @Test("Sounds follow the setting")
    func sounds() {
        #expect(NotificationContent.make(Self.message(), preferences: .init(sounds: true)).sound != nil)
        #expect(NotificationContent.make(Self.message(), preferences: .init(sounds: false)).sound == nil)
    }

    @Test("Attached pictures are recognized by their first bytes", arguments: [
        ([0xFF, 0xD8, 0xFF, 0xE0], "public.jpeg"),
        ([0x89, 0x50, 0x4E, 0x47], "public.png"),
        ([0x47, 0x49, 0x46, 0x38], "com.compuserve.gif"),
        (Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8), "org.webmproject.webp"),
        ([0, 0, 0, 0x18] + Array("ftypheic".utf8), "public.heic"),
    ] as [([UInt8], String)])
    func imageTypes(prefix: [UInt8], identifier: String) {
        let data = Data(prefix + [UInt8](repeating: 0, count: 16))
        #expect(NotificationExtras.imageType(data)?.identifier == identifier)
    }

    @Test("Anything else, or too little to tell, isn't attached")
    func unknownImageTypes() {
        #expect(NotificationExtras.imageType(Data("%PDF-1.7 not a picture".utf8)) == nil)
        #expect(NotificationExtras.imageType(Data([0xFF, 0xD8, 0xFF])) == nil)
    }
}
