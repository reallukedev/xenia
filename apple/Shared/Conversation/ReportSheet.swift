import XeniaCore
import SwiftUI

/// Report: sends a message to the server's administrators, with an optional reason, and can
/// block its sender in the same step.
struct ReportSheet: View {
    let message: TimelineMessage

    @Environment(AppModel.self) private var model
    @Environment(ConversationModel.self) private var conversation
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var alsoBlock = false
    @State private var isSending = false
    @State private var error: String?
    @FocusState private var reasonFocused: Bool

    private var server: String {
        model.account?.userId.split(separator: ":", maxSplits: 1).last.map(String.init) ?? String(localized: "your server")
    }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Report Message")
                    .font(.title2.bold())
                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Reason (Optional)", text: $reason, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
            Toggle("Block \(message.senderName)", isOn: $alsoBlock)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Report", action: report)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSending)
            }
            .padding(.top, Theme.Spacing.s)
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 420)
        .errorAlert("Couldn’t Report the Message", message: $error)
        #else
        NavigationStack {
            Form {
                Section {
                    TextField("Reason (Optional)", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                        .focused($reasonFocused)
                } footer: {
                    Text(explanation)
                }
                Section {
                    Toggle("Block \(message.senderName)", isOn: $alsoBlock)
                } footer: {
                    Text("You won’t see their messages or invitations.")
                }
            }
            .navigationTitle("Report Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Report", role: .confirm, action: report)
                        .disabled(isSending)
                }
            }
            .onAppear { reasonFocused = true }
        }
        .errorAlert("Couldn’t Report the Message", message: $error)
        #endif
    }

    private var explanation: String {
        if model.room(conversation.roomID)?.isEncrypted == true {
            // The server only ever had the encrypted message.
            return String(localized: "The administrators of \(server) will see who sent this message and your reason. It’s encrypted, so they can’t read it. \(message.senderName) won’t be told.")
        }
        return String(localized: "The administrators of \(server) will see this message and who sent it. \(message.senderName) won’t be told.")
    }

    @State private var reported = false

    private func report() {
        isSending = true
        Task {
            do {
                // Reported once, even if blocking needs another try.
                if !reported {
                    try await conversation.report(message, reason: reason.trimmingCharacters(in: .whitespacesAndNewlines))
                    reported = true
                }
            } catch {
                isSending = false
                self.error = Copy.error(error)
                return
            }
            if alsoBlock {
                do {
                    try await model.client.block(userId: message.senderId)
                } catch {
                    isSending = false
                    self.error = String(localized: "The message was reported, but \(message.senderName) couldn’t be blocked. Try again.")
                    return
                }
            }
            dismiss()
        }
    }
}
