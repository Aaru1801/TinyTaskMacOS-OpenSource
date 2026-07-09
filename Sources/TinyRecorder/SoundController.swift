import AppKit
import AudioToolbox

/// Subtle audio feedback. Off by default; toggleable in Settings.
enum SoundCue {
    case recordStart
    case recordStop
    case playStart
    case playEnd
    case error
    case tick

    fileprivate var systemSoundName: String {
        switch self {
        case .recordStart: return "Tink"
        case .recordStop:  return "Pop"
        case .playStart:   return "Morse"
        case .playEnd:     return "Glass"
        case .error:       return "Funk"
        case .tick:        return "Tink"
        }
    }
}

final class SoundController: NSObject, NSSoundDelegate {
    static let shared = SoundController()
    private override init() {}

    var enabled: Bool = false

    /// NSSound.play() is asynchronous; if the instance deallocates before it
    /// finishes, the cue is silently cut off. Hold a reference until it completes.
    private var active: [NSSound] = []

    func play(_ cue: SoundCue) {
        guard enabled else { return }
        if let s = NSSound(named: NSSound.Name(cue.systemSoundName)) {
            s.volume = 0.45
            s.delegate = self
            active.append(s)
            s.play()
        }
    }

    func sound(_ sound: NSSound, didFinishPlaying finished: Bool) {
        active.removeAll { $0 === sound }
    }
}
