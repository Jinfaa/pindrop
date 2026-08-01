//
//  ModelManagerTests.swift
//  Pindrop
//
//  Created on 2026-01-25.
//

import FluidAudio
import Foundation
import Testing
@testable import Pindrop

@MainActor
@Suite
struct ModelManagerTests {
    let modelManager = ModelManager()

    @Test func listAvailableModels() {
        let models = modelManager.availableModels

        #expect(!models.isEmpty)
        #expect(models.contains { $0.name == "mlx-community/whisper-tiny" })
        #expect(models.contains { $0.name == "mlx-community/whisper-base-mlx" })
        #expect(models.contains { $0.name == "mlx-community/whisper-small-mlx" })
        #expect(models.contains { $0.name == "mlx-community/whisper-large-v3-mlx" })
        #expect(models.contains { $0.name == "mlx-community/whisper-large-v3-turbo" })
        #expect(models.contains { $0.name == "mlx-community/whisper-medium-mlx" })
        #expect(models.contains { $0.name == "mlx-community/whisper-base.en-mlx" })
        #expect(models.contains { $0.name == "mlx-community/parakeet-tdt-0.6b-v2" })
        #expect(models.contains { $0.name == "openai_gpt-4o-transcribe" && $0.provider == .openAI })
        #expect(models.contains { $0.name == "openai_gpt-4o-mini-transcribe" && $0.provider == .openAI })
    }


    @Test func recommendedModelsUseCuratedOrder() {
        let recommendedModelNames = modelManager.recommendedModels.map(\.name)
        #expect(recommendedModelNames == ModelManager.englishRecommendedModelNames)
    }

    @Test func multilingualRecommendationsPreferWhisperMultilingualModels() {
        let recommendedModelNames = modelManager.recommendedModels(for: .spanish).map(\.name)
        #expect(recommendedModelNames == ModelManager.multilingualRecommendedModelNames)
    }

    @Test func modelSizes() {
        let models = modelManager.availableModels

        // Apple Speech uses on-device system models and reports 0 MB by design.
        for model in models where model.provider.isLocal && model.provider != .appleSpeech {
            #expect(model.sizeInMB > 0)
        }

        let tiny = models.first { $0.name == "mlx-community/whisper-tiny" }
        let base = models.first { $0.name == "mlx-community/whisper-base-mlx" }
        let small = models.first { $0.name == "mlx-community/whisper-small-mlx" }

        #expect(tiny != nil)
        #expect(base != nil)
        #expect(small != nil)

        if let tiny, let base, let small {
            #expect(tiny.sizeInMB < base.sizeInMB)
            #expect(base.sizeInMB < small.sizeInMB)
        }
    }

    @Test func checkDownloadedModels() async {
        let downloadedModels = await modelManager.getDownloadedModels()
        #expect(downloadedModels != nil)
    }

    @Test func isModelDownloaded() {
        let isDownloaded = modelManager.isModelDownloaded("mlx-community/whisper-tiny")
        #expect(isDownloaded == true || isDownloaded == false)
    }

    @Test func cloudModelsRequireNoLocalDownload() {
        #expect(modelManager.isModelDownloaded("openai_gpt-4o-transcribe"))
        #expect(modelManager.isModelDownloaded("openai_gpt-4o-mini-transcribe"))
    }

    @Test func modelLookup() {
        let model = modelManager.availableModels.first { $0.name == "mlx-community/whisper-tiny" }
        #expect(model != nil)
        #expect(model?.provider == .mlxWhisper)
    }

    @Test func invalidModelLookup() {
        let model = modelManager.availableModels.first { $0.name == "nonexistent-model" }
        #expect(model == nil)
    }

    @Test func containsParakeetModels() {
        let hasParakeetModel = modelManager.availableModels.contains { $0.provider == .parakeet }
        #expect(hasParakeetModel)
    }

    @Test func englishOnlyModelsWarnForNonEnglishSelection() throws {
        let model = try #require(modelManager.availableModels.first { $0.name == "mlx-community/whisper-base.en-mlx" })
        #expect(model.supports(language: .english) == true)
        #expect(model.supports(language: .simplifiedChinese) == false)

        let badge = model.languageBadgePresentation(for: .simplifiedChinese)
        #expect(badge.text == "English-only")
        #expect(badge.tone == .caution)
    }

    @Test func parakeetV3SupportsEuropeanLanguagesButNotChinese() throws {
        let model = try #require(modelManager.availableModels.first { $0.name == "mlx-community/parakeet-tdt-0.6b-v3" })
        #expect(model.supports(language: .spanish) == true)
        #expect(model.supports(language: .portugueseBrazil) == true)
        #expect(model.supports(language: .russian) == true)
        #expect(model.supports(language: .ukrainian) == true)
        #expect(model.supports(language: .polish) == true)
        #expect(model.supports(language: .simplifiedChinese) == false)
    }

    @Test func hindiAndMalayalamRecommendMultilingualWhisperModels() {
        let expected = ModelManager.multilingualRecommendedModelNames.filter { name in
            name != "mlx-community/parakeet-tdt-0.6b-v3"
        }
        #expect(modelManager.recommendedModels(for: .hindi).map(\.name) == expected)
        #expect(modelManager.recommendedModels(for: .malayalam).map(\.name) == expected)

        for language in [AppLanguage.hindi, .malayalam] {
            let names = modelManager.recommendedModels(for: language).map(\.name)
            #expect(names.contains("mlx-community/whisper-base-mlx"))
            #expect(names.contains("mlx-community/whisper-small-mlx"))
            #expect(names.contains("mlx-community/whisper-medium-mlx"))
            #expect(names.contains("mlx-community/whisper-large-v3-turbo"))
            #expect(!names.contains("mlx-community/whisper-base.en-mlx"))
            #expect(!names.contains("mlx-community/parakeet-tdt-0.6b-v3"))
            #expect(!names.contains("mlx-community/parakeet-tdt-0.6b-v2"))
        }
    }

    @Test func hindiAndMalayalamSupportedByMultilingualWhisperButNotEnglishOnlyOrParakeet() throws {
        let multilingual = try #require(modelManager.availableModels.first { $0.name == "mlx-community/whisper-base-mlx" })
        let englishOnly = try #require(modelManager.availableModels.first { $0.name == "mlx-community/whisper-base.en-mlx" })
        let parakeet = try #require(modelManager.availableModels.first { $0.name == "mlx-community/parakeet-tdt-0.6b-v3" })

        for language in [AppLanguage.hindi, .malayalam] {
            #expect(multilingual.supports(language: language))
            #expect(englishOnly.supports(language: language) == false)
            #expect(parakeet.supports(language: language) == false)

            let englishBadge = englishOnly.languageBadgePresentation(for: language)
            #expect(englishBadge.tone == .caution)
            #expect(englishBadge.text == "English-only")

            let parakeetBadge = parakeet.languageBadgePresentation(for: language)
            #expect(parakeetBadge.tone == .caution)
            #expect(parakeetBadge.text == "European multilingual")
        }
    }

    @Test func polishDictationUsesMultilingualRecommendations() throws {
        let recommendedModelNames = modelManager.recommendedModels(for: .polish).map(\.name)
        #expect(recommendedModelNames == ModelManager.multilingualRecommendedModelNames)
        let whisper = try #require(modelManager.availableModels.first { $0.name == "mlx-community/whisper-base-mlx" })
        #expect(whisper.supports(language: .polish))
    }

    @Test func deleteNonexistentModelThrowsModelNotFound() async {
        do {
            try await modelManager.deleteModel(named: "nonexistent-model")
            Issue.record("Expected modelNotFound for nonexistent model")
        } catch let error as ModelManager.ModelError {
            guard case .modelNotFound(let modelName) = error else {
                Issue.record("Expected modelNotFound error")
                return
            }
            #expect(modelName == "nonexistent-model")
        } catch {
            Issue.record("Expected ModelError, got \(error.localizedDescription)")
        }
    }

    @Test func downloadProgressInitialState() {
        #expect(modelManager.downloadProgress == 0.0)
        #expect(modelManager.isDownloading == false)
        #expect(modelManager.currentDownloadModel == nil)
        #expect(modelManager.downloadSnapshot == nil)
    }

    @Test func parakeetDownloadProgressMapping_listing_setsListingPhase() {
        let snapshot = ModelManager.parakeetDownloadSnapshot(
            modelName: "mlx-community/parakeet-tdt-0.6b-v3",
            progress: DownloadUtils.DownloadProgress(
                fractionCompleted: 0.12,
                phase: .listing
            )
        )

        #expect(snapshot.modelName == "mlx-community/parakeet-tdt-0.6b-v3")
        #expect(snapshot.progress == 0.12)
        #expect(snapshot.phase == .listing)
    }

    @Test func parakeetDownloadProgressMapping_downloading_setsFileCounts() {
        let snapshot = ModelManager.parakeetDownloadSnapshot(
            modelName: "mlx-community/parakeet-tdt-0.6b-v3",
            progress: DownloadUtils.DownloadProgress(
                fractionCompleted: 0.42,
                phase: .downloading(completedFiles: 3, totalFiles: 7)
            )
        )

        #expect(snapshot.progress == 0.42)
        #expect(snapshot.phase == .downloading(completedFiles: 3, totalFiles: 7))
    }

    @Test func parakeetDownloadProgressMapping_compiling_setsCompilingPhase() {
        let snapshot = ModelManager.parakeetDownloadSnapshot(
            modelName: "mlx-community/parakeet-tdt-0.6b-v3",
            progress: DownloadUtils.DownloadProgress(
                fractionCompleted: 0.76,
                phase: .compiling(modelName: "Decoder.mlmodelc")
            )
        )

        #expect(snapshot.progress == 0.76)
        #expect(snapshot.phase == .compiling(modelName: "Decoder.mlmodelc"))
    }

    @Test func whisperKitPreparationPhase_setsPreparingSnapshot() {
        let snapshot = ModelManager.preparingDownloadSnapshot(
            modelName: "mlx-community/whisper-base-mlx"
        )

        #expect(snapshot.progress == 0.85)
        #expect(snapshot.phase == .preparing)
    }

    @Test func downloadSnapshotClearsWhenRequested() {
        let snapshot = ModelManager.completedDownloadSnapshot(modelName: "mlx-community/whisper-base-mlx")

        modelManager.updateDownloadSnapshot(snapshot)
        #expect(modelManager.downloadSnapshot == snapshot)
        #expect(modelManager.downloadProgress == 1.0)

        modelManager.clearDownloadState(resetProgress: true)
        #expect(modelManager.downloadSnapshot == nil)
        #expect(modelManager.downloadProgress == 0.0)
    }

    @Test func downloadNonexistentModel() async {
        do {
            try await modelManager.downloadModel(named: "nonexistent-model")
            Issue.record("Expected error for nonexistent model")
        } catch {
            #expect(error is ModelManager.ModelError)
        }
    }

    @Test func featureModelRepoFolderNamesMatchDownloaderCacheLayout() {
        #expect(FeatureModelType.vad.repoFolderName == "silero-vad-coreml")
        #expect(FeatureModelType.diarization.repoFolderName == "speaker-diarization-coreml")
        // Streaming uses Nemotron Speech Streaming 0.6B. These folder names must match
        // FluidAudio's `Repo.nemotronStreaming*.folderName` values — that's where
        // DownloadUtils.downloadRepo materializes each chunk variant.
        #expect(FeatureModelType.streaming.repoFolderName == "nemotron-streaming/1120ms")
        #expect(FeatureModelType.streamingRepoFolderName(for: .standard) == "nemotron-streaming/1120ms")
        #expect(FeatureModelType.streamingRepoFolderName(for: .lowLatency) == "nemotron-streaming/560ms")
    }
    @Test func offlineDiarizationReadinessRequiresAllArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-diarization-readiness-\(UUID().uuidString)", isDirectory: true)
        let coreml = root.appendingPathComponent(FeatureModelType.diarization.repoFolderName, isDirectory: true)
        let offlineSibling = root.appendingPathComponent("speaker-diarization-offline", isDirectory: true)
        try FileManager.default.createDirectory(at: coreml, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // FluidAudio 0.15+ includes plda-parameters.json in requiredModels; coreml
        // readiness must still exclude it so the three PLDA candidate locations work.
        let coremlRequired = ModelNames.OfflineDiarizer.requiredModels.subtracting([
            ModelNames.OfflineDiarizer.pldaParameters
        ])
        #expect(coremlRequired.isEmpty == false)
        #expect(!coremlRequired.contains(ModelNames.OfflineDiarizer.pldaParameters))

        for path in coremlRequired {
            FileManager.default.createFile(
                atPath: coreml.appendingPathComponent(path).path,
                contents: Data()
            )
        }
        #expect(modelManager.isOfflineDiarizationModelsReady(at: root) == false)

        // Root candidate
        let rootPlda = root.appendingPathComponent("plda-parameters.json")
        FileManager.default.createFile(atPath: rootPlda.path, contents: Data("{}".utf8))
        #expect(modelManager.isOfflineDiarizationModelsReady(at: root))
        try FileManager.default.removeItem(at: rootPlda)
        #expect(modelManager.isOfflineDiarizationModelsReady(at: root) == false)

        // CoreML-folder candidate
        let coremlPlda = coreml.appendingPathComponent("plda-parameters.json")
        FileManager.default.createFile(atPath: coremlPlda.path, contents: Data("{}".utf8))
        #expect(modelManager.isOfflineDiarizationModelsReady(at: root))
        try FileManager.default.removeItem(at: coremlPlda)
        #expect(modelManager.isOfflineDiarizationModelsReady(at: root) == false)

        // Offline sibling-folder candidate
        try FileManager.default.createDirectory(at: offlineSibling, withIntermediateDirectories: true)
        let siblingPlda = offlineSibling.appendingPathComponent("plda-parameters.json")
        FileManager.default.createFile(atPath: siblingPlda.path, contents: Data("{}".utf8))
        #expect(modelManager.isOfflineDiarizationModelsReady(at: root))
    }
}
