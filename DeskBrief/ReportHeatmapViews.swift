import Foundation
import SwiftUI

struct HeatmapTimelineView: View {
    let kind: ReportKind
    let range: ReportRange
    let categories: [String]
    let items: [HeatmapEvent]
    let categoryColors: [String: Color]
    let overlayDailyHeatmap: Bool
    @Binding var hoveredDailyHeatmapEvent: HeatmapEvent?

    var body: some View {
        switch kind {
        case .day:
            DailyHeatmapView(
                range: range,
                categories: categories,
                items: items,
                categoryColors: categoryColors,
                hoveredEvent: $hoveredDailyHeatmapEvent
            )
        case .week, .month, .year:
            if overlayDailyHeatmap {
                OverlayDailyTimeHeatmapView(
                    categories: categories,
                    items: items,
                    categoryColors: categoryColors
                )
            } else {
                ContinuousHeatmapView(
                    range: range,
                    categories: categories,
                    items: items,
                    categoryColors: categoryColors
                )
            }
        }
    }
}

extension ReportKind {
    var supportsOverlayDailyTimeHeatmap: Bool {
        self != .day
    }
}

struct HeatmapLayoutMetrics: Equatable {
    let categoryCount: Int
    let rowHeight: CGFloat
    let rowSpacing: CGFloat
    let axisHeight: CGFloat
    let axisRowsSpacing: CGFloat
    let verticalPadding: CGFloat
    let availableHeight: CGFloat

    var rowStride: CGFloat {
        rowHeight + rowSpacing
    }

    var rowsHeight: CGFloat {
        max(CGFloat(max(categoryCount, 1)) * rowStride - rowSpacing, rowHeight)
    }

    var neededHeight: CGFloat {
        verticalPadding * 2 + axisHeight + axisRowsSpacing + rowsHeight
    }

    var containerHeight: CGFloat {
        let boundedAvailableHeight = availableHeight.isFinite ? max(availableHeight, 0) : neededHeight
        return min(neededHeight, boundedAvailableHeight)
    }

    var rowsViewportHeight: CGFloat {
        max(containerHeight - verticalPadding * 2 - axisHeight - axisRowsSpacing, 0)
    }
}

private struct HeatmapTimelineContainer<AxisContent: View, RowContent: View>: View {
    let categoryCount: Int
    let labelWidth: CGFloat
    let rowHeight: CGFloat
    let rowSpacing: CGFloat
    let horizontalPadding: CGFloat
    let axisHeight: CGFloat
    let axisRowsSpacing: CGFloat
    let verticalPadding: CGFloat
    private let axisContent: (CGFloat) -> AxisContent
    private let rowContent: (CGFloat, HeatmapLayoutMetrics) -> RowContent

    init(
        categoryCount: Int,
        labelWidth: CGFloat,
        rowHeight: CGFloat,
        rowSpacing: CGFloat,
        horizontalPadding: CGFloat,
        axisHeight: CGFloat = 30,
        axisRowsSpacing: CGFloat = 12,
        verticalPadding: CGFloat = 12,
        @ViewBuilder axisContent: @escaping (CGFloat) -> AxisContent,
        @ViewBuilder rowContent: @escaping (CGFloat, HeatmapLayoutMetrics) -> RowContent
    ) {
        self.categoryCount = categoryCount
        self.labelWidth = labelWidth
        self.rowHeight = rowHeight
        self.rowSpacing = rowSpacing
        self.horizontalPadding = horizontalPadding
        self.axisHeight = axisHeight
        self.axisRowsSpacing = axisRowsSpacing
        self.verticalPadding = verticalPadding
        self.axisContent = axisContent
        self.rowContent = rowContent
    }

    var body: some View {
        GeometryReader { geometry in
            let canvasWidth = max(geometry.size.width - labelWidth - horizontalPadding * 2, 320)
            let metrics = HeatmapLayoutMetrics(
                categoryCount: categoryCount,
                rowHeight: rowHeight,
                rowSpacing: rowSpacing,
                axisHeight: axisHeight,
                axisRowsSpacing: axisRowsSpacing,
                verticalPadding: verticalPadding,
                availableHeight: geometry.size.height
            )

            VStack(alignment: .leading, spacing: axisRowsSpacing) {
                axisContent(canvasWidth)

                ScrollView(.vertical, showsIndicators: metrics.rowsHeight > metrics.rowsViewportHeight) {
                    rowContent(canvasWidth, metrics)
                        .frame(height: metrics.rowsHeight, alignment: .topLeading)
                }
                .frame(height: metrics.rowsViewportHeight, alignment: .topLeading)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: metrics.containerHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.gray.opacity(0.06))
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct ContinuousHeatmapView: View {
    let range: ReportRange
    let categories: [String]
    let items: [HeatmapEvent]
    let categoryColors: [String: Color]

    private let labelWidth: CGFloat = 96
    private let rowHeight: CGFloat = 26
    private let rowSpacing: CGFloat = 10
    private let axisLabelWidth: CGFloat = 72
    private let horizontalPadding: CGFloat = 16

    var body: some View {
        HeatmapTimelineContainer(
            categoryCount: categories.count,
            labelWidth: labelWidth,
            rowHeight: rowHeight,
            rowSpacing: rowSpacing,
            horizontalPadding: horizontalPadding
        ) { canvasWidth in
            let tickDates = timelineTicks(canvasWidth: canvasWidth)

            HStack(alignment: .bottom, spacing: 0) {
                Color.clear
                    .frame(width: labelWidth, height: 1)

                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: 1)
                        .offset(y: 20)

                    ForEach(Array(tickDates.enumerated()), id: \.offset) { index, tick in
                        let xPosition = position(for: tick, in: canvasWidth)
                        VStack(spacing: 4) {
                            Text(tickLabel(for: tick, isLast: index == tickDates.count - 1))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: axisLabelWidth, alignment: .center)
                                .multilineTextAlignment(.center)
                            Rectangle()
                                .fill(Color.secondary.opacity(0.25))
                                .frame(width: 1, height: 8)
                        }
                        .frame(width: axisLabelWidth)
                        .offset(x: xPosition - axisLabelWidth / 2)
                    }
                }
                .frame(width: canvasWidth, height: 30)
            }
        } rowContent: { canvasWidth, metrics in
            let rowStride = metrics.rowStride
            let canvasHeight = metrics.rowsHeight
            let rowIndexMap = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($0.element, $0.offset) })

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: rowSpacing) {
                    ForEach(categories, id: \.self) { category in
                        Text(L10n.displayCategoryName(category))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: labelWidth, height: rowHeight, alignment: .leading)
                    }
                }

                ZStack(alignment: .topLeading) {
                    ForEach(Array(categories.enumerated()), id: \.element) { index, _ in
                        RoundedRectangle(cornerRadius: 8)
                            .fill(index.isMultiple(of: 2) ? Color.gray.opacity(0.08) : Color.clear)
                            .frame(width: canvasWidth, height: rowHeight)
                            .offset(y: CGFloat(index) * rowStride)
                    }

                    ForEach(items) { item in
                        if let rowIndex = rowIndexMap[item.category] {
                            RoundedRectangle(cornerRadius: 7)
                                .fill((categoryColors[item.category] ?? .accentColor).opacity(0.78))
                                .frame(
                                    width: max(eventWidth(for: item, in: canvasWidth), 1),
                                    height: rowHeight - 4
                                )
                                .offset(
                                    x: position(for: item.start, in: canvasWidth),
                                    y: CGFloat(rowIndex) * rowStride + 2
                                )
                        }
                    }
                }
                .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
            }
        }
    }

    fileprivate func timelineTicks(canvasWidth: CGFloat) -> [Date] {
        let tickCount = max(3, min(Int(canvasWidth / axisLabelWidth), 8))
        let totalDuration = range.interval.duration
        guard totalDuration > 0 else {
            return [range.interval.start]
        }

        return (0..<tickCount).map { index in
            if index == tickCount - 1 {
                return range.interval.end
            }
            let progress = Double(index) / Double(tickCount - 1)
            return range.interval.start.addingTimeInterval(totalDuration * progress)
        }
    }

    fileprivate func position(for date: Date, in width: CGFloat) -> CGFloat {
        let totalDuration = max(range.interval.duration, 1)
        let offset = date.timeIntervalSince(range.interval.start)
        let progress = min(max(offset / totalDuration, 0), 1)
        return CGFloat(progress) * width
    }

    fileprivate func eventWidth(for item: HeatmapEvent, in width: CGFloat) -> CGFloat {
        let totalDuration = max(range.interval.duration, 1)
        return CGFloat(item.end.timeIntervalSince(item.start) / totalDuration) * width
    }

    private func tickLabel(for tick: Date, isLast: Bool) -> String {
        let displayDate = isLast ? range.interval.end.addingTimeInterval(-1) : tick
        return AppDateFormatting.string(from: displayDate, style: .monthDay)
    }
}

private struct DailyHeatmapView: View {
    let range: ReportRange
    let categories: [String]
    let items: [HeatmapEvent]
    let categoryColors: [String: Color]
    @Binding var hoveredEvent: HeatmapEvent?

    private let labelWidth: CGFloat = 96
    private let rowHeight: CGFloat = 26
    private let rowSpacing: CGFloat = 10
    private let axisLabelWidth: CGFloat = 44
    private let horizontalPadding: CGFloat = 16

    var body: some View {
        HeatmapTimelineContainer(
            categoryCount: categories.count,
            labelWidth: labelWidth,
            rowHeight: rowHeight,
            rowSpacing: rowSpacing,
            horizontalPadding: horizontalPadding
        ) { canvasWidth in
            let tickDates = timelineTicks(canvasWidth: canvasWidth)

            HStack(alignment: .bottom, spacing: 0) {
                Color.clear
                    .frame(width: labelWidth, height: 1)

                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: 1)
                        .offset(y: 20)

                    ForEach(Array(tickDates.enumerated()), id: \.offset) { _, tick in
                        let xPosition = position(for: tick, in: canvasWidth)
                        VStack(spacing: 4) {
                            Text(tickLabel(for: tick))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: axisLabelWidth, alignment: .center)
                                .multilineTextAlignment(.center)
                            Rectangle()
                                .fill(Color.secondary.opacity(0.25))
                                .frame(width: 1, height: 8)
                        }
                        .frame(width: axisLabelWidth)
                        .offset(x: xPosition - axisLabelWidth / 2)
                    }
                }
                .frame(width: canvasWidth, height: 30)
            }
        } rowContent: { canvasWidth, metrics in
            let rowStride = metrics.rowStride
            let canvasHeight = metrics.rowsHeight
            let rowIndexMap = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($0.element, $0.offset) })
            let hoverFrames = hoverFrames(rowIndexMap: rowIndexMap, rowStride: rowStride, canvasWidth: canvasWidth)

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: rowSpacing) {
                    ForEach(categories, id: \.self) { category in
                        Text(L10n.displayCategoryName(category))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: labelWidth, height: rowHeight, alignment: .leading)
                    }
                }

                ZStack(alignment: .topLeading) {
                    ForEach(Array(categories.enumerated()), id: \.element) { index, _ in
                        RoundedRectangle(cornerRadius: 8)
                            .fill(index.isMultiple(of: 2) ? Color.gray.opacity(0.08) : Color.clear)
                            .frame(width: canvasWidth, height: rowHeight)
                            .offset(y: CGFloat(index) * rowStride)
                    }

                    ForEach(items) { item in
                        if let rowIndex = rowIndexMap[item.category] {
                            RoundedRectangle(cornerRadius: 7)
                                .fill((categoryColors[item.category] ?? .accentColor).opacity(0.78))
                                .frame(
                                    width: max(eventWidth(for: item, in: canvasWidth), 1),
                                    height: rowHeight - 4
                                )
                                .offset(
                                    x: position(for: item.start, in: canvasWidth),
                                    y: CGFloat(rowIndex) * rowStride + 2
                            )
                        }
                    }
                }
                .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoveredEvent = hoverFrames.last(where: { $0.rect.contains(location) })?.event
                    case .ended:
                        hoveredEvent = nil
                    }
                }
            }
        }
    }

    private func position(for date: Date, in width: CGFloat) -> CGFloat {
        let totalDuration = max(range.interval.duration, 1)
        let progress = min(max(date.timeIntervalSince(range.interval.start) / totalDuration, 0), 1)
        return CGFloat(progress) * width
    }

    private func eventWidth(for item: HeatmapEvent, in width: CGFloat) -> CGFloat {
        let totalDuration = max(range.interval.duration, 1)
        return CGFloat(item.end.timeIntervalSince(item.start) / totalDuration) * width
    }

    private func hoverFrames(
        rowIndexMap: [String: Int],
        rowStride: CGFloat,
        canvasWidth: CGFloat
    ) -> [DailyHeatmapHoverFrame] {
        items.compactMap { item in
            guard let rowIndex = rowIndexMap[item.category] else {
                return nil
            }

            let startX = position(for: item.start, in: canvasWidth)
            let width = max(eventWidth(for: item, in: canvasWidth), 1)
            let rect = CGRect(
                x: startX,
                y: CGFloat(rowIndex) * rowStride + 2,
                width: width,
                height: rowHeight - 4
            )
            return DailyHeatmapHoverFrame(event: item, rect: rect)
        }
    }

    private func timelineTicks(canvasWidth: CGFloat) -> [Date] {
        let hourStep = adaptiveHourStep(canvasWidth: canvasWidth)
        let totalHours = 24

        return stride(from: 0, through: totalHours, by: hourStep).compactMap { hour in
            Calendar.reportCalendar.date(byAdding: .hour, value: hour, to: range.interval.start)
        }
    }

    private func adaptiveHourStep(canvasWidth: CGFloat) -> Int {
        let maxLabelCount = max(Int(canvasWidth / axisLabelWidth), 2)
        for hourStep in [1, 2, 3, 4, 6, 8, 12] {
            if (24 / hourStep) + 1 <= maxLabelCount {
                return hourStep
            }
        }
        return 12
    }

    private func tickLabel(for tick: Date) -> String {
        let hours = Calendar.reportCalendar.dateComponents([.hour], from: range.interval.start, to: tick).hour ?? 0
        if hours == 24 {
            return AppTimeFormatting.endOfDayString(for: range.interval.end)
        }
        return AppTimeFormatting.string(from: tick)
    }
}

private struct DailyHeatmapHoverFrame {
    let event: HeatmapEvent
    let rect: CGRect
}

private struct OverlayDailyTimeHeatmapView: View {
    let categories: [String]
    let items: [HeatmapEvent]
    let categoryColors: [String: Color]

    private let labelWidth: CGFloat = 96
    private let rowHeight: CGFloat = 26
    private let rowSpacing: CGFloat = 10
    private let axisLabelWidth: CGFloat = 44
    private let horizontalPadding: CGFloat = 16

    var body: some View {
        HeatmapTimelineContainer(
            categoryCount: categories.count,
            labelWidth: labelWidth,
            rowHeight: rowHeight,
            rowSpacing: rowSpacing,
            horizontalPadding: horizontalPadding
        ) { canvasWidth in
            let tickDates = timelineTicks(canvasWidth: canvasWidth)

            HStack(alignment: .bottom, spacing: 0) {
                Color.clear
                    .frame(width: labelWidth, height: 1)

                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: 1)
                        .offset(y: 20)

                    ForEach(Array(tickDates.enumerated()), id: \.offset) { index, tick in
                        let isLast = index == tickDates.count - 1
                        let xPosition = isLast ? canvasWidth : position(for: tick, in: canvasWidth)
                        VStack(spacing: 4) {
                            Text(tickLabel(for: tick, isLast: isLast))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: axisLabelWidth, alignment: .center)
                                .multilineTextAlignment(.center)
                            Rectangle()
                                .fill(Color.secondary.opacity(0.25))
                                .frame(width: 1, height: 8)
                        }
                        .frame(width: axisLabelWidth)
                        .offset(x: xPosition - axisLabelWidth / 2)
                    }
                }
                .frame(width: canvasWidth, height: 30)
            }
        } rowContent: { canvasWidth, metrics in
            let rowStride = metrics.rowStride
            let canvasHeight = metrics.rowsHeight
            let rowIndexMap = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($0.element, $0.offset) })
            let fragments = OverlayDailyTimeHeatmap.fragments(from: items)
            let depthSegments = OverlayDailyTimeHeatmap.depthSegments(for: fragments)

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: rowSpacing) {
                    ForEach(categories, id: \.self) { category in
                        Text(L10n.displayCategoryName(category))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: labelWidth, height: rowHeight, alignment: .leading)
                    }
                }

                ZStack(alignment: .topLeading) {
                    ForEach(Array(categories.enumerated()), id: \.element) { index, _ in
                        RoundedRectangle(cornerRadius: 8)
                            .fill(index.isMultiple(of: 2) ? Color.gray.opacity(0.08) : Color.clear)
                            .frame(width: canvasWidth, height: rowHeight)
                            .offset(y: CGFloat(index) * rowStride)
                    }

                    ForEach(depthSegments) { segment in
                        if let rowIndex = rowIndexMap[segment.category] {
                            Rectangle()
                                .fill((categoryColors[segment.category] ?? .accentColor).opacity(segment.depth))
                                .frame(
                                    width: max(position(for: segment.endSeconds, in: canvasWidth) - position(for: segment.startSeconds, in: canvasWidth), 1),
                                    height: rowHeight - 4
                                )
                                .offset(
                                    x: position(for: segment.startSeconds, in: canvasWidth),
                                    y: CGFloat(rowIndex) * rowStride + 2
                                )
                        }
                    }
                }
                .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
            }
        }
    }

    private func timelineTicks(canvasWidth: CGFloat) -> [Date] {
        let hourStep = adaptiveHourStep(canvasWidth: canvasWidth)
        let base = Calendar.reportCalendar.startOfDay(for: Date())

        return stride(from: 0, through: 24, by: hourStep).compactMap { hour in
            Calendar.reportCalendar.date(byAdding: .hour, value: hour, to: base)
        }
    }

    private func adaptiveHourStep(canvasWidth: CGFloat) -> Int {
        let maxLabelCount = max(Int(canvasWidth / axisLabelWidth), 2)
        for hourStep in [1, 2, 3, 4, 6, 8, 12] {
            if (24 / hourStep) + 1 <= maxLabelCount {
                return hourStep
            }
        }
        return 12
    }

    private func position(for seconds: TimeInterval, in width: CGFloat) -> CGFloat {
        CGFloat(min(max(seconds / 86_400.0, 0), 1)) * width
    }

    private func position(for date: Date, in width: CGFloat) -> CGFloat {
        let dayStart = Calendar.reportCalendar.startOfDay(for: date)
        return position(for: date.timeIntervalSince(dayStart), in: width)
    }

    private func tickLabel(for tick: Date, isLast: Bool) -> String {
        if isLast {
            return AppTimeFormatting.endOfDayString(for: tick)
        }
        return AppTimeFormatting.string(from: tick)
    }
}

struct OverlayDailyTimeFragment: Identifiable, Equatable {
    let id: String
    let category: String
    let dayStart: Date
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
}

struct OverlayDailyTimeDepthSegment: Identifiable, Equatable {
    let id: String
    let category: String
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let depth: Double
}

enum OverlayDailyTimeHeatmap {
    static func fragments(
        from items: [HeatmapEvent],
        calendar: Calendar = .reportCalendar
    ) -> [OverlayDailyTimeFragment] {
        var fragments: [OverlayDailyTimeFragment] = []

        for item in items {
            var segmentStart = item.start
            while segmentStart < item.end {
                let dayStart = calendar.startOfDay(for: segmentStart)
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? item.end
                let segmentEnd = min(item.end, dayEnd)
                fragments.append(
                    OverlayDailyTimeFragment(
                        id: "\(item.id)-\(segmentStart.timeIntervalSince1970)",
                        category: item.category,
                        dayStart: dayStart,
                        startSeconds: segmentStart.timeIntervalSince(dayStart),
                        endSeconds: segmentEnd.timeIntervalSince(dayStart)
                    )
                )
                segmentStart = segmentEnd
            }
        }

        return fragments
    }

    static func depthSegments(for fragments: [OverlayDailyTimeFragment]) -> [OverlayDailyTimeDepthSegment] {
        let activityDays = Set(
            fragments.lazy
                .filter { $0.category != AppDefaults.absenceCategoryName }
                .map(\.dayStart)
        ).count
        let absenceDays = Set(
            fragments.lazy
                .filter { $0.category == AppDefaults.absenceCategoryName }
                .map(\.dayStart)
        ).count

        let fragmentsByCategory = Dictionary(grouping: fragments, by: \.category)
        let rawSegments = fragmentsByCategory.keys.sorted().flatMap { category -> [OverlayDailyTimeDepthSegment] in
            let categoryFragments = fragmentsByCategory[category] ?? []
            let recordedDayCount = category == AppDefaults.absenceCategoryName ? absenceDays : activityDays
            guard recordedDayCount > 0 else {
                return []
            }

            let contribution = 1.0 / Double(recordedDayCount)
            var occurrenceDeltas: [TimeInterval: Int] = [:]
            for fragment in categoryFragments {
                occurrenceDeltas[fragment.startSeconds, default: 0] += 1
                occurrenceDeltas[fragment.endSeconds, default: 0] -= 1
            }
            let boundaries = occurrenceDeltas.keys.sorted()
            guard boundaries.count >= 2 else {
                return []
            }

            var segments: [OverlayDailyTimeDepthSegment] = []
            var occurrenceCount = 0
            for index in 0..<(boundaries.count - 1) {
                let start = boundaries[index]
                let end = boundaries[index + 1]
                occurrenceCount += occurrenceDeltas[start, default: 0]
                guard end > start else {
                    continue
                }

                guard occurrenceCount > 0 else {
                    continue
                }

                let depth = Double(occurrenceCount) * contribution
                if let previous = segments.last,
                   previous.endSeconds == start,
                   previous.depth == depth {
                    segments[segments.count - 1] = OverlayDailyTimeDepthSegment(
                        id: previous.id,
                        category: category,
                        startSeconds: previous.startSeconds,
                        endSeconds: end,
                        depth: depth
                    )
                } else {
                    segments.append(
                        OverlayDailyTimeDepthSegment(
                            id: "\(category)-\(start)",
                            category: category,
                            startSeconds: start,
                            endSeconds: end,
                            depth: depth
                        )
                    )
                }
            }
            return segments
        }
        return normalizeDepths(rawSegments)
    }

    private static func normalizeDepths(
        _ segments: [OverlayDailyTimeDepthSegment]
    ) -> [OverlayDailyTimeDepthSegment] {
        let activityMaximum = segments.lazy
            .filter { $0.category != AppDefaults.absenceCategoryName }
            .map(\.depth)
            .max() ?? 0
        let absenceMaximum = segments.lazy
            .filter { $0.category == AppDefaults.absenceCategoryName }
            .map(\.depth)
            .max() ?? 0

        return segments.map { segment in
            let maximum = segment.category == AppDefaults.absenceCategoryName
                ? absenceMaximum
                : activityMaximum
            let normalizedDepth = maximum > 0 ? min(segment.depth / maximum, 1) : 0
            return OverlayDailyTimeDepthSegment(
                id: segment.id,
                category: segment.category,
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                depth: normalizedDepth
            )
        }
    }
}
