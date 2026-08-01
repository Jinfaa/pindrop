//
//  ParakeetEngineTests.swift
//  PindropTests
//
//  Created on 2026-01-30.
//
//  Unit suite is strictly offline: never calls loadModel(name:) with download
//  enabled / bare model names that would hit Hugging Face.
//

import Foundation
import Testing
@testable import Pindrop

@MainActor
@Suite("ParakeetEngine (unit, offline)")
struct ParakeetEngineTests {
    private func makeEngine() -> ParakeetEngine {
        ParakeetEngine()
    }

    private func makeFloat32AudioData(sampleCount: Int = 16_000) -> Data {
        var samples = [Float](repeating: 0, count: sampleCount)
        return samples.withUnsafeMutableBytes { Data($0) }
    }

    private func makeEmptyDownloadBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-mlx-parakeet-unit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func nonexistentModelPath() -> String {
        "/nonexistent/pindrop/mlx-parakeet/\(UUID().uuidString)"
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
                name: "mlx-community/parakeet-tdt-0.6b-v2",
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
        } catch ParakeetEngine.EngineError.modelNotLoaded {
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
        } catch ParakeetEngine.EngineError.modelNotLoaded {
        } catch ParakeetEngine.EngineError.invalidAudioData {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func engineErrorDescriptions() {
        #expect(ParakeetEngine.EngineError.modelNotLoaded.errorDescription == "Model is not loaded")
        #expect(ParakeetEngine.EngineError.invalidAudioData.errorDescription == "Invalid audio data")
        let message = "boom"
        #expect(
            ParakeetEngine.EngineError.transcriptionFailed(message).errorDescription
                == "Transcription failed: \(message)"
        )
        #expect(
            ParakeetEngine.EngineError.modelNotFound("x").errorDescription?
                .contains("x") == true
        )
    }

    @Test func migratesLegacyParakeetCoreMLNames() {
        #expect(
            ModelManager.migratedMLXModelName(from: "parakeet-tdt-0.6b-v2")
                == "mlx-community/parakeet-tdt-0.6b-v2"
        )
        #expect(
            ModelManager.migratedMLXModelName(from: "parakeet-tdt-0.6b-v3")
                == "mlx-community/parakeet-tdt-0.6b-v3"
        )
        #expect(
            ModelManager.migratedMLXModelName(from: "parakeet-tdt-1.1b")
                == "mlx-community/parakeet-tdt-1.1b"
        )
        #expect(
            ModelManager.migratedMLXModelName(from: "mlx-community/parakeet-tdt-0.6b-v3")
                == "mlx-community/parakeet-tdt-0.6b-v3"
        )
    }
}
