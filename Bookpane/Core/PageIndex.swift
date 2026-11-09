import Foundation

// Each chapter starts a page; its final partial screen counts as a full page.
struct PageIndex {
    private let heights: [Double]
    private let screenHeight: Double
    private let counts: [Int]

    var total: Int { counts.reduce(0, +) }

    init(heights: [Double], screenHeight: Double) {
        precondition(screenHeight.isFinite && screenHeight > 0)
        precondition(heights.allSatisfy { $0.isFinite && $0 >= 0 })
        self.heights = heights
        self.screenHeight = screenHeight
        counts = heights.map { max(1, Int(ceil($0 / screenHeight))) }
    }

    func page(chapter: Int, fraction: Double) -> Int {
        guard counts.indices.contains(chapter) else { return 1 }
        let progress = fraction.isFinite ? min(1, max(0, fraction)) : 0
        let offset = progress * max(0, heights[chapter] - screenHeight)
        // At the bottom, the last partial page is visible even if its top cannot reach the screen top.
        let local = progress == 1 ? counts[chapter] : min(counts[chapter], Int(floor(offset / screenHeight)) + 1)
        return counts.prefix(chapter).reduce(0, +) + local
    }
}
