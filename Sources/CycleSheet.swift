import SwiftUI
import AppKit

/// Drives and shows the account cycle: sign in, refresh, quick prep, sign out, next.
struct CycleSheet: View {
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var runner: CycleRunner
    @Environment(\.dismiss) private var dismiss

    @State private var setIcon = QuickPrep.setsIcon
    @State private var iconId = QuickPrep.iconId
    @State private var clearChallenges = QuickPrep.clearsChallenges
    @State private var confirmed = false

    private var eligible: Int { runner.eligibleCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if runner.items.isEmpty {
                setup
            } else {
                progress
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 620)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cycle all accounts")
                    .font(.system(size: 15, weight: .semibold))
                Text(runner.isRunning
                     ? "Running — \(doneCount) of \(runner.items.count) done"
                     : "\(eligible) account\(eligible == 1 ? "" : "s") ready to cycle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if runner.isRunning {
                ProgressView().controlSize(.small)
            }
        }
        .padding(18)
    }

    private var doneCount: Int { runner.items.filter(\.isTerminal).count }

    // MARK: Setup

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("For each account that has a saved login and password, League Vault will sign in through the Riot Client, launch League, refresh the account, run quick prep, sign out, and move to the next one.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 9) {
                    step(1, "Sign out whatever is signed in", "Through the Riot Client's own logout — it is left open, never force-quit.")
                    step(2, "Type the login and submit", "Synthetic keystrokes into the Riot Client, then Return.")
                    step(3, "Launch League and refresh", "Rank, last game, champions, wallet, penalties.")
                    step(4, "Quick prep", "Icon and challenge reset — never friends.")
                    step(5, "Publish and go to the next", "If the web dashboard is on.")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

                FormSection("Quick prep for each account") {
                    Toggle("Set the profile icon", isOn: $setIcon)
                        .toggleStyle(.checkbox)
                    if setIcon {
                        Picker("Icon", selection: $iconId) {
                            Text("6923 — preferred").tag(QuickPrep.preferredIconId)
                            Text("29 — always owned").tag(QuickPrep.fallbackIconId)
                        }
                        .pickerStyle(.radioGroup)
                        .padding(.leading, 18)
                    }
                    Toggle("Clear challenge badges, title and banner", isOn: $clearChallenges)
                        .toggleStyle(.checkbox)
                    Label("Friends are never removed by the cycle.", systemImage: "person.2")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                warningBox

                if !Autofill.isPermitted {
                    Label("Accessibility permission is off, so the login cannot be typed. Grant it from the Sign in sheet on any account first.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(isOn: $confirmed) {
                    Text("I understand this signs into each account for real, and may stall on a captcha or 2FA prompt.")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
            }
            .padding(18)
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var warningBox: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text("Leave the Mac alone while this runs — it drives the keyboard and the Riot Client window. Move the mouse or type and a login can land in the wrong place. Stop anytime; nothing is submitted twice.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.10)))
    }

    // MARK: Progress

    private var progress: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(runner.items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 10) {
                        stageIcon(item.stage, active: index == runner.currentIndex)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .font(.system(size: 12, weight: .medium))
                            Text(item.detail.isEmpty ? item.stage.rawValue : "\(item.stage.rawValue) — \(item.detail)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(stageColor(item.stage))
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .id(item.id)
                }
            }
            .listStyle(.inset)
            .onChange(of: runner.currentIndex) { _, i in
                if let i, runner.items.indices.contains(i) {
                    withAnimation { proxy.scrollTo(runner.items[i].id, anchor: .center) }
                }
            }
        }
    }

    private func stageIcon(_ stage: CycleRunner.Stage, active: Bool) -> some View {
        Group {
            switch stage {
            case .done:    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:  Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
            case .queued:  Image(systemName: "circle").foregroundStyle(.tertiary)
            default:
                if active { ProgressView().controlSize(.small).scaleEffect(0.6) }
                else { Image(systemName: "circle").foregroundStyle(.tertiary) }
            }
        }
        .font(.system(size: 13))
    }

    private func stageColor(_ stage: CycleRunner.Stage) -> Color {
        switch stage {
        case .failed:  return .red
        case .done:    return .green
        case .skipped: return .secondary
        default:       return .secondary
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if runner.isRunning {
                Text("Keep hands off the keyboard and mouse.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else if !runner.items.isEmpty {
                let failed = runner.items.filter { $0.stage == .failed }.count
                Text(failed == 0
                     ? "Finished. Every account cycled."
                     : "Finished. \(failed) did not complete — see the list.")
                    .font(.system(size: 11))
                    .foregroundStyle(failed == 0 ? .green : .orange)
            }
            Spacer()

            if runner.isRunning {
                Button("Stop", role: .destructive) { runner.stop() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(runner.items.isEmpty ? "Start cycle" : "Run again") {
                    persistPrefs()
                    runner.start(iconId: iconId, setIcon: setIcon, clearChallenges: clearChallenges)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(eligible == 0 || !confirmed || !Autofill.isPermitted)
            }
        }
        .padding(18)
    }

    private func persistPrefs() {
        QuickPrep.setsIcon = setIcon
        QuickPrep.iconId = iconId
        QuickPrep.clearsChallenges = clearChallenges
    }
}
