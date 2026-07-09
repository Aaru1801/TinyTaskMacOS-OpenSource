import Foundation
import CoreGraphics

/// A simple, line-oriented, hand-editable plain-text macro format ("TRM").
///
/// Header (line 1):  `TINYRECORDER 1`
/// Each event line:  optional `@<seconds>` absolute-time prefix, then a VERB + args.
/// Comments start with `#`; blank lines are ignored; verbs are case-insensitive.
///
///   MOVE x y
///   DRAG x y BTN
///   DOWN x y BTN [clicks=N]
///   UP   x y BTN [clicks=N]        BTN ∈ { L | R | M | <int> }
///   SCROLL dy [dx]
///   KEYDOWN <key> [+MODS]
///   KEYUP   <key> [+MODS]          <key> = symbolic name or #<decimal> raw keycode
///   FLAGS   <key> <maskhex>
///   WAIT ms                        pure delay, emits no event
enum TextMacroFormat {

    // MARK: - Export

    static func export(_ events: [RecordedEvent]) -> String {
        var lines = ["TINYRECORDER 1"]
        for e in events {
            let t = String(format: "@%.3f", e.time)
            let mods = modSuffix(e.flags)
            switch e.kind {
            case .mouseMoved:
                lines.append("\(t)  MOVE \(coord(e.x)) \(coord(e.y))")
            case .leftMouseDragged:
                lines.append("\(t)  DRAG \(coord(e.x)) \(coord(e.y)) L")
            case .rightMouseDragged:
                lines.append("\(t)  DRAG \(coord(e.x)) \(coord(e.y)) R")
            case .otherMouseDragged:
                lines.append("\(t)  DRAG \(coord(e.x)) \(coord(e.y)) M")
            case .leftMouseDown:
                lines.append("\(t)  DOWN \(coord(e.x)) \(coord(e.y)) L\(clicks(e))")
            case .leftMouseUp:
                lines.append("\(t)  UP \(coord(e.x)) \(coord(e.y)) L\(clicks(e))")
            case .rightMouseDown:
                lines.append("\(t)  DOWN \(coord(e.x)) \(coord(e.y)) R\(clicks(e))")
            case .rightMouseUp:
                lines.append("\(t)  UP \(coord(e.x)) \(coord(e.y)) R\(clicks(e))")
            case .otherMouseDown:
                lines.append("\(t)  DOWN \(coord(e.x)) \(coord(e.y)) M\(clicks(e))")
            case .otherMouseUp:
                lines.append("\(t)  UP \(coord(e.x)) \(coord(e.y)) M\(clicks(e))")
            case .scrollWheel:
                lines.append("\(t)  SCROLL \(e.scrollDeltaY) \(e.scrollDeltaX)")
            case .keyDown:
                lines.append("\(t)  KEYDOWN \(keyName(e.keyCode))\(mods)")
            case .keyUp:
                lines.append("\(t)  KEYUP \(keyName(e.keyCode))\(mods)")
            case .flagsChanged:
                lines.append("\(t)  FLAGS \(keyName(e.keyCode)) 0x\(String(e.flags, radix: 16))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func coord(_ v: CGFloat) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
    private static func clicks(_ e: RecordedEvent) -> String {
        e.clickCount > 1 ? " clicks=\(e.clickCount)" : ""
    }
    private static func modSuffix(_ flags: UInt64) -> String {
        var parts: [String] = []
        if flags & ModFlag.command != 0 { parts.append("CMD") }
        if flags & ModFlag.shift   != 0 { parts.append("SHIFT") }
        if flags & ModFlag.control != 0 { parts.append("CTRL") }
        if flags & ModFlag.option  != 0 { parts.append("OPT") }
        if flags & ModFlag.capsLock != 0 { parts.append("CAPS") }
        if flags & ModFlag.fn      != 0 { parts.append("FN") }
        return parts.isEmpty ? "" : " +" + parts.joined(separator: "+")
    }

    // MARK: - Import

    static func parse(_ text: String) throws -> MacroImportResult {
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = rawLines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              first.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("TINYRECORDER") else {
            throw MacroImportError.notTextFormat("missing 'TINYRECORDER' header line.")
        }

        var events: [RecordedEvent] = []
        var skipped = 0
        var implicitTime: TimeInterval = 0   // advances via WAIT / fallback when no @time

        var sawHeader = false
        for (idx, raw) in rawLines.enumerated() {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if !sawHeader {
                if line.uppercased().hasPrefix("TINYRECORDER") { sawHeader = true; continue }
            }

            // Optional @time prefix.
            var explicitTime: TimeInterval?
            if line.hasPrefix("@") {
                let sp = line.firstIndex(of: " ") ?? line.firstIndex(of: "\t")
                if let sp {
                    let tStr = String(line[line.index(after: line.startIndex)..<sp])
                    explicitTime = Self.finiteTime(tStr)
                    line = String(line[sp...]).trimmingCharacters(in: .whitespaces)
                }
            }

            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let verb = tokens.first?.uppercased() else { continue }
            let args = Array(tokens.dropFirst())
            let t = explicitTime ?? implicitTime

            do {
                if let ev = try parseLine(verb: verb, args: args, time: t) {
                    events.append(ev)
                    implicitTime = ev.time
                } else {
                    // WAIT: advance the implicit clock, emit nothing.
                    if verb == "WAIT", let ms = Double(args.first ?? ""), ms.isFinite {
                        implicitTime = t + max(0, ms) / 1000.0
                    }
                }
                if let et = explicitTime { implicitTime = max(implicitTime, et) }
            } catch {
                _ = idx
                skipped += 1
            }
        }

        guard !events.isEmpty else {
            throw MacroImportError.notTextFormat("no events found.")
        }
        // Ensure non-decreasing, normalized timeline.
        events.sort { $0.time < $1.time }
        return MacroImportResult(events: events, parsed: events.count, skipped: skipped, warning: nil)
    }

    private enum ParseError: Error { case bad }

    private static func parseLine(verb: String, args: [String], time: TimeInterval) throws -> RecordedEvent? {
        func num(_ i: Int) throws -> CGFloat {
            guard i < args.count, let v = Double(args[i]), v.isFinite else { throw ParseError.bad }
            return CGFloat(v)
        }
        func button(_ s: String) -> (RecordedEvent.Kind, RecordedEvent.Kind, RecordedEvent.Kind, Int64) {
            // returns (down, up, drag, mouseButton)
            switch s.uppercased() {
            case "R": return (.rightMouseDown, .rightMouseUp, .rightMouseDragged, 1)
            case "M": return (.otherMouseDown, .otherMouseUp, .otherMouseDragged, 2)
            case "L": return (.leftMouseDown, .leftMouseUp, .leftMouseDragged, 0)
            default:
                let n = Int64(s) ?? 0
                return (.otherMouseDown, .otherMouseUp, .otherMouseDragged, n)
            }
        }
        func clickCount() -> Int64 {
            for a in args where a.lowercased().hasPrefix("clicks=") {
                return Int64(a.dropFirst("clicks=".count)) ?? 1
            }
            return 1
        }

        switch verb {
        case "MOVE":
            return .make(.mouseMoved, time: time, x: try num(0), y: try num(1))
        case "DRAG":
            let b = button(args.count > 2 ? args[2] : "L")
            return .make(b.2, time: time, x: try num(0), y: try num(1), mouseButton: b.3)
        case "DOWN":
            let b = button(args.count > 2 ? args[2] : "L")
            return .make(b.0, time: time, x: try num(0), y: try num(1), mouseButton: b.3, clickCount: clickCount())
        case "UP":
            let b = button(args.count > 2 ? args[2] : "L")
            return .make(b.1, time: time, x: try num(0), y: try num(1), mouseButton: b.3, clickCount: clickCount())
        case "SCROLL":
            let dy = Int32(args.first ?? "0") ?? 0
            let dx = args.count > 1 ? (Int32(args[1]) ?? 0) : 0
            return .make(.scrollWheel, time: time, scrollDeltaY: dy, scrollDeltaX: dx)
        case "KEYDOWN":
            guard let code = keyCode(args.first ?? "") else { throw ParseError.bad }
            return .make(.keyDown, time: time, keyCode: code, flags: mods(args))
        case "KEYUP":
            guard let code = keyCode(args.first ?? "") else { throw ParseError.bad }
            return .make(.keyUp, time: time, keyCode: code, flags: mods(args))
        case "FLAGS":
            guard let code = keyCode(args.first ?? "") else { throw ParseError.bad }
            let mask = args.count > 1 ? parseHex(args[1]) : 0
            return .make(.flagsChanged, time: time, keyCode: code, flags: mask)
        case "WAIT":
            return nil
        default:
            throw ParseError.bad
        }
    }

    /// Parse a seconds value, rejecting NaN/±inf and clamping negatives to 0.
    private static func finiteTime(_ s: String) -> TimeInterval? {
        guard let v = TimeInterval(s), v.isFinite else { return nil }
        return max(0, v)
    }

    private static func parseHex(_ s: String) -> UInt64 {
        let v = s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
        return UInt64(v, radix: 16) ?? 0
    }

    private static func mods(_ args: [String]) -> UInt64 {
        for a in args where a.hasPrefix("+") {
            var f: UInt64 = 0
            for part in a.dropFirst().split(separator: "+") {
                switch part.uppercased() {
                case "CMD": f |= ModFlag.command
                case "SHIFT": f |= ModFlag.shift
                case "CTRL": f |= ModFlag.control
                case "OPT", "ALT": f |= ModFlag.option
                case "CAPS": f |= ModFlag.capsLock
                case "FN": f |= ModFlag.fn
                default: break
                }
            }
            return f
        }
        return 0
    }

    // MARK: - Key name <-> macOS keycode

    private static let nameToCode: [String: UInt16] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9,
        "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17, "O": 31, "U": 32,
        "I": 34, "P": 35, "L": 37, "J": 38, "K": 40, "N": 45, "M": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        "SPACE": 49, "ENTER": 36, "RETURN": 36, "TAB": 48, "BACKSPACE": 51, "DEL": 117,
        "DELETE": 51, "ESC": 53, "ESCAPE": 53,
        "LEFT": 123, "RIGHT": 124, "UP": 126, "DOWN": 125,
        "HOME": 115, "END": 119, "PAGEUP": 116, "PAGEDOWN": 121,
        "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97, "F7": 98, "F8": 100,
        "F9": 101, "F10": 109, "F11": 103, "F12": 111,
        "SHIFT": 56, "CTRL": 59, "CONTROL": 59, "OPT": 58, "ALT": 58, "OPTION": 58,
        "CMD": 55, "COMMAND": 55, "CAPS": 57, "CAPSLOCK": 57, "FN": 63,
        "MINUS": 27, "EQUAL": 24, "LEFTBRACKET": 33, "RIGHTBRACKET": 30, "BACKSLASH": 42,
        "SEMICOLON": 41, "QUOTE": 39, "COMMA": 43, "PERIOD": 47, "SLASH": 44, "GRAVE": 50,
    ]
    private static let codeToName: [UInt16: String] = {
        var m: [UInt16: String] = [:]
        // Prefer the first (canonical) name for each code.
        for (k, v) in nameToCode where m[v] == nil { m[v] = k }
        return m
    }()

    private static func keyCode(_ s: String) -> UInt16? {
        if s.hasPrefix("#") { return UInt16(s.dropFirst()) }
        return nameToCode[s.uppercased()]
    }
    private static func keyName(_ code: UInt16) -> String {
        codeToName[code] ?? "#\(code)"
    }
}
