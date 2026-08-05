//
//  RatingSounds.swift
//  Memor
//
//  One short system sound per study response rating, played the moment a
//  rating lands (the same submit() seam as the divider flash bar, so every
//  entry point — buttons, the 1–4 keys, Space-as-Good — and every query kind
//  sounds alike). Rising from a low thud for Again to a bright retro coin
//  chime shared by Good and Easy (both are "correct", so they celebrate the
//  same way). Again/Hard are built-in NSSound names; the Good/Easy chime is
//  a bundled CC0 asset (see ATTRIBUTIONS.md).
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
        // GoodChime (Resources/GoodChime.wav): an 8-bit two-note rising coin
        // "b-ding" (~1.0 kHz → ~2.0 kHz, 0.26s) — brighter and half the
        // length of any built-in. NSSound(named:) finds bundle sound files
        // before the system ones. CC0, by Juhani Junkala (SubspaceAudio),
        // sfx_coin_double4 from "The Essential Retro Video Game Sound
        // Effects Collection" — see ATTRIBUTIONS.md.
        case .good, .easy: return "GoodChime"
        }
    }

    /// Plays the sound for a landed rating. `streak` is the session streak
    /// AFTER the rating applied: every time it reaches a multiple of 5, the
    /// coin-cluster jackpot (StreakChime — sfx_coin_cluster3 from the same
    /// CC0 pack, see ATTRIBUTIONS.md) REPLACES the rating's own sound.
    /// Again resets the streak to 0, which never triggers the jackpot.
    static func play(_ rating: StudyResponseRating, streak: Int) {
        if streak > 0, streak.isMultiple(of: 5) {
            play(named: "StreakChime")
        } else {
            play(named: soundName(rating))
        }
    }

    /// Plays a COPY of the cached sound: NSSound(named:) hands back a shared
    /// instance that refuses to restart while it is still playing, which
    /// would swallow the effect on quick back-to-back ratings.
    private static func play(named name: NSSound.Name) {
        guard let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }
}
