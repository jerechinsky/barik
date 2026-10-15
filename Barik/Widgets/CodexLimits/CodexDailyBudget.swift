import Foundation

struct CodexDailyBudget: Equatable {
    let exactPercent: Double
    let conservativePercent: Int
    let periodEnd: Date
    let endsAtReset: Bool
    let targetRemainingPercent: Int

    var compactPercentText: String {
        if exactPercent > 0, exactPercent < 1 {
            return "<1%"
        }
        return "\(conservativePercent)%"
    }

    var spokenPercentText: String {
        if exactPercent > 0, exactPercent < 1 {
            return "less than 1 percent"
        }
        return "\(conservativePercent) percent"
    }
}

enum CodexDailyBudgetCalculator {
    /// Treat a reset in the very early morning as the end of the preceding
    /// evening's usable period. Otherwise a 04:00 reset would reserve quota
    /// after midnight even though there is no practical next day in which to
    /// spend it.
    private static let morningResetHour = 6

    static func calculate(
        remainingPercent: Int,
        resetsAt: Date,
        at date: Date = Date(),
        calendar: Calendar = .current,
        windowDurationMinutes: Int = 7 * 24 * 60
    ) -> CodexDailyBudget? {
        guard resetsAt > date, windowDurationMinutes > 0 else { return nil }

        let startOfToday = calendar.startOfDay(for: date)
        guard let nextMidnight = calendar.date(
            byAdding: .day,
            value: 1,
            to: startOfToday
        ), nextMidnight > date else {
            return nil
        }

        let morningCutoff = calendar.date(
            byAdding: .hour,
            value: morningResetHour,
            to: nextMidnight
        ) ?? nextMidnight
        let resetEndsTonight = resetsAt <= morningCutoff
        let periodEnd = resetEndsTonight ? resetsAt : nextMidnight
        // Anchor pacing to the server's whole quota window, never to the
        // balance observed when Barik happened to start. Reserve future days;
        // savings and debt both carry into the current day's allowance.
        let windowDuration = Double(windowDurationMinutes) * 60
        let futureFraction = max(0, min(1,
            resetsAt.timeIntervalSince(periodEnd) / windowDuration
        ))
        let target = Int(ceil(100 * futureFraction))
        let available = max(0, min(100, remainingPercent)) - target

        return CodexDailyBudget(
            exactPercent: Double(available),
            conservativePercent: available,
            periodEnd: periodEnd,
            endsAtReset: resetEndsTonight,
            targetRemainingPercent: target
        )
    }
}
