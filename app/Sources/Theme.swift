import SwiftUI

/// The Archive Console palette, in code.
///
/// Values are taken verbatim from the `vaultline-brand` system — do not
/// improvise new ones here. Blue and amber are accents: status, focus,
/// selection, a single progress fill. They are never large areas of colour.
///
/// **The app is dark only, deliberately.** Every tool this sits beside —
/// Resolve, Premiere, Hedge, Silverstack — is dark, because people grade and
/// cut in dark rooms and a white window in the middle of that is an intrusion.
/// It also happens to be the brand's own direction: "quiet technical
/// confidence… dark control-room interfaces."
enum VL {

    // MARK: Palette

    static let charcoal  = Color(hex: 0x0B0F14)   // primary background
    static let slate     = Color(hex: 0x151B23)   // raised surface
    static let slateHi   = Color(hex: 0x1B222C)   // hover / selected surface
    static let steel     = Color(hex: 0x7D8896)   // secondary text
    static let softWhite = Color(hex: 0xF4F1EA)   // primary text
    static let blue      = Color(hex: 0x4C8DFF)   // accent — links, focus, progress
    static let amber     = Color(hex: 0xD7A84F)   // accent — warnings, attention

    /// Hairlines. Nothing in this UI uses a heavy border.
    static let rule      = Color(hex: 0xF4F1EA).opacity(0.10)
    static let ruleSoft  = Color(hex: 0xF4F1EA).opacity(0.06)

    static let ink       = softWhite
    static let inkDim    = steel
    static let inkFaint  = Color(hex: 0x7D8896).opacity(0.65)

    // MARK: Metrics

    enum Space {
        static let xs: CGFloat = 4
        static let s:  CGFloat = 8
        static let m:  CGFloat = 14
        static let l:  CGFloat = 20
        static let xl: CGFloat = 28
    }

    enum Radius {
        static let small: CGFloat = 6
        static let panel: CGFloat = 9
        static let bar:   CGFloat = 3
    }

    // MARK: Type
    //
    // The brand locks colour and logo but not a typeface, so this is the system
    // face used with intent: tight tracking on display sizes, uppercase micro
    // labels for structure, tabular figures anywhere a number can change.

    static func display(_ size: CGFloat = 22) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }
    static let title    = Font.system(size: 15, weight: .semibold)
    static let body     = Font.system(size: 13)
    static let bodyMed  = Font.system(size: 13, weight: .medium)
    static let small    = Font.system(size: 11.5)
    static let micro    = Font.system(size: 10, weight: .semibold)
    static let mono     = Font.system(size: 11.5, design: .monospaced)
    static let monoSm   = Font.system(size: 10.5, design: .monospaced)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

// MARK: - Structure

/// Small uppercase label that gives a block its name. The main structural
/// device in this UI — it replaces boxes and headings, which keeps the surface
/// calm and lets the data do the work.
struct SectionLabel: View {
    let text: String
    var accessory: AnyView?

    init(_ text: String) { self.text = text; self.accessory = nil }
    init<A: View>(_ text: String, @ViewBuilder accessory: () -> A) {
        self.text = text
        self.accessory = AnyView(accessory())
    }

    var body: some View {
        HStack(spacing: VL.Space.s) {
            Text(text.uppercased())
                .font(VL.micro)
                .tracking(0.9)
                .foregroundStyle(VL.inkFaint)
            Rectangle().fill(VL.ruleSoft).frame(height: 1)
            if let accessory { accessory }
        }
    }
}

/// A raised surface. One elevation only — stacking panels inside panels is how
/// a calm interface turns into a noisy one.
struct Panel<Content: View>: View {
    var padding: CGFloat = VL.Space.m
    var tint: Color = VL.slate
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: VL.Radius.panel))
            .overlay(RoundedRectangle(cornerRadius: VL.Radius.panel)
                .strokeBorder(VL.ruleSoft, lineWidth: 1))
    }
}

// MARK: - Controls

struct VLPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VL.bodyMed)
            .foregroundStyle(VL.charcoal)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(configuration.isPressed ? VL.softWhite.opacity(0.82) : VL.softWhite,
                        in: RoundedRectangle(cornerRadius: VL.Radius.small))
            .contentShape(Rectangle())
    }
}

struct VLButton: ButtonStyle {
    var destructiveTint: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VL.body)
            .foregroundStyle(destructiveTint ? VL.amber : VL.ink)
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(configuration.isPressed ? VL.slateHi : VL.slate,
                        in: RoundedRectangle(cornerRadius: VL.Radius.small))
            .overlay(RoundedRectangle(cornerRadius: VL.Radius.small)
                .strokeBorder(VL.rule, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

struct VLQuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VL.body)
            .foregroundStyle(configuration.isPressed ? VL.ink : VL.inkDim)
            .contentShape(Rectangle())
    }
}

/// The one progress bar in the app. Thin, square-ended, single accent fill —
/// a chunky rounded bar would read as consumer software.
struct VLProgressBar: View {
    var value: Double
    var tint: Color = VL.blue
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: VL.Radius.bar).fill(VL.softWhite.opacity(0.08))
                RoundedRectangle(cornerRadius: VL.Radius.bar)
                    .fill(tint)
                    .frame(width: max(2, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
    }
}

/// A single number with a name. Used where a figure is the answer, rather than
/// a row in a comparison.
struct VLStat: View {
    let label: String
    let value: String
    var note: String?
    var tint: Color = VL.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(VL.micro).tracking(0.7).foregroundStyle(VL.inkFaint)
            Text(value)
                .font(.system(size: 17, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let note {
                Text(note).font(.system(size: 10.5)).foregroundStyle(VL.inkFaint).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VLChip: View {
    let text: String
    var tint: Color = VL.steel
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(tint.opacity(0.13), in: Capsule())
    }
}

/// Attention block. Amber, never red — nothing this app does is destructive,
/// so a red alarm would overstate it and train people to ignore the next one.
struct VLNotice<Content: View>: View {
    let title: String
    var systemImage: String = "exclamationmark.triangle"
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: VL.Space.m) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(VL.amber)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: VL.Space.xs) {
                Text(title).font(VL.bodyMed).foregroundStyle(VL.ink)
                content
            }
        }
        .padding(VL.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VL.amber.opacity(0.09), in: RoundedRectangle(cornerRadius: VL.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: VL.Radius.panel)
                .strokeBorder(VL.amber.opacity(0.28), lineWidth: 1))
    }
}

/// Text field styled for a dark control surface. SwiftUI's default field is a
/// bright well that punches a hole in the window.
struct VLFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(VL.body)
            .foregroundStyle(VL.ink)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(VL.charcoal, in: RoundedRectangle(cornerRadius: VL.Radius.small))
            .overlay(RoundedRectangle(cornerRadius: VL.Radius.small)
                .strokeBorder(VL.rule, lineWidth: 1))
    }
}

extension View {
    /// Root background. Applied once, at the window.
    func vlWindowBackground() -> some View {
        background(VL.charcoal.ignoresSafeArea())
    }
}
