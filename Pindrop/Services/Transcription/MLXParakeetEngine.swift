//
//  MLXParakeetEngine.swift
//  Pindrop
//
//  Created on 2026-01-30.
//

import Foundation
import MLX
import MLXAudioSTT

@MainActor
public final class MLXParakeetEngine: TranscriptionEngine, CapabilityReporting {

    public static var capabilities: AudioEngineCapabilities {
        [.transcription]
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
                return "MLX Parakeet model '\(name)' is not available locally"
            }
        }
    }

    public private(set) var state: TranscriptionEngineState = .unloaded
    public private(set) var error: Error?

    private var model: ParakeetModel?
    private var loadedRepoID: String?

    public init() {}

    public func loadModel(path: String) async throws {
        guard state != .loading else { return }

        state = .loading
        error = nil

        let wallStart = CFAbsoluteTimeGetCurrent()
        Log.boot.info("MLXParakeetEngine.loadModel(path) begin")

        do {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            model = try ParakeetModel.fromDirectory(directory)
            loadedRepoID = directory.lastPathComponent
            state = .ready
            Log.boot.info(
                "MLXParakeetEngine.loadModel(path) ready total=\(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - wallStart))"
            )
        } catch {
            Log.boot.error(
                "MLXParakeetEngine.loadModel(path) failed after \(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - wallStart)) \(error.localizedDescription)"
            )
            self.error = error
            state = .error
            throw error
        }
    }

    public func loadModel(name: String, downloadBase: URL? = nil) async throws {
        try await loadModel(name: name, downloadBase: downloadBase, download: true)
    }

    public func loadModel(name: String, downloadBase: URL?, download: Bool) async throws {
        guard state != .loading else { return }

        state = .loading
        error = nil

        let wallStart = CFAbsoluteTimeGetCurrent()
        Log.boot.info(
            "MLXParakeetEngine.loadModel(name) begin name=\(name) download=\(download)"
        )

        do {
            let cache = MLXWhisperModelStore.hubCache(downloadBase: downloadBase)
            if download {
                model = try await ParakeetModel.fromPretrained(name, cache: cache)
            } else {
                let localURL = MLXWhisperModelStore.modelDirectory(for: name, cache: cache)
                guard MLXWhisperModelStore.isModelPresent(at: localURL) else {
                    throw EngineError.modelNotFound(name)
                }
                model = try ParakeetModel.fromDirectory(localURL)
            }
            loadedRepoID = name
            state = .ready
            Log.boot.info(
                "MLXParakeetEngine.loadModel(name) ready total=\(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - wallStart))"
            )
        } catch {
            Log.boot.error(
                "MLXParakeetEngine.loadModel(name) failed after \(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - wallStart)) \(error.localizedDescription)"
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
            if let languageCode = options.language.whisperLanguageCode {
                parameters = STTGenerateParameters(
                    maxTokens: parameters.maxTokens,
                    temperature: parameters.temperature,
                    topP: parameters.topP,
                    topK: parameters.topK,
                    verbose: false,
                    language: languageCode,
                    chunkDuration: parameters.chunkDuration,
                    minChunkDuration: parameters.minChunkDuration,
                    repetitionPenalty: parameters.repetitionPenalty,
                    repetitionContextSize: parameters.repetitionContextSize
                )
            }

            let output = model.generate(audio: audio, generationParameters: parameters)
            state = .ready
            return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            state = .ready
            self.error = error
            throw EngineError.transcriptionFailed(error.localizedDescription)
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
}
