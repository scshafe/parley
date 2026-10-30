import SwiftUI

// Design tokens: kept in this folder, with no dependency on the rest of the
// app, so they can move to the shared scshafe-ios package (Sui-prefixed) as
// they are. The accent itself is the AccentColor asset (scshafe-ui 0.9.0:
// #0a4f99 light, #6cb6ff dark), so `Color.accentColor` and `.tint` follow it.

/// A status tone. A tone is never shown by colour alone: it always comes with
/// a symbol (`SuiToneLabel`), so it reads without colour vision.
enum SuiTone {
    case neutral, info, success, warning, danger

    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .danger: return .red
        }
    }

    /// The symbol that goes with the tone when the caller has no better one.
    var symbol: String {
        switch self {
        case .neutral: return "circle"
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "xmark.octagon.fill"
        }
    }
}

/// Text in a tone, with its symbol.
struct SuiToneLabel: View {
    let text: String
    var tone: SuiTone
    var symbol: String?

    init(_ text: String, tone: SuiTone, symbol: String? = nil) {
        self.text = text
        self.tone = tone
        self.symbol = symbol
    }

    var body: some View {
        Label(text, systemImage: symbol ?? tone.symbol)
            .foregroundStyle(tone.color)
    }
}
