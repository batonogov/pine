//
//  ConstantsTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct ConstantsTests {

    // MARK: - ASCII constants

    @Test func asciiNewlineHasCorrectValue() {
        #expect(ASCII.newline == 0x0A)
    }

    @Test func asciiCarriageReturnHasCorrectValue() {
        #expect(ASCII.carriageReturn == 0x0D)
    }

    // MARK: - File size thresholds ordering

    @Test func fileSizeThresholdsAreInAscendingOrder() {
        #expect(FileSizeConstants.oneKB < FileSizeConstants.oneMB)
        #expect(FileSizeConstants.oneMB < FileSizeConstants.tenMB)
    }

    @Test func oneKBIsExactly1024Bytes() {
        #expect(FileSizeConstants.oneKB == 1_024)
    }

    @Test func oneMBIsExactly1048576Bytes() {
        #expect(FileSizeConstants.oneMB == 1_048_576)
    }

    @Test func tenMBIsExactly10485760Bytes() {
        #expect(FileSizeConstants.tenMB == 10_485_760)
    }

    // MARK: - TabManager uses shared constants

    @Test func largeFileThresholdMatchesOneMB() {
        #expect(TabManager.largeFileThreshold == FileSizeConstants.oneMB)
    }

    @Test func hugeFileThresholdMatchesTenMB() {
        #expect(TabManager.hugeFileThreshold == FileSizeConstants.tenMB)
    }

    @Test func hugeFilePartialLoadSizeMatchesOneMB() {
        #expect(TabManager.hugeFilePartialLoadSize == FileSizeConstants.oneMB)
    }

    // MARK: - ProjectSearchProvider uses shared constants

    @Test func projectSearchMaxFileSizeMatchesOneMB() {
        #expect(ProjectSearchProvider.maxFileSize == FileSizeConstants.oneMB)
    }

    // MARK: - Bracket search radius

    @Test func bracketSearchRadiusIsPositive() {
        #expect(EditorConstants.bracketSearchRadius > 0)
    }

    @Test func bracketSearchRadiusIsReasonable() {
        // Should be at least a few hundred chars to catch nearby brackets
        #expect(EditorConstants.bracketSearchRadius >= 500)
        // But not so large it defeats the purpose of windowed search
        #expect(EditorConstants.bracketSearchRadius <= 50_000)
    }

    // MARK: - Search constants

    @Test func lineContentPrefixLimitIsPositive() {
        #expect(SearchConstants.lineContentPrefixLimit > 0)
    }

    @Test func lineContentPrefixLimitIsReasonable() {
        // Should show meaningful context but not unlimited
        #expect(SearchConstants.lineContentPrefixLimit >= 80)
        #expect(SearchConstants.lineContentPrefixLimit <= 1000)
    }

    // MARK: - Minimap constants

    @Test func minimapSyntaxAlphaIsBetweenZeroAndOne() {
        #expect(MinimapConstants.syntaxSegmentAlpha > 0)
        #expect(MinimapConstants.syntaxSegmentAlpha <= 1)
    }

    @Test func minimapDiffMarkerWidthIsPositive() {
        #expect(MinimapConstants.diffMarkerWidth > 0)
    }

    @Test func minimapLineHeightIsPositive() {
        #expect(MinimapConstants.lineHeight > 0)
    }

    @Test func minimapCharWidthIsPositive() {
        #expect(MinimapConstants.charWidth > 0)
    }

    @Test func minimapLeadingPaddingIsNonNegative() {
        #expect(MinimapConstants.leadingPadding >= 0)
    }
}
