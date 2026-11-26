import SwiftUI

struct PanelView: View {
    @ObservedObject var model: PanelModel

    private var statusColor: Color {
        if !model.ready { return .gray }
        if model.speaking { return .blue }
        if model.hearing { return .red }
        if model.thinking { return .orange }
        return model.micOn ? .green : .gray
    }

    private var statusText: String {
        if !model.ready { return "starting…" }
        if model.speaking { return "speaking" }
        if model.hearing { return "hearing you" }
        if model.thinking { return "thinking" }
        return model.micOn ? "listening" : "mic off"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            if !model.heardSoFar.isEmpty {
                Text("🎙 " + model.heardSoFar)
                    .font(.system(size: 11)).italic().foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }
            if let ask = model.pending { permissionBar(ask) }
            Divider()
            inputRow
        }
        .frame(minWidth: 300, minHeight: 260)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 0) {
                Text("Claude · \(model.title)").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(statusText).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            modeMenu
            iconButton(model.autoScreen ? "eye.fill" : "eye", help: "Attach a screenshot to every message",
                       active: model.autoScreen) { model.autoScreen.toggle() }
            iconButton(model.micOn ? "mic.fill" : "mic.slash", help: "Mic on/off (⌃⌥Space)",
                       active: model.micOn) { model.toggleMic() }
            iconButton("speaker.slash.fill", help: "Stop reading aloud — Claude keeps working (⌃⌥,)", active: false) { model.stopReading() }
                .disabled(!model.speaking)
            iconButton("stop.fill", help: "Stop reading and interrupt the current task (⌃⌥.)", active: false) { model.hush() }
                .disabled(!(model.speaking || model.thinking))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private var modeMenu: some View {
        Menu {
            Picker("Permissions", selection: $model.permissionMode) {
                ForEach(PermissionMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Text(model.permissionMode.detail)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: model.permissionMode == .bypass ? "exclamationmark.shield.fill" : "checkmark.shield")
                Text(model.permissionMode.short).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(model.permissionMode == .bypass ? Color.red : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Permission mode: \(model.permissionMode.detail)")
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.entries) { e in row(e).id(e.id) }
                }
                .padding(10)
            }
            .onChange(of: model.entries.count) {
                if let last = model.entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder private func row(_ e: Entry) -> some View {
        switch e.role {
        case .you:
            Text(e.text).font(.system(size: 12)).padding(6)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        case .claude:
            Text(e.text).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .tool:
            Text("⚙︎ " + e.text).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        case .system:
            Text(e.text).font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func permissionBar(_ ask: PermissionAsk) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Allow \(ask.tool)?  (or say yes / no)").font(.system(size: 11, weight: .semibold))
            Text(ask.summary).font(.system(size: 10, design: .monospaced)).lineLimit(3).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Deny") { model.answer(ask, allow: false) }
                Button("Allow") { model.answer(ask, allow: true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.15))
    }

    private var inputRow: some View {
        TextField("Type, or just talk…", text: $model.draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(8)
            .onSubmit { model.submitDraft() }
    }

    private func iconButton(_ name: String, help: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
