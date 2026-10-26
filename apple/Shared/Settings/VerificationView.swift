import XeniaCore
import SwiftUI

extension View {
    /// Shows the verification in progress when this window (or sheet) is where it belongs.
    func verificationSheet(isHost: Bool) -> some View {
        modifier(VerificationSheetHost(isHost: isHost))
    }
}

private struct VerificationSheetHost: ViewModifier {
    let isHost: Bool
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.sheet(item: presented) { verification in
            VerificationView(verification: verification)
                .environment(model)
        }
    }

    private var presented: Binding<VerificationModel?> {
        Binding(
            get: { isHost ? model.verification : nil },
            set: { if $0 == nil { model.verification = nil } }
        )
    }
}

/// Comparing emoji with another device or person: waiting, accepting, comparing, done.
struct VerificationView: View {
    @Bindable var verification: VerificationModel
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var finished = 0
    @State private var failed = 0

    var body: some View {
        let words = SettingsCopy.verification(
            verification.state, target: verification.target, isIncoming: verification.isIncoming
        )
        VStack(spacing: Theme.Spacing.xl) {
            Spacer(minLength: 0)
            if !isComparing {
                artwork
                    .frame(minHeight: 96)
            }
            VStack(spacing: Theme.Spacing.s) {
                Text(words.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(words.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentTransition(.opacity)
            .frame(maxWidth: 420)
            if isComparing {
                artwork
                    .padding(.top, Theme.Spacing.s)
            }
            Spacer(minLength: 0)
            actions
                .frame(maxWidth: 420)
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.top, Theme.Spacing.xxxl)
        .padding(.bottom, Theme.Spacing.xl)
        .frame(maxWidth: .infinity)
        #if os(macOS)
        .frame(width: 480)
        .frame(minHeight: 440)
        #else
        .presentationDetents([.large])
        #endif
        .animation(Theme.Motion.row, value: stateKey)
        .sensoryFeedback(.success, trigger: finished)
        .sensoryFeedback(.error, trigger: failed)
        .onChange(of: stateKey) { _, _ in
            switch verification.state {
            case .done?: finished += 1
            case .ended(.mismatch)?: failed += 1
            default: break
            }
        }
        .interactiveDismissDisabled(!verification.isFinished && verification.state != .incoming)
        // Closing the sheet mid-way stops this verification on both sides. Only this one: a
        // Try Again swaps a new verification in while this sheet goes away.
        .onDisappear { verification.cancel() }
        .errorAlert("Couldn’t Verify", message: $verification.errorMessage)
    }

    private var isComparing: Bool {
        if case .compare = verification.state { true } else { false }
    }

    private var isPerson: Bool {
        if case .person = verification.target { true } else { false }
    }

    /// Changes whenever the step does, for animation and haptics.
    private var stateKey: String {
        switch verification.state {
        case nil: "none"
        case .requested?: "requested"
        case .incoming?: "incoming"
        case .starting?: "starting"
        case .compare?: "compare"
        case .confirmed?: "confirmed"
        case .done?: "done"
        case .ended?: "ended"
        }
    }

    @ViewBuilder
    private var artwork: some View {
        switch verification.state {
        case .compare(let emojis, let decimals)?:
            if emojis.isEmpty {
                Text(decimals.map(String.init).joined(separator: "  "))
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            } else {
                EmojiGrid(emojis: emojis)
            }
        case .done?:
            Glyph(systemImage: "checkmark.seal.fill", tint: .green)
        case .ended(let reason)?:
            Glyph(systemImage: reason == .mismatch ? "exclamationmark.triangle.fill" : "xmark.seal.fill",
                  tint: reason == .mismatch ? .orange : .secondary)
        case .incoming?:
            Glyph(systemImage: isPerson ? "person.badge.shield.checkmark.fill" : "checkmark.shield.fill", tint: .blue)
        default:
            Glyph(systemImage: isPerson ? "person.2.fill" : "laptopcomputer.and.iphone", tint: .blue)
                .overlay(alignment: .bottomTrailing) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(6)
                        .background(.regularMaterial, in: .circle)
                        .offset(x: 10, y: 10)
                }
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: Theme.Spacing.s) {
            switch verification.state {
            case .incoming?:
                primary("Accept") { verification.accept() }
                secondary("Decline") {
                    verification.cancel()
                    dismiss()
                }
            case .compare?:
                primary("They Match") { verification.confirm() }
                Button("They Don’t Match", role: .destructive) { verification.mismatch() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .controlSize(.large)
                    .disabled(verification.isWorking)
            case .done?:
                primary("Done") { dismiss() }
            case .ended?:
                if !verification.isIncoming {
                    primary("Try Again") {
                        model.verify(verification.kind, fromSettings: verification.fromSettings)
                    }
                }
                secondary("Close") { dismiss() }
            default:
                secondary("Cancel") {
                    verification.cancel()
                    dismiss()
                }
            }
        }
    }

    private func primary(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(verification.isWorking)
    }

    private func secondary(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .keyboardShortcut(.cancelAction)
    }
}

private struct Glyph: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 64, weight: .regular))
            .foregroundStyle(tint == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint.gradient))
            .symbolRenderingMode(.hierarchical)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}

/// The seven emoji, four above three, each with its name, as every Matrix app lays them out.
private struct EmojiGrid: View {
    let emojis: [SasEmoji]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The emoji are dealt out one after another the moment they arrive, so the eye reads them
    /// in order, as it will compare them.
    @State private var isRevealed = false

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            row(Array(emojis.prefix(4)), from: 0)
            row(Array(emojis.dropFirst(4)), from: 4)
        }
        .onAppear { isRevealed = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(emojis.map { String(localized: String.LocalizationValue($0.description)) }.formatted(.list(type: .and))))
    }

    private func row(_ items: [SasEmoji], from start: Int) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, emoji in
                VStack(spacing: Theme.Spacing.xs) {
                    Text(emoji.symbol)
                        .font(.system(size: 44))
                    Text(LocalizedStringKey(emoji.description))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                // Four across, narrowing on the smallest screens rather than running off them.
                .frame(maxWidth: 72)
                .opacity(isRevealed ? 1 : 0)
                .scaleEffect(isRevealed || reduceMotion ? 1 : 0.85)
                .animation(reveal(Double(start + index)), value: isRevealed)
            }
        }
    }

    private func reveal(_ order: Double) -> Animation {
        reduceMotion
            ? Theme.Motion.contentFade.delay(order * 0.03)
            : .spring(duration: 0.34, bounce: 0.2).delay(order * 0.045)
    }
}

#Preview("Both Asked at Once") {
    let verification = VerificationModel(kind: .thisDevice)
    verification.apply(.ended(reason: .crossed))
    return VerificationView(verification: verification)
        .environment(AppModel())
}
