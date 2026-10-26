import SwiftUI

// MARK: - Icon tile

/// The filled, rounded well Settings puts before a row. Scales with Dynamic Type.
struct SettingsIconTile: View {
    var systemImage: String
    var color: Color = .accentColor
    /// Side at the default text size: 28 in rows, 64 (iPhone) or 40 (Mac) in a hero.
    var baseSide: CGFloat = 28

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    private var side: CGFloat { baseSide * scale }

    var body: some View {
        // Fitted to a box rather than sized by font, so wide symbols (two bubbles, a laptop
        // and phone) sit inside the tile with the same margin as square ones.
        Image(systemName: systemImage)
            .resizable()
            .fontWeight(.medium)
            .scaledToFit()
            .frame(width: side * 0.6, height: side * 0.56)
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(color.gradient, in: .rect(cornerRadius: side * 0.26, style: .continuous))
            .contentTransition(.symbolEffect(.replace))
            // The row's words carry the meaning; the tile is decoration.
            .accessibilityHidden(true)
    }
}

// MARK: - Legible colored text

/// A tint made readable as text: 4.5:1, or 7:1 with Increase Contrast. System orange and green
/// fail as text on a grouped background without this.
struct LegibleInk: ShapeStyle {
    var tint: Color

    func resolve(in environment: EnvironmentValues) -> Color {
        let isDark = environment.colorScheme == .dark
        let target: Float = environment.colorSchemeContrast == .increased ? 7 : 4.5
        // The hardest common background: grouped gray in light, the cell in dark.
        let surface = isDark
            ? Color.Resolved(red: 0.110, green: 0.110, blue: 0.118)
            : Color.Resolved(red: 0.949, green: 0.949, blue: 0.969)
        let destination = isDark
            ? Color.Resolved(red: 1, green: 1, blue: 1)
            : Color.Resolved(red: 0, green: 0, blue: 0)
        var candidate = tint.resolve(in: environment)
        let start = candidate
        var amount: Float = 0
        while candidate.contrast(against: surface) < target && amount < 1 {
            amount = min(1, amount + 0.03)
            candidate = start.mixed(with: destination, by: amount)
        }
        return Color(candidate)
    }
}

extension ShapeStyle where Self == LegibleInk {
    static func ink(_ tint: Color) -> LegibleInk { LegibleInk(tint: tint) }
}

nonisolated extension Color.Resolved {
    func mixed(with other: Color.Resolved, by amount: Float) -> Color.Resolved {
        Color.Resolved(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount,
            opacity: opacity
        )
    }

    var relativeLuminance: Float {
        0.2126 * linearRed + 0.7152 * linearGreen + 0.0722 * linearBlue
    }

    func contrast(against other: Color.Resolved) -> Float {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

extension SettingsCopy.Tone {
    /// The status line in its tone: grey when fine, orange ink when it needs you.
    func apply(to text: Text) -> Text {
        switch self {
        case .secondary: text.foregroundStyle(.secondary)
        case .warning: text.foregroundStyle(.ink(.orange))
        case .good: text.foregroundStyle(.ink(.green))
        }
    }
}

// MARK: - Hero

/// The top of a settings page: its tile, its name, and one line on how it stands. iPhone centers
/// it, as Settings opens a feature; the Mac sets it in a row with room for one control, as System
/// Settings' panes do.
struct SettingsHero<Icon: View, Accessory: View>: View {
    var title: Text
    var subtitle: Text
    var icon: Icon
    var accessory: Accessory

    static var tileSide: CGFloat {
        #if os(macOS)
        40
        #else
        64
        #endif
    }

    init(
        _ title: Text,
        subtitle: Text,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon()
        self.accessory = accessory()
    }

    var body: some View {
        Section {
            #if os(macOS)
            HStack(spacing: Theme.Spacing.m) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    title
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    subtitle
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: Theme.Spacing.s)
                accessory
            }
            .padding(.vertical, Theme.Spacing.xxs)
            #else
            VStack(spacing: Theme.Spacing.m) {
                icon
                VStack(spacing: Theme.Spacing.xs) {
                    title
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    subtitle
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                }
                accessory
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, Theme.Spacing.xs)
            .listRowBackground(Color.clear)
            #endif
        }
    }
}

extension SettingsHero where Icon == SettingsIconTile {
    init(
        _ title: Text,
        subtitle: Text,
        systemImage: String,
        tint: Color,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.init(title, subtitle: subtitle) {
            SettingsIconTile(systemImage: systemImage, color: tint, baseSide: Self.tileSide)
        } accessory: {
            accessory()
        }
    }
}

extension SettingsHero where Icon == SettingsIconTile, Accessory == EmptyView {
    init(_ title: Text, subtitle: Text, systemImage: String, tint: Color) {
        self.init(title, subtitle: subtitle, systemImage: systemImage, tint: tint) { EmptyView() }
    }
}

// MARK: - Rows

/// A row that leads to a page: a tile, a name, and where it stands at the trailing edge.
struct SettingsRowLabel: View {
    var title: LocalizedStringKey
    var systemImage: String
    var tint: Color
    var value: String?
    var valueTone: SettingsCopy.Tone = .secondary

    var body: some View {
        LabeledContent {
            if let value {
                valueTone == .warning ? Text(value).foregroundStyle(.ink(.orange)) : Text(value)
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                SettingsIconTile(systemImage: systemImage, color: tint)
            }
        }
    }
}

/// A name with a line under it, an optional tile before and a control after, all centered on the
/// middle of the text block. `Toggle` and `LabeledContent` hang a two-line label from its first
/// line, which leaves the control riding high.
struct SettingsDetailRow<Trailing: View>: View {
    var title: Text
    var detail: Text
    var systemImage: String?
    var tint: Color = .accentColor
    var trailing: Trailing

    init(
        title: Text,
        detail: Text,
        systemImage: String? = nil,
        tint: Color = .accentColor,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            if let systemImage {
                SettingsIconTile(systemImage: systemImage, color: tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                title
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Separators start under the text, as they do after a Label's icon.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            trailing
        }
        .padding(.vertical, 2)
    }
}

extension SettingsDetailRow where Trailing == EmptyView {
    init(title: Text, detail: Text, systemImage: String? = nil, tint: Color = .accentColor) {
        self.init(title: title, detail: detail, systemImage: systemImage, tint: tint) { EmptyView() }
    }
}

/// One switch in a section of its own, with a line on what the current choice does: under the
/// name on the Mac, with the switch centered beside both; in the footer on iPhone.
struct SettingsToggleSection: View {
    var title: LocalizedStringKey
    var detail: String
    @Binding var isOn: Bool
    var header: LocalizedStringKey?

    var body: some View {
        Section {
            #if os(macOS)
            SettingsDetailRow(title: Text(title), detail: Text(detail)) {
                Toggle(title, isOn: $isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            #else
            Toggle(title, isOn: $isOn)
            #endif
        } header: {
            if let header { Text(header) }
        } footer: {
            #if os(iOS)
            Text(detail)
            #endif
        }
    }
}

/// A button's title that turns into a small spinner while its work runs, without the row moving.
struct WorkingLabel: View {
    let title: LocalizedStringKey
    let working: Bool

    var body: some View {
        HStack {
            Text(title)
            if working {
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
    }
}

// MARK: - Page and pane

#if os(iOS)
extension View {
    /// A page that opens on a `SettingsHero`: the bar takes the title only once the hero has
    /// scrolled away, so the name is never on screen twice.
    func settingsPage(_ title: LocalizedStringKey) -> some View {
        modifier(SettingsPageTitle(title: title))
    }
}

private struct SettingsPageTitle: ViewModifier {
    var title: LocalizedStringKey
    @State private var isHeroHidden = false

    func body(content: Content) -> some View {
        content
            .navigationTitle(isHeroHidden ? title : "")
            .navigationBarTitleDisplayMode(.inline)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Roughly the hero's height at the default text size.
                geometry.contentOffset.y + geometry.contentInsets.top > 150
            } action: { _, hidden in
                isHeroHidden = hidden
            }
    }
}
#endif

#if os(macOS)
extension View {
    /// A grouped form at the Settings window's width, as tall as its content up to what fits on
    /// screen, and scrolling past that.
    func settingsPane() -> some View {
        SettingsPaneLayout { self.formStyle(.grouped) }
    }
}

/// The height comes from the form's ideal size, never from anything measured and stored, so
/// AppKit has nothing to loop on.
struct SettingsPaneLayout: Layout {
    static let width: CGFloat = 540

    private var tallest: CGFloat {
        max(420, (NSScreen.main?.visibleFrame.height ?? 900) - 160)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let form = subviews.first else { return .zero }
        let natural = form.sizeThatFits(ProposedViewSize(width: Self.width, height: nil)).height
        return CGSize(width: Self.width, height: min(natural, tallest))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
#endif

extension View {
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
