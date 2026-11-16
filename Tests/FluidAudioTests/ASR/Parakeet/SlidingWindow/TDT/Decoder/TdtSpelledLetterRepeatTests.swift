import XCTest

@testable import FluidAudio

final class TdtSpelledLetterRepeatTests: XCTestCase {

    private let blankId = 8192
    // Pieces as Parakeet's SentencePiece vocabulary writes them.
    private let vocab: [Int: String] = [
        10: "▁D",
        11: "A",
        12: "N",
        13: "▁A",
        20: "▁the",
        21: "ing",
        30: ".",
        31: "-",
        32: ",",
        33: "?",
        40: "▁a",
        41: "▁I",
        8192: "<blank>",
    ]

    private func rule(margin: Float = 3) -> TdtSpelledLetterRepeat {
        TdtSpelledLetterRepeat(margin: margin, blankId: blankId, tokens: .init(vocabulary: vocab))
    }

    /// Runs `apply` on a blank decision whose top-K holds `letter` `gap` logits below blank.
    private func decide(
        _ rule: inout TdtSpelledLetterRepeat, letter: Int, gap: Float, frame: Int, duration: Int = 3
    ) -> (label: Int, duration: Int) {
        var label = blankId
        var duration = duration
        rule.apply(
            label: &label, duration: &duration, frame: frame,
            topKIds: [blankId, 999, letter], topKLogits: [10, 9, 10 - gap])
        return (label, duration)
    }

    func testTokensFindSingleUppercaseLettersAndRunPunctuation() {
        let tokens = TdtSpelledLetterRepeat.Tokens(vocabulary: vocab)
        XCTAssertEqual(tokens.letters, [10, 11, 12, 13, 41])
        XCTAssertEqual(tokens.passThrough, [30, 31, 32])
    }

    func testTokensAcceptSpaceNormalizedPieces() {
        let tokens = TdtSpelledLetterRepeat.Tokens(vocabulary: [1: " D", 2: " the", 3: " ."])
        XCTAssertEqual(tokens.letters, [1])
        XCTAssertEqual(tokens.passThrough, [3])
    }

    func testRepeatsALetterThatClimbsBackOutOfADip() {
        var r = rule()
        r.didEmit(10, atFrame: 0)  // D
        r.didEmit(11, atFrame: 3)  // A
        XCTAssertEqual(decide(&r, letter: 11, gap: 6.5, frame: 4).label, blankId)  // the dip
        let d = decide(&r, letter: 11, gap: 2.5, frame: 5)
        XCTAssertEqual(d.label, 11)
        XCTAssertEqual(d.duration, 1)
    }

    func testKeepsBlankWhenTheLetterIsFartherThanTheMargin() {
        var r = rule()
        r.didEmit(11, atFrame: 3)
        _ = decide(&r, letter: 11, gap: 9, frame: 4)
        let d = decide(&r, letter: 11, gap: 3.5, frame: 5)
        XCTAssertEqual(d.label, blankId)
        // While watching, blanks advance one frame so a second letter is not skipped.
        XCTAssertEqual(d.duration, 1)
    }

    func testALetterHeldNearBlankIsNotRepeated() {
        // A long "I" stays a few logits under blank without dipping first.
        var r = rule()
        r.didEmit(41, atFrame: 3)
        for frame in 4...10 {
            XCTAssertEqual(decide(&r, letter: 41, gap: 2.9, frame: frame).label, blankId, "frame \(frame)")
        }
    }

    func testNearBlankWithNoFrameBeforeItIsNotRepeated() {
        // The first frame seen after a letter can be its own tail; there is no dip to climb from.
        var r = rule()
        r.didEmit(11, atFrame: 3)
        XCTAssertEqual(decide(&r, letter: 11, gap: 0.7, frame: 5).label, blankId)
    }

    func testASmallClimbIsNotEnough() {
        var r = rule()
        r.didEmit(11, atFrame: 3)
        _ = decide(&r, letter: 11, gap: 4.6, frame: 6)
        XCTAssertEqual(decide(&r, letter: 11, gap: 1.8, frame: 7).label, blankId)
    }

    func testALetterOutsideTopKCountsAsADip() {
        var r = rule()
        r.didEmit(11, atFrame: 3)
        var label = blankId
        var duration = 2
        r.apply(label: &label, duration: &duration, frame: 4, topKIds: [blankId, 999], topKLogits: [10, 2])
        XCTAssertEqual(label, blankId)
        XCTAssertEqual(decide(&r, letter: 11, gap: 1, frame: 5).label, 11)
    }

    func testWaitsTheMinimumGapBeforeRepeating() {
        var r = rule()
        r.didEmit(11, atFrame: 3)
        XCTAssertEqual(decide(&r, letter: 11, gap: 8, frame: 4).label, blankId)
        XCTAssertEqual(decide(&r, letter: 11, gap: 0.5, frame: 4).label, blankId)
        XCTAssertEqual(decide(&r, letter: 11, gap: 0.5, frame: 5).label, 11)
    }

    func testRepeatsALetterOnlyOnce() {
        var r = rule()
        r.didEmit(11, atFrame: 3)
        _ = decide(&r, letter: 11, gap: 8, frame: 4)
        XCTAssertEqual(decide(&r, letter: 11, gap: 1, frame: 5).label, 11)
        r.didEmit(11, atFrame: 5)
        XCTAssertFalse(r.isWatching(frame: 7))
        XCTAssertEqual(decide(&r, letter: 11, gap: 1, frame: 8).label, blankId)
    }

    func testALetterTheModelAlreadyDoubledIsNotTripled() {
        var r = rule()
        r.didEmit(11, atFrame: 3)
        r.didEmit(11, atFrame: 6)
        XCTAssertEqual(decide(&r, letter: 11, gap: 1, frame: 9).label, blankId)
    }

    func testANewLetterCanRepeatAgain() {
        var r = rule()
        r.didEmit(11, atFrame: 3)
        r.didEmit(11, atFrame: 5)
        r.didEmit(12, atFrame: 8)  // N
        _ = decide(&r, letter: 12, gap: 8, frame: 9)
        XCTAssertEqual(decide(&r, letter: 12, gap: 1, frame: 10).label, 12)
    }

    func testAWordEndsTheRunButPunctuationDoesNot() {
        var r = rule()
        r.didEmit(11, atFrame: 3)
        r.didEmit(30, atFrame: 4)  // "."
        XCTAssertTrue(r.isWatching(frame: 5))
        r.didEmit(20, atFrame: 5)  // " the"
        XCTAssertFalse(r.isWatching(frame: 6))
        XCTAssertEqual(decide(&r, letter: 11, gap: 0.1, frame: 7, duration: 3).label, blankId)
        XCTAssertEqual(decide(&r, letter: 11, gap: 0.1, frame: 7, duration: 3).duration, 3)
    }

    func testSentencePunctuationOtherThanRunMarksEndsTheRun() {
        var r = rule()
        r.didEmit(11, atFrame: 3)
        r.didEmit(33, atFrame: 4)  // "?"
        XCTAssertFalse(r.isWatching(frame: 5))
    }

    func testStopsWatchingAfterTheWindow() {
        var r = rule()
        r.didEmit(11, atFrame: 3)
        let last = 3 + TdtSpelledLetterRepeat.windowFrames
        XCTAssertTrue(r.isWatching(frame: last))
        XCTAssertFalse(r.isWatching(frame: last + 1))
        let d = decide(&r, letter: 11, gap: 0.1, frame: last + 1, duration: 4)
        XCTAssertEqual(d.label, blankId)
        XCTAssertEqual(d.duration, 4)
    }

    func testLeavesNonBlankDecisionsAlone() {
        var r = rule()
        r.didEmit(11, atFrame: 3)
        var label = 12
        var duration = 2
        r.apply(label: &label, duration: &duration, frame: 6, topKIds: [12, 11, blankId], topKLogits: [10, 9.9, 9])
        XCTAssertEqual(label, 12)
        XCTAssertEqual(duration, 2)
    }

    func testNeedsTheLetterAndBlankInTopK() {
        var r = rule()
        r.didEmit(11, atFrame: 3)
        var label = blankId
        var duration = 2
        r.apply(label: &label, duration: &duration, frame: 6, topKIds: [blankId, 12], topKLogits: [10, 9.9])
        XCTAssertEqual(label, blankId)
        r.apply(label: &label, duration: &duration, frame: 6, topKIds: nil, topKLogits: nil)
        XCTAssertEqual(label, blankId)
    }

    func testIdleUntilALetterIsEmitted() {
        var r = rule()
        XCTAssertFalse(r.isWatching(frame: 0))
        r.didEmit(40, atFrame: 1)  // " a" is lowercase, not a spelled letter
        XCTAssertFalse(r.isWatching(frame: 2))
    }

    func testConfigDefaultsOffAndManagerResolvesTokensOnlyWhenOn() {
        XCTAssertNil(TdtConfig.default.spelledLetterRepeatMargin)
        XCTAssertNil(AsrManager.spelledLetterTokens(config: .default, vocabulary: vocab))
        let on = ASRConfig(tdtConfig: TdtConfig(spelledLetterRepeatMargin: 3))
        XCTAssertEqual(
            AsrManager.spelledLetterTokens(config: on, vocabulary: vocab),
            TdtSpelledLetterRepeat.Tokens(vocabulary: vocab))
    }
}
