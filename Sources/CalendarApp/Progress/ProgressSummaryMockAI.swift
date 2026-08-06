import Foundation

/// Local stand-in for https://github.com/adeptify/prologue until wired.
/// Generates encouraging Chinese copy from stats only — no network.
enum ProgressSummaryMockAI {
    static func generate(from stats: ProgressSummaryStats, now: Date = Date()) -> ProgressSummaryReport {
        ProgressSummaryReport(
            stats: stats,
            highlights: highlights(stats),
            categorySections: categoryBodies(stats),
            encouragement: encouragement(stats),
            isMockAI: true,
            generatedAt: now
        )
    }

    // MARK: - Part 1

    private static func highlights(_ stats: ProgressSummaryStats) -> String {
        let period = stats.range.period.shortLabel
        let span = stats.range.rangeCaption
        let rate = stats.completionPercent

        if stats.totalItems == 0 {
            return period + "（" + span + "）目前还没有登记事项。空白本身也是一种节奏——你已经打开了复盘的入口，下一步只要轻轻放进一两件想推进的事，进度就会开始生长。"
        }

        let pace: String
        switch rate {
        case 80...:
            pace = "完成度大约 \(rate)%，节奏扎实，计划落地感很强。"
        case 50..<80:
            pace = "完成度大约 \(rate)%，整体在稳步推进；未完成的部分也清晰可见，便于聚焦。"
        case 25..<50:
            pace = "完成度大约 \(rate)%，这更像「铺开计划、开始啃硬骨头」的阶段——方向在，动作也有。"
        default:
            pace = "完成度大约 \(rate)%，起步阶段最珍贵的是把事项写下来；你已经迈出了规划这一步。"
        }

        let openNote: String
        if stats.openItems == 0 {
            openNote = "到今天为止，登记的事项都画上了完成勾，闭环感很好。"
        } else if stats.highPriorityOpen > 0 {
            openNote = "尚有 \(stats.openItems) 件未完成，其中 \(stats.highPriorityOpen) 件带有较高优先级，值得接下来优先关照。"
        } else {
            openNote = "尚有 \(stats.openItems) 件在路上，清单清楚，就不会慌。"
        }

        return "从" + period + "第一天到今天（" + span + "），一共关联 \(stats.totalItems) 件事项，已完成 \(stats.completedItems) 件。"
            + pace + "\n" + openNote
            + "\n这份小结先以鼓励为主：你愿意停下来看一眼自己的节奏，本身就是高质量的自我管理。"
    }

    // MARK: - Part 2

    private static func categoryBodies(_ stats: ProgressSummaryStats) -> [ProgressCategoryNarrative] {
        if stats.categories.isEmpty {
            return [
                ProgressCategoryNarrative(
                    name: "分类",
                    colorHex: "#8C8F96",
                    body: "本时段暂无按分类可汇总的事项。"
                )
            ]
        }
        return stats.categories.map { cat in
            let body: String
            if cat.total == 0 {
                body = "无事项。"
            } else if cat.completed == cat.total {
                body = "共 \(cat.total) 件，全部完成。"
            } else {
                let pct = Int((cat.completionRate * 100).rounded())
                body = "共 \(cat.total) 件，已完成 \(cat.completed) 件，未完成 \(cat.total - cat.completed) 件（完成率 \(pct)%）。"
            }
            return ProgressCategoryNarrative(name: cat.name, colorHex: cat.colorHex, body: body)
        }
    }

    // MARK: - Part 3

    private static func encouragement(_ stats: ProgressSummaryStats) -> String {
        let period = stats.range.period.shortLabel
        if stats.totalItems == 0 {
            return "空白页也值得温柔以待。你随时可以加一件小事——不必完美，开始就好。" + period + "余下的日子，慢慢写就行。"
        }
        if stats.completionPercent >= 80 {
            return "你把计划推进到了很舒服的位置。请务必记得：完成之外，也要给自己一点放松。继续保持这份清醒与行动力，" + period + "收官会很漂亮。"
        }
        if stats.completedItems > 0 {
            return "已经完成的 \(stats.completedItems) 件，是真实发生过的进步，不是幻觉。剩下的不用一次扛完——选最重要的一两件，轻轻推进一步，就足够被肯定。你配得上这份夸夸。"
        }
        return "事项在册，就是对生活的认真。哪怕勾选还不多，规划本身已经在替未来的你铺路。深呼吸，从最小的一步开始，我会站在你这边。"
    }
}
