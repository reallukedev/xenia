import XeniaCore
import SwiftUI

extension View {
    /// Shows `message` in an alert while it's set, and clears it when dismissed.
    func errorAlert(_ title: LocalizedStringKey, message: Binding<String?>) -> some View {
        modifier(ErrorAlertModifier(title: title, message: message))
    }
}

private struct ErrorAlertModifier: ViewModifier {
    let title: LocalizedStringKey
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: isPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            // Every alert here reports an action the person just took that failed.
            .sensoryFeedback(trigger: message) { _, new in new == nil ? nil : .error }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { message != nil }, set: { if !$0 { message = nil } })
    }
}
