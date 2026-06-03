import SwiftUI

// MARK: - CostTimelinePoint Extensions

extension CostTimelinePoint {
    var date: Date { BucketDateParser.parse(bucket) }

    var resolvedDate: Date? { BucketDateParser.parseOptional(bucket) }
}
