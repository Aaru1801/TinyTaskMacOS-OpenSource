import Cocoa
import SwiftUI
import Combine

// MARK: - Window controller

final class RecordingHUDController {
    private var window: NSPanel?
    private let recorder: Recorder
    private let onDiscard: () -> Void
    private let onStop:    () -> Void
    private weak var state: AppState?

    init(recorder: Recorder,
         state: AppState?,
         onDiscard: @escaping () -> Void,
         onStop: @escaping () -> Void) {
        self.recorder = recorder
        self.state = state
        self.onDiscard = onDiscard
        self.onStop = onStop
    }

    func show() {
        if window == nil { create() }
        position()
        window?.alphaValue = 0
        window?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            self.window?.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let win = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            win.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.window?.orderOut(nil)
        })
    }

    private func create() {
        let view = RecordingHUDView(
            recorder: recorder,
            state: state,
            onDiscard: onDiscard,
            onStop: onStop
        )
        let host = NSHostingView(rootView: view)
        let fitting = host.fittingSize
        let w: CGFloat = fitting.width  > 0 ? fitting.width  : 320
        let h: CGFloat = fitting.height > 0 ? fitting.height : 240

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        // The HUD floats over the live desktop — the one place real Liquid Glass
        // refraction shines. Host the SwiftUI body INSIDE an NSGlassEffectView so
        // the glass samples real content behind it (macOS 26+); fall back to the
        // HUD vibrancy material on earlier systems.
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 16
            glass.contentView = host
            panel.contentView = glass
        } else {
            let fx = NSVisualEffectView()
            fx.material = .hudWindow
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 16
            fx.layer?.masksToBounds = true
            host.frame = fx.bounds
            host.autoresizingMask = [.width, .height]
            fx.addSubview(host)
            panel.contentView = fx
        }
        window = panel
    }

    private func position() {
        guard let win = window else { return }
        // Position on the screen the user is actually working on.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = win.frame.size
        // Top-right with menu-bar gap.
        let x = visible.maxX - size.width - 24
        let y = visible.maxY - size.height - 12
        win.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }
}

// MARK: - View

struct RecordingHUDView: View {
    @ObservedObject var recorder: Recorder
    weak var state: AppState?
    let onDiscard: () -> Void
    let onStop:  () -> Void

    @State private var pulse = false

    /// The actual configured "stop recording" hotkey — pressing record again toggles off.
    private var stopHotkeyName: String {
        state?.recordHotkey.name ?? "F6"
    }
    /// The "stop everything" hotkey, shown as the discard shortcut affordance.
    private var emergencyHotkeyName: String {
        state?.stopHotkey.name ?? "F7"
    }

    private var minutes: String { String(format: "%02d", Int(recorder.liveDuration) / 60) }
    private var seconds: String { String(format: "%02d", Int(recorder.liveDuration) % 60) }
    private var hundredths: String {
        String(format: "%02d", Int((recorder.liveDuration - floor(recorder.liveDuration)) * 100))
    }

    private var durationLabel: String {
        String(format: "%.1fs", recorder.liveDuration)
    }

    var body: some View {
        let s = recorder.liveStats
        ZStack {
            // Inky translucent layer over the host glass: guarantees legible white
            // content over any desktop, while the NSGlassEffectView behind still
            // refracts. (This is the design's exact approach.)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.52),
                             Color(red: 0.047, green: 0.051, blue: 0.071).opacity(0.52)],
                    startPoint: .top, endPoint: .bottom))

            VStack(alignment: .leading, spacing: 10) {
                // Top row: status + big gradient timer
                HStack(spacing: 10) {
                    RecDot(size: 10)
                    Text("RECORDING")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Color.white.opacity(0.60))
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("\(minutes):\(seconds)")
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .tracking(-0.5)
                        Text(".\(hundredths)")
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .opacity(0.55)
                    }
                    .foregroundStyle(LinearGradient(
                        colors: [.white, Color(red: 0.77, green: 0.78, blue: 0.82)],
                        startPoint: .top, endPoint: .bottom))
                    .contentTransition(.numericText())
                }

                // Event-track panel
                VStack(spacing: 2) {
                    LiveWaveform(events: recorder.events)
                        .frame(height: 28)
                    HStack {
                        Text("0s")
                        Spacer()
                        Text(durationLabel).foregroundStyle(Color.white.opacity(0.55))
                        Spacer()
                        Text("LIVE")
                    }
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.35))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.30))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)))

                // 4-stat grid
                HStack(spacing: 6) {
                    HUDStat(icon: "cursorarrow.click", value: s.clicks, label: "Clicks", tint: Brand.sigGreen)
                    HUDStat(icon: "keyboard",          value: s.keys,   label: "Keys",   tint: Brand.sigBlue)
                    HUDStat(icon: "arrow.up.and.down", value: s.scrolls, label: "Scroll", tint: Brand.sigTeal)
                    HUDStat(icon: "hand.draw",         value: s.drags,  label: "Drag",   tint: Brand.sigViolet)
                }

                // Action bar
                HStack(spacing: 6) {
                    HUDButton(title: "Discard", icon: "trash", shortcut: emergencyHotkeyName, tint: nil, action: onDiscard)
                    HUDButton(title: "Stop", icon: "stop.fill", shortcut: stopHotkeyName, tint: Brand.red500, action: onStop)
                }
            }
            .padding(14)
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        )
        .environment(\.colorScheme, .dark)
        .onAppear { pulse = recorder.isRecording }
        .onChange(of: recorder.isRecording) { _, recording in pulse = recording }
    }
}

// MARK: - HUD pieces

private struct LiveWaveform: View {
    let events: [RecordedEvent]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // Show last ~150 events as vertical bars sliding across.
            let recent = Array(events.suffix(150))
            let count = max(1, recent.count)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: h)

                ForEach(0..<recent.count, id: \.self) { i in
                    let ev = recent[i]
                    let x = (CGFloat(i) / CGFloat(count)) * w
                    let isImpact = Brand.isImpact(ev.kind)
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Brand.eventColor(ev.kind).opacity(isImpact ? 1.0 : 0.6))
                        .frame(
                            width: isImpact ? 2 : 1.2,
                            height: isImpact ? h : h * 0.45
                        )
                        .offset(x: x)
                }
            }
        }
    }
}

private struct HUDStat: View {
    let icon: String
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text("\(value)")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .tracking(-0.2)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.4), value: value)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(0.3)
                .foregroundStyle(Color.white.opacity(0.40))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }
}

private struct HUDButton: View {
    let title: String
    let icon: String
    let shortcut: String
    let tint: Color?
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(-0.1)
                Spacer(minLength: 0)
                KeyCapView(text: shortcut, size: .sm, variant: .glass)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        tint != nil
                            ? AnyShapeStyle(Brand.redGradient)
                            : AnyShapeStyle(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(tint != nil ? 0.22 : 0.10), lineWidth: 0.5)
                    )
                    .shadow(
                        color: (tint ?? .black).opacity(hovered ? 0.32 : (tint != nil ? 0.28 : 0.14)),
                        radius: hovered ? 7 : 4, y: 2
                    )
            )
        }
        .buttonStyle(HoverPressButtonStyle())
        .onHover { hovered = $0 }
        .interactiveLift3D(intensity: 0.82, cornerRadius: 12)
    }
}
