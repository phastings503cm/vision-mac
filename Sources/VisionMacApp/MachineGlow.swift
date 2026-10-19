import AppKit
import SwiftUI
import VisionHarnessCore

// MARK: - "Machine in use by Vision AI"
//
// While the agent is driving this Mac — moving the mouse, typing, bringing apps
// forward — the edges of the whole screen glow and a small label says who is
// at the controls: which chat has the real mouse (and how many wait), or that
// chats are working in the background and the mouse is free (see GlowStatus).
// The glow is a floating, click-through panel covering the screen: it can
// never take input itself; ⌘. stops a chat and ⌃⌥⌘. stops all AI control
// from any app.

/// What the pill says; the view follows it while the panel is up.
@MainActor
@Observable
final class MachineGlowModel {
    var text = GlowStatus.pill(control: .idle, work: [])
}

/// Owns the overlay panel and follows the transport's `machineInUse` flag.
@MainActor
final class MachineGlowController {
    static let shared = MachineGlowController()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    let model = MachineGlowModel()

    /// The pill's text: who has the mouse, who waits, or that the AI works in the background.
    func setText(_ text: String) {
        if model.text != text { model.text = text }
    }

    /// Show the glow while `active`; remove it (with a small linger) once not.
    func setActive(_ active: Bool) {
        if active {
            hideTask?.cancel()
            hideTask = nil
            if panel == nil { show() }
        } else if panel != nil, hideTask == nil {
            // Linger a moment: control tools run in bursts, and a flickering
            // border is worse than a slightly-long one.
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    private func show() {
        // No app running (unit tests): nothing to draw on.
        guard NSApp != nil else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: MachineGlowView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
        hideTask = nil
    }
}

/// The glow itself: an animated border inset around the screen edges and the
/// label bottom-center. Drawn with almost no layer cost (a stroked gradient
/// and one text), refreshed by its own timeline so the shimmer moves.
struct MachineGlowView: View {
    let model: MachineGlowModel
    @State private var shimmer: Bool = false

    var body: some View {
        ZStack {
            // The border: a rounded-rect stroke hugging the screen edges,
            // gradient-shifting so it reads as alive without being loud.
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color(red: 0.20, green: 0.95, blue: 0.55).opacity(0.85),
                                 Color(red: 0.15, green: 0.75, blue: 0.95).opacity(0.55),
                                 Color(red: 0.20, green: 0.95, blue: 0.55).opacity(0.85)],
                        startPoint: shimmer ? .topLeading : .bottomTrailing,
                        endPoint: shimmer ? .bottomTrailing : .topLeading),
                    lineWidth: 5)
                .padding(6)
                .shadow(color: Color(red: 0.20, green: 0.95, blue: 0.55).opacity(0.65), radius: 10)

            Label(model.text, systemImage: "visionpro")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.72), in: Capsule())
                .overlay(Capsule().strokeBorder(Color(red: 0.20, green: 0.95, blue: 0.55).opacity(0.6), lineWidth: 1))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 18)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
    }
}
