import XeniaCore
import Foundation
import Observation

/// This device's settings, kept in the app's defaults like any Apple app's preferences.
@Observable
final class Preferences {
    @ObservationIgnored var onChange: (() -> Void)?
    /// A setting changed on this device (not one that came from iCloud): iCloud sync sends it up.
    @ObservationIgnored var onSave: ((String, Bool) -> Void)?
    @ObservationIgnored private var applyingRemote = false

    /// Every setting follows you across devices through iCloud.
    nonisolated static let syncedKeys = [
        "mentionsTimeSensitive", "showPreviews", "roomsNotifyForAll", "sounds", "sendReadReceipts",
        "showMembershipChanges", "unifiedList", "sendTypingNotifications", "colorCodePeople", "sectionedList",
        "linkPreviews", "linkPreviewsEncrypted", "syncDrafts",
    ]
    // Shared with the notification extension on iPhone, which reads previews, sounds and Time
    // Sensitive when it shows a pushed message.
    @ObservationIgnored private let defaults: UserDefaults

    /// Mentions break through Focus and stay on the Lock Screen for an hour.
    var mentionsTimeSensitive: Bool { didSet { save(mentionsTimeSensitive, "mentionsTimeSensitive") } }
    /// Notifications show who wrote and what; off, they just say "New Message".
    var showPreviews: Bool { didSet { save(showPreviews, "showPreviews") } }
    /// Groups notify for every message, or only when you're mentioned.
    var roomsNotifyForAll: Bool { didSet { save(roomsNotifyForAll, "roomsNotifyForAll") } }
    var sounds: Bool { didSet { save(sounds, "sounds") } }
    /// Others see when you've read their messages; off, receipts are private to your devices.
    var sendReadReceipts: Bool { didSet { save(sendReadReceipts, "sendReadReceipts") } }
    /// Conversations show people joining, leaving and changing their names.
    var showMembershipChanges: Bool { didSet { save(showMembershipChanges, "showMembershipChanges") } }
    /// Chats and rooms in one list, as Messages shows them; off, they're two lists.
    var unifiedList: Bool { didSet { save(unifiedList, "unifiedList") } }
    /// Show typing to others.
    var sendTypingNotifications: Bool { didSet { save(sendTypingNotifications, "sendTypingNotifications") } }
    /// With chats and rooms together, they're split under Chats and Rooms headings.
    var sectionedList: Bool { didSet { save(sectionedList, "sectionedList") } }
    /// Each person's name and initials wear their own color; off, they're gray, as in Messages.
    var colorCodePeople: Bool { didSet { save(colorCodePeople, "colorCodePeople") } }
    /// Links show a card with the page's title and image, read by your server.
    var linkPreviews: Bool { didSet { save(linkPreviews, "linkPreviews") } }
    /// In encrypted conversations too. Off by default: the server would learn which links were
    /// shared there.
    var linkPreviewsEncrypted: Bool { didSet { save(linkPreviewsEncrypted, "linkPreviewsEncrypted") } }
    /// Unsent drafts follow you to your other devices through iCloud, end-to-end encrypted.
    var syncDrafts: Bool { didSet { save(syncDrafts, "syncDrafts") } }

    /// Whether to ask the server for link cards in a conversation.
    func fetchesLinkPreviews(encrypted: Bool) -> Bool {
        linkPreviews && (!encrypted || linkPreviewsEncrypted)
    }

    /// `defaults` is the shared store in the app; `legacy` is where settings lived before it.
    /// Tests pass their own store and no legacy one.
    init(defaults: UserDefaults = AppGroup.defaults, legacy: UserDefaults? = .standard) {
        self.defaults = defaults
        let migrates = legacy != nil && legacy != defaults && defaults.object(forKey: "xenia.pref.migrated") == nil
        func read(_ key: String, _ fallback: Bool) -> Bool {
            let name = "xenia.pref.\(key)"
            // Settings from before the shared defaults existed carry over once.
            if migrates, defaults.object(forKey: name) == nil, let old = legacy?.object(forKey: name) as? Bool {
                defaults.set(old, forKey: name)
            }
            return defaults.object(forKey: name) as? Bool ?? fallback
        }
        mentionsTimeSensitive = read("mentionsTimeSensitive", true)
        showPreviews = read("showPreviews", true)
        roomsNotifyForAll = read("roomsNotifyForAll", true)
        sounds = read("sounds", true)
        sendReadReceipts = read("sendReadReceipts", true)
        sendTypingNotifications = read("sendTypingNotifications", true)
        showMembershipChanges = read("showMembershipChanges", true)
        unifiedList = read("unifiedList", false)
        colorCodePeople = read("colorCodePeople", false)
        sectionedList = read("sectionedList", false)
        linkPreviews = read("linkPreviews", true)
        linkPreviewsEncrypted = read("linkPreviewsEncrypted", false)
        syncDrafts = read("syncDrafts", true)
        if migrates { defaults.set(true, forKey: "xenia.pref.migrated") }
    }

    private func save(_ value: Bool, _ key: String) {
        defaults.set(value, forKey: "xenia.pref.\(key)")
        if !applyingRemote { onSave?(key, value) }
        onChange?()
    }

    /// A value from another device. Only a real change is applied, so nothing echoes back.
    func apply(remote value: Bool, forKey key: String) {
        guard self.value(forKey: key) != value else { return }
        applyingRemote = true
        defer { applyingRemote = false }
        switch key {
        case "mentionsTimeSensitive": mentionsTimeSensitive = value
        case "showPreviews": showPreviews = value
        case "roomsNotifyForAll": roomsNotifyForAll = value
        case "sounds": sounds = value
        case "sendReadReceipts": sendReadReceipts = value
        case "showMembershipChanges": showMembershipChanges = value
        case "unifiedList": unifiedList = value
        case "sendTypingNotifications": sendTypingNotifications = value
        case "colorCodePeople": colorCodePeople = value
        case "sectionedList": sectionedList = value
        case "linkPreviews": linkPreviews = value
        case "linkPreviewsEncrypted": linkPreviewsEncrypted = value
        case "syncDrafts": syncDrafts = value
        default: break
        }
    }

    func value(forKey key: String) -> Bool? {
        switch key {
        case "mentionsTimeSensitive": mentionsTimeSensitive
        case "showPreviews": showPreviews
        case "roomsNotifyForAll": roomsNotifyForAll
        case "sounds": sounds
        case "sendReadReceipts": sendReadReceipts
        case "showMembershipChanges": showMembershipChanges
        case "unifiedList": unifiedList
        case "sendTypingNotifications": sendTypingNotifications
        case "colorCodePeople": colorCodePeople
        case "sectionedList": sectionedList
        case "linkPreviews": linkPreviews
        case "linkPreviewsEncrypted": linkPreviewsEncrypted
        case "syncDrafts": syncDrafts
        default: nil
        }
    }

    /// How chats and rooms are listed, stored as the two settings above so older versions keep
    /// reading "together" correctly.
    var listLayout: ListLayout {
        get { unifiedList ? (sectionedList ? .sections : .together) : .separate }
        set {
            if newValue != .separate { sectionedList = newValue == .sections }
            unifiedList = newValue != .separate
        }
    }
}

enum ListLayout: Hashable, CaseIterable {
    /// Two lists: tabs on iPhone, Chats and Rooms in the Mac's sidebar.
    case separate
    /// One list, newest first, as Messages shows it.
    case together
    /// One list with Chats and Rooms headings, like Mail's mailboxes.
    case sections
}
