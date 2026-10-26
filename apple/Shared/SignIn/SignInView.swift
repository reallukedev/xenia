import XeniaCore
import SwiftUI

/// Sign In to Xenia: username and password first, the server one tap away and checked live.
struct SignInView: View {
    let endedReason: SignOutReason?

    @State private var form = SignInModel(server: AppEnvironment.defaultServer)

    var body: some View {
        SignInForm(form: form, endedReason: endedReason)
    }
}

private struct SignInForm: View {
    @Bindable var form: SignInModel
    let endedReason: SignOutReason?

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @FocusState private var focus: Field?
    @State private var signedIn = 0

    enum Field { case username, password, server }

    var body: some View {
        #if os(macOS)
        content
            .frame(minWidth: 480, minHeight: 560)
            .background(.background)
        #else
        ScrollView {
            content
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.xxl)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.groupedBackground)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Theme.Spacing.m) {
                SignInButton(form: form, action: submit)
                NewcomerLink()
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.s)
            .background(Color.groupedBackground)
        }
        #endif
    }

    private var content: some View {
        VStack(spacing: 0) {
            Image("Logo")
                .resizable()
                .frame(width: logoSize, height: logoSize)
                .clipShape(.rect(cornerRadius: logoSize * 0.225, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                .accessibilityHidden(true)
                .padding(.bottom, Theme.Spacing.l)

            Text("Sign In to Xenia")
                .font(titleFont)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text("Use your Matrix account, on any server.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, Theme.Spacing.s)
                .padding(.bottom, endedReason == nil ? Theme.Spacing.xxl : Theme.Spacing.l)

            if let endedReason {
                EndedNotice(reason: endedReason)
                    .padding(.bottom, Theme.Spacing.l)
            }

            FieldCard {
                FieldRow(label: "Username") {
                    TextField("name or @name:server", text: $form.username)
                        .textContentType(.username)
                        .focused($focus, equals: .username)
                        .onSubmit { focus = .password }
                        .submitLabel(.next)
                        .signInFieldStyle()
                }
                Divider().padding(.leading, Theme.Spacing.l)
                FieldRow(label: "Password") {
                    SecureField("Required", text: $form.password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .onSubmit(submit)
                        .submitLabel(.go)
                }
            }

            ServerCard(form: form, focus: $focus)
                .padding(.top, Theme.Spacing.xl)

            if let error = form.error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Theme.Spacing.l)
                    .padding(.horizontal, Theme.Spacing.l)
                    .transition(.opacity)
            }

            #if os(macOS)
            SignInButton(form: form, action: submit)
                .padding(.top, Theme.Spacing.xxl)
            NewcomerLink()
                .padding(.top, Theme.Spacing.l)
            #endif
        }
        .frame(maxWidth: columnWidth)
        .frame(maxWidth: .infinity)
        .animation(Theme.Motion.contentFade, value: form.error)
        .sensoryFeedback(trigger: form.error) { _, new in new == nil ? nil : .error }
        .sensoryFeedback(.success, trigger: signedIn)
        .task(id: form.server) {
            await form.checkServer(with: model.client)
        }
        .defaultFocus($focus, .username)
    }

    private var logoSize: CGFloat {
        #if os(macOS)
        64
        #else
        76
        #endif
    }

    private var titleFont: Font {
        #if os(macOS)
        .title.bold()
        #else
        .largeTitle.bold()
        #endif
    }

    private var columnWidth: CGFloat {
        #if os(macOS)
        340
        #else
        440
        #endif
    }

    private func submit() {
        guard form.canSubmit else { return }
        focus = nil
        let password = form.password
        Task {
            if let account = await form.signIn(with: model.client) {
                signedIn += 1
                model.rememberAccount(account, password: password)
            }
        }
    }
}

private struct EndedNotice: View {
    let reason: SignOutReason

    var body: some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Spacing.l)
    }

    private var message: String {
        switch reason {
        case .sessionRevoked:
            String(localized: "You were signed out. Sign in again to continue.")
        case .restoreFailed:
            String(localized: "Xenia couldn’t open your last session. Sign in again to continue.")
        }
    }
}

private struct FieldCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.groupedCell, in: .rect(cornerRadius: cardRadius, style: .continuous))
    }

    private var cardRadius: CGFloat {
        #if os(macOS)
        10
        #else
        26
        #endif
    }
}

private struct FieldRow<Field: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let field: Field

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(label)
                .frame(width: labelWidth, alignment: .leading)
            field
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .frame(minHeight: rowHeight)
    }

    private var labelWidth: CGFloat {
        #if os(macOS)
        76
        #else
        96
        #endif
    }

    private var rowHeight: CGFloat {
        #if os(macOS)
        34
        #else
        52
        #endif
    }
}

private struct ServerCard: View {
    @Bindable var form: SignInModel
    var focus: FocusState<SignInForm.Field?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            FieldCard {
                if form.isEditingServer {
                    FieldRow(label: "Server") {
                        TextField("matrix.org", text: $form.server)
                            .textContentType(.URL)
                            .focused(focus, equals: .server)
                            .onSubmit { form.isEditingServer = false }
                            .signInFieldStyle()
                            #if os(iOS)
                            .keyboardType(.URL)
                            #endif
                    }
                } else {
                    Button {
                        form.isEditingServer = true
                        focus.wrappedValue = .server
                    } label: {
                        FieldRow(label: "Server") {
                            HStack(spacing: Theme.Spacing.s) {
                                Spacer(minLength: 0)
                                ServerStatusGlyph(check: form.serverCheck)
                                Text(form.serverDisplay)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Image(systemName: "chevron.forward")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Server, \(form.serverDisplay)"))
                    .accessibilityHint(Text("Changes the server"))
                }
            }
            Group {
                if case .problem(let message, _) = form.serverCheck {
                    Text(message).foregroundStyle(.red)
                } else {
                    Text("Where your account lives. Typing @name:server fills it in.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .padding(.horizontal, Theme.Spacing.l)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
        }
        // The check answers a moment after typing stops: its mark and words fade in.
        .animation(Theme.Motion.contentFade, value: form.serverCheck)
        .onChange(of: focus.wrappedValue) { _, field in
            if field != .server, !form.server.trimmingCharacters(in: .whitespaces).isEmpty {
                form.isEditingServer = false
            }
        }
    }
}

private struct ServerStatusGlyph: View {
    let check: SignInModel.ServerCheck

    var body: some View {
        switch check {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("Checking the server"))
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(Text("Server ready"))
        case .problem:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel(Text("Server problem"))
        }
    }
}

private struct SignInButton: View {
    let form: SignInModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text("Sign In").opacity(form.isSigningIn ? 0 : 1)
                if form.isSigningIn {
                    ProgressView()
                        .controlSize(.small)
                        #if os(iOS)
                        .tint(.white)
                        #endif
                }
            }
            .frame(maxWidth: .infinity)
            #if os(iOS)
            .frame(height: 30)
            #endif
            .animation(Theme.Motion.contentFade, value: form.isSigningIn)
        }
        #if os(iOS)
        .buttonStyle(.glassProminent)
        #else
        .buttonStyle(.borderedProminent)
        #endif
        .controlSize(.large)
        .disabled(!form.canSubmit)
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel(Text("Sign In"))
    }
}

private struct NewcomerLink: View {
    var body: some View {
        Link(destination: URL(string: "https://matrix.org/try-matrix/")!) {
            Text("New to Matrix? \(Text("Find a server and create an account").foregroundStyle(.tint))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func signInFieldStyle() -> some View {
        self
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
    }
}

#Preview("Sign In") {
    SignInView(endedReason: nil)
        .environment(AppModel())
}

#Preview("Signed Out Elsewhere") {
    SignInView(endedReason: .sessionRevoked)
        .environment(AppModel())
}
