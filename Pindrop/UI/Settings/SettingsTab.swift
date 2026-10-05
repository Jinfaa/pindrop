//
//  SettingsTab.swift
//  Pindrop
//
//  Created on 2026-07-09.
//

import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case dictation
    case appearance
    case shortcuts
    case ai
    case about

    var id: String { rawValue }

    func title(locale: Locale) -> String {
        switch self {
        case .general: return localized("General", locale: locale)
        case .dictation: return localized("Dictation", locale: locale)
        case .appearance: return localized("Appearance", locale: locale)
        case .shortcuts: return localized("Shortcuts", locale: locale)
        case .ai: return localized("AI", locale: locale)
        case .about: return localized("About", locale: locale)
        }
    }

    var systemIcon: String {
        switch self {
        case .general: return "gearshape"
        case .dictation: return "mic.fill"
        case .appearance: return "paintbrush"
        case .shortcuts: return "keyboard"
        case .ai: return "sparkles"
        case .about: return "info.circle"
        }
    }

    var accessibilityIdentifier: String {
        "settings.tab.\(rawValue)"
    }
}

/// Routes a settings tab to its grouped-form pane view.
struct SettingsPaneContent: View {
    @ObservedObject var settings: SettingsStore
    let tab: SettingsTab
    let launchAtLoginManager: LaunchAtLoginManager

    init(
        settings: SettingsStore,
        tab: SettingsTab,
        launchAtLoginManager: LaunchAtLoginManager
    ) {
        self.settings = settings
        self.tab = tab
        self.launchAtLoginManager = launchAtLoginManager
    }

    @MainActor
    init(settings: SettingsStore, tab: SettingsTab) {
        self.init(
            settings: settings,
            tab: tab,
            launchAtLoginManager: LaunchAtLoginManager()
        )
    }

    @ViewBuilder
    var body: some View {
        switch tab {
        case .general:
            GeneralSettingsView(
                settings: settings,
                launchAtLoginManager: launchAtLoginManager
            )
        case .dictation:
            DictationSettingsView(settings: settings)
        case .appearance:
            ThemeSettingsView(settings: settings)
        case .shortcuts:
            HotkeysSettingsView(settings: settings)
        case .ai:
            AIEnhancementSettingsView(settings: settings)
        case .about:
            AboutSettingsView(settings: settings)
        }
    }
}
