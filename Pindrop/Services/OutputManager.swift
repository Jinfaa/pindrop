//
//  OutputManager.swift
//  Pindrop
//
//  Created on 2026-01-25.
//

import Foundation
import AppKit
import ApplicationServices
import os.log

enum OutputMode {
    case clipboard
    case directInsert
}

enum OutputManagerError: Error, LocalizedError {
    case accessibilityPermissionDenied
    case emptyText
    case clipboardWriteFailed
    case textInsertionFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Accessibility permission is required for direct text insertion"
        case .emptyText:
            return "Cannot output empty text"
        case .clipboardWriteFailed:
            return "Failed to write text to clipboard"
        case .textInsertionFailed:
            return "Failed to insert text directly"
        }
    }
}

// MARK: - Protocols

protocol ClipboardProtocol {
    func copyToClipboard(_ text: String) -> Bool
    func captureSnapshot() -> ClipboardSnapshot
    func currentChangeCount() -> Int
    func currentStringContent() -> String?
    func restoreSnapshot(_ snapshot: ClipboardSnapshot) -> Bool
}

struct ClipboardSnapshot: Equatable {
    let items: [[String: Data]]
    let changeCount: Int

    static let empty = ClipboardSnapshot(items: [], changeCount: 0)
}

protocol KeySimulationProtocol {
    /// Simulates ⌘V.
    /// - Parameter allowSystemEventsFallback: When `true`, a failed CGEvent sequence may
    ///   fall back to System Events. Hypervisors often ignore System Events' synthetic
    ///   modifiers and only receive a bare `v`, so callers should pass `false` for known VM hosts.
    func simulatePaste(allowSystemEventsFallback: Bool) async throws
}

extension KeySimulationProtocol {
    func simulatePaste() async throws {
        try await simulatePaste(allowSystemEventsFallback: true)
    }
}

struct KeySimulationEvent: Equatable {
    let virtualKey: CGKeyCode
    let keyDown: Bool
    let flags: CGEventFlags
}

/// Conservative detection of frontmost hypervisor / VM host apps where Unicode key
/// injection (`virtualKey: 0`) and System Events paste are unreliable.
enum VirtualMachineHostDetector {
    /// Bundle IDs for VMware Fusion, Parallels, VirtualBox, and VirtualBuddy/AVF hosts.
    static let knownBundleIdentifiers: Set<String> = [
        "com.vmware.fusion",
        "com.vmware.vmware-vmx",
        "com.parallels.desktop.console",
        "org.virtualbox.app.virtualbox",
        "org.virtualbox.app.virtualboxvm",
        "codes.rambo.virtualbuddy",
    ]

    static func isVirtualMachineHost(bundleIdentifier: String?) -> Bool {
        guard let normalized = normalizedBundleIdentifier(bundleIdentifier) else {
            return false
        }
        if knownBundleIdentifiers.contains(normalized) {
            return true
        }
        // Prefix matches catch helper / guest-window processes that share a vendor root.
        return knownBundleIdentifiers.contains { known in
            normalized.hasPrefix(known + ".")
        }
    }

    static func normalizedBundleIdentifier(_ bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else { return nil }
        let normalized = bundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

// MARK: - Real Implementations

final class SystemClipboard: ClipboardProtocol {
    func copyToClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    func captureSnapshot() -> ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        guard let pasteboardItems = pasteboard.pasteboardItems else {
            return .empty
        }

        let items = pasteboardItems.map { item in
            var capturedItem: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    capturedItem[type.rawValue] = data
                }
            }
            return capturedItem
        }

        return ClipboardSnapshot(items: items, changeCount: pasteboard.changeCount)
    }

    func currentChangeCount() -> Int {
        NSPasteboard.general.changeCount
    }

    func currentStringContent() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func restoreSnapshot(_ snapshot: ClipboardSnapshot) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard !snapshot.items.isEmpty else {
            return true
        }

        let pasteboardItems = snapshot.items.map { capturedItem in
            let item = NSPasteboardItem()
            for (type, data) in capturedItem {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }

        return pasteboard.writeObjects(pasteboardItems)
    }
}

final class SystemKeySimulation: KeySimulationProtocol {
    private let pasteScriptRunner: () throws -> Bool
    private let keyEventPoster: (CGEventSource?, KeySimulationEvent) -> Bool
    private let sleeper: (UInt64) async throws -> Void

    init(
        pasteScriptRunner: @escaping () throws -> Bool = SystemKeySimulation.runSystemEventsPasteScript,
        keyEventPoster: @escaping (CGEventSource?, KeySimulationEvent) -> Bool = SystemKeySimulation.postKeyEvent,
        sleeper: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.pasteScriptRunner = pasteScriptRunner
        self.keyEventPoster = keyEventPoster
        self.sleeper = sleeper
    }

    func simulatePaste(allowSystemEventsFallback: Bool) async throws {
        do {
            try await simulatePasteWithCGEvent()
            return
        } catch {
            guard allowSystemEventsFallback else {
                throw error
            }

            Log.output.debug("CGEvent paste failed; falling back to System Events: \(error.localizedDescription)")
            if try pasteScriptRunner() {
                return
            }

            throw error
        }
    }

    private static func runSystemEventsPasteScript() throws -> Bool {
        let scriptSource = "tell application \"System Events\" to keystroke \"v\" using command down"
        guard let script = NSAppleScript(source: scriptSource) else {
            return false
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)

        if let error {
            Log.output.debug("System Events paste failed: \(String(describing: error))")
            return false
        }

        return true
    }

    /// Posts an explicit physical Command down/up around `v`. Hypervisors ignore
    /// `.maskCommand` alone and only honor real modifier key events.
    ///
    /// If any event after Command-down fails to create/post, Command-up is still
    /// emitted so the modifier is not left stuck.
    private func simulatePasteWithCGEvent() async throws {
        let commandKeyCode: CGKeyCode = 0x37
        let vKeyCode: CGKeyCode = 0x09
        let source = CGEventSource(stateID: .hidSystemState)

        var commandIsDown = false
        defer {
            if commandIsDown {
                // Best-effort cleanup; ignore failure so the original error surfaces.
                _ = keyEventPoster(
                    source,
                    KeySimulationEvent(virtualKey: commandKeyCode, keyDown: false, flags: [])
                )
            }
        }

        let commandDown = KeySimulationEvent(virtualKey: commandKeyCode, keyDown: true, flags: .maskCommand)
        guard keyEventPoster(source, commandDown) else {
            Log.output.error("Failed to create CGEvent for paste")
            throw OutputManagerError.textInsertionFailed
        }
        commandIsDown = true
        try await sleeper(50_000_000)

        let vDown = KeySimulationEvent(virtualKey: vKeyCode, keyDown: true, flags: .maskCommand)
        guard keyEventPoster(source, vDown) else {
            Log.output.error("Failed to create CGEvent for paste")
            throw OutputManagerError.textInsertionFailed
        }
        try await sleeper(50_000_000)

        let vUp = KeySimulationEvent(virtualKey: vKeyCode, keyDown: false, flags: .maskCommand)
        guard keyEventPoster(source, vUp) else {
            Log.output.error("Failed to create CGEvent for paste")
            throw OutputManagerError.textInsertionFailed
        }
        try await sleeper(50_000_000)

        let commandUp = KeySimulationEvent(virtualKey: commandKeyCode, keyDown: false, flags: [])
        guard keyEventPoster(source, commandUp) else {
            Log.output.error("Failed to create CGEvent for paste")
            throw OutputManagerError.textInsertionFailed
        }
        // Successful Command-up; prevent the defer from posting a second one.
        commandIsDown = false
    }

    private static func postKeyEvent(source: CGEventSource?, event: KeySimulationEvent) -> Bool {
        guard let cgEvent = CGEvent(
            keyboardEventSource: source,
            virtualKey: event.virtualKey,
            keyDown: event.keyDown
        ) else {
            Log.output.error("Failed to create CGEvents for paste")
            return false
        }

        cgEvent.flags = event.flags
        cgEvent.post(tap: .cghidEventTap)
        return true
    }
}

@MainActor
final class OutputManager {

    /// How `output(_:)` actually landed the text in the target app. `.pasted` means the
    /// paste keystroke was issued; `.copiedToClipboard` means the text was left on the
    /// clipboard for the user to paste manually — `clipboardFallbackReason` tells
    /// callers whether that was copy-only mode working as designed, the intentional
    /// no-AX fallback, or a real paste failure, so they can surface the right message.
    ///
    /// Destination fields are always captured from the frontmost app at insert/copy time
    /// (including clipboard-only mode: "frontmost app at copy time").
    struct OutputResult: Equatable {
        enum Kind: Equatable {
            case pasted
            case copiedToClipboard
        }

        enum ClipboardFallbackReason: Equatable {
            /// Clipboard output mode: copying IS the output, by user choice.
            case copyOnlyMode
            /// Accessibility permission is missing; copying was the intended behavior.
            case accessibilityUnavailable
            /// A paste was attempted and failed; the copy is a recovery, not a success.
            case pasteFailed
        }

        let kind: Kind
        let clipboardFallbackReason: ClipboardFallbackReason?
        /// Pasteboard contents captured before the fallback copy replaced them, so
        /// callers can offer Undo. Only set for `.copiedToClipboard`.
        let previousClipboardSnapshot: ClipboardSnapshot?
        let destinationAppName: String?
        let destinationAppBundleID: String?

        var didPaste: Bool { kind == .pasted }
        var didCopyToClipboard: Bool { kind == .copiedToClipboard }

        static func pasted(
            destinationAppName: String? = nil,
            destinationAppBundleID: String? = nil
        ) -> OutputResult {
            OutputResult(
                kind: .pasted,
                clipboardFallbackReason: nil,
                previousClipboardSnapshot: nil,
                destinationAppName: destinationAppName,
                destinationAppBundleID: destinationAppBundleID
            )
        }

        static func copiedToClipboard(
            reason: ClipboardFallbackReason = .pasteFailed,
            previousClipboardSnapshot: ClipboardSnapshot? = nil,
            destinationAppName: String? = nil,
            destinationAppBundleID: String? = nil
        ) -> OutputResult {
            OutputResult(
                kind: .copiedToClipboard,
                clipboardFallbackReason: reason,
                previousClipboardSnapshot: previousClipboardSnapshot,
                destinationAppName: destinationAppName,
                destinationAppBundleID: destinationAppBundleID
            )
        }
    }

    private(set) var outputMode: OutputMode
    private let clipboard: ClipboardProtocol
    private let keySimulation: KeySimulationProtocol
    private let accessibilityPermissionChecker: () -> Bool
    private let frontmostApplicationProvider: () -> NSRunningApplication?
    private let virtualMachineHostChecker: (String?) -> Bool
    /// Where the user was typing when dictation started; consumed by the next `output(_:)`.
    private var insertionTarget: InsertionTarget?

    init(
        outputMode: OutputMode = .clipboard,
        clipboard: ClipboardProtocol = SystemClipboard(),
        keySimulation: KeySimulationProtocol = SystemKeySimulation(),
        accessibilityPermissionChecker: @escaping () -> Bool = { AXIsProcessTrusted() },
        frontmostApplicationProvider: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
        virtualMachineHostChecker: @escaping (String?) -> Bool = { VirtualMachineHostDetector.isVirtualMachineHost(bundleIdentifier: $0) }
    ) {
        self.outputMode = outputMode
        self.clipboard = clipboard
        self.keySimulation = keySimulation
        self.accessibilityPermissionChecker = accessibilityPermissionChecker
        self.frontmostApplicationProvider = frontmostApplicationProvider
        self.virtualMachineHostChecker = virtualMachineHostChecker
    }

    func setOutputMode(_ mode: OutputMode) {
        self.outputMode = mode
    }

    /// Remembers the frontmost app and its focused element so the transcript lands there
    /// even if the user switches away while it is being processed.
    func rememberInsertionTarget(enabled: Bool = true) {
        guard enabled,
              let app = frontmostApplicationProvider(),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            insertionTarget = nil
            return
        }
        let element = AXInsertion.focusedElement().flatMap { element -> AXUIElement? in
            var pid: pid_t = 0
            return AXUIElementGetPid(element, &pid) == .success && pid == app.processIdentifier ? element : nil
        }
        insertionTarget = InsertionTarget(app: app, element: element)
    }

    @discardableResult
    func output(_ text: String) async throws -> OutputResult {
        guard !text.isEmpty else {
            throw OutputManagerError.emptyText
        }

        Log.output.debug("Output called, mode: \(String(describing: self.outputMode)), length: \(text.count)")

        let target = insertionTarget
        insertionTarget = nil

        if outputMode == .directInsert, let target, target.userMovedAway(frontmost: frontmostApplicationProvider()) {
            return try await outputToRememberedTarget(text, target: target)
        }

        // Capture insert/copy-time frontmost app unconditionally before any paste or copy.
        let destination = captureDestinationApp()

        switch outputMode {
        case .clipboard:
            return try await outputViaClipboard(text, destination: destination)
        case .directInsert:
            return try await outputViaDirectInsert(text, destination: destination)
        }
    }

    func pasteText(_ text: String) async throws {
        guard !text.isEmpty else {
            throw OutputManagerError.emptyText
        }

        let destination = captureDestinationApp()
        try await pasteViaClipboard(
            text,
            restoreClipboard: true,
            allowSystemEventsFallback: !isVirtualMachineDestination(destination.bundleID)
        )
    }

    private func captureDestinationApp() -> (name: String?, bundleID: String?) {
        let app = frontmostApplicationProvider()
        return (app?.localizedName, app?.bundleIdentifier)
    }

    /// Clipboard mode is truly copy-only: the transcript is left on the pasteboard
    /// for the user to paste themselves, and the prior contents ride along in the
    /// result so callers can offer Undo. (Historically this mode pasted exactly like
    /// direct insert; users who had it stored were migrated to direct insert when the
    /// semantics were fixed — see SettingsStore.migrateOutputModeToCopyOnlySemanticsIfNeeded.)
    private func outputViaClipboard(
        _ text: String,
        destination: (name: String?, bundleID: String?)
    ) async throws -> OutputResult {
        let snapshot = try copyReplacingClipboard(text)
        return .copiedToClipboard(
            reason: .copyOnlyMode,
            previousClipboardSnapshot: snapshot,
            destinationAppName: destination.name,
            destinationAppBundleID: destination.bundleID
        )
    }

    /// Direct insert is paste-based: one atomic Cmd+V with clipboard snapshot/restore.
    /// (Character-by-character CGEvent typing was removed — the overlay-streaming
    /// architecture inserts final text exactly once, and paste is the only insertion
    /// primitive reliable across apps.) On paste failure the text is left on the
    /// clipboard so the user's words are never lost.
    ///
    /// Known VM hosts never use Unicode `virtualKey: 0` character injection (which
    /// hypervisors interpret as repeating "A"). They always take the clipboard paste
    /// path with explicit physical Command events, and skip System Events fallback.
    private func outputViaDirectInsert(
        _ text: String,
        destination: (name: String?, bundleID: String?)
    ) async throws -> OutputResult {
        guard checkAccessibilityPermission() else {
            let snapshot = try copyReplacingClipboard(text)
            return .copiedToClipboard(
                reason: .accessibilityUnavailable,
                previousClipboardSnapshot: snapshot,
                destinationAppName: destination.name,
                destinationAppBundleID: destination.bundleID
            )
        }

        let isVMHost = isVirtualMachineDestination(destination.bundleID)
        if isVMHost {
            Log.output.info(
                "Frontmost app is a known VM host (\(destination.bundleID ?? "unknown")); using clipboard paste with physical Command modifiers"
            )
        }

        do {
            try await pasteViaClipboard(
                text,
                restoreClipboard: true,
                allowSystemEventsFallback: !isVMHost
            )
            return .pasted(
                destinationAppName: destination.name,
                destinationAppBundleID: destination.bundleID
            )
        } catch is CancellationError {
            // The operation was cancelled before the paste keystroke landed; abort
            // cleanly instead of stomping the clipboard with the transcript.
            throw CancellationError()
        } catch {
            Log.output.error("Direct insert paste failed; leaving text on clipboard: \(error.localizedDescription)")
            try copyToClipboard(text)
            return .copiedToClipboard(
                reason: .pasteFailed,
                destinationAppName: destination.name,
                destinationAppBundleID: destination.bundleID
            )
        }
    }

    /// Tries a silent Accessibility write into the remembered field first (no focus change).
    /// Apps that ignore it (Chromium/Electron, terminals) get a hop: activate the target,
    /// refocus the field, paste, then return the user to the app they moved to.
    private func outputToRememberedTarget(_ text: String, target: InsertionTarget) async throws -> OutputResult {
        let name = target.app.localizedName
        let bundleID = target.app.bundleIdentifier
        guard checkAccessibilityPermission(), !target.app.isTerminated else {
            let snapshot = try copyReplacingClipboard(text)
            return .copiedToClipboard(
                reason: checkAccessibilityPermission() ? .pasteFailed : .accessibilityUnavailable,
                previousClipboardSnapshot: snapshot,
                destinationAppName: name,
                destinationAppBundleID: bundleID
            )
        }

        if let element = target.element, await AXInsertion.insert(text, into: element) {
            Log.output.info("Inserted into remembered field via Accessibility in \(bundleID ?? "unknown")")
            return .pasted(destinationAppName: name, destinationAppBundleID: bundleID)
        }

        let returnTo = frontmostApplicationProvider()
        target.app.activate(options: [.activateIgnoringOtherApps])
        if let element = target.element {
            AXInsertion.focus(element)
        }
        try await Task.sleep(nanoseconds: 150_000_000)

        do {
            try await pasteViaClipboard(
                text,
                restoreClipboard: true,
                allowSystemEventsFallback: !isVirtualMachineDestination(bundleID)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.output.error("Paste into remembered target failed; leaving text on clipboard: \(error.localizedDescription)")
            try copyToClipboard(text)
            return .copiedToClipboard(reason: .pasteFailed, destinationAppName: name, destinationAppBundleID: bundleID)
        }

        if let returnTo, returnTo.processIdentifier != target.app.processIdentifier {
            returnTo.activate(options: [.activateIgnoringOtherApps])
        }
        Log.output.info("Pasted into remembered target \(bundleID ?? "unknown") via focus hop")
        return .pasted(destinationAppName: name, destinationAppBundleID: bundleID)
    }

    private func isVirtualMachineDestination(_ bundleIdentifier: String?) -> Bool {
        virtualMachineHostChecker(bundleIdentifier)
    }

    private func pasteViaClipboard(
        _ text: String,
        restoreClipboard: Bool,
        allowSystemEventsFallback: Bool = true
    ) async throws {
        let previousSnapshot = restoreClipboard ? clipboard.captureSnapshot() : .empty
        let targetApplication = frontmostApplicationProvider()
        let success = clipboard.copyToClipboard(text)

        guard success else {
            Log.output.error("Failed to write to clipboard")
            throw OutputManagerError.clipboardWriteFailed
        }

        let temporaryClipboardChangeCount = clipboard.currentChangeCount()

        do {
            try await Task.sleep(nanoseconds: 120_000_000)
            targetApplication?.activate(options: [.activateIgnoringOtherApps])
            try await Task.sleep(nanoseconds: 80_000_000)
            try await keySimulation.simulatePaste(allowSystemEventsFallback: allowSystemEventsFallback)
        } catch {
            if restoreClipboard && shouldRestoreClipboard(expectedChangeCount: temporaryClipboardChangeCount, insertedText: text) {
                let restored = clipboard.restoreSnapshot(previousSnapshot)
                if !restored {
                    Log.output.error("Failed to restore clipboard snapshot after paste failure")
                }
            }

            throw error
        }

        // The paste keystroke landed — the insertion is committed. Run the deferred
        // clipboard restore in an unstructured task so cancelling the surrounding
        // operation can neither skip the restore nor turn this success into a failure
        // (which previously dropped history and re-stomped the clipboard on Escape
        // during the restore window).
        guard restoreClipboard else { return }
        let restoreTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if self.shouldRestoreClipboard(expectedChangeCount: temporaryClipboardChangeCount, insertedText: text) {
                let restored = self.clipboard.restoreSnapshot(previousSnapshot)
                if !restored {
                    Log.output.error("Failed to restore clipboard snapshot")
                }
            } else {
                Log.output.info("Skipping clipboard restore because clipboard changed externally")
            }
        }
        await restoreTask.value
    }

    func copyToClipboard(_ text: String) throws {
        let success = clipboard.copyToClipboard(text)

        guard success else {
            throw OutputManagerError.clipboardWriteFailed
        }
    }

    /// Snapshots the pasteboard, writes `text`, and returns the prior contents for undo.
    @discardableResult
    func copyReplacingClipboard(_ text: String) throws -> ClipboardSnapshot {
        let snapshot = clipboard.captureSnapshot()
        try copyToClipboard(text)
        return snapshot
    }

    func captureClipboardSnapshot() -> ClipboardSnapshot {
        clipboard.captureSnapshot()
    }

    @discardableResult
    func restoreClipboardSnapshot(_ snapshot: ClipboardSnapshot) -> Bool {
        clipboard.restoreSnapshot(snapshot)
    }

    func checkAccessibilityPermission() -> Bool {
        accessibilityPermissionChecker()
    }

    func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func shouldRestoreClipboard(expectedChangeCount: Int, insertedText: String) -> Bool {
        clipboard.currentChangeCount() == expectedChangeCount
            || clipboard.currentStringContent() == insertedText
    }

}

// MARK: - Remembered insertion target

struct InsertionTarget {
    let app: NSRunningApplication
    let element: AXUIElement?

    func userMovedAway(frontmost: NSRunningApplication?) -> Bool {
        guard frontmost?.processIdentifier == app.processIdentifier else { return true }
        guard let element, let focused = AXInsertion.focusedElement() else { return false }
        return !CFEqual(element, focused)
    }
}

enum AXInsertion {
    static func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Replaces the field's selection with `text`. Many apps report success without
    /// changing anything, so success means the field's value actually changed.
    static func insert(_ text: String, into element: AXUIElement) async -> Bool {
        guard let before = stringValue(element) else { return false }
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        guard status == .success else { return false }
        try? await Task.sleep(nanoseconds: 50_000_000)
        return stringValue(element) != before
    }

    static func focus(_ element: AXUIElement) {
        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success,
           let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
            let windowElement = window as! AXUIElement
            AXUIElementSetAttributeValue(windowElement, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
        }
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private static func stringValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
