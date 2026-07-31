//
//  MLXWhisperEngineTests.swift
//  PindropTests
//
//  Created on 2026-07-31.
//
//  Unit suite is strictly offline: never calls loadModel(name:) with download
//  enabled / bare model names that would hit Hugging Face. Network-backed
//  coverage lives in MLXWhisperEngineIntegrationTests (PINDROP_RUN_INTEGRATION_TESTS).
//

import Foundation
import Testing
@testable import Pindrop

@MainActor
@Suite("MLXWhisperEngine (unit, offline)")
struct MLXWhisperEngineTests {
    private func makeEngine() -> MLXWhisperEngine {
        MLXWhisperEngine()
    }

    private func makeFloat32AudioData(sampleCount: Int = 16_000) -> Data {
        var samples = [Float](repeating: 0, count: sampleCount)
        return samples.withUnsafeMutableBytes { Data($0) }
    }

    private func makeEmptyDownloadBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-mlx-whisper-unit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func nonexistentModelPath() -> String {
        "/nonexistent/pindrop/mlx-whisper/\(UUID().uuidString)"
    }

    @Test func initialStateIsUnloaded() {
        let engine = makeEngine()
        #expect(engine.state == .unloaded)
        #expect(engine.error == nil)
    }

    @Test func loadModelWithInvalidPathThrowsError() async throws {
        let engine = makeEngine()
        do {
            try await engine.loadModel(modelPath: nonexistentModelPath())
            Issue.record("Should throw error for invalid model path")
        } catch {
            #expect(engine.state == .error)
            #expect(engine.error != nil)
        }
    }

    @Test func loadModelByNameWithoutDownloadFailsOffline() async throws {
        let engine = makeEngine()
        let downloadBase = try makeEmptyDownloadBase()
        defer { try? FileManager.default.removeItem(at: downloadBase) }

        do {
            try await engine.loadModel(
                name: "mlx-community/whisper-tiny",
                downloadBase: downloadBase,
                download: false
            )
            Issue.record("Expected offline name load to fail when model is absent")
        } catch {
            #expect(engine.state == .error)
            #expect(engine.error != nil)
        }
    }

    @Test func unloadModelResetsState() async throws {
        let engine = makeEngine()
        do {
            try await engine.loadModel(modelPath: nonexistentModelPath())
        } catch {}

        await engine.unloadModel()
        #expect(engine.state == .unloaded)
        #expect(engine.error == nil)
    }

    @Test func transcribeWithoutModelThrows() async throws {
        let engine = makeEngine()
        do {
            _ = try await engine.transcribe(audioData: makeFloat32AudioData())
            Issue.record("Should throw when model is not loaded")
        } catch MLXWhisperEngine.EngineError.modelNotLoaded {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func transcribeEmptyAudioThrows() async throws {
        let engine = makeEngine()
        do {
            try await engine.loadModel(modelPath: nonexistentModelPath())
        } catch {}

        do {
            _ = try await engine.transcribe(audioData: Data())
            Issue.record("Should throw for empty audio")
        } catch MLXWhisperEngine.EngineError.modelNotLoaded {
        } catch MLXWhisperEngine.EngineError.invalidAudioData {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func mapsHindiAndMalayalamWhisperCodesToAppLanguage() {
        #expect(MLXWhisperEngine.appLanguage(forWhisperLanguageCode: "hi") == .hindi)
        #expect(MLXWhisperEngine.appLanguage(forWhisperLanguageCode: "ml") == .malayalam)
        #expect(MLXWhisperEngine.appLanguage(forWhisperLanguageCode: "HI") == .hindi)
        #expect(MLXWhisperEngine.appLanguage(forWhisperLanguageCode: " ml ") == .malayalam)
    }

    @Test func engineErrorDescriptions() {
        #expect(MLXWhisperEngine.EngineError.modelNotLoaded.errorDescription == "Model is not loaded")
        #expect(MLXWhisperEngine.EngineError.invalidAudioData.errorDescription == "Invalid audio data")
        let message = "boom"
        #expect(
            MLXWhisperEngine.EngineError.transcriptionFailed(message).errorDescription
                == "Transcription failed: \(message)"
        )
    }

    @Test func migratesLegacyWhisperKitModelNames() {
        #expect(
            ModelManager.migratedMLXModelName(from: "openai_whisper-base.en")
                == "mlx-community/whisper-base.en-mlx"
        )
        #expect(
            ModelManager.migratedMLXModelName(from: "openai_whisper-large-v3_turbo")
                == "mlx-community/whisper-large-v3-turbo"
        )
        #expect(
            ModelManager.migratedMLXModelName(from: "mlx-community/whisper-tiny")
                == "mlx-community/whisper-tiny"
        )
        #expect(ModelManager.migratedMLXModelName(from: "parakeet-tdt-0.6b-v3") == nil)
    }
}

@MainActor
@Suite(
    "MLXWhisperEngine (integration, network)",
    .enabled(if: ProcessInfo.processInfo.environment["PINDROP_RUN_INTEGRATION_TESTS"] == "1"),
    .disabled(
        if: ProcessInfo.processInfo.environment["PINDROP_RUN_INTEGRATION_TESTS"] != "1",
        "MLX Whisper network/model-download tests are disabled by default. Run with PINDROP_RUN_INTEGRATION_TESTS=1."
    )
)
struct MLXWhisperEngineIntegrationTests {
    @Test func loadTinyModelByNameDownloadsAndSetsReady() async throws {
        let engine = MLXWhisperEngine()
        defer {
            Task { @MainActor in await engine.unloadModel() }
        }
        try await engine.loadModel(name: "mlx-community/whisper-tiny", downloadBase: nil, download: true)
        #expect(engine.state == .ready)
    }
}
