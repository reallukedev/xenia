import Foundation
import ImageIO
import XeniaCore
import Testing
@testable import Xenia

@Suite("Copy")
struct CopyTests {
    @Test("Media without a caption reads as its kind")
    func mediaPreviews() {
        #expect(Copy.preview(of: .image(caption: nil)) == "Photo")
        #expect(Copy.preview(of: .image(caption: "Sunset")) == "Sunset")
        #expect(Copy.preview(of: .file(name: "notes.pdf", caption: nil)) == "notes.pdf")
        #expect(Copy.preview(of: .emote(text: "waves"), sender: "Maya") == "Maya waves")
        #expect(Copy.preview(of: .gallery(count: 1)) == "1 Photo")
        #expect(Copy.preview(of: .gallery(count: 4)) == "4 Photos")
    }

    @Test("Notes about you say You")
    func notes() {
        #expect(Copy.note(.membership(name: "Maya", isYou: false, change: .joined)) == "Maya joined")
        #expect(Copy.note(.membership(name: "Luke", isYou: true, change: .left)) == "You left")
        #expect(Copy.note(.renamed(oldName: "Sam", newName: "Samuel")) == "Sam is now Samuel")
    }

    @Test("Errors become sentences")
    func errors() {
        #expect(Copy.error(XeniaError.InvalidCredentials) == "The username or password is incorrect. Check them and try again.")
        // What the core logs for itself never reaches people.
        #expect(Copy.error(XeniaError.Generic(message: "sqlite: disk I/O error")) == "Something went wrong. Try again in a moment.")
        #expect(Copy.error(XeniaError.Forbidden(message: "M_FORBIDDEN")).contains("M_FORBIDDEN") == false)
        #expect(Copy.error(CancellationError()) == "Something went wrong. Try again in a moment.")
    }
}

@Suite("Settings copy")
struct SettingsCopyTests {
    @Test("The hero reports the connection before the backup")
    func heroOrder() {
        #expect(SettingsCopy.hero(connection: .offline, backup: .off).tone == .warning)
        #expect(SettingsCopy.hero(connection: .offline, backup: .off).text.hasPrefix("Offline"))
        #expect(SettingsCopy.hero(connection: .connected, backup: .off).text == "Chat backup is off")
        #expect(SettingsCopy.hero(connection: .connected, backup: .on).tone == .secondary)
    }

    @Test("Every backup state has a row value")
    func backupValues() {
        #expect(SettingsCopy.backupValue(.needsKey) == "Needs Key")
        #expect(SettingsCopy.backupValue(nil) == "Checking…")
    }

    @Test("An unverified device is asked for before backup, but only when a backup exists to read")
    func heroAsksToVerify() {
        let needsVerifying = SettingsCopy.hero(connection: .connected, backup: .on, deviceVerified: false)
        #expect(needsVerifying.tone == .warning)
        #expect(needsVerifying.text.contains("Verify this"))
        // With backup off there's nothing older to unlock: the backup is what needs you.
        #expect(SettingsCopy.hero(connection: .connected, backup: .off, deviceVerified: false).text == "Chat backup is off")
        // Offline outranks everything.
        #expect(SettingsCopy.hero(connection: .offline, backup: .on, deviceVerified: false).text.hasPrefix("Offline"))
    }

    @Test("Privacy reports each choice, and blocked people only when there are some")
    func privacyHero() {
        #expect(SettingsCopy.privacyHero(receipts: true, typing: false, blocked: 0) == "Read receipts on · typing hidden")
        #expect(SettingsCopy.privacyHero(receipts: false, typing: true, blocked: 2) == "Read receipts off · typing shared · 2 people blocked")
        #expect(SettingsCopy.privacyHero(receipts: true, typing: true, blocked: 1).hasSuffix("1 person blocked"))
    }

    @Test("Notifications say what reaches you, and warn when they're off")
    func notificationsHero() {
        #expect(SettingsCopy.notificationsHero(.denied, roomsNotifyForAll: true).tone == .warning)
        #expect(SettingsCopy.notificationsHero(.allowed, roomsNotifyForAll: false).text == "On · Chats and mentions")
        #expect(SettingsCopy.notificationsValue(.allowed, roomsNotifyForAll: false) == "Mentions")
        #expect(SettingsCopy.notificationsValue(.notAsked, roomsNotifyForAll: true) == "Not Asked")
    }

    @Test("Storage reads as bytes, and None when empty")
    func storage() {
        #expect(SettingsCopy.bytes(0) == "None")
        #expect(SettingsCopy.bytes(1_500_000).contains("MB"))
        #expect(SettingsCopy.blockedValue(nil) == nil)
        #expect(SettingsCopy.blockedValue(0) == "None")
    }
}

@Suite("Devices and verification")
struct DevicesCopyTests {
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 15))!

    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    @Test("A device's symbol comes from the name it gave itself", arguments: [
        ("Xenia on iPhone", "iphone"),
        ("Element on iPad", "ipad"),
        ("Xenia on Mac", "laptopcomputer"),
        ("app.element.io: Firefox on Windows", "globe"),
        ("Element Desktop: Linux", "desktopcomputer"),
        ("Pixel Android", "smartphone"),
        ("Seed script", "questionmark.app.dashed"),
    ])
    func symbols(name: String, symbol: String) {
        #expect(SettingsCopy.deviceSymbol(name: name) == symbol)
    }

    @Test("An unnamed device falls back to its ID")
    func unnamed() {
        let session = Session(deviceId: "ABCDEF", name: nil, lastSeenMs: nil, lastSeenIp: nil, isCurrent: false, isVerified: false)
        #expect(SettingsCopy.deviceName(session) == "ABCDEF")
        #expect(SettingsCopy.deviceSymbol(name: nil) == "questionmark.app.dashed")
    }

    @Test("Activity reads as now, today, yesterday, then a date")
    func lastActive() throws {
        #expect(SettingsCopy.lastActive(nil, now: now) == nil)
        #expect(SettingsCopy.lastActive(ms(now.addingTimeInterval(-60)), now: now) == "Active now")
        let earlier = try #require(SettingsCopy.lastActive(ms(now.addingTimeInterval(-3 * 3600)), now: now))
        #expect(earlier.hasPrefix("Today at"))
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: now))
        #expect(SettingsCopy.lastActive(ms(yesterday), now: now) == "Yesterday")
        let lastYear = try #require(Calendar.current.date(from: DateComponents(year: 2025, month: 3, day: 2)))
        let old = try #require(SettingsCopy.lastActive(ms(lastYear), now: now))
        #expect(old.contains("2025"))
    }

    @Test("The devices page asks to verify first, and counts the others once verified")
    func devicesHero() {
        #expect(SettingsCopy.devicesHero(thisVerified: false, others: 3).tone == .warning)
        #expect(SettingsCopy.devicesHero(thisVerified: true, others: 0).text == "This iPhone is verified." || SettingsCopy.devicesHero(thisVerified: true, others: 0).text == "This Mac is verified.")
        #expect(SettingsCopy.devicesHero(thisVerified: true, others: 2).text.hasSuffix("2 other devices signed in"))
        #expect(SettingsCopy.devicesHero(thisVerified: nil, others: 0).text == "Checking your devices…")
    }

    @Test("Waiting names who to open, by target")
    func waiting() {
        let mac = SettingsCopy.verification(.requested, target: .device("Xenia on Mac"), isIncoming: false)
        #expect(mac.title == "Waiting for Xenia on Mac")
        let person = SettingsCopy.verification(.requested, target: .person("Maya"), isIncoming: false)
        #expect(person.title == "Waiting for Maya")
        let any = SettingsCopy.verification(nil, target: .anyDevice, isIncoming: false)
        #expect(any.title.hasPrefix("Verify This"))
    }

    @Test("A request from a person reads differently from one of my devices")
    func incoming() {
        #expect(SettingsCopy.verification(.incoming, target: .person("Maya"), isIncoming: true).title == "Maya Wants to Verify")
        #expect(SettingsCopy.verification(.incoming, target: .device("Xenia on iPhone"), isIncoming: true).title == "Verify Xenia on iPhone?")
        #expect(SettingsCopy.verification(.done, target: .person("Maya"), isIncoming: false).title == "Maya Is Verified")
    }

}

@Suite("Profile photo")
struct ProfilePhotoTests {
    @Test("Profile photos are cropped square and scaled down")
    func profilePhoto() async throws {
        let image = try #require(Self.jpeg(width: 1200, height: 800))
        let data = try #require(await ProfilePhoto.squareJPEG(from: image))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let out = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(out.width == 512)
        #expect(out.height == 512)
        #expect(await ProfilePhoto.squareJPEG(from: Data("not an image".utf8)) == nil)
    }

    private static func jpeg(width: Int, height: Int) -> Data? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

@Suite("Time format")
struct TimeFormatTests {
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 15))!

    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    private func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: now)!
    }

    @Test("Lists say Yesterday, then the weekday for a week, then the date")
    func list() {
        #expect(TimeFormat.list(ms(daysAgo(1)), now: now) == "Yesterday")
        // Thursday, September 24, 2026.
        #expect(TimeFormat.list(ms(daysAgo(3)), now: now) == "Monday")
        // A numeric date, in whatever order this Mac writes them.
        let older = TimeFormat.list(ms(daysAgo(10)), now: now)
        #expect(older.contains("14") && older.contains("9") && older.allSatisfy { !$0.isLetter })
        #expect(TimeFormat.list(0, now: now).isEmpty)
    }

    @Test("Just after midnight, last night's message is Yesterday, not a time")
    func acrossMidnight() {
        let earlyMorning = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 0, minute: 5))!
        let lateLastNight = earlyMorning.addingTimeInterval(-10 * 60)
        #expect(TimeFormat.list(ms(lateLastNight), now: earlyMorning) == "Yesterday")
        #expect(TimeFormat.relative(ms(lateLastNight), now: earlyMorning) == "10m")
    }

    @Test("Headers say Today with the time, and give older days in full")
    func header() {
        let earlier = Calendar.current.date(byAdding: .hour, value: -2, to: now)!
        #expect(TimeFormat.header(ms(earlier), now: now).day == "Today")
        let lastYear = Calendar.current.date(from: DateComponents(year: 2025, month: 3, day: 2, hour: 9, minute: 41))!
        let header = TimeFormat.header(ms(lastYear), now: now)
        #expect(header.day.contains("2025"))
        #expect(header.time.hasPrefix("at "))
    }

    @Test("Relative times are compact, and turn into the list's words after a day")
    func relative() {
        #expect(TimeFormat.relative(ms(now), now: now) == "Now")
        #expect(TimeFormat.relative(ms(now.addingTimeInterval(-5 * 60)), now: now) == "5m")
        #expect(TimeFormat.relative(ms(now.addingTimeInterval(-3 * 3600)), now: now) == "3h")
        #expect(TimeFormat.relative(ms(daysAgo(1)), now: now) == "Yesterday")
    }
}

@Suite("Sign in")
struct SignInTests {
    @Test("A full address fills in the server")
    @MainActor
    func fullAddress() {
        let form = SignInModel(server: "matrix.org")
        form.username = "@maya:example.org"
        #expect(form.server == "example.org")
        #expect(SignInModel.localpart(of: "@maya:example.org") == "maya")
    }

    @Test("A bare name keeps the server")
    @MainActor
    func bareName() {
        let form = SignInModel(server: "matrix.org")
        form.username = "maya"
        #expect(form.server == "matrix.org")
    }

    @Test("Only the name part signs in", arguments: [
        ("maya", "maya"),
        (" @maya:example.org ", "maya"),
        ("@maya", "maya"),
        ("maya:example.org", "maya"),
        ("@", ""),
    ])
    func localpart(input: String, expected: String) {
        #expect(SignInModel.localpart(of: input) == expected)
    }

    @Test("The server reads as its address, without the scheme or a trailing slash")
    @MainActor
    func serverDisplay() {
        #expect(SignInModel(server: "https://matrix.example.org/").serverDisplay == "matrix.example.org")
        #expect(SignInModel(server: " http://localhost:8008 ").serverDisplay == "localhost:8008")
    }

    @Test("Changing the details takes the last error away")
    @MainActor
    func errorClears() {
        let form = SignInModel(server: "matrix.org")
        form.password = "wrong"
        form.error = "The username or password is incorrect. Check them and try again."
        form.password = "right"
        #expect(form.error == nil)
        form.error = "Again"
        form.username = "maya"
        #expect(form.error == nil)
    }

    @Test("Signing in needs a name, a password and a server")
    @MainActor
    func canSubmit() {
        let form = SignInModel(server: "matrix.org")
        form.username = "@"
        form.password = "secret"
        #expect(!form.canSubmit)
        form.username = "maya"
        #expect(form.canSubmit)
        form.server = "  "
        #expect(!form.canSubmit)
    }
}
