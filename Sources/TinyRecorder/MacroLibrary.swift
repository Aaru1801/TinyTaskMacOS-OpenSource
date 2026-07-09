import Foundation
import Combine

/// A saved macro entry in the library.
struct SavedMacro: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var events: [RecordedEvent]
    var createdAt: Date
    var modifiedAt: Date
    var version: Int = 3

    // Playback configuration
    var loops: Int = 1
    var speed: Double = 1.0

    // Personalization
    /// SF Symbol name or single emoji used as the card icon.
    var icon: String?
    /// Card accent color (hex like "#F44" or named "blue", "green", etc.). Defaults pick auto.
    var accent: String?
    /// User-defined tags for filtering / grouping.
    var tags: [String] = []
    /// Pinned to the top of the library and to the "Favorites" library filter.
    var favorite: Bool = false
    /// Per-macro global hotkey (F-key only, for reliability).
    var hotkey: HotkeyBinding?
    /// Free-form user notes shown in the editor inspector.
    var notes: String = ""
    /// Optional chain — when this macro finishes playing, immediately play this next macro.
    var chainTo: UUID?

    // Statistics
    var playCount: Int = 0
    var lastPlayedAt: Date?
    var totalRunTime: TimeInterval = 0

    var duration: TimeInterval { events.last?.time ?? 0 }
    var eventCount: Int { events.count }
    var clickCount: Int {
        events.filter { $0.kind == .leftMouseDown || $0.kind == .rightMouseDown || $0.kind == .otherMouseDown }.count
    }
    var keyCount: Int { events.filter { $0.kind.isKey }.count }
    var scrollCount: Int { events.filter { $0.kind == .scrollWheel }.count }

    enum CodingKeys: String, CodingKey {
        case id, name, events, createdAt, modifiedAt, version
        case loops, speed
        case icon, accent, tags, favorite, hotkey, notes, chainTo
        case playCount, lastPlayedAt, totalRunTime
    }

    init(id: UUID = UUID(),
         name: String,
         events: [RecordedEvent],
         createdAt: Date = Date(),
         modifiedAt: Date = Date(),
         version: Int = 3,
         loops: Int = 1,
         speed: Double = 1.0,
         icon: String? = nil,
         accent: String? = nil,
         tags: [String] = [],
         favorite: Bool = false,
         hotkey: HotkeyBinding? = nil,
         notes: String = "",
         chainTo: UUID? = nil,
         playCount: Int = 0,
         lastPlayedAt: Date? = nil,
         totalRunTime: TimeInterval = 0) {
        self.id = id
        self.name = name
        self.events = events
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.version = version
        self.loops = loops
        self.speed = speed
        self.icon = icon
        self.accent = accent
        self.tags = tags
        self.favorite = favorite
        self.hotkey = hotkey
        self.notes = notes
        self.chainTo = chainTo
        self.playCount = playCount
        self.lastPlayedAt = lastPlayedAt
        self.totalRunTime = totalRunTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.events = try c.decode([RecordedEvent].self, forKey: .events)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 3
        self.loops = try c.decodeIfPresent(Int.self, forKey: .loops) ?? 1
        self.speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1.0
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
        self.accent = try c.decodeIfPresent(String.self, forKey: .accent)
        self.tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        self.hotkey = try c.decodeIfPresent(HotkeyBinding.self, forKey: .hotkey)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        self.chainTo = try c.decodeIfPresent(UUID.self, forKey: .chainTo)
        self.playCount = try c.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        self.lastPlayedAt = try c.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        self.totalRunTime = try c.decodeIfPresent(TimeInterval.self, forKey: .totalRunTime) ?? 0
    }
}

/// Built-in library filters (in addition to user tags).
enum LibraryFilter: Hashable {
    case all
    case favorites
    case recent
    case mostPlayed
    case withHotkey
    case tag(String)

    var label: String {
        switch self {
        case .all:        return "All Macros"
        case .favorites:  return "Favorites"
        case .recent:     return "Recent"
        case .mostPlayed: return "Most Played"
        case .withHotkey: return "Has Hotkey"
        case .tag(let t): return t
        }
    }

    var systemImage: String {
        switch self {
        case .all:        return "tray.full"
        case .favorites:  return "star.fill"
        case .recent:     return "clock"
        case .mostPlayed: return "chart.bar.fill"
        case .withHotkey: return "keyboard"
        case .tag:        return "tag.fill"
        }
    }
}

/// On-disk representation of the whole library.
private struct LibraryData: Codable {
    var macros: [SavedMacro]
    var currentMacroID: UUID?
    var version: Int = 2
}

/// The user's saved macros. Auto-persists to Application Support.
final class MacroLibrary: ObservableObject {
    @Published private(set) var macros: [SavedMacro] = []
    @Published var currentMacroID: UUID?

    var currentMacro: SavedMacro? {
        guard let id = currentMacroID else { return nil }
        return macros.first { $0.id == id }
    }

    /// All distinct tags across macros, sorted alphabetically.
    var allTags: [String] {
        let set = Set(macros.flatMap { $0.tags })
        return set.sorted()
    }

    private static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("TinyRecorder", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("library.json")
    }

    /// False when a library.json exists on disk that we could not read or decode.
    /// While false, save() refuses to run so we never overwrite the user's only
    /// copy of their data with the empty in-memory library.
    private var loadedCleanly = true

    init() { load() }

    // MARK: - Persistence

    func load() {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadedCleanly = true   // no file yet — a fresh, empty library is expected
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            // Exists but unreadable (permissions, transient I/O). Don't let a later
            // save() clobber it — the data may be fine, we just can't read it now.
            loadedCleanly = false
            NSLog("TinyRecorder: library.json exists but could not be read — refusing to overwrite it.")
            return
        }
        guard let decoded = try? JSONDecoder().decode(LibraryData.self, from: data) else {
            // Corrupt: preserve a copy before anything overwrites it, and only allow
            // future saves if that backup actually succeeded.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("library.corrupt-\(stamp).json")
            let backedUp = ((try? FileManager.default.copyItem(at: url, to: backup)) != nil)
            loadedCleanly = backedUp
            NSLog("TinyRecorder: library.json failed to decode — " +
                  (backedUp ? "backed up to \(backup.lastPathComponent)."
                            : "BACKUP FAILED; refusing to overwrite the original."))
            return
        }
        self.macros = decoded.macros
        self.currentMacroID = decoded.currentMacroID
        loadedCleanly = true
    }

    func save() {
        guard loadedCleanly else {
            NSLog("TinyRecorder: skipping save to avoid overwriting an unreadable library.json.")
            return
        }
        let data = LibraryData(macros: macros, currentMacroID: currentMacroID)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        guard let encoded = try? enc.encode(data) else { return }
        try? encoded.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: - Mutations

    /// Insert a fully-built macro (used by importers to preserve metadata).
    func insert(_ macro: SavedMacro) {
        macros.insert(macro, at: 0)
        currentMacroID = macro.id
        save()
    }

    @discardableResult
    func add(events: [RecordedEvent], name: String? = nil, loops: Int = 1) -> SavedMacro {
        let n = (name?.isEmpty == false) ? name! : autoName()
        let m = SavedMacro(name: n, events: events, loops: loops)
        macros.insert(m, at: insertionIndex())
        currentMacroID = m.id
        save()
        return m
    }

    /// New macros sit below favorites, at the top of the non-favorite section.
    private func insertionIndex() -> Int {
        macros.firstIndex(where: { !$0.favorite }) ?? macros.count
    }

    func setLoops(id: UUID, loops: Int) {
        mutate(id) { $0.loops = max(0, loops) }
    }

    func setSpeed(id: UUID, speed: Double) {
        mutate(id) { $0.speed = max(0.1, min(10.0, speed)) }
    }

    func setIcon(id: UUID, icon: String?) {
        mutate(id) { $0.icon = icon }
    }

    func setAccent(id: UUID, accent: String?) {
        mutate(id) { $0.accent = accent }
    }

    func setHotkey(id: UUID, hotkey: HotkeyBinding?) {
        // Make sure no other macro has this hotkey.
        if let hk = hotkey {
            for i in macros.indices where macros[i].id != id && macros[i].hotkey?.keyCode == hk.keyCode {
                macros[i].hotkey = nil
                macros[i].modifiedAt = Date()
            }
        }
        mutate(id) { $0.hotkey = hotkey }
    }

    func setNotes(id: UUID, notes: String) {
        mutate(id) { $0.notes = notes }
    }

    func setChainTo(id: UUID, target: UUID?) {
        // Refuse self-chains and any link that would close a cycle
        // (walk capped by macro count in case a cycle already exists via import).
        if let target {
            if target == id { return }
            var cursor: UUID? = target
            var hops = 0
            while let c = cursor, hops <= macros.count {
                if c == id { return }   // would create a cycle
                cursor = macros.first(where: { $0.id == c })?.chainTo
                hops += 1
            }
        }
        mutate(id) { $0.chainTo = target }
    }

    func toggleFavorite(id: UUID) {
        mutate(id) { $0.favorite.toggle() }
        // Re-sort: favorites at top, preserve relative order otherwise.
        let favorites = macros.filter { $0.favorite }
        let rest = macros.filter { !$0.favorite }
        macros = favorites + rest
        save()
    }

    func addTag(id: UUID, _ tag: String) {
        let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        mutate(id) { if !$0.tags.contains(t) { $0.tags.append(t); $0.tags.sort() } }
    }

    func removeTag(id: UUID, _ tag: String) {
        mutate(id) { $0.tags.removeAll { $0 == tag } }
    }

    func updateEvents(id: UUID, events: [RecordedEvent]) {
        mutate(id) {
            $0.events = events
        }
    }

    func rename(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate(id) { $0.name = trimmed.isEmpty ? "Untitled" : trimmed }
    }

    func delete(id: UUID) {
        // If anyone chains to this, break the chain.
        for i in macros.indices where macros[i].chainTo == id {
            macros[i].chainTo = nil
            macros[i].modifiedAt = Date()
        }
        macros.removeAll { $0.id == id }
        if currentMacroID == id {
            currentMacroID = macros.first?.id
        }
        save()
    }

    func deleteMany(ids: Set<UUID>) {
        for id in ids {
            for i in macros.indices where macros[i].chainTo == id {
                macros[i].chainTo = nil
            }
        }
        macros.removeAll { ids.contains($0.id) }
        if let cur = currentMacroID, ids.contains(cur) {
            currentMacroID = macros.first?.id
        }
        save()
    }

    func duplicate(id: UUID) {
        guard let src = macros.first(where: { $0.id == id }) else { return }
        var copy = src
        copy.id = UUID()
        copy.name = src.name + " copy"
        copy.createdAt = Date()
        copy.modifiedAt = Date()
        copy.hotkey = nil // hotkey is unique
        copy.playCount = 0
        copy.lastPlayedAt = nil
        copy.totalRunTime = 0
        copy.favorite = false
        if let idx = macros.firstIndex(where: { $0.id == id }) {
            macros.insert(copy, at: idx + 1)
        } else {
            macros.insert(copy, at: 0)
        }
        save()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        macros.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    /// Move a macro by id immediately before another id (for SwiftUI drag-and-drop).
    func move(id: UUID, before targetID: UUID) {
        guard let from = macros.firstIndex(where: { $0.id == id }),
              let to = macros.firstIndex(where: { $0.id == targetID }),
              from != to else { return }
        let macro = macros.remove(at: from)
        let insertAt = (from < to) ? to - 1 : to
        macros.insert(macro, at: insertAt)
        save()
    }

    func select(id: UUID) {
        currentMacroID = id
        save()
    }

    /// Atomically increment play stats.
    func recordPlay(id: UUID, runTime: TimeInterval) {
        mutate(id) {
            $0.playCount += 1
            $0.lastPlayedAt = Date()
            $0.totalRunTime += runTime
        }
    }

    // MARK: - Filtering

    func macros(for filter: LibraryFilter, search: String) -> [SavedMacro] {
        let trimmed = search.trimmingCharacters(in: .whitespaces).lowercased()
        let base: [SavedMacro]
        switch filter {
        case .all:        base = macros
        case .favorites:  base = macros.filter { $0.favorite }
        case .recent:
            let cutoff = Date().addingTimeInterval(-86_400 * 7) // last 7 days
            base = macros.filter { ($0.lastPlayedAt ?? $0.modifiedAt) >= cutoff }
        case .mostPlayed:
            base = macros.sorted { $0.playCount > $1.playCount }
                .filter { $0.playCount > 0 }
        case .withHotkey: base = macros.filter { $0.hotkey != nil }
        case .tag(let t): base = macros.filter { $0.tags.contains(t) }
        }
        if trimmed.isEmpty { return base }
        return base.filter {
            $0.name.lowercased().contains(trimmed)
                || $0.tags.contains { $0.lowercased().contains(trimmed) }
                || $0.notes.lowercased().contains(trimmed)
        }
    }

    // MARK: - Helpers

    private func mutate(_ id: UUID, _ body: (inout SavedMacro) -> Void) {
        guard let idx = macros.firstIndex(where: { $0.id == id }) else { return }
        body(&macros[idx])
        macros[idx].modifiedAt = Date()
        save()
    }

    private func autoName() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d · HH:mm"
        return "Macro " + f.string(from: Date())
    }
}

// MARK: - Relative-time helper

enum RelativeTime {
    static func string(from date: Date) -> String {
        let s = -date.timeIntervalSinceNow
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86_400 { return "\(Int(s / 3600))h ago" }
        if s < 604_800 { return "\(Int(s / 86_400))d ago" }
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }
}
