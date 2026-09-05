import SwiftUI
import AppKit

extension Tier {
    var color: Color {
        switch self {
        case .unranked:    return Color(red: 0.55, green: 0.57, blue: 0.60)
        case .iron:        return Color(red: 0.45, green: 0.42, blue: 0.40)
        case .bronze:      return Color(red: 0.68, green: 0.45, blue: 0.28)
        case .silver:      return Color(red: 0.60, green: 0.65, blue: 0.70)
        case .gold:        return Color(red: 0.83, green: 0.66, blue: 0.27)
        case .platinum:    return Color(red: 0.29, green: 0.68, blue: 0.70)
        case .emerald:     return Color(red: 0.24, green: 0.68, blue: 0.45)
        case .diamond:     return Color(red: 0.42, green: 0.55, blue: 0.90)
        case .master:      return Color(red: 0.63, green: 0.40, blue: 0.85)
        case .grandmaster: return Color(red: 0.83, green: 0.32, blue: 0.33)
        case .challenger:  return Color(red: 0.36, green: 0.75, blue: 0.92)
        }
    }
}

/// Small rounded label used for rank, region and status.
struct Chip: View {
    var text: String
    var color: Color
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(filled ? Color.white : color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(filled ? color : color.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(color.opacity(filled ? 0 : 0.35), lineWidth: 1)
            )
    }
}

/// Titled container used for each block in the detail pane.
struct Card<Content: View>: View {
    var title: String
    var systemImage: String
    var accessory: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.5)
                Spacer()
                if let accessory { accessory }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct LabeledValue: View {
    var label: String
    var value: String
    var monospaced: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 13, weight: .medium, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
        }
    }
}

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
