import XeniaCore
import SwiftUI

/// From, Mentions, Type and Date for one conversation's search, as capsules under the field
/// (Photos' and Mail's filters). A chosen filter fills with the accent and names its choice.
struct SearchFilterBar: View {
    @Binding var refinements: SearchRefinements
    let members: [Member]
    /// A one-to-one chat: every message is to you, so Mentions has nothing to narrow.
    let isDirect: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            fromMenu
            if !isDirect {
                FilterChip(title: String(localized: "Mentions"), systemImage: "at", isOn: refinements.mentionsMe) {
                    refinements.mentionsMe.toggle()
                }
            }
            typeMenu
            dateMenu
            if !refinements.isEmpty {
                Button("Clear Filters", systemImage: "xmark.circle.fill") {
                    refinements = SearchRefinements()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear Filters")
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .animation(Theme.Motion.flip, value: refinements.isEmpty)
        .sensoryFeedback(.selection, trigger: refinements)
    }

    private var people: [Member] {
        members.filter { !$0.isInvited }.sorted { a, b in
            // You first, then by name.
            if a.isYou != b.isYou { return a.isYou }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private var fromMenu: some View {
        Menu {
            Picker("From", selection: $refinements.sender) {
                Text("Anyone").tag(Member?.none)
                Divider()
                ForEach(people, id: \.userId) { member in
                    Text(member.isYou ? String(localized: "You") : member.name).tag(Optional(member))
                }
            }
            .pickerStyle(.inline)
        } label: {
            FilterChipLabel(
                title: refinements.sender.map { $0.isYou ? String(localized: "From You") : String(localized: "From \($0.name)") }
                    ?? String(localized: "From"),
                systemImage: "person",
                isOn: refinements.sender != nil,
                showsChevron: true
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(people.isEmpty)
    }

    private var typeMenu: some View {
        Menu {
            ForEach(MessageKind.all, id: \.self) { kind in
                Toggle(isOn: Binding(
                    get: { refinements.kinds.contains(kind) },
                    set: { on in
                        if on { refinements.kinds.insert(kind) } else { refinements.kinds.remove(kind) }
                    }
                )) {
                    Label(kind.title, systemImage: kind.systemImage)
                }
            }
        } label: {
            FilterChipLabel(title: typeTitle, systemImage: "square.grid.2x2", isOn: !refinements.kinds.isEmpty, showsChevron: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var typeTitle: String {
        let chosen = refinements.kinds.sorted { $0.order < $1.order }
        switch chosen.count {
        case 0: return String(localized: "Type")
        case 1: return chosen[0].title
        default: return chosen.map(\.title).formatted(.list(type: .or))
        }
    }

    private var dateMenu: some View {
        Menu {
            Picker("Date", selection: $refinements.date) {
                ForEach(SearchDate.presets, id: \.self) { date in
                    Text(date.title).tag(date)
                }
                if case .range = refinements.date {
                    Divider()
                    Text(refinements.date.title).tag(refinements.date)
                }
            }
            .pickerStyle(.inline)
        } label: {
            FilterChipLabel(
                title: refinements.date == .anyTime ? String(localized: "Date") : refinements.date.title,
                systemImage: "calendar",
                isOn: refinements.date != .anyTime,
                showsChevron: true
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// A filter that's on or off.
private struct FilterChip: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FilterChipLabel(title: title, systemImage: systemImage, isOn: isOn, showsChevron: false)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct FilterChipLabel: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(title)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
        }
        .font(Self.font)
        .padding(.horizontal, Self.horizontalPadding)
        .frame(height: Self.height)
        .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: .capsule)
        .contentShape(.capsule)
        .animation(Theme.Motion.flip, value: isOn)
    }

    #if os(macOS)
    private static let font = Font.callout
    private static let height: CGFloat = 24
    private static let horizontalPadding: CGFloat = 8
    #else
    private static let font = Font.subheadline
    private static let height: CGFloat = 32
    private static let horizontalPadding: CGFloat = 12
    #endif
}

extension MessageKind {
    var title: String {
        switch self {
        case .photo: String(localized: "Photos")
        case .video: String(localized: "Videos")
        case .file: String(localized: "Files")
        case .link: String(localized: "Links")
        case .audio: String(localized: "Audio")
        case .poll: String(localized: "Polls")
        }
    }

    var systemImage: String {
        switch self {
        case .photo: "photo"
        case .video: "video"
        case .file: "doc"
        case .link: "link"
        case .audio: "waveform"
        case .poll: "chart.bar.xaxis"
        }
    }
}

extension SearchDate {
    var title: String {
        switch self {
        case .anyTime: return String(localized: "Any Time")
        case .today: return String(localized: "Today")
        case .pastWeek: return String(localized: "Past Week")
        case .pastMonth: return String(localized: "Past Month")
        case .pastYear: return String(localized: "Past Year")
        case .range(let after, let before):
            let style = Date.FormatStyle(date: .abbreviated, time: .omitted)
            // `before` is the day after the last one searched.
            let last = before.flatMap { Calendar.current.date(byAdding: .day, value: -1, to: $0) }
            switch (after, last) {
            case let (after?, last?) where Calendar.current.isDate(after, inSameDayAs: last):
                return after.formatted(style)
            case let (after?, last?) where after < last:
                return (after..<last).formatted(.interval.day().month(.abbreviated).year())
            case let (after?, _?):
                return String(localized: "Since \(after.formatted(style))")
            case let (after?, nil):
                return String(localized: "Since \(after.formatted(style))")
            case let (nil, last?):
                return String(localized: "Until \(last.formatted(style))")
            case (nil, nil):
                return String(localized: "Any Time")
            }
        }
    }
}
