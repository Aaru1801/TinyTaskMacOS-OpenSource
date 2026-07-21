import SwiftUI
import AppKit

/// Spotlight-inspired command deck for launching macros and common actions
/// without leaving the keyboard. It deliberately floats above both the compact
/// popover and full library so the interaction model stays identical everywhere.
struct QuickRunPalette: View {
    let controller: MenuBarController
    var compact = false
    let onDismiss: () -> Void

    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var library: MacroLibrary

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var queryFocused: Bool

    private enum Action {
        case macro(UUID)
        case record
        case play
        case importFile
        case edit
        case settings
    }

    private struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let tint: Color
        let action: Action
        var trailing: String? = nil
        var searchText: String = ""
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.20)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                searchHeader
                Divider().opacity(0.45)
                resultsList
                Divider().opacity(0.45)
                keyboardFooter
            }
            .frame(maxWidth: compact ? 370 : 500)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color.white.opacity(0.075), .clear, Brand.sigViolet.opacity(0.035)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.65)
                    )
            )
            .shadow(color: .black.opacity(0.30), radius: 28, y: 14)
            .interactiveLift3D(intensity: 0.14, cornerRadius: 16)
            .padding(.horizontal, compact ? 14 : 24)
        }
        .onAppear {
            selectedIndex = 0
            DispatchQueue.main.async { queryFocused = true }
        }
        .onChange(of: query) {
            selectedIndex = 0
        }
        .onChange(of: entries.count) { _, count in
            selectedIndex = max(0, min(selectedIndex, max(0, count - 1)))
        }
        .onExitCommand(perform: onDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick Run")
    }

    private var searchHeader: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Brand.sigViolet, Brand.sigBlue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .shadow(color: Brand.sigViolet.opacity(0.28), radius: 5, y: 2)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)

            TextField("Run a macro or command", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: compact ? 13 : 14, weight: .medium))
                .focused($queryFocused)
                .onSubmit(activateSelected)
                .onMoveCommand { direction in
                    switch direction {
                    case .down: moveSelection(by: 1)
                    case .up: moveSelection(by: -1)
                    default: break
                    }
                }

            if query.isEmpty {
                KeyCapView(text: "⌘K", size: .sm)
            } else {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Quick Run search")
            }

            KeyCapView(text: "esc", size: .sm)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    @ViewBuilder
    private var resultsList: some View {
        if entries.isEmpty {
            VStack(spacing: 7) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Brand.sigViolet)
                Text("No match for “\(query)”")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("Try a macro name, tag, or command.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 126)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            resultRow(entry, selected: index == selectedIndex)
                                .id(entry.id)
                                .onHover { hovering in
                                    if hovering { selectedIndex = index }
                                }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: compact ? 292 : 336)
                .onChange(of: selectedIndex) { _, index in
                    guard entries.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(entries[index].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func resultRow(_ entry: Entry, selected: Bool) -> some View {
        Button { activate(entry) } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(entry.tint.opacity(selected ? 0.20 : 0.11))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(entry.tint.opacity(selected ? 0.40 : 0.18), lineWidth: 0.5)
                        )
                    Image(systemName: entry.symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(entry.tint)
                }
                .frame(width: 29, height: 29)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(entry.subtitle)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                if let trailing = entry.trailing {
                    Text(trailing)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if selected {
                    KeyCapView(text: "↵", size: .sm)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? entry.tint.opacity(0.105) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(entry.tint.opacity(selected ? 0.22 : 0), lineWidth: 0.6)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .interactiveLift3D(intensity: selected ? 0.32 : 0.18, cornerRadius: 10)
        .accessibilityLabel(
            "\(entry.title), \(entry.subtitle)" +
                (entry.trailing.map { ", \($0)" } ?? "")
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var keyboardFooter: some View {
        HStack(spacing: 12) {
            keyboardHint("↑↓", "navigate")
            keyboardHint("↵", "run")
            Spacer()
            Text(query.isEmpty ? "RECENT + FAVORITES" : "BEST MATCHES")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 13)
        .frame(height: 34)
    }

    private func keyboardHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            KeyCapView(text: key, size: .sm)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    private var entries: [Entry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let commands = commandEntries.filter {
            trimmed.isEmpty || fuzzyScore(trimmed, in: $0.title + " " + $0.subtitle) != nil
        }

        let orderedMacros = library.macros.sorted { lhs, rhs in
            if lhs.favorite != rhs.favorite { return lhs.favorite }
            return (lhs.lastPlayedAt ?? lhs.modifiedAt) > (rhs.lastPlayedAt ?? rhs.modifiedAt)
        }
        let macros: [SavedMacro]
        if trimmed.isEmpty {
            macros = Array(orderedMacros.prefix(compact ? 5 : 6))
        } else {
            macros = orderedMacros
                .compactMap { macro -> (SavedMacro, Int)? in
                    let haystack = ([macro.name, macro.notes] + macro.tags).joined(separator: " ")
                    return fuzzyScore(trimmed, in: haystack).map { (macro, $0) }
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }

        let macroEntries = macros.map { macro in
            Entry(
                id: "macro-\(macro.id.uuidString)",
                title: macro.name,
                subtitle: "\(macro.eventCount) events · \(quickDuration(macro.duration))" +
                    (macro.tags.isEmpty ? "" : " · \(macro.tags.prefix(2).joined(separator: ", "))"),
                symbol: macro.icon ?? "wave.3.right",
                tint: cardAccentColor(for: macro.accent),
                action: .macro(macro.id),
                trailing: macro.loops <= 0 ? "∞" : (macro.loops > 1 ? "×\(macro.loops)" : nil),
                searchText: ([macro.name, macro.notes] + macro.tags).joined(separator: " ")
            )
        }

        let combined = macroEntries + commands
        guard !trimmed.isEmpty else { return combined }
        return combined.sorted { lhs, rhs in
            let lhsScore = fuzzyScore(trimmed, in: lhs.title + " " + lhs.subtitle + " " + lhs.searchText) ?? Int.min
            let rhsScore = fuzzyScore(trimmed, in: rhs.title + " " + rhs.subtitle + " " + rhs.searchText) ?? Int.min
            return lhsScore > rhsScore
        }
    }

    private var commandEntries: [Entry] {
        var commands: [Entry] = [
            Entry(
                id: "command-record",
                title: state.recordingCountdownActive ? "Cancel Recording" : (recorder.isRecording ? "Stop & Save Recording" : "Start Recording"),
                subtitle: recorder.isRecording ? "Finish the live capture safely" : "Capture mouse and keyboard input",
                symbol: recorder.isRecording ? "stop.fill" : "record.circle",
                tint: Brand.red500,
                action: .record,
                trailing: state.recordHotkey.name
            ),
            Entry(
                id: "command-import",
                title: "Import Macro…",
                subtitle: "TinyRecorder, TinyTask, JSON, or text",
                symbol: "square.and.arrow.down",
                tint: Brand.sigBlue,
                action: .importFile,
                trailing: "⌘O"
            ),
        ]
        if player.isPlaying || !recorder.events.isEmpty {
            commands.insert(Entry(
                id: "command-play",
                title: player.isPlaying ? "Stop Playback" : "Play Current Macro",
                subtitle: library.currentMacro?.name ?? "Replay the current event buffer",
                symbol: player.isPlaying ? "stop.fill" : "play.fill",
                tint: player.isPlaying ? Brand.red500 : Brand.sigGreen,
                action: .play,
                trailing: player.isPlaying ? state.stopHotkey.name : state.playHotkey.name
            ), at: 1)
        }
        if library.currentMacro != nil {
            commands.append(Entry(
                id: "command-edit",
                title: "Open Current in Editor",
                subtitle: library.currentMacro?.name ?? "Current macro",
                symbol: "slider.horizontal.below.rectangle",
                tint: Brand.sigAmber,
                action: .edit,
                trailing: "⌥⌘E"
            ))
        }
        commands.append(Entry(
            id: "command-settings",
            title: "Settings…",
            subtitle: "Hotkeys, capture, playback, and appearance",
            symbol: "gearshape.fill",
            tint: Brand.sigViolet,
            action: .settings,
            trailing: "⌘,"
        ))
        return commands
    }

    private func moveSelection(by delta: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + entries.count) % entries.count
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func activateSelected() {
        guard entries.indices.contains(selectedIndex) else { return }
        activate(entries[selectedIndex])
    }

    private func activate(_ entry: Entry) {
        onDismiss()
        DispatchQueue.main.async {
            switch entry.action {
            case .macro(let id): controller.playMacroByID(id)
            case .record: controller.toggleRecording()
            case .play:
                if player.isPlaying { controller.stopAll() }
                else { controller.play() }
            case .importFile: controller.open()
            case .edit: controller.openEditor()
            case .settings: controller.showSettingsWindow()
            }
        }
    }

    /// Compact subsequence matcher with adjacency/word-start bonuses. It feels
    /// forgiving like Spotlight while keeping deterministic, dependency-free UI.
    private func fuzzyScore(_ needle: String, in haystack: String) -> Int? {
        let needle = Array(needle.lowercased())
        let haystack = Array(haystack.lowercased())
        guard !needle.isEmpty else { return 0 }

        var score = 0
        var cursor = 0
        var previousMatch: Int?
        for (needleIndex, character) in needle.enumerated() {
            guard cursor <= haystack.count else { return nil }
            guard let relative = haystack[cursor...].firstIndex(of: character) else { return nil }
            let index = relative
            score += 10
            if let previousMatch, index == previousMatch + 1 { score += 9 }
            if index == 0 || haystack[index - 1].isWhitespace { score += 6 }
            score -= min(4, index - cursor)
            previousMatch = index
            cursor = index + 1
            if needleIndex < needle.count - 1, cursor >= haystack.count { return nil }
        }
        return score - max(0, haystack.count - needle.count) / 12
    }

    private func quickDuration(_ seconds: TimeInterval) -> String {
        let safe = max(0, seconds.isFinite ? seconds : 0)
        if safe < 10 { return String(format: "%.1fs", safe) }
        if safe < 60 { return "\(Int(safe.rounded()))s" }
        return String(format: "%d:%02d", Int(safe) / 60, Int(safe) % 60)
    }
}
