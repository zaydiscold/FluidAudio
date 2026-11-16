import Foundation

/// Writes a spelled-out letter a second time when the joint scores the repeat just under blank.
///
/// Spelling a word aloud repeats letters: "D A A N". After the decoder emits "A", the joint
/// usually reads a second "A" sound as the same letter still being said and predicts blank,
/// so the word comes out "DAN". The second letter is heard, though: after the first one fades,
/// the letter's score against blank dips and then climbs back to within a few logits of blank.
/// With ``TdtConfig/spelledLetterRepeatMargin`` set, this rule writes the letter again when, at
/// least two frames after it, the letter is in the joint's top-K within that many logits of
/// blank and has climbed at least ``minimumRise`` logits from its lowest point since.
///
/// The climb separates a second letter from one letter held long. In real recordings a held
/// letter ("I", or the "S" in "H U S S E I N") stays flat near blank, or sits near it right
/// after the letter with no dip before; a repeated letter climbs out of a dip.
///
/// The rule only watches the few frames right after a single uppercase letter piece ("▁D",
/// "A"), and visits those one at a time so a second letter is not skipped over. Top-K is
/// requested only for those frames, so other speech decodes exactly as before. A letter is
/// written at most twice in a row.
struct TdtSpelledLetterRepeat: Sendable {

    /// Token ids the rule works with, resolved once per vocabulary.
    struct Tokens: Sendable, Equatable {
        /// Single uppercase letter pieces, the tokens a spelled word decodes into.
        let letters: Set<Int>
        /// Pieces that do not end a run of spelled letters: punctuation such as "-", "." and ",".
        let passThrough: Set<Int>

        init(letters: Set<Int>, passThrough: Set<Int>) {
            self.letters = letters
            self.passThrough = passThrough
        }

        init(vocabulary: [Int: String]) {
            var letters: Set<Int> = []
            var passThrough: Set<Int> = []
            for (id, piece) in vocabulary {
                let core = piece.replacingOccurrences(of: ASRConstants.sentencePieceWordBoundary, with: "")
                    .trimmingCharacters(in: .whitespaces)
                if core.count == 1, let c = core.first, c.isLetter, c.isUppercase {
                    letters.insert(id)
                    continue
                }
                if !core.isEmpty, core.allSatisfy({ Self.runPunctuation.contains($0) }) {
                    passThrough.insert(id)
                }
            }
            self.letters = letters
            self.passThrough = passThrough
        }

        private static let runPunctuation: Set<Character> = [".", ",", "-"]
    }

    /// A second letter cannot start sooner than this after the first (2 frames, 160 ms).
    static let minimumGapFrames = 2
    /// How far, in logits, the letter must climb from its lowest score since it was written.
    static let minimumRise: Float = 3
    /// Frames after a letter that the rule watches (12 frames, 960 ms). Repeats in the
    /// measured set started within 9 frames; later frames decode with the usual skips.
    static let windowFrames = 12

    let margin: Float
    let blankId: Int
    let tokens: Tokens

    private var letter: Int?
    private var letterFrame = 0
    private var doubled = false
    /// The letter's lowest score against blank since it was written, over the frames seen.
    private var lowestGap: Float?

    init(margin: Float, blankId: Int, tokens: Tokens) {
        self.margin = margin
        self.blankId = blankId
        self.tokens = tokens
    }

    /// Whether the joint call at `frame` should return top-K for this rule.
    func isWatching(frame: Int) -> Bool {
        guard letter != nil, !doubled else { return false }
        return frame - letterFrame <= Self.windowFrames
    }

    /// Turns a blank at `frame` into the last spelled letter when the letter has climbed back
    /// to within `margin` logits of blank, and limits blank skips to one frame while watching.
    mutating func apply(label: inout Int, duration: inout Int, frame: Int, topKIds: [Int]?, topKLogits: [Float]?) {
        guard label == blankId, let letter, isWatching(frame: frame) else { return }
        duration = min(duration, 1)
        guard let topKIds, let topKLogits,
            let blankIndex = topKIds.firstIndex(of: blankId), blankIndex < topKLogits.count
        else { return }
        // A letter outside the top-K is far below blank: count it at the lowest top-K score.
        let letterLogit = topKIds.firstIndex(of: letter).flatMap { $0 < topKLogits.count ? topKLogits[$0] : nil }
        let gap = (letterLogit ?? topKLogits.min() ?? topKLogits[blankIndex]) - topKLogits[blankIndex]
        let lowest = lowestGap
        lowestGap = min(lowest ?? gap, gap)
        guard letterLogit != nil, frame - letterFrame >= Self.minimumGapFrames, gap > -margin,
            let lowest, gap - lowest >= Self.minimumRise
        else { return }
        label = letter
        duration = 1
    }

    /// Records an emitted token: a letter starts or continues a spelled run, punctuation
    /// keeps it, and anything else ends it.
    mutating func didEmit(_ token: Int, atFrame frame: Int) {
        if tokens.letters.contains(token) {
            doubled = token == letter
            letter = token
            letterFrame = frame
            lowestGap = nil
        } else if !tokens.passThrough.contains(token) {
            letter = nil
            doubled = false
        }
    }
}
