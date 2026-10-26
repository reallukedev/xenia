import Foundation
import Observation
import XeniaCore

/// The sign-in form: fields, the live check of the server, and signing in.
@Observable
final class SignInModel {
    enum ServerCheck: Equatable {
        case idle
        case checking
        case ready
        /// Something's wrong; the message says what, in words. Only a server that answered that
        /// it can't work with Xenia blocks signing in: one that couldn't be reached (offline,
        /// say) gets to try, and signing in says what went wrong.
        case problem(String, blocksSignIn: Bool)
    }

    /// Editing the details takes the last error away: it was about what was there before.
    var username = "" {
        didSet {
            takeServer(from: username)
            if username != oldValue { error = nil }
        }
    }
    var password = "" {
        didSet { if password != oldValue { error = nil } }
    }
    var server: String
    var isEditingServer = false
    private(set) var serverCheck: ServerCheck = .idle
    private(set) var isSigningIn = false
    var error: String?

    init(server: String) {
        self.server = server
    }

    var canSubmit: Bool {
        !isSigningIn
            && !Self.localpart(of: username).isEmpty
            && !password.isEmpty
            && !server.trimmingCharacters(in: .whitespaces).isEmpty
            && !isProblem
    }

    private var isProblem: Bool {
        if case .problem(_, blocksSignIn: true) = serverCheck { true } else { false }
    }

    /// "https://matrix.example.org/" reads as "matrix.example.org".
    var serverDisplay: String {
        var text = server.trimmingCharacters(in: .whitespaces)
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// "@maya:example.org" fills in the server; a bare "maya" keeps the server field's value.
    private func takeServer(from input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("@") || trimmed.contains(":"),
              let colon = trimmed.firstIndex(of: ":") else { return }
        let host = String(trimmed[trimmed.index(after: colon)...])
        if !host.isEmpty, !host.contains(" "), host != server {
            server = host
        }
    }

    static func localpart(of input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("@") { text.removeFirst() }
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        return text
    }

    /// Checks the server after a pause in typing: that it's a Matrix server, offers password
    /// sign-in and has the sync Xenia needs, so problems show before pressing Sign In.
    func checkServer(with client: XeniaClient) async {
        let address = server.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else {
            serverCheck = .idle
            return
        }
        serverCheck = .checking
        do {
            try await Task.sleep(for: .milliseconds(450))
        } catch {
            return  // A newer address is being checked.
        }
        await runCheck(address, with: client)
    }

    private func runCheck(_ address: String, with client: XeniaClient) async {
        do {
            let info = try await client.checkServer(address: address)
            // The core's calls don't stop when the task is cancelled: a slow answer about an
            // earlier address must not replace the current one's.
            guard !Task.isCancelled, address == server.trimmingCharacters(in: .whitespaces) else { return }
            if !info.supportsPassword {
                serverCheck = .problem(Copy.error(XeniaError.PasswordLoginUnsupported), blocksSignIn: true)
            } else if !info.supportsSlidingSync {
                serverCheck = .problem(Copy.error(XeniaError.SlidingSyncUnsupported), blocksSignIn: true)
            } else {
                serverCheck = .ready
            }
        } catch {
            guard !Task.isCancelled, address == server.trimmingCharacters(in: .whitespaces) else { return }
            serverCheck = .problem(Copy.error(error), blocksSignIn: false)
        }
    }

    /// Signs in; returns the account on success (the app switches to the lists by itself).
    func signIn(with client: XeniaClient) async -> Account? {
        guard canSubmit else { return nil }
        isSigningIn = true
        error = nil
        do {
            return try await client.signIn(server: server, username: Self.localpart(of: username), password: password)
        } catch {
            self.error = Copy.error(error)
            isSigningIn = false
            // The earlier check may have failed only for the moment: look again, so the server's
            // status matches what signing in just found.
            if case .problem(_, blocksSignIn: false) = serverCheck {
                await runCheck(server.trimmingCharacters(in: .whitespaces), with: client)
            }
            return nil
        }
    }
}
