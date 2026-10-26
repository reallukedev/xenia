import Foundation
import Observation
import XeniaCore

/// One verification with another device or person, from request to done, as the sheet shows it.
@Observable
final class VerificationModel: Identifiable {
    enum Kind: Equatable {
        /// Ask my other devices to verify this one.
        case thisDevice
        /// Ask one of my other devices, by ID.
        case session(deviceID: String, name: String)
        /// Ask someone else, through our chat.
        case person(userID: String, name: String)
        /// Someone asked this device.
        case incoming(VerificationPeer)
    }

    let id = UUID()
    let kind: Kind
    /// Where the sheet shows: the Settings window, or the main window (Mac).
    let fromSettings: Bool

    /// For a request from someone else: their name, when a chat with them is known.
    var requesterName: String?

    private(set) var state: VerificationState?
    private(set) var peer: VerificationPeer?
    private(set) var isWorking = false
    var errorMessage: String?

    @ObservationIgnored private var verification: Verification?
    /// Cancelled before the core handed back the verification: cancel it as soon as it does.
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private weak var model: AppModel?

    init(kind: Kind, fromSettings: Bool = false) {
        self.kind = kind
        self.fromSettings = fromSettings
        if case .incoming(let peer) = kind {
            self.peer = peer
            state = .incoming
        }
    }

    var isIncoming: Bool {
        if case .incoming = kind { true } else { false }
    }

    var isFinished: Bool {
        switch state {
        case .done?, .ended?: true
        default: false
        }
    }

    /// Who it's with, for the sheet's words.
    var target: SettingsCopy.VerificationTarget {
        switch kind {
        case .thisDevice: return .anyDevice
        case .session(_, let name): return .device(name)
        case .person(_, let name): return .person(name)
        case .incoming(let peer):
            if !peer.isSelf { return .person(requesterName ?? peer.userId) }
            return peer.deviceName.map { .device($0) } ?? .anyDevice
        }
    }

    func start(model: AppModel) async {
        guard verification == nil else { return }
        self.model = model
        let events = VerificationEvents()
        events.verification = self
        do {
            let started: Verification = switch kind {
            case .thisDevice:
                try await model.client.verifyThisDevice(listener: events)
            case .session(let deviceID, _):
                try await model.client.verifySession(deviceId: deviceID, listener: events)
            case .person(let userID, _):
                try await model.client.verifyPerson(userId: userID, listener: events)
            case .incoming(let peer):
                try await model.client.incomingVerification(userId: peer.userId, flowId: peer.flowId, listener: events)
            }
            verification = started
            if cancelRequested {
                await started.cancel()
                return
            }
            if peer == nil || peer?.deviceName == nil { peer = started.peer() }
            if state == nil { state = .requested }
        } catch {
            state = .ended(reason: .other)
            errorMessage = Copy.error(error)
        }
    }

    func apply(_ new: VerificationState) {
        // The first ending stands: a cancel here is reported back by the core afterwards.
        guard !isFinished else { return }
        state = new
        // Either side's badge in the device list changes.
        if case .done = new { model?.refreshDevices() }
    }

    func accept() { act { try await $0.accept() } }
    func confirm() { act { try await $0.confirm() } }
    func mismatch() { act { try await $0.mismatch() } }

    /// Stops a verification still in progress (closing the sheet does this too).
    func cancel() {
        guard !isFinished else { return }
        state = .ended(reason: .cancelledHere)
        guard let verification else {
            cancelRequested = true
            return
        }
        Task { await verification.cancel() }
    }

    private func act(_ work: @escaping (Verification) async throws -> Void) {
        guard let verification, !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do { try await work(verification) } catch { errorMessage = Copy.error(error) }
        }
    }
}

/// Receives a verification's steps on the core's threads and applies them on the main thread.
final class VerificationEvents: VerificationListener, @unchecked Sendable {
    nonisolated(unsafe) weak var verification: VerificationModel?

    nonisolated init() {}

    nonisolated func onState(state: VerificationState) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.verification?.apply(state) }
        }
    }
}
