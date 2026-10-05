//
//  SettingsPresentation.swift
//  Pindrop
//
//  Created on 2026-07-10.
//
//  Pure helpers for Settings window presentation (U8). No SwiftUI side effects.
//

import Foundation

// MARK: - Layout metrics (spec §13 — normative)

enum SettingsLayoutMetrics {
    /// Settings panes keep their form width inside the wider main window.
    static let contentMaxWidth: CGFloat = 620

    /// Tab strip
    static let tabGap: CGFloat = 4
    static let tabTopPadding: CGFloat = 20
    static let tabBottomPadding: CGFloat = 10
    static let tabRadius: CGFloat = 8
    static let tabVerticalPadding: CGFloat = 7
    static let tabHorizontalPadding: CGFloat = 12
    static let tabIconSize: CGFloat = 17
    static let tabColumnGap: CGFloat = 4

    /// Content column
    static let contentTopPadding: CGFloat = 20
    static let contentSidePadding: CGFloat = 24
    static let contentBottomPadding: CGFloat = 24
    static let groupGap: CGFloat = 16

    /// Group card
    static let cardRadius: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 12
    static let rowHorizontalPadding: CGFloat = 16
    static let rowGap: CGFloat = 12

    /// Toggle switch 36×21
    static let toggleWidth: CGFloat = 36
    static let toggleHeight: CGFloat = 21
    static let toggleKnob: CGFloat = 17
    static let togglePadding: CGFloat = 2

    /// Dropdown / small button
    static let dropdownRadius: CGFloat = 7
    static let dropdownVerticalPadding: CGFloat = 5
    static let dropdownHorizontalPadding: CGFloat = 12

    /// About
    static let aboutIconSize: CGFloat = 64
}

// MARK: - Dictation audio retention labels

enum DictationRetentionPresentation {
    /// Picker labels for off / 7 / 30 / forever.
    static func label(_ retention: DictationAudioRetention, locale: Locale) -> String {
        switch retention {
        case .off:
            return localized("Off", locale: locale)
        case .days7:
            return localized("7 days", locale: locale)
        case .days30:
            return localized("30 days", locale: locale)
        case .forever:
            return localized("Forever", locale: locale)
        }
    }

    /// Stable display order for the retention picker.
    static var pickerOrder: [DictationAudioRetention] {
        [.off, .days7, .days30, .forever]
    }
}

// MARK: - Disk usage formatting (reuses Models-style MB/GB ramp)

enum DictationAudioDiskUsageFormatting {
    /// Formats `totalBytes` + `snippetCount` as "Audio on disk: 142 MB · 64 snippets".
    static func summaryLine(usage: DictationAudioDiskUsage, locale: Locale) -> String {
        let size = formattedByteCount(usage.totalBytes)
        let snippets = snippetCountLabel(usage.snippetCount, locale: locale)
        return String(
            format: localized("Audio on disk: %@ · %@", locale: locale),
            size,
            snippets
        )
    }

    /// "0 MB", "142 MB", "1.2 GB" — same style as ModelsDiskTotal when given whole MB.
    static func formattedByteCount(_ bytes: Int64) -> String {
        let safe = max(0, bytes)
        if safe < 1024 {
            return "0 MB"
        }
        let mb = Double(safe) / (1024.0 * 1024.0)
        if mb < 1 {
            // Sub-megabyte: show as 1 MB when non-zero so the row never says "0 MB" for tiny files.
            return "1 MB"
        }
        if mb >= 1000 {
            let gb = mb / 1000.0
            if abs(gb.rounded() - gb) < 0.05 {
                return "\(Int(gb.rounded())) GB"
            }
            return String(format: "%.1f GB", gb)
        }
        let rounded = Int(mb.rounded())
        return "\(rounded) MB"
    }

    /// "1 snippet" / "64 snippets"
    static func snippetCountLabel(_ count: Int, locale: Locale) -> String {
        if count == 1 {
            return localized("1 snippet", locale: locale)
        }
        return String(
            format: localized("%d snippets", locale: locale),
            count
        )
    }
}

// MARK: - Theme preset chip ordering (U1 legacy-graphite rule)

enum SettingsThemePresetPresentation {
    /// Visible catalog presets, plus the active legacy preset (e.g. graphite) only while selected.
    static func presetsForPicker(
        selectedID: String,
        catalog: [PindropThemePreset] = PindropThemePresetCatalog.presets,
        legacy: [PindropThemePreset] = PindropThemePresetCatalog.legacyPresets
    ) -> [PindropThemePreset] {
        var list = catalog
        if let legacyMatch = legacy.first(where: { $0.id == selectedID }),
           !list.contains(where: { $0.id == legacyMatch.id }) {
            list.append(legacyMatch)
        }
        return list
    }

    /// Whether a legacy tile should appear for the given selection.
    static func shouldShowLegacyPreset(
        legacyID: String,
        selectedID: String
    ) -> Bool {
        legacyID == selectedID
    }
}

// MARK: - Speaker profile summary

enum SpeakerProfileSummaryPresentation {
    /// "3 trained — used to label who said what in meetings"
    static func summary(trainedCount: Int, locale: Locale) -> String {
        let trained: String
        if trainedCount == 1 {
            trained = localized("1 trained", locale: locale)
        } else {
            trained = String(
                format: localized("%d trained", locale: locale),
                trainedCount
            )
        }
        return String(
            format: localized("%@ — used to label who said what in meetings", locale: locale),
            trained
        )
    }

    /// Profiles with evidence are "trained"; zero-evidence rows still count as stored but untrained.
    static func trainedCount(evidenceCounts: [Int]) -> Int {
        evidenceCounts.filter { $0 > 0 }.count
    }
}

// MARK: - Hotkey conflict aggregate line

enum SettingsHotkeyConflictPresentation {
    /// Pane-level status under the shortcut list.
    static func aggregateStatus(
        statuses: [HotkeyConflictStatus],
        locale: Locale
    ) -> String {
        if statuses.contains(where: {
            if case .pindropConflict = $0 { return true }
            return false
        }) {
            return localized("Some shortcuts conflict with each other.", locale: locale)
        }
        if statuses.contains(where: {
            if case .systemShortcut = $0 { return true }
            return false
        }) {
            return localized("Some shortcuts may conflict with system shortcuts.", locale: locale)
        }
        return localized("No conflicts with system or app shortcuts.", locale: locale)
    }
}

// MARK: - About

enum SettingsAboutPresentation {
    static let taglineKey = "Speak. It's written."
}
