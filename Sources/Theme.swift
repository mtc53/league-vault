import SwiftUI
import AppKit

// The native window and the published dashboard are one product seen two ways, so they
// share a palette. Everything below is the :root block of Resources/dashboard.html
// transcribed — if a colour changes there, change it here too.

extension Color {
    /// 0xRRGGBB, the way the stylesheet writes it.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue:  Double(hex & 0xff) / 255,
            opacity: opacity)
    }
}

enum LV {
    static let bg        = Color(hex: 0x06060b)
    static let bg2       = Color(hex: 0x0a0a12)
    static let panel     = Color(hex: 0x0f101a)
    static let panel2    = Color(hex: 0x141525)
    static let line      = Color(hex: 0x20223a)
    static let lineSoft  = Color(hex: 0x191b2e)
    static let text      = Color(hex: 0xe9eaf5)
    static let muted     = Color(hex: 0x8b90ab)
    static let dim       = Color(hex: 0x5f6480)
    static let accent    = Color(hex: 0xff3d8b)
    static let accentLit = Color(hex: 0xff5c9d)
    static let good      = Color(hex: 0x2fd6a3)
    static let warn      = Color(hex: 0xf5a524)
    static let bad       = Color(hex: 0xff4d5e)

    /// Card and panel radius, matching --r.
    static let radius: CGFloat = 14
    static let control: CGFloat = 10

    static let mono = Font.Design.monospaced

    /// The hairline every panel, card and row is drawn with.
    static func border(_ color: Color = LV.line, radius: CGFloat = LV.radius, width: CGFloat = 1) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(color, lineWidth: width)
    }
}

extension Tier {
    var color: Color {
        switch self {
        case .unranked:    return Color(hex: 0x8c8f9c)
        case .iron:        return Color(hex: 0x7a7570)
        case .bronze:      return Color(hex: 0xad7248)
        case .silver:      return Color(hex: 0x98a3ae)
        case .gold:        return Color(hex: 0xd4a843)
        case .platinum:    return Color(hex: 0x4aaeb3)
        case .emerald:     return Color(hex: 0x3dae72)
        case .diamond:     return Color(hex: 0x6b8ce6)
        case .master:      return Color(hex: 0xa166d9)
        case .grandmaster: return Color(hex: 0xd45254)
        case .challenger:  return Color(hex: 0x5cbfeb)
        }
    }
}

extension PenaltyKind {
    /// Red for anything blocking play, amber for the rest.
    var accent: Color { isCritical ? LV.bad : LV.warn }
}

// MARK: - Surfaces

/// The page's `.panel`: a flat dark block with a hairline, used for cards, rows,
/// fields and anything else that sits on the background.
struct PanelBackground: ViewModifier {
    var fill: Color = LV.panel
    var radius: CGFloat = LV.radius
    var stroke: Color = LV.line

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke, lineWidth: 1))
    }
}

extension View {
    func panel(fill: Color = LV.panel, radius: CGFloat = LV.radius, stroke: Color = LV.line) -> some View {
        modifier(PanelBackground(fill: fill, radius: radius, stroke: stroke))
    }

    /// The page's `h3`: tiny, wide-tracked, uppercase, dim.
    func sectionLabel() -> some View {
        self.font(.system(size: 10, weight: .bold))
            .kerning(1.5)
            .textCase(.uppercase)
            .foregroundStyle(LV.dim)
    }
}

// MARK: - Pills

/// The page's `.pill`: uppercase, wide-tracked, tinted to its own colour.
struct Pill: View {
    var text: String
    var color: Color = LV.muted
    /// A glowing dot ahead of the text, the way the live/idle pills carry one.
    var dot: Bool = false
    var systemImage: String?
    /// Ghost pills sit on the neutral panel tint rather than their own colour.
    var ghost: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if dot {
                Circle().fill(color)
                    .frame(width: 5, height: 5)
                    .shadow(color: color, radius: 3)
            }
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 8, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.5)
                .textCase(.uppercase)
                .lineLimit(1)
        }
        .foregroundStyle(ghost ? LV.muted : color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(ghost ? Color.white.opacity(0.04) : color.opacity(0.13)))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(ghost ? LV.line : color.opacity(0.3), lineWidth: 1))
        .fixedSize()
    }
}

/// Small rounded label used wherever a value needs its own colour. Reads as a pill but
/// keeps its capitalisation, because most of these carry names and numbers.
struct Chip: View {
    var text: String
    var color: Color
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(filled ? Color.white : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(filled ? color : color.opacity(0.13)))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(color.opacity(filled ? 0 : 0.3), lineWidth: 1))
    }
}

/// The page's `.rank` pill: a tier-coloured crest, the rank, then LP in mono.
struct RankPill: View {
    var entry: RankEntry
    /// Peak ranks are shown the same way, just quieter.
    var muted: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Crest(tier: entry.tier == .unranked ? entry.effectiveTier : entry.tier)
                .frame(width: 15, height: 15)
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .lineLimit(1)
            if entry.tier != .unranked {
                Text("\(entry.lp) LP")
                    .font(.system(size: 10, weight: .semibold, design: LV.mono))
                    .foregroundStyle(LV.dim)
            }
        }
        .foregroundStyle(muted ? LV.muted : color)
        .padding(.leading, 5)
        .padding(.trailing, 9)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(LV.bg.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(LV.line, lineWidth: 1))
        .fixedSize()
    }

    private var color: Color { entry.effectiveTier.color }

    private var label: String {
        if entry.tier == .unranked {
            return entry.peakDisplay.map { "Peak \($0)" } ?? "Unranked"
        }
        return entry.tier.isApex ? entry.tier.display : "\(entry.tier.display) \(entry.division.rawValue)"
    }
}

/// Stands in for the site's mini rank crest — a tier-coloured chevron stack, drawn
/// rather than fetched so the window has something to show with no network.
struct Crest: View {
    var tier: Tier

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(LinearGradient(colors: [tier.color.opacity(0.85), tier.color.opacity(0.35)],
                                     startPoint: .top, endPoint: .bottom))
            Image(systemName: tier == .unranked ? "questionmark" : "chevron.up")
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(LV.bg)
        }
        .opacity(tier == .unranked ? 0.5 : 1)
    }
}

// MARK: - Cards

/// Titled container used for each block in the detail pane — the page's `.sect`
/// rendered as a panel.
struct Card<Content: View>: View {
    var title: String
    var systemImage: String
    var accessory: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(LV.dim)
                Text(title).sectionLabel()
                Spacer()
                if let accessory { accessory }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

/// The page's `.kv` cell: a tiny uppercase caption over a mono value.
struct LabeledValue: View {
    var label: String
    var value: String
    var monospaced: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 9.5, weight: .bold))
                .kerning(1.2)
                .textCase(.uppercase)
                .foregroundStyle(LV.dim)
            Text(value)
                .font(.system(size: 13.5, weight: .semibold, design: monospaced ? LV.mono : .default))
                .foregroundStyle(LV.text)
                .textSelection(.enabled)
        }
    }
}

/// One figure in the hero strip: a big mono number over a wide-tracked caption.
struct StatTotal: View {
    var value: String
    var label: String
    var tint: Color = LV.text

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: LV.mono))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 9.5, weight: .bold))
                .kerning(1.2)
                .textCase(.uppercase)
                .foregroundStyle(LV.dim)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(minWidth: 104, alignment: .leading)
        .panel(fill: Color.white.opacity(0.03), radius: LV.control)
    }
}

// MARK: - Controls

/// The page's search box.
struct SearchField: View {
    var prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LV.dim)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(LV.text)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(LV.dim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 38)
        .panel(radius: LV.control)
    }
}

/// The page's `<select>`: a flat panel-coloured menu that shows its chosen value.
struct SelectMenu<Content: View>: View {
    var title: String
    /// nil when nothing is chosen, so the menu shows its title in the muted colour.
    var value: String?
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 6) {
                Text(value ?? title)
                    .font(.system(size: 12))
                    .foregroundStyle(value == nil ? LV.muted : LV.text)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(LV.dim)
            }
        }
        // .borderlessButton throws the label's own chrome away and draws AppKit's
        // arrow instead; .button keeps the label and lets a ButtonStyle dress it.
        .menuStyle(.button)
        .buttonStyle(SelectFieldStyle())
        .menuIndicator(.hidden)
    }
}

/// The box a SelectMenu and anything shaped like one sits in.
struct SelectFieldStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 11)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .panel(fill: configuration.isPressed ? LV.panel2 : LV.panel, radius: 9)
    }
}

/// The page's `.fchip`: one active filter, with the cross that clears it.
struct FilterChip: View {
    var text: String
    var clear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
            Button(action: clear) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Color(hex: 0xffb3d0))
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .padding(.vertical, 5)
        .background(Capsule().fill(LV.accent.opacity(0.14)))
        .overlay(Capsule().strokeBorder(LV.accent.opacity(0.32), lineWidth: 1))
    }
}

/// The page's `.btn` and `.btn.primary` — used in the topbar and on the detail sheet,
/// so the window's own actions look like the site's.
struct LVButtonStyle: ButtonStyle {
    var primary = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(primary ? Color.white : LV.text)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 30 : 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(primary
                          ? (configuration.isPressed ? LV.accentLit : LV.accent)
                          : (configuration.isPressed ? LV.panel2 : LV.panel)))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(primary ? LV.accent : LV.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

extension ButtonStyle where Self == LVButtonStyle {
    static var lv: LVButtonStyle { LVButtonStyle() }
    static var lvPrimary: LVButtonStyle { LVButtonStyle(primary: true) }
    static var lvCompact: LVButtonStyle { LVButtonStyle(compact: true) }
}

/// A bare icon button for window chrome — the topbar and the sheet's close control.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(configuration.isPressed ? LV.text : LV.muted)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(configuration.isPressed ? LV.panel2 : LV.panel))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(LV.line, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var lvIcon: IconButtonStyle { IconButtonStyle() }
}

// MARK: - Utilities

enum Clipboard {
    /// Copies and then wipes the pasteboard, so a password doesn't linger.
    static func copy(_ string: String, clearAfter seconds: TimeInterval? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        guard let seconds else { return }
        let stamp = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if NSPasteboard.general.changeCount == stamp {
                NSPasteboard.general.clearContents()
            }
        }
    }
}

extension Int {
    /// 12345 -> "12,345"
    var grouped: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: self)) ?? "\(self)"
    }

    /// 12345 -> "12.3k", for the places a full number would not fit.
    var compact: String {
        if self >= 1_000_000 { return String(format: "%.1fm", Double(self) / 1_000_000) }
        if self >= 10_000 { return "\(self / 1_000)k" }
        if self >= 1_000 { return String(format: "%.1fk", Double(self) / 1_000) }
        return "\(self)"
    }
}

extension Date {
    var relativeDisplay: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: self, relativeTo: Date())
    }

    var shortDisplay: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: self)
    }
}
