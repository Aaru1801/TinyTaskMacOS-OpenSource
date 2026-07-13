import Cocoa

// CLI playback mode: ./TinyRecorder --play /path/to/macro.tinyrec
// Used by exported .command scripts. Exempt from the single-instance guard —
// it never touches the library.
let args = CommandLine.arguments
if args.count >= 3, args[1] == "--play" {
    let path = args[2]
    let url = URL(fileURLWithPath: path)
    do {
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder()
        let events: [RecordedEvent]
        let speed: Double
        let loops: Int
        if let saved = try? dec.decode(SavedMacro.self, from: data), !saved.events.isEmpty {
            events = saved.events
            speed = saved.speed
            // Continuous (0) would run forever with no in-app stop hotkey — clamp.
            loops = max(1, saved.loops)
        } else {
            let macro = try dec.decode(Macro.self, from: data)
            events = macro.events
            speed = 1.0
            loops = 1
        }

        // Post events from a background thread with plain sleeps — no run-loop
        // pumping, no MainActor hops, so timing stays faithful to the recording.
        let semaphore = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            Player.playSynchronously(events: events, loops: loops, speed: speed)
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("TinyRecorder: failed to play \(path): \(error)\n".utf8))
        exit(1)
    }
}

// CLI conversion mode: ./TinyRecorder --convert in.rec out.tinyrec
// Converts TinyTask .rec or text .txt/.trm to .tinyrec (JSON) or .txt (TRM),
// chosen by the OUTPUT extension. No GUI, exempt from the single-instance guard.
if args.count >= 4, args[1] == "--convert" {
    let inURL = URL(fileURLWithPath: args[2])
    let outURL = URL(fileURLWithPath: args[3])
    do {
        let data = try Data(contentsOf: inURL)
        let inExt = inURL.pathExtension.lowercased()
        let result: MacroImportResult
        switch inExt {
        case "rec":
            result = try TinyTaskImporter.parse(data)
        case "txt", "trm":
            guard let text = String(data: data, encoding: .utf8) else {
                throw MacroImportError.notTextFormat("input is not UTF-8 text.")
            }
            result = try TextMacroFormat.parse(text)
        case "tinyrec", "json":
            let dec = JSONDecoder()
            if let saved = try? dec.decode(SavedMacro.self, from: data) {
                result = MacroImportResult(events: saved.events, parsed: saved.events.count, skipped: 0, warning: nil)
            } else {
                let macro = try dec.decode(Macro.self, from: data)
                result = MacroImportResult(events: macro.events, parsed: macro.events.count, skipped: 0, warning: nil)
            }
        default:
            // Sniff.
            if data.count % 20 == 0, let r = try? TinyTaskImporter.parse(data) {
                result = r
            } else if let text = String(data: data, encoding: .utf8), let r = try? TextMacroFormat.parse(text) {
                result = r
            } else {
                throw MacroImportError.unreadable("unrecognized input format.")
            }
        }

        let normalizedEvents = RecordedEvent.normalized(result.events)
        let outExt = outURL.pathExtension.lowercased()
        let name = inURL.deletingPathExtension().lastPathComponent
        if outExt == "txt" || outExt == "trm" {
            try TextMacroFormat.export(normalizedEvents).write(to: outURL, atomically: true, encoding: .utf8)
        } else {
            let macro = SavedMacro(name: name, events: normalizedEvents)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted]
            try enc.encode(macro).write(to: outURL, options: .atomic)
        }

        var msg = "TinyRecorder: converted \(normalizedEvents.count) events -> \(outURL.lastPathComponent)"
        if result.skipped > 0 { msg += " (\(result.skipped) skipped)" }
        if let w = result.warning { msg += "\n  warning: \(w)" }
        FileHandle.standardOutput.write(Data((msg + "\n").utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("TinyRecorder: conversion failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// Single-instance guard: a second copy would double-register Carbon hotkeys,
// run a second event tap, and clobber library.json last-writer-wins.
let myPID = ProcessInfo.processInfo.processIdentifier
let myExec = Bundle.main.executableURL?.resolvingSymlinksInPath()
let twin = NSWorkspace.shared.runningApplications.first { app in
    guard app.processIdentifier != myPID else { return false }
    // Our shipped bundle, or a bundle-less dev build running the *same* binary.
    // Matching only on the executable *name* would clobber any unrelated tool
    // that happens to be called "TinyRecorder".
    if app.bundleIdentifier == "com.tinyrecorder.app" { return true }
    return app.bundleIdentifier == nil
        && app.executableURL?.resolvingSymlinksInPath() == myExec
}
if let twin {
    twin.activate()
    exit(0)
}

// Normal app mode — full Dock app.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
