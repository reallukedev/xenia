import XeniaCore
import SwiftUI

/// A person's or room's photo, or their initials when there's none.
///
/// People are round, as in Messages. Rooms are rounded squares, the way businesses and apps are
/// drawn, so a group reads differently from a person at a glance. People's initials are on
/// Messages' gray unless Settings color-codes people; rooms always wear their own color.
struct AvatarView: View {
    let name: String
    /// Picks the color: a user or room ID.
    let seed: String
    /// An `mxc://` URL.
    let url: String?
    let size: CGFloat
    var isRoom = false

    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    @Environment(\.redactionReasons) private var redaction
    @State private var image: PlatformImage?

    var body: some View {
        // A cached photo shows on the first frame, so scrolling never flashes initials.
        let shown = image ?? url.flatMap { model.media.cached(MediaLoader.avatarKey($0, points: size)) }
        ZStack {
            Rectangle().fill(fill)
            // A placeholder row's face is just the gray circle. Only placeholders: iOS redacts
            // for privacy while the app is in the switcher, and faces should stay as they are.
            if !isPlaceholder, shown == nil {
                Text(initials(name: name))
                    .font(.system(size: size * (isRoom ? 0.38 : 0.4), weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(size * 0.1)
            }
            if let shown {
                Image(platformImage: shown)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity.animation(Theme.Motion.contentFade))
            }
        }
        .frame(width: size, height: size)
        .clipShape(AvatarShape(isRoom: isRoom))
        // One layer: a pressed button's fade dims the photo as a whole, instead of letting the
        // room's color and initials show through it.
        .compositingGroup()
        .accessibilityHidden(true)
        .task(id: url) {
            // A reused row may still hold the photo of the person it showed before.
            image = nil
            guard let url else { return }
            guard model.media.cached(MediaLoader.avatarKey(url, points: size)) == nil else { return }
            image = await model.media.avatar(url, points: size, scale: scale)
        }
    }

    private var isPlaceholder: Bool { redaction.contains(.placeholder) }

    private var fill: AnyShapeStyle {
        if isPlaceholder {
            AnyShapeStyle(.quaternary)
        } else if isRoom || model.preferences.colorCodePeople {
            AnyShapeStyle(Color.person(seed).gradient)
        } else {
            AnyShapeStyle(Color.monogram)
        }
    }
}

/// A circle for a person; for a room, a square with an app icon's continuous corners.
nonisolated struct AvatarShape: Shape {
    var isRoom: Bool

    func path(in rect: CGRect) -> Path {
        if isRoom {
            RoundedRectangle(cornerRadius: rect.width * 0.25, style: .continuous).path(in: rect)
        } else {
            Circle().path(in: rect)
        }
    }
}

extension RoomSummary {
    /// Rooms are drawn as places; chats, even group chats, are drawn as people.
    var isRoom: Bool { !isDirect }
}

#Preview {
    HStack {
        AvatarView(name: "Maya Okafor", seed: "@maya:localhost", url: nil, size: 52)
        AvatarView(name: "Christopher Montgomery-Wellington III", seed: "@christopher:localhost", url: nil, size: 52)
        AvatarView(name: "Design Crit", seed: "!abc:localhost", url: nil, size: 52, isRoom: true)
    }
    .padding()
    .environment(AppModel())
}
