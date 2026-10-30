import SwiftUI

// Feedback pieces: banner, toast and haptics. Kept together, with no
// dependency on the rest of the app, so they can move to the shared
// scshafe-ios package (Sui-prefixed) as they are. The tones are in Tokens.swift.

/// A message that stays until the situation changes: a tinted block with the
/// tone's symbol, and an optional dismiss. Content, so no glass.
struct SuiBanner: View {
    let text: String
    var tone: SuiTone = .danger
    var symbol: String?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SuiToneLabel(text, tone: tone, symbol: symbol)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(10)
        .background(tone.color.opacity(0.12), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// A message that goes by itself. It floats over the content, so it is a
/// glass control; it clears the binding after `seconds`.
private struct SuiToastModifier: ViewModifier {
    @Binding var message: String?
    let tone: SuiTone
    let seconds: Double

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message {
                    SuiToneLabel(message, tone: tone)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onTapGesture { self.message = nil }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("toast")
                }
            }
            .animation(.snappy, value: message)
            .task(id: message) {
                guard message != nil else { return }
                try? await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled { message = nil }
            }
    }
}

extension View {
    /// Shows `message` as a toast while it is non-nil, then clears it.
    func suiToast(_ message: Binding<String?>, tone: SuiTone = .danger, seconds: Double = 4) -> some View {
        modifier(SuiToastModifier(message: message, tone: tone, seconds: seconds))
    }
}

/// The haptics the app uses, by meaning.
enum SuiHaptic {
    case sent, play, error

    var feedback: SensoryFeedback {
        switch self {
        case .sent: return .success
        case .play: return .impact(weight: .light)
        case .error: return .error
        }
    }
}

extension View {
    /// Plays `haptic` whenever `trigger` changes.
    func suiHaptic<T: Equatable>(_ haptic: SuiHaptic, trigger: T) -> some View {
        sensoryFeedback(haptic.feedback, trigger: trigger)
    }
}
