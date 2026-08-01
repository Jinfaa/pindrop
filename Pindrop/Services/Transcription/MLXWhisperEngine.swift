//
//  MLXWhisperEngine.swift
//  Pindrop
//
//  Created on 2026-07-31.
//

import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT

@MainActor
public final class MLXWhisperEngine: TranscriptionEngine, CapabilityReporting {

    public static var capabilities: AudioEngineCapabilities {
        [.transcription, .languageDetection]
    }

    public enum EngineError: Error, LocalizedError {
        case modelNotLoaded
        case invalidAudioData
        case transcriptionFailed(String)
        case modelNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "Model is not loaded"
            case .invalidAudioData:
                return "Invalid audio data"
            case .transcriptionFailed(let message):
                return "Transcription failed: \(message)"
            case .modelNotFound(let name):
                return "MLX Whisper model '\(name)' is not available locally"
            }
        }
    }

    public private(set) var state: TranscriptionEngineState = .unloaded
    public private(set) var error: Error?

    private var model: WhisperModel?
    private var loadedRepoID: String?

    public init() {}

    public func loadModel(path: String) async throws {
        guard state != .loading else { return }

        state = .loading
        error = nil

        let wallStart = CFAbsoluteTimeGetCurrent()
        Log.boot.info("MLXWhisperEngine.loadModel(path) begin")

        do {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let cache = MLXWhisperModelStore.hubCache
            model = try await WhisperModel.fromDirectory(directory, cache: cache)
            loadedRepoID = directory.lastPathComponent
            state = .ready
            Log.boot.info(
                "MLXWhisperEngine.loadModel(path) ready total=\(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - wallStart))"
            )
        } catch {
            Log.boot.error(
                "MLXWhisperEngine.loadModel(path) failed after \(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - wallStart)) \(error.localizedDescription)"
            )
            self.error = error
            state = .error
            throw error
        }
    }

    public func loadModel(name: String, downloadBase: URL?) async throws {
        try await loadModel(name: name, downloadBase: downloadBase, download: true)
    }

    public func loadModel(name: String, downloadBase: URL?, download: Bool) async throws {
        guard state != .loading else { return }

        state = .loading
        error = nil

        let wallStart = CFAbsoluteTimeGetCurrent()
        Log.boot.info(
            "MLXWhisperEngine.loadModel(name) begin name=\(name) download=\(download)"
        )

        do {
            let cache = MLXWhisperModelStore.hubCache(downloadBase: downloadBase)
            if download {
                model = try await WhisperModel.fromPretrained(name, cache: cache)
            } else {
                let localURL = MLXWhisperModelStore.modelDirectory(for: name, cache: cache)
                guard MLXWhisperModelStore.isModelPresent(at: localURL) else {
                    throw EngineError.modelNotFound(name)
                }
                model = try await WhisperModel.fromDirectory(localURL, cache: cache)
            }
            loadedRepoID = name
            state = .ready
            Log.boot.info(
                "MLXWhisperEngine.loadModel(name) ready total=\(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - wallStart))"
            )
        } catch {
            Log.boot.error(
                "MLXWhisperEngine.loadModel(name) failed after \(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - wallStart)) \(error.localizedDescription)"
            )
            self.error = error
            state = .error
            throw error
        }
    }

    public func transcribe(audioData: Data, options: TranscriptionOptions) async throws -> String {
        guard state == .ready, let model else {
            throw EngineError.modelNotLoaded
        }

        guard !audioData.isEmpty else {
            throw EngineError.invalidAudioData
        }

        state = .transcribing

        do {
            let samples = audioData.withUnsafeBytes { bytes in
                Array(bytes.bindMemory(to: Float.self))
            }
            guard !samples.isEmpty else {
                throw EngineError.invalidAudioData
            }

            let audio = MLXArray(samples)
            var parameters = model.defaultGenerationParameters
            parameters = STTGenerateParameters(
                maxTokens: parameters.maxTokens,
                temperature: parameters.temperature,
                topP: parameters.topP,
                topK: parameters.topK,
                verbose: false,
                language: options.language.whisperLanguageCode,
                chunkDuration: parameters.chunkDuration,
                minChunkDuration: parameters.minChunkDuration,
                repetitionPenalty: parameters.repetitionPenalty,
                repetitionContextSize: parameters.repetitionContextSize
            )

            let output = model.generate(audio: audio, generationParameters: parameters)
            state = .ready
            return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            state = .ready
            self.error = error
            throw error
        }
    }

    public func detectLanguage(samples: [Float], sampleRate: Int) async throws -> AppLanguage? {
        guard state == .ready, let model else {
            throw EngineError.modelNotLoaded
        }

        guard !samples.isEmpty else {
            throw EngineError.invalidAudioData
        }

        state = .transcribing

        do {
            let audio = MLXArray(samples)
            let parameters = STTGenerateParameters(
                maxTokens: 1,
                temperature: 0,
                language: nil
            )
            let output = model.generate(audio: audio, generationParameters: parameters)
            state = .ready
            guard let code = output.language else { return nil }
            return Self.appLanguage(forWhisperLanguageCode: code)
        } catch {
            state = .ready
            self.error = error
            throw error
        }
    }

    public func unloadModel() async {
        model = nil
        loadedRepoID = nil
        error = nil
        state = .unloaded
    }

    public func loadModel(modelName: String, downloadBase: URL? = nil, download: Bool = true) async throws {
        try await loadModel(name: modelName, downloadBase: downloadBase, download: download)
    }

    public func loadModel(modelPath: String) async throws {
        try await loadModel(path: modelPath)
    }

    static func appLanguage(forWhisperLanguageCode code: String) -> AppLanguage? {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedCode.isEmpty else { return nil }

        return AppLanguage.allCases.first { language in
            language != .automatic &&
                (language.whisperLanguageCode?.lowercased() == normalizedCode ||
                 language.rawValue.lowercased() == normalizedCode)
        }
    }
}

enum MLXWhisperModelStore {
    static var modelsBaseURL: URL {
        HubCache.default.cacheDirectory
    }

    static var hubCache: HubCache {
        .default
    }

    static func hubCache(downloadBase: URL?) -> HubCache {
        guard let downloadBase else { return .default }
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Pindrop", isDirectory: true)
            .standardizedFileURL
        if downloadBase.standardizedFileURL == appSupport {
            return .default
        }
        return HubCache(cacheDirectory: downloadBase.appendingPathComponent("models", isDirectory: true))
    }

    static func modelDirectory(for repoID: String, cache: HubCache = hubCache) -> URL {
        let leaf = repoID.replacingOccurrences(of: "/", with: "_")
        return cache.cacheDirectory
            .appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent(leaf, isDirectory: true)
    }

    static func isModelPresent(at directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey]
              )
        else {
            return false
        }

        return files.contains { file in
            guard file.pathExtension == "safetensors" else { return false }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return size > 0
        }
    }

    static func download(
        repoID: String,
        expectedByteCount: Int64? = nil,
        progressHandler: (@MainActor @Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {
        guard let id = Repo.ID(rawValue: repoID) else {
            throw MLXWhisperEngine.EngineError.modelNotFound(repoID)
        }
        let cache = hubCache
        let client = HubClient(cache: cache)
        let progressRef = ProgressObservationBox()
        let report = Progress(totalUnitCount: 1000)
        let poller = Task { @MainActor in
            var lastFraction: Double = -1
            while !Task.isCancelled {
                let fraction = resolvedDownloadFraction(
                    hubProgress: progressRef.progress,
                    repoID: repoID,
                    expectedByteCount: expectedByteCount
                )
                if abs(fraction - lastFraction) >= 0.002 || (fraction >= 0.99 && lastFraction < 0.99) {
                    lastFraction = fraction
                    report.completedUnitCount = Int64((fraction * 1000).rounded(.down))
                    progressHandler?(report)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { poller.cancel() }

        do {
            let url = try await ModelUtils.resolveOrDownloadModel(
                client: client,
                cache: cache,
                repoID: id,
                requiredExtension: "safetensors",
                additionalMatchingPatterns: ["*.json", "*.txt", "*.model", "merges.txt", "vocab.json"],
                progressHandler: { progress in
                    progressRef.progress = progress
                }
            )
            report.completedUnitCount = report.totalUnitCount
            await progressHandler?(report)
            return url
        } catch {
            poller.cancel()
            throw error
        }
    }

    static func loadPretrained(repoID: String) async throws -> WhisperModel {
        try await WhisperModel.fromPretrained(repoID, cache: hubCache)
    }

    static func resolvedDownloadFraction(
        hubProgress: Progress?,
        repoID: String,
        expectedByteCount: Int64?
    ) -> Double {
        let hubFraction = saneProgressFraction(hubProgress)
        let diskFraction = diskDownloadFraction(repoID: repoID, expectedByteCount: expectedByteCount)
        return min(0.99, max(hubFraction, diskFraction))
    }

    static func saneProgressFraction(_ progress: Progress?) -> Double {
        guard let progress else { return 0 }
        let total = progress.totalUnitCount
        let completed = progress.completedUnitCount
        guard total > 0, completed >= 0, completed <= total else { return 0 }
        let fraction = Double(completed) / Double(total)
        guard fraction.isFinite, fraction >= 0 else { return 0 }
        return min(1, fraction)
    }

    static func diskDownloadFraction(repoID: String, expectedByteCount: Int64?) -> Double {
        guard let expectedByteCount, expectedByteCount > 0 else { return 0 }
        let observed = observedDownloadBytes(repoID: repoID)
        guard observed > 0 else { return 0 }
        return min(1, Double(observed) / Double(expectedByteCount))
    }

    static func observedDownloadBytes(repoID: String) -> Int64 {
        let leafBytes = directoryByteSize(modelDirectory(for: repoID))
        var hubBlobBytes: Int64 = 0
        if let id = Repo.ID(rawValue: repoID) {
            let blobs = hubCache.repoDirectory(repo: id, kind: .model)
                .appendingPathComponent("blobs", isDirectory: true)
            hubBlobBytes = directoryByteSize(blobs)
        }
        return max(leafBytes, hubBlobBytes) + recentCFNetworkTempBytes()
    }

    static func directoryByteSize(_ directory: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              )
        else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    static func recentCFNetworkTempBytes(now: Date = Date()) -> Int64 {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let files = try? fm.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        let cutoff = now.addingTimeInterval(-2 * 60 * 60)
        var total: Int64 = 0
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix("CFNetworkDownload_"), name.hasSuffix(".tmp") else { continue }
            let values = try? file.resourceValues(forKeys: [
                .contentModificationDateKey, .fileSizeKey, .isRegularFileKey
            ])
            guard values?.isRegularFile == true else { continue }
            guard let modified = values?.contentModificationDate, modified >= cutoff else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}

private final class ProgressObservationBox: @unchecked Sendable {
    var progress: Progress?
}
