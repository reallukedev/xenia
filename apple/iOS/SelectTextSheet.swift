import XeniaCore
import SwiftUI
import UIKit

/// A message opened on its own so any part of it can be selected, copied, looked up or shared,
/// with links, dates and addresses live.
struct SelectTextSheet: View {
    let message: TimelineMessage

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableText(text: message.plainText ?? "")
                .padding(.horizontal, Theme.Spacing.xl)
                .navigationTitle(message.isOwn ? String(localized: "You") : message.senderName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", role: .close) { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        // Words to read and select: nothing from the conversation showing through.
        .presentationBackground(Color(uiColor: .systemBackground))
    }
}

private struct SelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.dataDetectorTypes = [.link, .phoneNumber, .address, .calendarEvent]
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 24, right: 0)
        view.textContainer.lineFragmentPadding = 0
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard view.text != text else { return }
        view.text = text
        // Everything starts selected, so the handles are right there to narrow it.
        DispatchQueue.main.async {
            view.becomeFirstResponder()
            view.selectedRange = NSRange(location: 0, length: (text as NSString).length)
        }
    }
}
