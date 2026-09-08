import Core
import DesignSystem
import Foundation

// The Summary figures and the trend data are computed in Core; the Mac only
// decides which palette entry each segment and series draws with.

extension UsageSummaryFigures.Segment {
    var color: AdaptiveDesignColor {
        switch kind {
        case .input: DesignSystem.Chart.compositionInput
        case .cacheRead: DesignSystem.Chart.compositionCacheRead
        case .cacheWrite: DesignSystem.Chart.compositionCacheWrite
        case .output: DesignSystem.Chart.compositionOutput
        }
    }
}

extension UsageTrendSeries {
    var color: AdaptiveDesignColor {
        colorIndex.map { DesignSystem.Chart.series[$0 % DesignSystem.Chart.series.count] } ?? DesignSystem.Chart.unpriced
    }
}
