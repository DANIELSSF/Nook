import SwiftUI

// Entering a subagent's own conversation, like Claude's agent view in its terminal. A click on an agent's row in a list
// (`SubagentList`) shows that agent's record in the mirror (`TerminalSession.viewedAgent`); while it does, a slim bar over
// the mirror says whose conversation it is, with the way back, and the composer keeps writing to Claude.
//
// The bar and the placeholder never animate layout: they come in with a fade of their own opacity, so the mirror below
// them changes size at once and only once.

/// The bar over the mirror while an agent's conversation is shown: its name, model, kind and state, what it is doing
/// right now, and a button back to Claude's conversation (Esc does the same).
struct AgentViewBar: View {
    /// The agent as the list knows it; nil once it left the list (finished a while ago) but its record is still shown.
    var agent: SubagentActivity?
    var animated = true
    var onBack: () -> Void
    @State private var shown = false
    @State private var overBack = false

    static let height: CGFloat = 28

    var body: some View {
        HStack(spacing: 8) {
            backButton
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 12)
            if let agent {
                // What does not fit goes away in this order: the live status first, then the agent's type. The name and the
                // model stay, and the name is cut only when even they do not fit.
                ViewThatFits(in: .horizontal) {
                    info(agent, kind: true, status: true, cutsName: false)
                    info(agent, kind: false, status: true, cutsName: false)
                    info(agent, kind: true, status: false, cutsName: false)
                    info(agent, kind: false, status: false, cutsName: true)
                }
            } else {
                Text("Agente").font(.system(size: 10.5, weight: .semibold))
                Spacer(minLength: 6)
                Text("Conversación de un agente anterior").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.leading, 5).padding(.trailing, 11).frame(height: Self.height)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 0.5))
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: 0.18)) { shown = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(agent.map { "Conversación del agente \($0.name)" } ?? "Conversación de un agente")
        .help(agent.map { $0.name + "\n" + $0.detail } ?? "")
    }

    private func info(_ agent: SubagentActivity, kind: Bool, status: Bool, cutsName: Bool) -> some View {
        HStack(spacing: 8) {
            SubagentStateGlyph(state: agent.state, animated: animated).frame(width: 13)
            Text(agent.name).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                .fixedSize(horizontal: !cutsName, vertical: false)
            if let model = AgentModelName.short(agent.model) { AgentChip(text: model, prominent: true) }
            if kind, let type = agent.kind { AgentChip(text: type, prominent: false) }
            Spacer(minLength: 6)
            if status { self.status(agent).frame(maxWidth: Self.statusWidth, alignment: .trailing) }
        }
    }

    /// The most the live status takes; a longer one is cut in its middle (a path) or its end.
    static let statusWidth: CGFloat = 190

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 8.5, weight: .bold))
                Text("Volver a Claude").font(.system(size: 10.5, weight: .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(Color.primary.opacity(0.9))
            .padding(.horizontal, 8).frame(height: 20)
            .background(Color.white.opacity(overBack ? 0.17 : 0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { overBack = $0 }
        .help("Volver a la conversación de Claude (Esc)")
        .accessibilityLabel("Volver a Claude")
    }

    /// What the agent does now (a working one), or how it ended.
    @ViewBuilder private func status(_ agent: SubagentActivity) -> some View {
        switch agent.state {
        case .running:
            if let current = agent.activity {
                let parts = AgentActivityLine.parse(current)
                HStack(spacing: 4) {
                    Text("⎿").font(.system(size: 9)).foregroundStyle(Color.secondary.opacity(0.7))
                    Text(parts.tool).font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(Color.secondary).lineLimit(1).fixedSize()
                    if let argument = parts.argument {
                        Text(argument).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Color.secondary.opacity(0.8))
                            .lineLimit(1).truncationMode(parts.isPath ? .middle : .tail)
                    }
                }
            } else {
                Text(agent.toolUses != nil ? "Pensando…" : "Trabajando…").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        case .done:
            Text(Self.endingText(agent)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        case .failed:
            Text(Self.endingText(agent)).font(.system(size: 10)).foregroundStyle(AgentPalette.failed).lineLimit(1)
        }
    }

    /// "Listo · 3m 12s" for a finished agent (the list has the rest of its counters); a failed one says what happened.
    static func endingText(_ agent: SubagentActivity) -> String {
        switch agent.state {
        case .running: return agent.detail
        case .done: return "Listo" + (agent.duration.map { " · " + $0 } ?? "")
        case .failed: return agent.detail
        }
    }
}

/// Shown over the empty mirror when the agent has no record to read yet. It waits a moment first: right after entering,
/// the record is being read and the mirror is empty for a blink, which is no reason to say anything.
struct AgentViewPlaceholder: View {
    var delay = 0.9
    @State private var shown = false

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "text.bubble").font(.system(size: 15, weight: .light)).foregroundStyle(.tertiary)
            Text("Este agente aún no tiene registro").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text("Su conversación aparecerá aquí en cuanto empiece.").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center).padding(.horizontal, 24)
        .opacity(shown ? 1 : 0)
        .task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { shown = true } }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
