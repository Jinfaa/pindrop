//
//  ParakeetEngineTests.swift
//  PindropTests
//
//  Created on 2026-01-30.
//

import Foundation
import Testing
@testable import Pindrop

@MainActor
@Suite("ParakeetEngine CoreML (unit, offline)")
struct ParakeetEngineTests {
    @Test func initialStateIsUnloaded() {
        let engine = ParakeetEngine()
        #expect(engine.state == .unloaded)
        #expect(engine.error == nil)
    }

    @Test func transcribeRequiresLoadedModel() async {
        let engine = ParakeetEngine()
        do {
            _ = try await engine.transcribe(audioData: Data(count: 64))
            Issue.record("Should throw")
        } catch ParakeetEngine.EngineError.modelNotLoaded {
        } catch {
            Issue.record("Unexpected \(error)")
        }
    }

    @Test func unloadFromUnloadedIsSafe() async {
        let engine = ParakeetEngine()
        await engine.unloadModel()
        #expect(engine.state == .unloaded)
    }
}
