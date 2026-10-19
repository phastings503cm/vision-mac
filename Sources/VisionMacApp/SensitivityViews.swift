import SwiftUI
import VisionHarnessCore

/// The strip at the top of a Sensitive chat: what the policy is, and what it means for the chat's model right now.
struct SensitivityHeader: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    var body: some View {
        if let line = model.transport.sensitivityHeader(for: session) {
            let refused = model.transport.sensitivityRefusal(for: session) != nil
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: refused ? "exclamationmark.lock.fill" : "lock.shield.fill")
                    .foregroundStyle(refused ? Theme.errorTint : Theme.successTint)
                Text(line)
                    .font(.system(size: 11.5))
                    .foregroundStyle(refused ? Theme.errorTint : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button("Turn Off") { model.transport.setSensitive(false, for: session) }
                    .controlSize(.small)
                    .help("Make this chat not Sensitive: every model may be used, with the usual masking")
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((refused ? Theme.errorTint : Theme.successTint).opacity(0.08))
            .help(SensitivityPolicy.explanation)
        }
    }
}

/// The composer's Sensitive control: this chat, and what new chats in its project start with.
struct SensitiveMenu: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    var body: some View {
        let transport = model.transport
        Menu {
            Toggle("Sensitive Chat", isOn: Binding(get: { session.sensitive },
                                                   set: { transport.setSensitive($0, for: session) }))
            Toggle(session.projectName.map { "New Chats in \($0) Start Sensitive" } ?? "New Chats Without a Project Start Sensitive",
                   isOn: Binding(get: { transport.projectStartsSensitive(session.cwd) },
                                 set: { transport.setProjectStartsSensitive($0, path: session.cwd) }))
            Divider()
            Text(SensitivityPolicy.explanation)
        } label: {
            Label(session.sensitive ? "Sensitive" : "Not sensitive",
                  systemImage: session.sensitive ? "lock.shield.fill" : "lock.open")
                .foregroundStyle(session.sensitive ? Theme.successTint : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(session.sensitive
              ? "Sensitive: only private models, or others through the shield. Claude Code is refused."
              : "Not sensitive: every model may be used. Make it Sensitive to keep it on private models (or masked).")
    }
}
