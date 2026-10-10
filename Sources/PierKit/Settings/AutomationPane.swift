import AppKit
import SwiftUI

/// How to make dock icons bounce, badge or speak up from scripts and AI agents.
struct AutomationPane: View {
    private let installCommand = "sudo mkdir -p /usr/local/bin && sudo ln -sf /Applications/Pier.app/Contents/Resources/pier /usr/local/bin/pier"
    private let hookSnippet = """
    {
      "hooks": {
        "Stop": [{ "hooks": [{ "type": "command",
          "command": "pier notify --message 'Claude finished' --text ✓" }] }],
        "Notification": [{ "hooks": [{ "type": "command",
          "command": "pier bounce --until-opened --text '!' --color '#FF9F0A'" }] }]
      }
    }
    """

    var body: some View {
        Form {
            Section {
                Text("Any script or AI agent can get your attention through the dock: bounce an icon, badge it, or pop a short message above it. Everything clears when you open the app.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Bounce Finder") { send("pier://notify?app=com.apple.finder&message=Hello%20from%20Pier&text=1") }
                    Button("Clear") { send("pier://clear?app=all") }
                }
            } header: { Text("Agent notifications") }

            Section {
                CodeBlock(text: installCommand)
                CodeBlock(text: """
                pier notify --message "Build finished"
                pier bounce --until-opened
                pier badge --text 3 --color "#34C759"
                pier clear
                """)
            } header: {
                Text("Command line")
            } footer: {
                Text("Run the first line once in Terminal to install the `pier` command. Without --app, pier targets the app that ran it, such as your terminal or Claude.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                CodeBlock(text: hookSnippet)
            } header: {
                Text("Claude Code hooks")
            } footer: {
                Text("Add to ~/.claude/settings.json: your terminal's icon bounces and shows a check mark when Claude finishes, and keeps bouncing when it needs your input.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                CodeBlock(text: "open -g \"pier://notify?app=com.apple.Terminal&message=Done&text=%E2%9C%93\"")
            } header: {
                Text("URL scheme")
            } footer: {
                Text("Actions: notify, bounce, badge, flash, clear. Options: app, text, color, message, times, until=opened, sticky=1.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func send(_ string: String) {
        if let url = URL(string: string) { AttentionService.shared.handle(url) }
    }
}

/// Monospaced, selectable text with a copy button.
struct CodeBlock: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }
}
