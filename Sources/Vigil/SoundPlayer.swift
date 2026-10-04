import AppKit
import VigilCore

/// Plays system alert sounds with NSSound. No audio files of our own, no permissions.
/// The level is Vigil's volume times the macOS alert volume, so muting alerts in System Settings mutes Vigil too.
final class SystemSoundPlayer: SoundPlaying {
    /// NSSound stops when deallocated, so the sound that is playing stays referenced here.
    private var current: NSSound?

    func play(_ sound: String, volume: Double) {
        guard let s = NSSound(contentsOf: SystemSounds.url(sound), byReference: true) else {
            Log.shared.warning("sound \(sound) not found in \(SystemSounds.directory.path)")
            return
        }
        current?.stop()
        s.volume = Float(volume * SystemSounds.alertVolume())
        current = s
        s.play()
    }
}
