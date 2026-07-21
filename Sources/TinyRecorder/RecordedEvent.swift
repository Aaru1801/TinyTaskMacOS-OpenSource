import Foundation
import CoreGraphics

struct RecordedEvent: Codable, Equatable, Sendable {
    /// Defensive bounds for hand-edited/imported macro files. Values outside
    /// these ranges cannot describe a practical macOS recording and can make
    /// downstream integer formatting or Core Graphics conversion trap.
    private static let maximumTime: TimeInterval = 7 * 24 * 60 * 60
    private static let maximumCoordinate: CGFloat = 1_000_000
    private static let maximumMouseButton: Int64 = 31
    private static let maximumClickCount: Int64 = 16

    enum Kind: Int, Codable, Sendable {
        case leftMouseDown      = 1
        case leftMouseUp        = 2
        case rightMouseDown     = 3
        case rightMouseUp       = 4
        case mouseMoved         = 5
        case leftMouseDragged   = 6
        case rightMouseDragged  = 7
        case keyDown            = 10
        case keyUp              = 11
        case flagsChanged       = 12
        case scrollWheel        = 22
        case otherMouseDown     = 25
        case otherMouseUp       = 26
        case otherMouseDragged  = 27

        var isMouse: Bool {
            switch self {
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                 .mouseMoved, .leftMouseDragged, .rightMouseDragged,
                 .otherMouseDown, .otherMouseUp, .otherMouseDragged:
                return true
            default:
                return false
            }
        }

        var isKey: Bool {
            switch self {
            case .keyDown, .keyUp, .flagsChanged: return true
            default: return false
            }
        }
    }

    var kind: Kind
    /// Seconds since the start of the recording.
    var time: TimeInterval
    var x: CGFloat
    var y: CGFloat
    var keyCode: UInt16
    var flags: UInt64
    var mouseButton: Int64
    var clickCount: Int64
    var scrollDeltaY: Int32
    var scrollDeltaX: Int32

    var location: CGPoint {
        get { CGPoint(x: x, y: y) }
        set { x = newValue.x; y = newValue.y }
    }

    /// Bring externally supplied event lists into the same shape as a fresh
    /// recording. Native macro files are user-editable JSON, so their timeline
    /// is not guaranteed to be sorted or even non-negative.
    static func normalized(_ events: [RecordedEvent]) -> [RecordedEvent] {
        events.enumerated().compactMap { offset, event -> (Int, RecordedEvent)? in
            guard event.time.isFinite else { return nil }
            var event = event
            event.time = max(0, min(Self.maximumTime, event.time))
            event.x = event.x.isFinite
                ? max(-Self.maximumCoordinate, min(Self.maximumCoordinate, event.x))
                : 0
            event.y = event.y.isFinite
                ? max(-Self.maximumCoordinate, min(Self.maximumCoordinate, event.y))
                : 0
            event.mouseButton = max(0, min(Self.maximumMouseButton, event.mouseButton))
            event.clickCount = max(0, min(Self.maximumClickCount, event.clickCount))
            return (offset, event)
        }
        .sorted { lhs, rhs in
            lhs.1.time == rhs.1.time ? lhs.0 < rhs.0 : lhs.1.time < rhs.1.time
        }
        .map(\.1)
    }
}

struct Macro: Codable {
    var events: [RecordedEvent]
    var createdAt: Date
    var version: Int = 1

    var duration: TimeInterval {
        events.last?.time ?? 0
    }
}
