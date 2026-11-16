public struct TdtConfig: Sendable {
    public let includeTokenDuration: Bool
    public let maxSymbolsPerStep: Int
    public let durationBins: [Int]
    public let blankId: Int
    public let boundarySearchFrames: Int
    public let maxTokensPerChunk: Int
    public let consecutiveBlankLimit: Int
    /// Experimental. Writes a spelled-out letter a second time ("D A A N" rather than "DAN") when,
    /// right after it, the joint scores the same letter within this many logits of blank. `nil`
    /// (the default) turns it off. Needs a v3-style joint with `top_k_ids` / `top_k_logits`
    /// outputs. At 3 it cut dropped doubles in synthetic spelled clips from 4.8% to 2.2%, but in
    /// real recordings it also wrote letters people said once, mostly at the end of a spelled
    /// word. See `TdtSpelledLetterRepeat`.
    public let spelledLetterRepeatMargin: Float?

    public static let `default` = TdtConfig()

    public init(
        includeTokenDuration: Bool = true,
        maxSymbolsPerStep: Int = 10,
        durationBins: [Int] = [0, 1, 2, 3, 4],
        // Parakeet-TDT-0.6b-v3 uses 8192 regular tokens + blank token at index 8192
        blankId: Int = 8192,
        // Number of frames to search at chunk boundaries for token alignment (NeMo tdt_search_boundary)
        // Increased to 20 frames (1.6s) to match the context overlap in ChunkProcessor
        boundarySearchFrames: Int = 20,
        // Maximum tokens to process per chunk (prevents runaway decoding)
        // Increased to 150 for 11.2s center chunks (~40 words * 2-3 tokens/word + buffer)
        maxTokensPerChunk: Int = 150,
        // Number of consecutive blanks to trigger early termination in last chunk
        consecutiveBlankLimit: Int = 5,
        spelledLetterRepeatMargin: Float? = nil
    ) {
        self.includeTokenDuration = includeTokenDuration
        self.maxSymbolsPerStep = maxSymbolsPerStep
        self.durationBins = durationBins
        self.blankId = blankId
        self.boundarySearchFrames = boundarySearchFrames
        self.maxTokensPerChunk = maxTokensPerChunk
        self.consecutiveBlankLimit = consecutiveBlankLimit
        self.spelledLetterRepeatMargin = spelledLetterRepeatMargin
    }
}
