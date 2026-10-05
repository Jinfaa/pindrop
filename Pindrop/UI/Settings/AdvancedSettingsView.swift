//
//  AdvancedSettingsView.swift
//  Pindrop
//
//  Created on 2026-04-15.
//

import AppKit
import SwiftUI

struct AdvancedSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @Environment(\.locale) private var locale

    @State private var errorMessage: String?
    @AppStorage(SettingsLogLevel.userDefaultsKey) private var logLevelRaw = SettingsLogLevel.info.rawValue

    private var logLevel: SettingsLogLevel {
        get { SettingsLogLevel(rawValue: logLevelRaw) ?? .info }
        nonmutating set { logLevelRaw = newValue.rawValue }
    }

    var body: some View {
        SettingsPaneStack {
            // Diagnostics / logs
            SettingsGroupCard {
                SettingsRow(showSeparator: true) {
                    SettingsRowLabel(title: localized("Log level", locale: locale))
                } control: {
                    Menu {
                        ForEach(SettingsLogLevel.allCases) { level in
                            Button(level.title(locale: locale)) {
                                logLevel = level
                            }
                        }
                    } label: {
                        SettingsMenuButton(title: logLevel.title(locale: locale))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .accessibilityIdentifier("settings.picker.logLevel")
                }

                SettingsRow(showSeparator: true) {
                    SettingsRowLabel(
                        title: localized("Diagnostics", locale: locale),
                        subtitle: localized("Logs never include transcript text", locale: locale)
                    )
                } control: {
                    EmptyView()
                }

                SettingsRow(showSeparator: false) {
                    SettingsRowLabel(title: localized("Export Logs…", locale: locale))
                } control: {
                    Button {
                        exportLogs()
                    } label: {
                        SettingsMenuButton(
                            title: localized("Export Logs…", locale: locale),
                            showsChevron: false
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.button.exportLogs")
                }
            }
        }
        .alert(
            localized("Error", locale: locale),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(localized("OK", locale: locale), role: .cancel) {}
        } message: {
            if let errorMessage {
                Text(errorMessage)
            }
        }
    }

    private func exportLogs() {
        SettingsLogExport.presentExportPanel(locale: locale) { message in
            errorMessage = message
        }
    }
}

#Preview {
    AdvancedSettingsView(settings: SettingsStore())
        .frame(width: 620, height: 600)
        .background(AppColors.windowBackground)
        .themeRefresh()
}
