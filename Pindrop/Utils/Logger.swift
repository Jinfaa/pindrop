//
//  Logger.swift
//  Pindrop
//
//  Created on 2026-01-25.
//
//  Logging is intentionally disabled: Pindrop writes no logs to disk or the
//  unified log. The `Log` API stays so call sites compile; messages are
//  autoclosures that are never evaluated.
//

import Foundation

enum Log {
    static let audio = AppLogCategory()
    static let transcription = AppLogCategory()
    static let model = AppLogCategory()
    static let output = AppLogCategory()
    static let hotkey = AppLogCategory()
    static let app = AppLogCategory()
    static let boot = AppLogCategory()
    static let ui = AppLogCategory()
    static let aiEnhancement = AppLogCategory()
    static let context = AppLogCategory()
}

final class AppLogCategory: Sendable {
    func debug(_ message: @autoclosure () -> String) {}
    func info(_ message: @autoclosure () -> String) {}
    func warning(_ message: @autoclosure () -> String) {}
    func error(_ message: @autoclosure () -> String) {}
    func debugVisible(_ message: @autoclosure () -> String) {}
    func infoVisible(_ message: @autoclosure () -> String) {}
    func warningVisible(_ message: @autoclosure () -> String) {}
    func errorVisible(_ message: @autoclosure () -> String) {}
}

extension Bundle {
    var appShortVersionString: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var appBuildVersionString: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
}
