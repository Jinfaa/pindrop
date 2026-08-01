//
//  ModelManager.swift
//  Pindrop
//
//  Created on 2026-01-25.
//

import Foundation
import FluidAudio
import MLXAudioSTT

@MainActor
@Observable
class ModelManager {
    /// Optional telemetry peer, injected by AppCoordinator after construction.
    /// Download start/failure signals are dropped entirely when nil or opted out.
    @ObservationIgnored var telemetryService: TelemetryService?

    nonisolated static let englishRecommendedModelNames = [
        "apple_speech_on_device",
        "mlx-community/whisper-base.en-mlx",
        "mlx-community/whisper-small.en-mlx",
        "mlx-community/whisper-medium-mlx",
        "mlx-community/whisper-large-v3-turbo",
        "mlx-community/parakeet-tdt-0.6b-v2"
    ]

    nonisolated static let multilingualRecommendedModelNames = [
        "apple_speech_on_device",
        "mlx-community/whisper-base-mlx",
        "mlx-community/whisper-small-mlx",
        "mlx-community/whisper-medium-mlx",
        "mlx-community/whisper-large-v3-turbo",
        "mlx-community/parakeet-tdt-0.6b-v3"
    ]

    nonisolated static let recommendedModelNames = englishRecommendedModelNames
    nonisolated static let recommendedModelNameSet: Set<String> = Set(englishRecommendedModelNames)

    
    enum ModelProvider: String, CaseIterable, Sendable {
        case mlxWhisper = "MLX Whisper"
        case parakeet = "Parakeet"
        case senseVoice = "SenseVoice"
        case appleSpeech = "Apple Speech"
        case openAI = "OpenAI"
        case elevenLabs = "ElevenLabs"
        case groq = "Groq"

        var isLocal: Bool {
            switch self {
            case .mlxWhisper, .parakeet, .senseVoice, .appleSpeech: return true
            case .openAI, .elevenLabs, .groq: return false
            }
        }

        var iconName: String {
            switch self {
            case .mlxWhisper: return "waveform"
            case .parakeet: return "bird"
            case .senseVoice: return "globe.asia.australia"
            case .appleSpeech: return "apple.logo"
            case .openAI: return "sparkles"
            case .elevenLabs: return "waveform.circle"
            case .groq: return "bolt"
            }
        }

        var credentialStorageKey: String {
            switch self {
            case .openAI: return "openai"
            case .elevenLabs: return "elevenlabs"
            case .groq: return "groq"
            case .mlxWhisper, .parakeet, .senseVoice, .appleSpeech:
                return rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
            }
        }
    }
    
    enum ModelLanguage: String, Sendable {
        case english = "English-only"
        case multilingual = "Multilingual"
    }

    enum LanguageSupport: Sendable {
        case englishOnly
        case fullMultilingual
        case parakeetV3European

        enum BadgeTone: Sendable {
            case normal
            case caution
        }

        struct BadgePresentation: Sendable {
            let iconName: String
            let text: String
            let tone: BadgeTone
        }

        func supports(_ language: AppLanguage) -> Bool {
            guard language != .automatic else { return true }

            switch self {
            case .englishOnly:
                return language.isEnglish
            case .fullMultilingual:
                return true
            case .parakeetV3European:
                switch language {
                case .automatic, .english, .russian, .ukrainian, .spanish, .french, .german, .portugueseBrazil, .italian, .dutch, .turkish, .polish:
                    return true
                case .simplifiedChinese, .japanese, .korean, .hindi, .malayalam:
                    return false
                }
            }
        }

        var badgeText: String {
            switch self {
            case .englishOnly:
                return "English-only"
            case .fullMultilingual:
                return "Multilingual"
            case .parakeetV3European:
                return "European multilingual"
            }
        }

        var badgeIconName: String {
            switch self {
            case .englishOnly:
                return "textformat"
            case .fullMultilingual, .parakeetV3European:
                return "globe"
            }
        }

        func badgePresentation(for language: AppLanguage) -> BadgePresentation {
            BadgePresentation(
                iconName: badgeIconName,
                text: badgeText,
                tone: supports(language) ? .normal : .caution
            )
        }
    }
    
    enum ModelAvailability: Equatable, Sendable {
        case available
        case comingSoon
        case requiresSetup
    }

    enum DownloadPhase: Equatable, Sendable {
        case idle
        case listing
        case downloading(completedFiles: Int?, totalFiles: Int?)
        case compiling(modelName: String?)
        case preparing
        case completed
    }

    struct DownloadSnapshot: Equatable, Sendable {
        let modelName: String
        let progress: Double
        let phase: DownloadPhase
    }
    
    struct WhisperModel: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let displayName: String
        let sizeInMB: Int
        let description: String
        let speedRating: Double
        let accuracyRating: Double
        let language: ModelLanguage
        let languageSupport: LanguageSupport
        let provider: ModelProvider
        let availability: ModelAvailability
        
        init(
            name: String,
            displayName: String,
            sizeInMB: Int,
            description: String = "",
            speedRating: Double = 5.0,
            accuracyRating: Double = 5.0,
            language: ModelLanguage = .multilingual,
            languageSupport: LanguageSupport? = nil,
            provider: ModelProvider = .mlxWhisper,
            availability: ModelAvailability = .available
        ) {
            self.id = name
            self.name = name
            self.displayName = displayName
            self.sizeInMB = sizeInMB
            self.description = description
            self.speedRating = speedRating
            self.accuracyRating = accuracyRating
            self.language = language
            self.languageSupport = languageSupport ?? (language == .english ? .englishOnly : .fullMultilingual)
            self.provider = provider
            self.availability = availability
        }
        
        var formattedSize: String {
            if sizeInMB >= 1000 {
                return String(format: "%.1f GB", Double(sizeInMB) / 1000.0)
            } else {
                return "\(sizeInMB) MB"
            }
        }

        func supports(language: AppLanguage) -> Bool {
            languageSupport.supports(language)
        }

        func languageBadgePresentation(for language: AppLanguage) -> LanguageSupport.BadgePresentation {
            languageSupport.badgePresentation(for: language)
        }
    }
    
    enum ModelError: Error, LocalizedError {
        case modelNotFound(String)
        case downloadFailed(String)
        case deleteFailed(String)
        case downloadNotImplemented(String)
        
        var errorDescription: String? {
            switch self {
            case .modelNotFound(let name):
                return "Model '\(name)' not found"
            case .downloadFailed(let message):
                return "Download failed: \(message)"
            case .deleteFailed(let message):
                return "Delete failed: \(message)"
            case .downloadNotImplemented(let provider):
                return "Download for \(provider) models is not yet implemented"
            }
        }
    }
    
    let availableModels: [WhisperModel] = [
        // Apple Speech (on-device, uses system models — no download required)
        WhisperModel(
            name: "apple_speech_on_device",
            displayName: "Apple Speech",
            sizeInMB: 0,
            description: "Apple's built-in on-device speech recognition. No download required — uses system models.",
            speedRating: 9.5,
            accuracyRating: 8.0,
            language: .multilingual,
            languageSupport: .fullMultilingual,
            provider: .appleSpeech,
            availability: .available
        ),

        // MLX Whisper (mlx-community)
        WhisperModel(
            name: "mlx-community/whisper-tiny",
            displayName: "Whisper Tiny",
            sizeInMB: 75,
            description: "Fastest model, ideal for quick dictation with acceptable accuracy",
            speedRating: 10.0,
            accuracyRating: 6.0,
            language: .multilingual
        ),
        WhisperModel(
            name: "mlx-community/whisper-tiny.en-mlx",
            displayName: "Whisper Tiny (English)",
            sizeInMB: 75,
            description: "English-optimized tiny model with slightly better accuracy",
            speedRating: 10.0,
            accuracyRating: 6.5,
            language: .english
        ),
        WhisperModel(
            name: "mlx-community/whisper-base-mlx",
            displayName: "Whisper Base",
            sizeInMB: 145,
            description: "Good balance between speed and accuracy for everyday use",
            speedRating: 9.0,
            accuracyRating: 7.0,
            language: .multilingual
        ),
        WhisperModel(
            name: "mlx-community/whisper-base.en-mlx",
            displayName: "Whisper Base (English)",
            sizeInMB: 145,
            description: "English-optimized base model, recommended for most users",
            speedRating: 9.0,
            accuracyRating: 7.5,
            language: .english
        ),
        WhisperModel(
            name: "mlx-community/whisper-small-mlx",
            displayName: "Whisper Small",
            sizeInMB: 483,
            description: "Higher accuracy for complex vocabulary and technical terms",
            speedRating: 7.5,
            accuracyRating: 8.0,
            language: .multilingual
        ),
        WhisperModel(
            name: "mlx-community/whisper-small.en-mlx",
            displayName: "Whisper Small (English)",
            sizeInMB: 483,
            description: "English-optimized with excellent accuracy for professional use",
            speedRating: 7.5,
            accuracyRating: 8.5,
            language: .english
        ),
        WhisperModel(
            name: "mlx-community/whisper-medium-mlx",
            displayName: "Whisper Medium",
            sizeInMB: 1500,
            description: "Excellent for multilingual and code-switching (e.g. Chinese/English mix)",
            speedRating: 6.5,
            accuracyRating: 8.8,
            language: .multilingual
        ),
        WhisperModel(
            name: "mlx-community/whisper-medium.en-mlx",
            displayName: "Whisper Medium (English)",
            sizeInMB: 1500,
            description: "English-optimized medium model with high accuracy",
            speedRating: 6.5,
            accuracyRating: 9.0,
            language: .english
        ),
        WhisperModel(
            name: "mlx-community/whisper-large-v3-mlx",
            displayName: "Whisper Large v3",
            sizeInMB: 3100,
            description: "Maximum accuracy for demanding transcription tasks",
            speedRating: 5.0,
            accuracyRating: 9.7,
            language: .multilingual
        ),
        WhisperModel(
            name: "mlx-community/whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            sizeInMB: 1600,
            description: "Near large-model accuracy with significantly faster processing",
            speedRating: 7.5,
            accuracyRating: 9.5,
            language: .multilingual
        ),
        
        WhisperModel(
            name: "mlx-community/parakeet-tdt-0.6b-v2",
            displayName: "Parakeet TDT 0.6B V2",
            sizeInMB: 2470,
            description: "NVIDIA Parakeet TDT via MLX — English-only",
            speedRating: 8.5,
            accuracyRating: 9.8,
            language: .english,
            provider: .parakeet,
            availability: .available
        ),
        WhisperModel(
            name: "mlx-community/parakeet-tdt-0.6b-v3",
            displayName: "Parakeet TDT 0.6B V3",
            sizeInMB: 2470,
            description: "NVIDIA Parakeet TDT via MLX — 25 European languages",
            speedRating: 8.0,
            accuracyRating: 9.9,
            language: .multilingual,
            languageSupport: .parakeetV3European,
            provider: .parakeet,
            availability: .available
        ),
        WhisperModel(
            name: "mlx-community/parakeet-tdt-1.1b",
            displayName: "Parakeet TDT 1.1B",
            sizeInMB: 4400,
            description: "Larger NVIDIA Parakeet TDT via MLX — English-only",
            speedRating: 7.0,
            accuracyRating: 9.95,
            language: .english,
            provider: .parakeet,
            availability: .available
        ),

        // SenseVoice (FunASR via FluidAudio CoreML / ANE)
        WhisperModel(
            name: "sensevoice-small",
            displayName: "SenseVoice Small",
            sizeInMB: 230,
            description: "FunASR SenseVoice-Small — ultra-fast non-autoregressive multilingual ASR with built-in punctuation (CoreML / Apple Neural Engine)",
            speedRating: 9.8,
            accuracyRating: 8.8,
            language: .multilingual,
            languageSupport: .fullMultilingual,
            provider: .senseVoice,
            availability: .available
        ),
        
        // Cloud providers
        WhisperModel(
            name: "openai_gpt-4o-mini-transcribe",
            displayName: "OpenAI GPT-4o Mini Transcribe",
            sizeInMB: 0,
            description: "OpenAI's recommended model for fast, accurate cloud transcription",
            speedRating: 9.5,
            accuracyRating: 9.8,
            language: .multilingual,
            provider: .openAI,
            availability: .available
        ),
        WhisperModel(
            name: "openai_gpt-4o-transcribe",
            displayName: "OpenAI GPT-4o Transcribe",
            sizeInMB: 0,
            description: "High-quality cloud transcription through the OpenAI Audio API",
            speedRating: 9.0,
            accuracyRating: 9.6,
            language: .multilingual,
            provider: .openAI,
            availability: .available
        ),
        WhisperModel(
            name: "groq_whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo (Groq)",
            sizeInMB: 0,
            description: "Lightning-fast cloud inference powered by Groq",
            speedRating: 10.0,
            accuracyRating: 9.5,
            language: .multilingual,
            provider: .groq,
            availability: .comingSoon
        ),
        WhisperModel(
            name: "elevenlabs_scribe",
            displayName: "ElevenLabs Scribe",
            sizeInMB: 0,
            description: "High-quality transcription with speaker diarization",
            speedRating: 8.0,
            accuracyRating: 9.3,
            language: .multilingual,
            provider: .elevenLabs,
            availability: .comingSoon
        )
    ]

    func recommendedModels(for language: AppLanguage) -> [WhisperModel] {
        let recommendedModelNames: [String]
        switch language {
        case .english:
            recommendedModelNames = Self.englishRecommendedModelNames
        case .automatic, .russian, .ukrainian, .simplifiedChinese, .spanish, .french, .german, .turkish, .japanese, .portugueseBrazil, .italian, .dutch, .korean, .hindi, .malayalam, .polish:
            recommendedModelNames = Self.multilingualRecommendedModelNames
        }

        let recommendationRanks = Dictionary(
            uniqueKeysWithValues: recommendedModelNames.enumerated().map { index, name in
                (name, index)
            }
        )

        return availableModels
            .filter { recommendedModelNames.contains($0.name) }
            .filter { $0.supports(language: language) }
            .sorted {
                recommendationRanks[$0.name, default: .max] < recommendationRanks[$1.name, default: .max]
            }
    }

    var recommendedModels: [WhisperModel] {
        recommendedModels(for: .english)
    }
    
    private(set) var downloadProgress: Double = 0.0
    private(set) var isDownloading: Bool = false
    private(set) var currentDownloadModel: String?
    private(set) var downloadSnapshot: DownloadSnapshot?
    private(set) var downloadedModelNames: Set<String> = []
    
    private(set) var featureDownloadProgress: Double = 0.0
    private(set) var isDownloadingFeature: Bool = false
    private(set) var currentDownloadingFeature: FeatureModelType?
    private(set) var downloadedFeatureModels: Set<FeatureModelType> = []
    
    private let fileManager = FileManager.default
    
    /// Last decile (0...10) logged for MLX Whisper/Parakeet file download progress to avoid log spam.
    private var mlxAudioDownloadLastLoggedDecile: Int = -1
    
    private var modelsBaseURL: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Pindrop", isDirectory: true)
    }

    private var legacyWhisperKitModelsURL: URL {
        modelsBaseURL
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
    }
    
    private var legacyParakeetCoreMLModelsURL: URL {
        modelsBaseURL.appendingPathComponent("FluidInference", isDirectory: true)
                     .appendingPathComponent("parakeet-coreml", isDirectory: true)
    }
    
    private var fluidAudioModelsURL: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Shared FluidAudio cache folder for SenseVoice-Small CoreML artifacts.
    private var senseVoiceModelsURL: URL {
        fluidAudioModelsURL.appendingPathComponent(
            Repo.senseVoiceSmall.folderName,
            isDirectory: true
        )
    }

    private func localModelPath(for model: WhisperModel) -> URL? {
        switch model.provider {
        case .mlxWhisper, .parakeet:
            return MLXWhisperModelStore.modelDirectory(for: model.name)
        case .senseVoice:
            // Only advertise a local path when the catalog int8 set is complete.
            guard SenseVoiceModels.modelsExist(
                at: senseVoiceModelsURL,
                precision: SenseVoiceEngine.catalogPrecision
            ) else {
                return nil
            }
            return senseVoiceModelsURL
        case .appleSpeech:
            // Apple Speech uses system models; no local path to manage.
            return nil
        case .openAI, .elevenLabs, .groq:
            return nil
        }
    }

    func existingLocalModelPath(for modelName: String) -> URL? {
        guard let model = availableModels.first(where: { $0.name == modelName }),
              let modelPath = localModelPath(for: model) else {
            return nil
        }

        if model.provider == .mlxWhisper || model.provider == .parakeet {
            guard MLXWhisperModelStore.isModelPresent(at: modelPath) else {
                return nil
            }
            return modelPath
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: modelPath.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        return modelPath
    }
    
    private static var isPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
    
    init() {
        guard !Self.isPreview else { return }
    }
    
    func refreshDownloadedModels() async {
        var downloaded: Set<String> = []

        for model in availableModels where model.provider == .mlxWhisper || model.provider == .parakeet {
            if let path = localModelPath(for: model),
               MLXWhisperModelStore.isModelPresent(at: path) {
                downloaded.insert(model.name)
            }
        }

        // SenseVoice catalog entry is int8-only: discovery and load share the
        // same precision decision so a fp16/fp32-only cache is never shown as ready.
        if SenseVoiceModels.modelsExist(
            at: senseVoiceModelsURL,
            precision: SenseVoiceEngine.catalogPrecision
        ) {
            downloaded.insert("sensevoice-small")
        }
        
        if downloaded != downloadedModelNames {
            Log.model.debug("Found \(downloaded.count) downloaded models: \(downloaded)")
        }
        downloadedModelNames = downloaded
    }
    
    func getDownloadedModels() async -> [WhisperModel] {
        await refreshDownloadedModels()
        return availableModels.filter { downloadedModelNames.contains($0.name) }
    }
    
    func isModelDownloaded(_ modelName: String) -> Bool {
        guard let model = availableModels.first(where: { $0.name == modelName }) else {
            return false
        }
        // System and cloud models have no local asset to download.
        if model.provider == .appleSpeech || (!model.provider.isLocal && model.availability == .available) {
            return true
        }
        return downloadedModelNames.contains(modelName)
    }

    static func parakeetDownloadSnapshot(
        modelName: String,
        progress: DownloadUtils.DownloadProgress
    ) -> DownloadSnapshot {
        let phase: DownloadPhase

        switch progress.phase {
        case .listing:
            phase = .listing
        case .downloading(let completedFiles, let totalFiles):
            phase = .downloading(completedFiles: completedFiles, totalFiles: totalFiles)
        case .compiling(let modelName):
            phase = .compiling(modelName: modelName)
        }

        return DownloadSnapshot(
            modelName: modelName,
            progress: progress.fractionCompleted,
            phase: phase
        )
    }

    static func whisperDownloadSnapshot(
        modelName: String,
        fileDownloadFraction: Double
    ) -> DownloadSnapshot {
        DownloadSnapshot(
            modelName: modelName,
            progress: fileDownloadFraction * 0.8,
            phase: .downloading(completedFiles: nil, totalFiles: nil)
        )
    }

    static func preparingDownloadSnapshot(
        modelName: String,
        progress: Double = 0.85
    ) -> DownloadSnapshot {
        DownloadSnapshot(modelName: modelName, progress: progress, phase: .preparing)
    }

    static func completedDownloadSnapshot(modelName: String) -> DownloadSnapshot {
        DownloadSnapshot(modelName: modelName, progress: 1.0, phase: .completed)
    }

    func updateDownloadSnapshot(
        _ snapshot: DownloadSnapshot,
        onProgress: ((DownloadSnapshot) -> Void)? = nil
    ) {
        let clampedSnapshot = DownloadSnapshot(
            modelName: snapshot.modelName,
            progress: min(max(snapshot.progress, 0.0), 1.0),
            phase: snapshot.phase
        )

        downloadSnapshot = clampedSnapshot
        downloadProgress = clampedSnapshot.progress
        onProgress?(clampedSnapshot)
    }

    func clearDownloadState(resetProgress: Bool) {
        downloadSnapshot = nil
        if resetProgress {
            downloadProgress = 0.0
        }
    }
    
    func downloadModel(
        named modelName: String,
        onProgress: ((DownloadSnapshot) -> Void)? = nil
    ) async throws {
        guard let model = availableModels.first(where: { $0.name == modelName }) else {
            throw ModelError.modelNotFound(modelName)
        }

        // Cloud models are remote and have no downloadable local asset.
        guard model.provider.isLocal else { return }
        
        guard !isDownloading else {
            Log.boot.error("downloadModel rejected: another download in progress current=\(currentDownloadModel ?? "nil")")
            throw ModelError.downloadFailed("Another download is in progress")
        }
        
        Log.boot.info("ModelManager.downloadModel begin name=\(modelName) provider=\(model.provider.rawValue)")
        let downloadWallClock = CFAbsoluteTimeGetCurrent()

        isDownloading = true
        currentDownloadModel = modelName
        clearDownloadState(resetProgress: true)

        defer {
            isDownloading = false
            currentDownloadModel = nil
        }

        telemetryService?.send(
            .modelDownloadStarted,
            parameters: [TelemetryParameter.model: modelName]
        )
        do {
            if model.provider == .parakeet {
                try await downloadMLXParakeetModel(named: modelName, onProgress: onProgress)
            } else if model.provider == .senseVoice {
                try await downloadSenseVoiceModel(named: modelName, onProgress: onProgress)
            } else if model.provider == .mlxWhisper {
                try await downloadMLXWhisperModel(named: modelName, onProgress: onProgress)
            } else if model.provider == .appleSpeech {
                await refreshDownloadedModels()
            } else {
                throw ModelError.downloadNotImplemented(model.provider.rawValue)
            }
        } catch {
            telemetryService?.send(
                .modelDownloadFailed,
                parameters: [
                    TelemetryParameter.model: modelName,
                    TelemetryParameter.errorCase: TelemetryService.errorCaseName(error)
                ]
            )
            throw error
        }
        Log.boot.info("ModelManager.downloadModel finished OK name=\(modelName) wallClock=\(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - downloadWallClock))")
    }
    
    private func downloadMLXWhisperModel(
        named modelName: String,
        onProgress: ((DownloadSnapshot) -> Void)? = nil
    ) async throws {
        mlxAudioDownloadLastLoggedDecile = -1
        let pipelineStart = CFAbsoluteTimeGetCurrent()
        do {
            Log.model.info("Downloading MLX Whisper model: \(modelName)")
            Log.boot.info(
                "MLX Whisper pipeline begin repo=\(modelName) storageLeaf=Pindrop/models/mlx-audio"
            )

            try fileManager.createDirectory(
                at: MLXWhisperModelStore.modelsBaseURL,
                withIntermediateDirectories: true
            )

            let fileDownloadStart = CFAbsoluteTimeGetCurrent()
            _ = try await MLXWhisperModelStore.download(
                repoID: modelName,
                progressHandler: { [weak self] progress in
                    guard let self else { return }
                    let fraction = progress.fractionCompleted
                    let decile = min(10, Int(fraction * 10.0001))
                    if decile > self.mlxAudioDownloadLastLoggedDecile || fraction >= 1.0 {
                        self.mlxAudioDownloadLastLoggedDecile = max(self.mlxAudioDownloadLastLoggedDecile, decile)
                        Log.boot.info(
                            "MLX Whisper download progress fraction=\(String(format: "%.3f", fraction))"
                        )
                    }
                    self.updateDownloadSnapshot(
                        Self.whisperDownloadSnapshot(
                            modelName: modelName,
                            fileDownloadFraction: fraction
                        ),
                        onProgress: onProgress
                    )
                }
            )
            Log.boot.info(
                "MLX Whisper download finished elapsed=\(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - fileDownloadStart))"
            )

            updateDownloadSnapshot(Self.preparingDownloadSnapshot(modelName: modelName), onProgress: onProgress)
            let prewarmStart = CFAbsoluteTimeGetCurrent()
            _ = try await MLXWhisperModelStore.loadPretrained(repoID: modelName)
            Log.boot.info(
                "MLX Whisper prewarm completed elapsed=\(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - prewarmStart))"
            )

            updateDownloadSnapshot(Self.completedDownloadSnapshot(modelName: modelName), onProgress: onProgress)
            await refreshDownloadedModels()
            Log.boot.info(
                "MLX Whisper pipeline success totalElapsed=\(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - pipelineStart))"
            )
        } catch {
            clearDownloadState(resetProgress: true)
            let nsError = error as NSError
            Log.boot.error(
                "MLX Whisper pipeline failed after \(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - pipelineStart)) domain=\(nsError.domain) code=\(nsError.code) description=\(error.localizedDescription)"
            )
            throw ModelError.downloadFailed(error.localizedDescription)
        }
    }

    private func downloadMLXParakeetModel(
        named modelName: String,
        onProgress: ((DownloadSnapshot) -> Void)? = nil
    ) async throws {
        mlxAudioDownloadLastLoggedDecile = -1
        let pipelineStart = CFAbsoluteTimeGetCurrent()
        do {
            Log.model.info("Downloading MLX Parakeet model: \(modelName)")
            Log.boot.info(
                "MLX Parakeet pipeline begin repo=\(modelName) storageLeaf=Pindrop/models/mlx-audio"
            )

            try fileManager.createDirectory(
                at: MLXWhisperModelStore.modelsBaseURL,
                withIntermediateDirectories: true
            )

            let fileDownloadStart = CFAbsoluteTimeGetCurrent()
            _ = try await MLXWhisperModelStore.download(
                repoID: modelName,
                progressHandler: { [weak self] progress in
                    guard let self else { return }
                    let fraction = progress.fractionCompleted
                    let decile = min(10, Int(fraction * 10.0001))
                    if decile > self.mlxAudioDownloadLastLoggedDecile || fraction >= 1.0 {
                        self.mlxAudioDownloadLastLoggedDecile = max(self.mlxAudioDownloadLastLoggedDecile, decile)
                        Log.boot.info(
                            "MLX Parakeet download progress fraction=\(String(format: "%.3f", fraction))"
                        )
                    }
                    self.updateDownloadSnapshot(
                        Self.whisperDownloadSnapshot(
                            modelName: modelName,
                            fileDownloadFraction: fraction
                        ),
                        onProgress: onProgress
                    )
                }
            )
            Log.boot.info(
                "MLX Parakeet download finished elapsed=\(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - fileDownloadStart))"
            )

            updateDownloadSnapshot(Self.preparingDownloadSnapshot(modelName: modelName), onProgress: onProgress)
            let prewarmStart = CFAbsoluteTimeGetCurrent()
            _ = try await ParakeetModel.fromPretrained(modelName, cache: MLXWhisperModelStore.hubCache)
            Log.boot.info(
                "MLX Parakeet prewarm completed elapsed=\(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - prewarmStart))"
            )

            updateDownloadSnapshot(Self.completedDownloadSnapshot(modelName: modelName), onProgress: onProgress)
            await refreshDownloadedModels()
            Log.boot.info(
                "MLX Parakeet pipeline success totalElapsed=\(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - pipelineStart))"
            )
        } catch {
            clearDownloadState(resetProgress: true)
            let nsError = error as NSError
            Log.boot.error(
                "MLX Parakeet pipeline failed after \(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - pipelineStart)) domain=\(nsError.domain) code=\(nsError.code) description=\(error.localizedDescription)"
            )
            throw ModelError.downloadFailed(error.localizedDescription)
        }
    }

    /// Maps legacy WhisperKit / CoreML Parakeet catalog IDs onto mlx-community repos.
    nonisolated static func migratedMLXModelName(from legacyName: String) -> String? {
        if legacyName.hasPrefix("mlx-community/") {
            return legacyName
        }

        let normalized = legacyName.lowercased()
        if normalized.hasPrefix("parakeet-") {
            if normalized.contains("1.1b") {
                return "mlx-community/parakeet-tdt-1.1b"
            }
            if normalized.contains("v3") {
                return "mlx-community/parakeet-tdt-0.6b-v3"
            }
            if normalized.contains("v2") {
                return "mlx-community/parakeet-tdt-0.6b-v2"
            }
            return "mlx-community/parakeet-tdt-0.6b-v3"
        }

        guard normalized.hasPrefix("openai_whisper-") || normalized.hasPrefix("distil-whisper_") else {
            return nil
        }

        if normalized.contains("turbo") {
            return "mlx-community/whisper-large-v3-turbo"
        }
        if normalized.contains("tiny.en") {
            return "mlx-community/whisper-tiny.en-mlx"
        }
        if normalized.contains("tiny") {
            return "mlx-community/whisper-tiny"
        }
        if normalized.contains("base.en") {
            return "mlx-community/whisper-base.en-mlx"
        }
        if normalized.contains("base") {
            return "mlx-community/whisper-base-mlx"
        }
        if normalized.contains("small.en") {
            return "mlx-community/whisper-small.en-mlx"
        }
        if normalized.contains("small") {
            return "mlx-community/whisper-small-mlx"
        }
        if normalized.contains("medium.en") {
            return "mlx-community/whisper-medium.en-mlx"
        }
        if normalized.contains("medium") {
            return "mlx-community/whisper-medium-mlx"
        }
        if normalized.contains("large") || normalized.contains("distil") {
            return "mlx-community/whisper-large-v3-mlx"
        }
        return "mlx-community/whisper-base-mlx"
    }

    func removeLegacyWhisperKitCacheIfPresent() {
        let legacy = legacyWhisperKitModelsURL
        guard fileManager.fileExists(atPath: legacy.path) else { return }
        do {
            try fileManager.removeItem(at: legacy)
            Log.model.info("Removed legacy WhisperKit CoreML cache at \(legacy.path)")
        } catch {
            Log.model.error("Failed to remove legacy WhisperKit cache: \(error.localizedDescription)")
        }
    }

    func removeLegacyParakeetCoreMLCacheIfPresent() {
        let legacy = legacyParakeetCoreMLModelsURL
        guard fileManager.fileExists(atPath: legacy.path) else { return }
        do {
            try fileManager.removeItem(at: legacy)
            Log.model.info("Removed legacy Parakeet CoreML cache at \(legacy.path)")
        } catch {
            Log.model.error("Failed to remove legacy Parakeet CoreML cache: \(error.localizedDescription)")
        }
    }

    private func downloadSenseVoiceModel(
        named modelName: String,
        onProgress: ((DownloadSnapshot) -> Void)? = nil
    ) async throws {
        let pipelineStart = CFAbsoluteTimeGetCurrent()
        let precision = SenseVoiceEngine.catalogPrecision
        let requiredArtifacts = SenseVoiceEngine.requiredDownloadArtifacts(precision: precision)
        Log.model.info(
            "SenseVoice model download requested: \(modelName) precision=\(precision.rawValue) artifacts=\(requiredArtifacts.sorted())"
        )
        Log.boot.info("SenseVoice pipeline begin name=\(modelName) precision=\(precision.rawValue)")

        // Guard the catalog contract: int8 must never pull fp16/fp32 encoders.
        #if DEBUG
        assert(
            !requiredArtifacts.contains(ModelNames.SenseVoice.encoderFile)
                && !requiredArtifacts.contains(ModelNames.SenseVoice.encoderFp32File),
            "SenseVoice int8 download set must not include fp16/fp32 encoders"
        )
        #endif

        do {
            try fileManager.createDirectory(at: fluidAudioModelsURL, withIntermediateDirectories: true)
        } catch {
            throw ModelError.downloadFailed(
                "Failed to create SenseVoice models directory: \(error.localizedDescription)"
            )
        }

        do {
            let fetchStart = CFAbsoluteTimeGetCurrent()
            // FluidAudio 0.15.4+ is precision-aware: variant=int8 fetches only
            // preprocessor + SenseVoiceSmall_int8 (+ vocab.json as root aux).
            _ = try await SenseVoiceModels.download(
                precision: precision,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        self.updateDownloadSnapshot(
                            Self.parakeetDownloadSnapshot(modelName: modelName, progress: progress),
                            onProgress: onProgress
                        )
                    }
                }
            )
            Log.boot.info(
                "SenseVoice download finished elapsed=\(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - fetchStart))"
            )

            guard SenseVoiceModels.modelsExist(at: senseVoiceModelsURL, precision: precision) else {
                throw ModelError.downloadFailed(
                    "SenseVoice int8 artifacts incomplete after download"
                )
            }

            // Compile/load once so first dictation does not pay cold-start cost.
            updateDownloadSnapshot(
                Self.preparingDownloadSnapshot(modelName: modelName),
                onProgress: onProgress
            )
            _ = try SenseVoiceModels.load(from: senseVoiceModelsURL, precision: precision)

            updateDownloadSnapshot(Self.completedDownloadSnapshot(modelName: modelName), onProgress: onProgress)
            await refreshDownloadedModels()
            Log.boot.info(
                "SenseVoice pipeline success totalElapsed=\(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - pipelineStart))"
            )
        } catch {
            clearDownloadState(resetProgress: true)
            Log.model.error("SenseVoice model download failed: \(error.localizedDescription)")
            if let modelError = error as? ModelError {
                throw modelError
            }
            throw ModelError.downloadFailed(error.localizedDescription)
        }
    }
    
    func deleteModel(named modelName: String) async throws {
        guard let model = availableModels.first(where: { $0.name == modelName }) else {
            throw ModelError.modelNotFound(modelName)
        }

        guard let modelPath = localModelPath(for: model) else {
            throw ModelError.deleteFailed("Model \(modelName) is not stored locally")
        }

        guard fileManager.fileExists(atPath: modelPath.path) else {
            throw ModelError.modelNotFound(modelName)
        }

        do {
            try fileManager.removeItem(at: modelPath)
            await refreshDownloadedModels()
        } catch {
            throw ModelError.deleteFailed(error.localizedDescription)
        }
    }
    
    // MARK: - Feature Models

    func isFeatureModelDownloaded(_ type: FeatureModelType) -> Bool {
        downloadedFeatureModels.contains(type)
    }

    /// True when the specific streaming chunk variant matching `profile` is present on
    /// disk. `isFeatureModelDownloaded(.streaming)` answers the broader "any variant is
    /// present" question; this helper is for code paths that care which one.
    func isStreamingChunkVariantDownloaded(_ profile: StreamingChunkProfile) -> Bool {
        let folder = fluidAudioModelsURL.appendingPathComponent(profile.repoFolderName)
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Complete offline Community-1 diarization readiness.
    ///
    /// Requires every CoreML asset in `ModelNames.OfflineDiarizer.requiredModels`
    /// (excluding `plda-parameters.json`) under `speaker-diarization-coreml`, plus
    /// `plda-parameters.json` in one of the three locations FluidAudio accepts.
    /// Directory existence alone is not readiness.
    ///
    /// FluidAudio 0.15+ lists PLDA inside `requiredModels`; we still treat it as a
    /// separate candidate check so root / coreml / offline-sibling placements all
    /// remain valid — forcing PLDA only under coreml would make the other two
    /// documented locations unreachable.
    func isOfflineDiarizationReady() -> Bool {
        isOfflineDiarizationModelsReady(at: fluidAudioModelsURL)
    }

    /// Reusable complete-asset check used by refresh, download completion, and preflight.
    func isOfflineDiarizationModelsReady(at modelsRoot: URL) -> Bool {
        let coremlFolder = modelsRoot
            .appendingPathComponent(FeatureModelType.diarization.repoFolderName, isDirectory: true)

        let coremlRequiredModels = ModelNames.OfflineDiarizer.requiredModels.subtracting([
            ModelNames.OfflineDiarizer.pldaParameters
        ])
        for modelName in coremlRequiredModels {
            let modelURL = coremlFolder.appendingPathComponent(modelName)
            guard fileManager.fileExists(atPath: modelURL.path) else {
                return false
            }
        }

        // FluidAudio accepts PLDA params at the models root, inside the online/offline
        // shared coreml folder, or under the offline-specific sibling folder.
        let pldaCandidates = [
            modelsRoot.appendingPathComponent("plda-parameters.json", isDirectory: false),
            coremlFolder.appendingPathComponent("plda-parameters.json", isDirectory: false),
            modelsRoot
                .appendingPathComponent("speaker-diarization-offline", isDirectory: true)
                .appendingPathComponent("plda-parameters.json", isDirectory: false),
        ]
        return pldaCandidates.contains { fileManager.fileExists(atPath: $0.path) }
    }

    func refreshDownloadedFeatureModels() async {
        var downloaded: Set<FeatureModelType> = []

        for type in FeatureModelType.allCases {
            switch type {
            case .streaming:
                // Either chunk variant counts as "streaming downloaded" so toggling the
                // low-latency setting doesn't silently mark the feature as missing.
                if isStreamingChunkVariantDownloaded(.standard)
                    || isStreamingChunkVariantDownloaded(.lowLatency) {
                    downloaded.insert(type)
                }
            case .diarization:
                if isOfflineDiarizationModelsReady(at: fluidAudioModelsURL) {
                    downloaded.insert(type)
                }
            case .vad:
                let repoFolder = fluidAudioModelsURL.appendingPathComponent(type.repoFolderName)
                let legacyFolder = fluidAudioModelsURL.appendingPathComponent("silero-vad")
                var isDirectory: ObjCBool = false
                if (fileManager.fileExists(atPath: repoFolder.path, isDirectory: &isDirectory)
                        && isDirectory.boolValue)
                    || (fileManager.fileExists(atPath: legacyFolder.path, isDirectory: &isDirectory)
                        && isDirectory.boolValue)
                {
                    downloaded.insert(type)
                }
            }
        }

        if downloaded != downloadedFeatureModels {
            Log.model.debug("Found \(downloaded.count) downloaded feature models: \(downloaded)")
        }
        downloadedFeatureModels = downloaded
    }

    func downloadFeatureModel(
        _ type: FeatureModelType,
        streamingChunkProfile: StreamingChunkProfile = .standard,
        onProgress: ((Double) -> Void)? = nil
    ) async throws {
        guard !isDownloadingFeature else {
            throw ModelError.downloadFailed("Another feature download is in progress")
        }

        isDownloadingFeature = true
        currentDownloadingFeature = type
        featureDownloadProgress = 0.0

        defer {
            isDownloadingFeature = false
            currentDownloadingFeature = nil
        }

        Log.model.info("Downloading feature model: \(type.displayName)")

        do {
            switch type {
            case .vad:
                let progressHandler: DownloadUtils.ProgressHandler = { [weak self] progress in
                    let fraction = min(max(progress.fractionCompleted, 0), 0.99)
                    Task { @MainActor in
                        guard let self,
                              self.isDownloadingFeature,
                              self.currentDownloadingFeature == .vad else {
                            return
                        }
                        self.featureDownloadProgress = max(0.05, fraction)
                        onProgress?(self.featureDownloadProgress)
                    }
                }
                _ = try await VadManager(config: .default, progressHandler: progressHandler)

            case .diarization:
                // Offline Community-1 assets: download/prewarm via OfflineDiarizerModels,
                // bridge FluidAudio progress onto MainActor, and only mark complete once
                // every required artifact is present. Discard the in-memory models after.
                let progressHandler: DownloadUtils.ProgressHandler = { [weak self] progress in
                    let fraction = min(max(progress.fractionCompleted, 0), 0.99)
                    Task { @MainActor in
                        guard let self,
                              self.isDownloadingFeature,
                              self.currentDownloadingFeature == .diarization else {
                            return
                        }
                        // Never claim 1.0 from the handler — readiness sets that.
                        self.featureDownloadProgress = fraction
                        onProgress?(fraction)
                    }
                }
                _ = try await OfflineDiarizerModels.load(
                    from: OfflineDiarizerModels.defaultModelsDirectory(),
                    progressHandler: progressHandler
                )
                guard isOfflineDiarizationModelsReady(at: fluidAudioModelsURL) else {
                    featureDownloadProgress = 0.0
                    onProgress?(0.0)
                    throw ModelError.downloadFailed(
                        "Speaker diarization model files are incomplete after download"
                    )
                }

            case .streaming:
                featureDownloadProgress = 0.1
                onProgress?(0.1)
                featureDownloadProgress = 0.3
                onProgress?(0.3)
                let repo: Repo = {
                    switch streamingChunkProfile {
                    case .standard: return .nemotronStreaming1120
                    case .lowLatency: return .nemotronStreaming560
                    }
                }()
                try await DownloadUtils.downloadRepo(
                    repo,
                    to: fluidAudioModelsURL
                )
            }

            featureDownloadProgress = 1.0
            onProgress?(1.0)

            Log.model.info("Feature model download complete: \(type.displayName)")
            await refreshDownloadedFeatureModels()

            // Diarization must still be marked ready after refresh; a race or partial
            // cache must not leave the feature enabled with incomplete assets.
            if type == .diarization, !downloadedFeatureModels.contains(.diarization) {
                featureDownloadProgress = 0.0
                onProgress?(0.0)
                throw ModelError.downloadFailed(
                    "Speaker diarization model files are incomplete after download"
                )
            }
        } catch {
            featureDownloadProgress = 0.0
            Log.model.error("Feature model download failed: \(error.localizedDescription)")
            if let modelError = error as? ModelError {
                throw modelError
            }
            throw ModelError.downloadFailed(error.localizedDescription)
        }
    }
}
