import Foundation

/// Thin wrapper around llama.cpp for running one text-generation prompt through
/// a downloaded GGUF model — the inference engine behind Custom Operations.
/// Mirrors `WhisperBridge`'s shape (owns one C context, serializes all C calls
/// onto a private queue, async entry point) but for text-in/text-out instead
/// of audio-in/text-out.
///
/// Lifecycle note: unlike `WhisperBridge` (one bridge per language, loaded for
/// the app's lifetime via `LanguageModelSlot`), a `TextGenerationBridge` is
/// expected to be loaded on demand per operation invocation and can be shared
/// across operations that reference the same model file — that sharing lives
/// in a future `TextGenerationModelSlot` layered on top of this bridge, not
/// here. This type only knows how to load one model and run prompts through it.
final class TextGenerationBridge: @unchecked Sendable {
    private let model: OpaquePointer
    private let queue = DispatchQueue(label: "com.whisperdictation.llama", qos: .userInitiated)

    /// True once `shutdownAndFree()` has freed the model/context. Same
    /// termination-safety contract as `WhisperBridge.freed`: NSApplication's
    /// terminate path skips Swift deinits, so shutdown must be explicit and
    /// idempotent, checked before every queue-bound C call.
    private var freed = false

    private static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Context window size in tokens. 2048 covers a prepend/append-framed
    /// selection plus a generated response for the vast majority of
    /// clipboard-sized text; large pastes beyond this are a known limitation
    /// to revisit once real usage shows it's actually needed.
    private static let contextSize: UInt32 = 2048

    init(modelPath: String) throws {
        llama_backend_init()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = Self.isAppleSilicon ? Int32.max : 0

        fputs("[TextGenerationBridge] Loading model: \(modelPath)\n", stderr)

        guard let loadedModel = llama_model_load_from_file(modelPath, modelParams) else {
            throw TextGenerationError.modelLoadFailed(modelPath)
        }
        self.model = loadedModel
        fputs("[TextGenerationBridge] Model loaded | GPU layers: \(modelParams.n_gpu_layers)\n", stderr)
    }

    deinit {
        if !freed { llama_model_free(model) }
    }

    /// Cancel any in-flight generation (none tracked yet — see note on
    /// `activeCancelFlag` once streaming/cancellation is added) and free the
    /// model on the serial queue. Same rationale as
    /// `WhisperBridge.shutdownAndFree`: ggml's Metal teardown asserts at exit
    /// if resources are still alive when NSApplication calls exit().
    func shutdownAndFree() {
        queue.sync {
            guard !self.freed else { return }
            self.freed = true
            llama_model_free(self.model)
        }
    }

    /// Runs `prompt` through the model's chat template (so instruct-tuned
    /// models respond in their trained chat format rather than raw
    /// completion) and returns the generated text, decoded greedily up to
    /// `maxTokens` or until the model emits an end-of-generation token.
    ///
    /// Async entry point: bridges the synchronous, queue-bound inference to
    /// async the same way `WhisperBridge.transcribe` does, so the calling
    /// cooperative-pool task is released during the multi-second decode.
    func generate(prompt: String, maxTokens: Int32 = 512) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async {
                guard !self.freed else {
                    continuation.resume(throwing: TextGenerationError.cancelled)
                    return
                }
                do {
                    let result = try self.runInference(prompt: prompt, maxTokens: maxTokens)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous inference body. MUST be called on `queue` — same
    /// single-queue-owns-the-C-context contract as `WhisperBridge.runInference`.
    private func runInference(prompt: String, maxTokens: Int32) throws -> String {
        dispatchPrecondition(condition: .onQueue(queue))
        let startTime = CFAbsoluteTimeGetCurrent()

        guard let vocab = llama_model_get_vocab(model) else {
            throw TextGenerationError.generationFailed("Model has no vocabulary.")
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = Self.contextSize
        contextParams.n_batch = Self.contextSize
        let threadCount = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        contextParams.n_threads = threadCount
        contextParams.n_threads_batch = threadCount

        guard let context = llama_init_from_model(model, contextParams) else {
            throw TextGenerationError.generationFailed("Failed to create inference context.")
        }
        defer { llama_free(context) }

        let formattedPrompt = Self.applyChatTemplate(model: model, userMessage: prompt)

        // Tokenize. llama_tokenize returns a negative count when the buffer is
        // too small — the two-pass pattern (probe size, then fill) is the
        // documented way to size the token buffer without over-allocating.
        let promptUTF8 = Array(formattedPrompt.utf8)
        var tokenCount = llama_tokenize(vocab, formattedPrompt, Int32(promptUTF8.count), nil, 0, true, true)
        guard tokenCount < 0 else {
            throw TextGenerationError.generationFailed("Tokenization produced no tokens.")
        }
        tokenCount = -tokenCount
        var tokens = [llama_token](repeating: 0, count: Int(tokenCount))
        let written = llama_tokenize(vocab, formattedPrompt, Int32(promptUTF8.count), &tokens, tokenCount, true, true)
        guard written > 0 else {
            throw TextGenerationError.generationFailed("Tokenization failed.")
        }
        tokens = Array(tokens.prefix(Int(written)))

        guard Int(tokenCount) < Int(Self.contextSize) else {
            throw TextGenerationError.promptTooLong(tokenCount: Int(tokenCount), contextSize: Int(Self.contextSize))
        }

        // Greedy sampling: deterministic output for a text-rewrite tool is
        // preferable to sampled variation — the same operation on the same
        // selection should produce the same result. Revisit if real usage
        // shows outputs are too repetitive/mechanical for some operations.
        let samplerParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(samplerParams) else {
            throw TextGenerationError.generationFailed("Failed to create sampler.")
        }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        // Decode the prompt as one batch.
        var batch = llama_batch_get_one(&tokens, Int32(tokens.count))
        guard llama_decode(context, batch) == 0 else {
            throw TextGenerationError.generationFailed("Failed to decode prompt.")
        }

        // Generate one token at a time until EOG or maxTokens, decoding each
        // sampled token as a single-token batch for the next step — the
        // standard llama.cpp generation loop (see llama.h's own usage example
        // above llama_sampler_sample).
        var generated = ""
        var newToken: llama_token = 0
        var generatedCount: Int32 = 0
        while generatedCount < maxTokens {
            newToken = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, newToken) { break }

            var pieceBuffer = [CChar](repeating: 0, count: 256)
            let pieceLength = llama_token_to_piece(vocab, newToken, &pieceBuffer, Int32(pieceBuffer.count), 0, true)
            if pieceLength > 0 {
                let bytes = pieceBuffer.prefix(Int(pieceLength)).map { UInt8(bitPattern: $0) }
                if let piece = String(bytes: bytes, encoding: .utf8) {
                    generated += piece
                }
            }

            generatedCount += 1
            var nextTokenVar = newToken
            batch = llama_batch_get_one(&nextTokenVar, 1)
            guard llama_decode(context, batch) == 0 else {
                throw TextGenerationError.generationFailed("Failed to decode generated token.")
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let trimmed = generated.trimmingCharacters(in: .whitespacesAndNewlines)
        fputs("[TextGenerationBridge] Done (\(String(format: "%.2f", elapsed))s, \(generatedCount) tokens)\n", stderr)
        return trimmed
    }

    /// Wraps `userMessage` in the model's own chat template (read from the
    /// GGUF file's metadata) so instruct-tuned models reply conversationally
    /// instead of continuing the text as raw completion. Falls back to the
    /// raw message unwrapped if the model has no chat template metadata (an
    /// older/base-style GGUF) — degraded but not a hard failure, since plain
    /// completion still produces *some* output for operations the user wrote
    /// a self-contained prompt for.
    private static func applyChatTemplate(model: OpaquePointer, userMessage: String) -> String {
        guard let templatePtr = llama_model_chat_template(model, nil) else {
            return userMessage
        }

        var result = userMessage
        userMessage.withCString { contentCStr in
            "user".withCString { roleCStr in
                var message = llama_chat_message(role: roleCStr, content: contentCStr)
                let bufferSize = Int32(userMessage.utf8.count * 2 + 256)
                var buffer = [CChar](repeating: 0, count: Int(bufferSize))
                let length = llama_chat_apply_template(templatePtr, &message, 1, true, &buffer, bufferSize)
                if length > 0, length <= bufferSize {
                    let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
                    if let formatted = String(bytes: bytes, encoding: .utf8) {
                        result = formatted
                    }
                }
            }
        }
        return result
    }
}

enum TextGenerationError: LocalizedError {
    case modelLoadFailed(String)
    case generationFailed(String)
    case promptTooLong(tokenCount: Int, contextSize: Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path):
            return "Failed to load model at: \(path)"
        case .generationFailed(let reason):
            return "Text generation failed: \(reason)"
        case .promptTooLong(let tokenCount, let contextSize):
            return "Selected text is too long for this model (\(tokenCount) tokens, limit \(contextSize)). Try a shorter selection."
        case .cancelled:
            return "Text generation cancelled."
        }
    }
}
