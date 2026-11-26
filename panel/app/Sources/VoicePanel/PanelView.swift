import AppKit
import SwiftUI

// MARK: - look

enum Theme {
    // Plain dark mode: a solid background (nothing behind the window shows through) and one accent.
    static let background = Color(red: 0.11, green: 0.11, blue: 0.12)   // #1C1C1E
    static let blue = Color(red: 0.04, green: 0.52, blue: 1.00)          // #0A84FF (system blue, dark)
    static let violet = blue
    static let cyan = Color(red: 0.39, green: 0.82, blue: 1.00)          // #64D2FF
    static let pink = Color(red: 1.00, green: 0.27, blue: 0.23)          // #FF453A
    static let amber = Color(red: 1.00, green: 0.62, blue: 0.04)         // #FF9F0A
    static let mint = Color(red: 0.19, green: 0.82, blue: 0.35)          // #30D158

    static let accent = LinearGradient(colors: [blue, blue], startPoint: .top, endPoint: .bottom)
    static let hairline = LinearGradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0.08)],
                                         startPoint: .leading, endPoint: .trailing)
    static let card = Color.white.opacity(0.07)
    static let cardStroke = Color.white.opacity(0.10)
    static let well = Color.white.opacity(0.05)
}

/// Status dot with a soft glow; rings ripple out while something is happening.
struct StatusOrb: View {
    let color: Color
    let pulsing: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !pulsing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            ZStack {
                if pulsing {
                    Circle().stroke(color.opacity(0.7), lineWidth: 1.5)
                        .scaleEffect(1 + t * 1.6).opacity(1 - t)
                }
                Circle().fill(color).shadow(color: color.opacity(0.9), radius: 4)
            }
        }
        .frame(width: 10, height: 10)
    }
}

/// Little equaliser bars while speaking or hearing.
struct WaveBars: View {
    let color: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule().fill(color)
                        .frame(width: 2, height: 3 + 8 * abs(sin(t * 6 + Double(i) * 0.9)))
                }
            }
            .frame(height: 12)
        }
    }
}

// MARK: - transcript model

enum TranscriptItem: Identifiable {
    case entry(Entry)
    case tools([Entry])   // a run of consecutive tool calls
    var id: UUID {
        switch self {
        case .entry(let e): return e.id
        case .tools(let run): return run[0].id
        }
    }
}

/// Drags the window from wherever it sits (the header). The window itself isn't movable by its
/// background, because then dragging across message text moved the panel instead of selecting.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct CompactHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - panel

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @State private var expandedTools: Set<UUID> = []

    private var statusColor: Color {
        if !model.ready { return .gray }
        if model.speaking { return Theme.cyan }
        if model.hearing { return Theme.pink }
        if model.thinking { return Theme.amber }
        return model.micOn ? Theme.mint : .gray
    }

    private var statusText: String {
        if !model.ready { return "starting…" }
        if model.speaking { return "speaking" }
        if model.hearing { return "hearing you" }
        if model.thinking { return "thinking" }
        return model.micOn ? "listening" : "mic off"
    }

    private var busy: Bool { model.ready && (model.speaking || model.hearing || model.thinking || model.micOn) }

    var body: some View {
        Group {
            if model.compact {
                // Minimised: just the header (and a permission prompt if one is waiting).
                VStack(spacing: 0) {
                    header
                    if let ask = model.pending { permissionBar(ask).padding([.horizontal, .bottom], 8) }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: CompactHeightKey.self, value: g.size.height)
                })
                .onPreferenceChange(CompactHeightKey.self) { model.compactHeight = $0 }
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                expanded
            }
        }
        .background(backdrop)
        .environment(\.colorScheme, .dark)
    }

    private var backdrop: some View {
        Theme.background.ignoresSafeArea()
    }

    private var hairline: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }

    private var expanded: some View {
        VStack(spacing: 0) {
            header
            hairline
            transcript
            if !model.heardSoFar.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "waveform").foregroundStyle(Theme.pink)
                    Text(model.heardSoFar).italic().foregroundStyle(.secondary).lineLimit(2)
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 5)
            }
            if let ask = model.pending { permissionBar(ask).padding(.horizontal, 8).padding(.bottom, 6) }
            inputRow
        }
        .frame(minWidth: 300, minHeight: 260)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 9) {
            StatusOrb(color: statusColor, pulsing: busy)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("Claude").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                    Text(model.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Text(statusText).font(.system(size: 10, weight: .medium)).foregroundStyle(statusColor.opacity(0.9))
                    if model.speaking || model.hearing { WaveBars(color: statusColor.opacity(0.9)) }
                }
            }
            Spacer(minLength: 4)
            modeMenu
            HStack(spacing: 1) {
                iconButton(model.autoScreen ? "eye.fill" : "eye", help: "Attach a screenshot to every message",
                           active: model.autoScreen) { model.autoScreen.toggle() }
                iconButton(model.micOn ? "mic.fill" : "mic.slash", help: "Mic on/off (⌃⌥Space)",
                           active: model.micOn) { model.toggleMic() }
                iconButton("speaker.slash.fill", help: "Stop reading aloud — Claude keeps working (⌃⌥,)", active: false) { model.stopReading() }
                    .disabled(!model.speaking)
                iconButton("stop.fill", help: "Stop reading and interrupt the current task (⌃⌥.)", active: false) { model.hush() }
                    .disabled(!(model.speaking || model.thinking))
                iconButton(model.compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                           help: model.compact ? "Show the conversation (⌃⌥M)" : "Minimise to this bar (⌃⌥M)",
                           active: false) { model.compact.toggle() }
            }
            .padding(2)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().stroke(Theme.cardStroke))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(WindowDragArea())   // drag the panel by its header; text elsewhere stays selectable
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
                Text(model.permissionMode.short).font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(model.permissionMode == .bypass ? Theme.pink : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Permission mode: \(model.permissionMode.detail)")
    }

    // MARK: transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        switch item {
                        case .entry(let e): row(e)
                        case .tools(let run): toolGroup(run)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: model.entries.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// Transcript rows, with each run of consecutive tool calls (and their allow/deny notes) folded into one item.
    private var items: [TranscriptItem] {
        var out: [TranscriptItem] = []
        var run: [Entry] = []
        for e in model.entries {
            if e.role == .tool || (e.role == .permission && !run.isEmpty) {
                run.append(e)
            } else {
                if !run.isEmpty { out.append(.tools(run)); run = [] }
                out.append(.entry(e))
            }
        }
        if !run.isEmpty { out.append(.tools(run)) }
        return out
    }

    /// Collapsed: the most recent tool call and a count. Expanded: every call in the run.
    private func toolGroup(_ run: [Entry]) -> some View {
        let key = run[0].id
        let open = expandedTools.contains(key)
        let calls = run.filter { $0.role == .tool }
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if open { expandedTools.remove(key) } else { expandedTools.insert(key) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                    Image(systemName: "gearshape.fill").font(.system(size: 9)).foregroundStyle(Theme.cyan.opacity(0.8))
                    if open {
                        Text(calls.count == 1 ? "1 tool call" : "\(calls.count) tool calls")
                        Spacer(minLength: 0)
                    } else {
                        Text(calls.last?.text ?? "").lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        if calls.count > 1 {
                            Text("\(calls.count)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.7), in: Capsule())
                        }
                    }
                }
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Hide tool calls" : "Show all tool calls")
            if open {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(run) { e in
                        Text(e.text)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(e.role == .tool ? .secondary : .tertiary)
                            .lineLimit(4).textSelection(.enabled)
                            .contextMenu { copyMenu(e.text) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.cardStroke))
    }

    @ViewBuilder private func row(_ e: Entry) -> some View {
        switch e.role {
        case .you:
            HStack {
                Spacer(minLength: 40)
                Text(e.text).font(.system(size: 12)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Theme.accent.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .textSelection(.enabled)
                    .contextMenu { copyMenu(e.text) }
            }
        case .claude:
            Text(e.text).font(.system(size: 12)).lineSpacing(2)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.cardStroke))
                .textSelection(.enabled)
                .contextMenu { copyMenu(e.text) }
        case .tool:
            toolGroup([e])
        case .system, .permission:
            Text(e.text).font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: copy

    @ViewBuilder private func copyMenu(_ text: String) -> some View {
        Button("Copy") { copyToClipboard(text) }
        Button("Copy conversation") { copyToClipboard(conversationText) }
    }

    /// The conversation as plain text (tool and system lines left out).
    private var conversationText: String {
        model.entries.compactMap { e -> String? in
            switch e.role {
            case .you: return "You: " + e.text
            case .claude: return "Claude: " + e.text
            default: return nil
            }
        }.joined(separator: "\n\n")
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: permission + input

    private func permissionBar(_ ask: PermissionAsk) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(Theme.amber)
                Text("Allow \(ask.tool)?").font(.system(size: 11, weight: .semibold))
                Text("or say yes / no").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(ask.summary).font(.system(size: 10, design: .monospaced)).lineLimit(3).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Spacer()
                Button("Deny") { model.answer(ask, allow: false) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Theme.card, in: Capsule())
                    .overlay(Capsule().stroke(Theme.cardStroke))
                Button("Allow") { model.answer(ask, allow: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 4)
                    .background(Theme.accent, in: Capsule())
            }
        }
        .padding(10)
        .background(Theme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.amber.opacity(0.35)))
    }

    private var inputRow: some View {
        let hasText = !model.draft.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 6) {
            TextField("Type, or just talk…", text: $model.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { model.submitDraft() }
            Button { model.submitDraft() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 17))
                    .foregroundStyle(hasText ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.secondary.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .disabled(!hasText)
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.cardStroke))
        .padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 4)
    }

    private func iconButton(_ name: String, help: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.secondary))
                .frame(width: 22, height: 22)
                .background(active ? Theme.violet.opacity(0.18) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
