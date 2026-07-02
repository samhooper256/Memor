//
//  TextSubstitutions.swift
//  Memor
//
//  Kills macOS automatic text substitutions in every editor. No Memor text
//  input should ever rewrite what the user typed.
//

import AppKit
import Foundation

extension NSTextView {
    /// Turns off every macOS feature that rewrites typed text.
    /// Note: "..." → "…" and "--" → "—" are smart DASHES
    /// (isAutomaticDashSubstitutionEnabled), not text replacement.
    func disableAutomaticSubstitutions() {
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
    }
}

/// Written to the app domain at launch so the defaults that seed every new
/// NSTextView — including the window field editors behind NSTextField and
/// SwiftUI TextField — have all automatic substitutions off. Must be a
/// `set`, not `register(defaults:)`: the registration domain is searched
/// after NSGlobalDomain, so registering would lose to a system-wide
/// "smart quotes and dashes" setting.
func registerSubstitutionKillDefaults() {
    for key in [
        "NSAutomaticDashSubstitutionEnabled",      // "..." → "…", "--" → "—"
        "NSAutomaticQuoteSubstitutionEnabled",
        "NSAutomaticTextReplacementEnabled",
        "NSAutomaticPeriodSubstitutionEnabled",
        "NSAutomaticSpellingCorrectionEnabled",
    ] {
        UserDefaults.standard.set(false, forKey: key)
    }
}
