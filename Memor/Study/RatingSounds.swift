//
//  RatingSounds.swift
//  Memor
//
//  One short system sound per study response rating, played the moment a
//  rating lands (the same submit() seam as the divider flash bar, so every
//  entry point — buttons, the 1–4 keys, Space-as-Good — and every query kind
//  sounds alike). Built-in NSSound names, no bundled assets; the four are
//  distinct so the ear learns the outcome without looking, rising from a low
//  thud for Again to a bright chime for Easy.
//

import AppKit

enum RatingSounds {
    /// Tweak here, not per call site: a study session hears these hundreds of
    /// times, so they play a notch quieter than a raw system alert.
    private static let volume: Float = 0.6

    private static func soundName(_ rating: StudyResponseRating) -> NSSound.Name {
        switch rating {
        case .again: return "Basso"
        case .hard: return "Pop"
        case .good: return "Tink"
        case .easy: return "Glass"
        }
    }

    /// Plays a COPY of the cached sound: NSSound(named:) hands back a shared
    /// instance that refuses to restart while it is still playing, which
    /// would swallow the effect on quick back-to-back ratings.
    static func play(_ rating: StudyResponseRating) {
        guard let sound = NSSound(named: soundName(rating))?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }
}
