import Foundation

extension String {
    /// A localized string with automatic grammar agreement resolved ("1 member", "3 members").
    /// `String(localized:)` alone leaves inflection markup in the text; this resolves it.
    init(inflecting value: String.LocalizationValue) {
        self = String(AttributedString(localized: value).characters)
    }
}
