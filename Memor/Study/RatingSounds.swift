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

    /// Every NSSound is created AND played on this queue, never the main
    /// thread: NSSound.play() synchronously primes its playback channel
    /// before returning (~10–30ms per press measured warm, ~0.5s on the
    /// process's first play), which audibly delayed the chime and pushed the
    /// SRS write + next-query render behind it on every rating. Serial so
    /// rapid back-to-back ratings keep their order.
    private static let playbackQueue = DispatchQueue(label: "com.sam.Memor.rating-sounds")

    /// Absorbs the audio stack's per-process cold start (~0.5s measured on
    /// the first NSSound.play()) off the first rating press by playing one
    /// muted sound when Study mode loads. Zero volume is inaudible, so this
    /// runs regardless of the Sound Effects setting.
    static func prewarm() {
        playbackQueue.async {
            guard let sound = NSSound(named: "GoodChime")?.copy() as? NSSound else { return }
            sound.volume = 0
            sound.play()
        }
    }

    private static func soundName(_ rating: StudyResponseRating, streak: Int) -> NSSound.Name {
        switch rating {
        case .again: return "Basso"
        case .hard: return "Pop"
        // GoodChime (Resources/GoodChime.wav): an 8-bit two-note rising coin
        // "b-ding" (~1.0 kHz → ~2.0 kHz, 0.26s) — brighter and half the
        // length of any built-in. From streak 11 up (the badge's blue tier
        // onward) correct answers switch to GoodChime2, a mellower coin
        // double (sfx_coin_double1, 0.21s). NSSound(named:) finds bundle
        // sound files before the system ones. Both CC0, by Juhani Junkala
        // (SubspaceAudio), from "The Essential Retro Video Game Sound
        // Effects Collection" — see ATTRIBUTIONS.md.
        case .good, .easy: return streak >= 11 ? "GoodChime2" : "GoodChime"
        }
    }

    /// Plays the sound for a landed rating. `streak` is the session streak
    /// AFTER the rating applied; `previousStreak` is the streak it replaced.
    /// Every time the streak reaches a multiple of 5, the coin-cluster
    /// jackpot (StreakChime — sfx_coin_cluster3) REPLACES the rating's own
    /// sound. Losing a streak escalates the same way: an Again that ends a
    /// run of 5–9 plays StreakLoss (sfx_sounds_error13, a flat ~740 Hz
    /// "wrong!" buzzer — mid-register on purpose, its screechier
    /// predecessor error12 was rejected) and a run of 10+ plays
    /// StreakLossBig (sfx_sounds_negative1, a long low descent) instead of
    /// Basso — a smaller run keeps the plain thud. Again zeroes the streak, so the
    /// jackpot branch and the loss branches can never collide. All from the
    /// same CC0 pack — see ATTRIBUTIONS.md.
    static func play(_ rating: StudyResponseRating, streak: Int, previousStreak: Int) {
        guard SoundSettings.shared.soundEffectsEnabled else { return }
        if streak > 0, streak.isMultiple(of: 5) {
            play(named: "StreakChime")
        } else if rating == .again, previousStreak >= 10 {
            play(named: "StreakLossBig")
        } else if rating == .again, previousStreak >= 5 {
            play(named: "StreakLoss")
        } else {
            play(named: soundName(rating, streak: streak))
        }
    }

    /// Plays a COPY of the cached sound: NSSound(named:) hands back a shared
    /// instance that refuses to restart while it is still playing, which
    /// would swallow the effect on quick back-to-back ratings. The copy is
    /// created inside the queue closure so no NSSound ever crosses threads.
    private static func play(named name: NSSound.Name) {
        let volume = Self.volume
        playbackQueue.async {
            guard let sound = NSSound(named: name)?.copy() as? NSSound else { return }
            sound.volume = volume
            sound.play()
        }
    }
}
