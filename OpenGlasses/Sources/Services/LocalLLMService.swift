import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers
import UIKit

/// Manages on-device LLM inference via Apple's MLX framework.
/// Handles model downloading, loading, generation, and lifecycle.
@MainActor
final class LocalLLMService: ObservableObject {
    @Published var isModelLoaded = false
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var isGenerating = false
    @Published var isLoadingModel = false   // a model is being loaded into memory right now
    @Published var loadedModelId: String?
    @Published var downloadingModelId: String?

    private var modelContainer: ModelContainer?
    private var activeDownloadTask: Task<Void, Error>?

    /// Injectable download primitive (BK P5) so a test can drive a fake download — and its
    /// cancellation — without touching the network. `nil` ⇒ the real `HubClient` path. Reports
    /// fractional progress; throws (e.g. `CancellationError`) to abort.
    var downloadFunction: ((_ modelId: String, _ onProgress: @escaping (Double) -> Void) async throws -> Void)?

    /// Set when the app enters the background during a generation so the token loop
    /// can stop before submitting the next Metal command buffer (forbidden in the
    /// background — see `generate`).
    private var enteredBackgroundDuringGeneration = false

    /// HubClient configured to store models in Application Support (persistent, not purgeable).
    private let hub: HubClient = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDir = appSupport.appendingPathComponent("LocalModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        return HubClient(cache: HubCache(cacheDirectory: modelsDir))
    }()

    // MARK: - Recommended Models

    static let recommendedModels: [RecommendedModel] = [
        // Gemma 4 — best on-device agent model
        RecommendedModel(
            id: "mlx-community/gemma-4-e2b-it-4bit",
            name: "Gemma 4 E2B (Agent)",
            estimatedSize: "3.6 GB",
            hasVision: true,
            hasToolCalling: true,
            notes: "Best on-device agent — vision, tool calling, 140+ languages. Uses ~4 GB while running; close other apps if it refuses to load.",
            minimumRAMGB: 8
        ),
        // Vision models (can see photos from glasses)
        RecommendedModel(
            id: "mlx-community/SmolVLM2-2.2B-Instruct-mlx",
            name: "SmolVLM2 2.2B (Vision)",
            estimatedSize: "1.5 GB",
            hasVision: true,
            hasToolCalling: false,
            notes: "Best small vision model — sees photos + video"
        ),
        RecommendedModel(
            id: "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
            name: "SmolVLM2 500M (Vision)",
            estimatedSize: "0.35 GB",
            hasVision: true,
            hasToolCalling: false,
            notes: "Tiny vision model — basic photo understanding"
        ),
        // Text-only MLX models
        RecommendedModel(
            id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            name: "Qwen 2.5 3B",
            estimatedSize: "1.8 GB",
            hasVision: false,
            hasToolCalling: true,
            notes: "Strong reasoning and tool use"
        ),
        RecommendedModel(
            id: "mlx-community/gemma-2-2b-it-4bit",
            name: "Gemma 2 2B",
            estimatedSize: "1.5 GB",
            hasVision: false,
            hasToolCalling: true,
            notes: "Good balance of size and quality"
        ),
        RecommendedModel(
            id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            name: "Qwen 2.5 0.5B",
            estimatedSize: "0.4 GB",
            hasVision: false,
            hasToolCalling: true,
            notes: "Ultra-light, basic capability"
        ),
    ]

    /// Known vision model IDs that must load through `VLMModelFactory`.
    ///
    /// `gemma-4-e2b-it-4bit` stays on the TEXT factory. History: the VLM factory used to
    /// fatally trap on 1-D tokens (talk-button crash); mlx-swift-lm 3.31.4 fixed the trap
    /// (it now throws catchably) — but a device re-test (2026-07-15) shows this 4-bit
    /// checkpoint still fails VLM weight mapping: `keyNotFound(language_model…k_norm.weight,
    /// Gemma4RMSNormZeroShift)` — the community text-quant lacks the VLM export's module
    /// tree. On-device Gemma vision needs a VLM-exported checkpoint; until one is adopted,
    /// image turns on this model are refused honestly by the vision guard in LLMService.
    static let visionModelIds: Set<String> = [
        "mlx-community/SmolVLM2-2.2B-Instruct-mlx",
        "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
    ]

    /// Whether the currently loaded model supports vision.
    var isVisionModel: Bool {
        guard let id = loadedModelId else { return false }
        return Self.visionModelIds.contains(id)
    }

    /// Vision capability by model id (usable before the model is loaded).
    /// NOTE: mlx-swift-lm 3.31.4 fixed the Gemma-4 VLM forward-pass trap that forced
    /// `gemma-4-e2b-it-4bit` onto the text factory — re-enabling its vision routing is a
    /// candidate follow-up, gated on an on-device crash check (talk-button path).
    nonisolated static func isVisionCapable(modelId: String) -> Bool {
        visionModelIds.contains(modelId)
    }

    // MARK: - Model Management

    /// Download a model from HuggingFace without loading into memory.
    /// Only one download runs at a time — call cancelDownload() first if needed.
    func downloadModel(_ modelId: String) async throws {
        // BK P5: a second download while one is live is refused with a VISIBLE error (was a silent
        // `return`, which let a second multi-GB download start over the same shared progress state).
        guard !isDownloading else {
            throw LocalLLMError.alreadyDownloading
        }
        isDownloading = true
        downloadingModelId = modelId
        downloadProgress = 0
        defer {
            isDownloading = false
            downloadingModelId = nil
            activeDownloadTask = nil
        }

        // BK P5: own the cancellable unit. Before, the real Task lived in the caller and
        // `activeDownloadTask` was permanently nil, so `cancelDownload()` cancelled nothing and
        // `hub.downloadSnapshot` ran to completion — Cancel was a UI-only no-op. Running the
        // download inside `activeDownloadTask` means cancellation reaches the network/disk layer.
        let task = Task { [weak self] in
            guard let self else { return }
            if let fake = self.downloadFunction {
                try await fake(modelId) { self.downloadProgress = $0 }
            } else {
                guard let repoID = Repo.ID(rawValue: modelId) else {
                    throw LocalLLMError.generationFailed("Invalid model id: \(modelId)")
                }
                _ = try await self.hub.downloadSnapshot(of: repoID) { @MainActor progress in
                    self.downloadProgress = progress.fractionCompleted
                }
            }
        }
        activeDownloadTask = task
        do {
            try await task.value
        } catch is CancellationError {
            print("🚫 Model download cancelled: \(modelId)")
            throw CancellationError()
        }

        downloadProgress = 1.0
        print("✅ Local model downloaded: \(modelId)")
    }

    /// Cancel any in-progress download and reset state (BK P5). Now that the download runs inside
    /// `activeDownloadTask`, this actually stops it instead of just clearing the UI flags.
    func cancelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        isDownloading = false
        downloadingModelId = nil
        downloadProgress = 0
    }

    /// Load an already-downloaded model into memory.
    /// Uses LLMModelFactory for text models, VLMModelFactory for vision models.
    func loadModel(_ modelId: String) async throws {
        if loadedModelId == modelId && isModelLoaded {
            return  // Already loaded — no GPU work needed, safe even in background
        }

        // Loading materializes model weights on the GPU via Metal (same restriction
        // as generate()), which iOS forbids in the background. The model is unloaded
        // when the app backgrounds, so a backgrounded scheduled task would otherwise
        // try to reload here and crash. Refuse early with a catchable error so callers
        // can defer.
        guard UIApplication.shared.applicationState != .background else {
            throw LocalLLMError.backgrounded
        }

        // Memory headroom gate: weights bigger than the app's remaining allocation
        // budget don't fail cleanly — the load (or first generation) thrashes the
        // compressor and ends in a silent Jetsam kill. Refuse with a catchable,
        // speakable error instead. Skipped when either number is unknown (model not
        // on disk yet, or no per-app budget on this platform — see MemoryHeadroom).
        //
        // Runs BEFORE the unload below so a refused load keeps the current model
        // usable — but credits the outgoing model's weights back to the budget
        // (effectiveAvailableBytes), so swapping models on a full phone isn't
        // refused when the swap itself would fit.
        let modelBytes = modelSizeOnDisk(modelId)
        let reclaimableBytes = loadedModelId.map { modelSizeOnDisk($0) } ?? 0
        let availableBytes = MemoryHeadroom.effectiveAvailableBytes(
            budget: MemoryHeadroom.availableBytes(), reclaimableBytes: reclaimableBytes)
        guard MemoryHeadroom.canLoad(modelBytes: modelBytes, availableBytes: availableBytes) else {
            throw LocalLLMError.insufficientMemory(
                neededBytes: modelBytes + MemoryHeadroom.workingOverheadBytes,
                availableBytes: availableBytes)
        }

        isLoadingModel = true
        defer { isLoadingModel = false }
        unloadModel()

        // MLX recycles evaluation buffers through a cache whose default limit is Metal's
        // recommendedMaxWorkingSetSize — effectively "all of RAM" on iPhone. Left uncapped,
        // each turn's temporaries accumulate there instead of returning to the OS (Gemma's
        // 262k-vocab chunked-prefill logits are ~256 MB apiece): observed 2.6 → 6.0 GB app
        // footprint over five questions, ending in a silent Jetsam kill with every daemon
        // on the phone idle-exited (2026-07-13 19:12 JetsamEvent). Cap it small per MLX's
        // own iOS guidance; set here (not init) so simulator unit tests never touch Metal.
        Memory.cacheLimit = 20 * 1024 * 1024

        let config = ModelConfiguration(id: modelId)
        let factory: any ModelFactory = Self.visionModelIds.contains(modelId)
            ? VLMModelFactory.shared
            : LLMModelFactory.shared

        modelContainer = try await factory.loadContainer(
            from: #hubDownloader(hub),
            using: #huggingFaceTokenizerLoader(),
            configuration: config
        ) { progress in
            Task { @MainActor in
                self.downloadProgress = progress.fractionCompleted
            }
        }

        loadedModelId = modelId
        isModelLoaded = true
        print("✅ Local model loaded: \(modelId) (vision: \(Self.visionModelIds.contains(modelId)))")
    }

    /// Unload model from memory.
    func unloadModel() {
        let hadModel = modelContainer != nil
        modelContainer = nil
        loadedModelId = nil
        isModelLoaded = false
        if hadModel {
            // Return MLX's recycled evaluation buffers to the OS — without this, Unload
            // frees the weights but leaves the buffer cache resident. Guarded so a
            // never-loaded service (unit tests on the simulator) never touches Metal.
            Memory.clearCache()
        }
        print("🔄 Local model unloaded")
    }

    // MARK: - Generation

    /// Generate a text response from the local model.
    func generate(
        userMessage: String,
        systemPrompt: String,
        history: [(role: String, content: String)] = [],
        onToken: ((String) -> Void)? = nil
    ) async throws -> String {
        // On-device inference runs on the GPU via Metal, which iOS forbids in the
        // background: submitting a command buffer there raises
        // kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted, which MLX
        // surfaces as an *uncatchable* C++ exception that terminates the process.
        // Refuse early with a catchable Swift error so callers can defer instead.
        // BK P4: one generation at a time per ModelContainer. A fast follow-up (or a stray
        // concurrent call) must not enter while a generation is live — two token loops on one
        // container is undefined. Checked before we flip `isGenerating`. (The sequential
        // re-generations inside `sendLocal` are strictly one-at-a-time and won't trip this.)
        guard !isGenerating else {
            throw LocalLLMError.alreadyGenerating
        }
        guard UIApplication.shared.applicationState != .background else {
            throw LocalLLMError.backgrounded
        }
        guard let container = modelContainer else {
            throw LocalLLMError.modelNotLoaded
        }

        isGenerating = true
        defer { isGenerating = false }

        // Tokenize a candidate history exactly as the model will — chat template, with the
        // no-system-role fallback some small models need. Used both to measure truncation
        // candidates and to produce the final token ids.
        let tokenizer = await container.tokenizer
        func tokenize(_ hist: [(role: String, content: String)]) throws -> [Int] {
            var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]
            for turn in hist { messages.append(["role": turn.role, "content": turn.content]) }
            messages.append(["role": "user", "content": userMessage])
            do {
                return try tokenizer.applyChatTemplate(messages: messages)
            } catch {
                // Merge the system prompt into the user turn for models without a system role.
                // No "User:" transcript label — a small model reads a speaker-labelled dialogue
                // and can flip roles, replying *as* the user addressed to the persona name.
                var fallback: [[String: String]] = []
                for turn in hist { fallback.append(["role": turn.role, "content": turn.content]) }
                fallback.append(["role": "user", "content": systemPrompt + "\n\n" + userMessage])
                return try tokenizer.applyChatTemplate(messages: fallback)
            }
        }

        // BK P2: budget the prompt from the *loaded model's* context window minus the generation
        // reserve (prompt + up to 512 new tokens must both fit, or generation OOMs mid-stream —
        // an uncatchable per-token kill), then truncate oldest-history-first to fit instead of
        // hard-rejecting. Only a prompt that can't be trimmed under budget (system + current turn
        // alone too big) throws `.promptTooLong` — catchable, so the caller can fall back to cloud.
        let budget = LocalModelBudget.promptBudget(for: loadedModelId)
        let trimmedHistory = try LocalModelBudget.historyFittingBudget(
            history: history, budget: budget
        ) { try tokenize($0).count }
        if trimmedHistory.count < history.count {
            NSLog("🔬 LocalLLM.generate trimmed history %d→%d turns to fit budget %d",
                  history.count, trimmedHistory.count, budget)
        }
        let tokens = try tokenize(trimmedHistory)

        // Token shape depends on which factory loaded the model:
        // - Text models (LLMModelFactory) MUST get 1D (L,) tokens. The library's default
        //   `prepare` chunks prompts longer than the 512-token prefill step as
        //   `y[.newAxis, ..<512]` / `y = y[512...]`, which assumes 1D — on a (1, L) batch
        //   those slices hit axis 0, so the remainder becomes an EMPTY (0, L) array and the
        //   next forward pass dies in QuantizedEmbedding's reshape ("cannot infer dimension"),
        //   an uncatchable fatal MLX error. Short prompts skip the chunk loop, which is why
        //   a (1, L) batch *appeared* to work: any real question (system prompt + tools
        //   > 512 tokens) crashed the app.
        // - Vision models (VLMModelFactory, e.g. SmolVLM2/Idefics3) skip that chunked
        //   prepare and feed the tokens to the language model in one shot, so they need the
        //   explicit (1, L) batch axis (their forward pass indexes dim(2)).
        let tokenIDs = Self.tokenBatch(tokens, isVisionModel: Self.visionModelIds.contains(loadedModelId ?? ""))
        // NSLog (not print) so it survives a fatal MLX crash in the unified log,
        // confirming what shape reaches the model.
        NSLog("🔬 LocalLLM.generate model=%@ tokenIDs.shape=%@ count=%d", loadedModelId ?? "?", "\(tokenIDs.shape)", tokens.count)

        let input = LMInput(text: .init(tokens: tokenIDs))

        // Watch for backgrounding *during* generation. The pre-check above covers
        // the already-backgrounded case; this covers the app being sent to the
        // background mid-stream, where the next per-token Metal eval would crash.
        enteredBackgroundDuringGeneration = false
        let bgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main thread; this type is @MainActor.
            MainActor.assumeIsolated { self?.enteredBackgroundDuringGeneration = true }
        }
        defer { NotificationCenter.default.removeObserver(bgObserver) }

        // Generate
        let parameters = GenerateParameters(maxTokens: 512, temperature: 0.7, topP: 0.9)
        let stream = try await container.generate(input: input, parameters: parameters)

        // Drive the stream through the pure loop below so we can bail out *before* requesting the
        // next token — before MLX submits the next Metal command buffer. Non-text generations
        // (`.info`/`.toolCall`) are skipped; the loop keeps pulling until a text chunk or the end.
        var iterator = stream.makeAsyncIterator()
        let output = try await Self.drainTokenStream(
            nextChunk: {
                while let generation = await iterator.next() {
                    if case .chunk(let text) = generation { return text }
                    // .info / .toolCall / unknown — not spoken text; keep pulling.
                }
                return nil
            },
            isBackgrounded: { [weak self] in
                (self?.enteredBackgroundDuringGeneration ?? false) || UIApplication.shared.applicationState == .background
            },
            onToken: onToken
        )
        // Memory telemetry per turn — footprint should now stay flat across questions;
        // before the cacheLimit cap it grew ~0.7 GB per turn until the Jetsam kill.
        NSLog("🔬 LocalLLM.generate done — mlx active=%dMB cache=%dMB, app footprint=%dMB",
              Memory.activeMemory / 1_048_576, Memory.cacheMemory / 1_048_576,
              Int(MemoryHeadroom.appFootprintBytes() / 1_048_576))
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shape token ids for the loaded model (see the call site in `generate` for why):
    /// 1D (L,) for text-factory models — their chunked prefill slices axis 0 and an explicit
    /// batch axis fatally breaks prompts over the prefill step size; (1, L) for vision-factory
    /// models, whose prepare skips chunking and requires the batch axis.
    nonisolated static func tokenBatch(_ tokens: [Int], isVisionModel: Bool) -> MLXArray {
        let array = MLXArray(tokens)
        return isVisionModel ? array.expandedDimensions(axis: 0) : array
    }

    /// Pure token-drain loop (BK P4). Accumulates text chunks, honouring:
    /// - **Barge-in cancellation** — checked every iteration *before* pulling the next token, and
    ///   it always **throws `CancellationError`** (never a partial return). `ConversationTurnRunner`
    ///   maps `CancellationError` → `onCancelled`, the only path where a barge-in doesn't speak the
    ///   partial reply. Without this the MLX loop polled only background state, so `stop`/barge-in
    ///   marked the task cancelled but inference ran to completion (GPU/battery burn).
    /// - **Mid-stream backgrounding** — bail before the next Metal eval (uncatchable GPU crash);
    ///   return what we have, or throw `.backgrounded` if nothing was produced.
    ///
    /// `nextChunk`/`isBackgrounded` are injected so a fake stream drives this headlessly (no MLX
    /// model / GPU). Returns the accumulated (untrimmed) output.
    static func drainTokenStream(
        nextChunk: () async -> String?,
        isBackgrounded: () -> Bool,
        onToken: ((String) -> Void)?
    ) async throws -> String {
        var output = ""
        while true {
            try Task.checkCancellation()
            if isBackgrounded() {
                if output.isEmpty { throw LocalLLMError.backgrounded }
                break
            }
            guard let text = await nextChunk() else { break }
            output += text
            onToken?(text)
        }
        return output
    }

    // MARK: - Storage Info

    /// Persistent model storage directory (Application Support, never purged by iOS).
    var modelDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("LocalModels", isDirectory: true)
    }

    /// Get the on-disk path for a model. swift-huggingface uses a Python-compatible
    /// cache layout: <cacheDir>/models--{org}--{name}/
    private func modelPath(_ modelId: String) -> URL {
        let repoName = modelId.replacingOccurrences(of: "/", with: "--")
        return modelDirectory.appendingPathComponent("models--\(repoName)", isDirectory: true)
    }

    /// Check if a model is downloaded.
    func isModelDownloaded(_ modelId: String) -> Bool {
        FileManager.default.fileExists(atPath: modelPath(modelId).path)
    }

    /// Get size of a downloaded model on disk.
    func modelSizeOnDisk(_ modelId: String) -> Int64 {
        directorySize(modelPath(modelId))
    }

    /// Delete a downloaded model.
    func deleteModel(_ modelId: String) throws {
        if loadedModelId == modelId {
            unloadModel()
        }
        let path = modelPath(modelId)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
            print("🗑️ Deleted local model: \(modelId)")
        }
    }

    /// List all downloaded model IDs by scanning the cache directory.
    func downloadedModelIds() -> [String] {
        // swift-huggingface stores as: <cacheDir>/models--{org}--{modelName}
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: modelDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var ids: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("models--") else { continue }
            // models--{org}--{modelName} → {org}/{modelName}
            let repo = String(name.dropFirst("models--".count))
            let id = repo.replacingOccurrences(of: "--", with: "/")
            ids.append(id)
        }
        return ids.sorted()
    }

    // MARK: - Helpers

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

// MARK: - Types

enum LocalLLMError: LocalizedError {
    case modelNotLoaded
    case generationFailed(String)
    case backgrounded
    case insufficientMemory(neededBytes: Int64, availableBytes: Int64)
    case promptTooLong(tokens: Int, limit: Int)
    case alreadyGenerating
    case alreadyDownloading

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No local model is loaded. Download one in Settings → AI Models."
        case .generationFailed(let reason):
            return "Local model generation failed: \(reason)"
        case .backgrounded:
            return "On-device models can't run while the app is in the background. Switch to a cloud model for background tasks."
        case .insufficientMemory(let needed, let available):
            let gb = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / 1_073_741_824) }
            return "Not enough memory to load the on-device model — it needs about \(gb(needed)) GB but only \(gb(available)) GB is available. Free up about \(gb(needed - available)) GB by closing other apps, or switch to a cloud model."
        case .promptTooLong(let tokens, let limit):
            return "Prompt is too long for the on-device model (\(tokens) tokens; limit \(limit)). Switch to a cloud model for this request."
        case .alreadyGenerating:
            return "The on-device model is already generating a response. Wait for it to finish."
        case .alreadyDownloading:
            return "A model download is already in progress. Cancel it first, or wait for it to finish."
        }
    }
}

struct RecommendedModel: Identifiable {
    let id: String
    let name: String
    let estimatedSize: String
    let hasVision: Bool
    let hasToolCalling: Bool
    let notes: String
    /// Minimum device RAM (GB) required to load this model. 0 = no restriction.
    let minimumRAMGB: Double

    init(id: String, name: String, estimatedSize: String, hasVision: Bool,
         hasToolCalling: Bool, notes: String, minimumRAMGB: Double = 0) {
        self.id = id
        self.name = name
        self.estimatedSize = estimatedSize
        self.hasVision = hasVision
        self.hasToolCalling = hasToolCalling
        self.notes = notes
        self.minimumRAMGB = minimumRAMGB
    }

    /// Whether the current device has enough RAM to run this model.
    var isCompatibleWithDevice: Bool {
        guard minimumRAMGB > 0 else { return true }
        return LocalLLMService.deviceRAMGB >= minimumRAMGB
    }
}

extension LocalLLMService {
    /// Physical RAM of this device in GB.
    nonisolated static var deviceRAMGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }
}
