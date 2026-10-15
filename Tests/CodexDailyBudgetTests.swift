import Foundation

@main
private enum CodexDailyBudgetTests {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Prague")!
        func date(_ day: Int, _ hour: Int = 0, month: Int = 9) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
        }
        let reset = Date(timeIntervalSince1970: 1791046688)
        func budget(_ remaining: Int, _ now: Date, resetAt: Date? = nil) -> CodexDailyBudget {
            CodexDailyBudgetCalculator.calculate(remainingPercent: remaining,
                resetsAt: resetAt ?? reset, at: now, calendar: calendar)!
        }
        // Real account snapshot: 21% left on Wednesday, Saturday 18:58 reset.
        let today = budget(21, date(30, 21))
        precondition(today.targetRemainingPercent == 40)
        precondition(today.conservativePercent == -19 && today.compactPercentText == "-19%")
        precondition(budget(40, date(30, 21)).compactPercentText == "0%")
        precondition(budget(39, date(30, 21)).compactPercentText == "-1%")
        precondition(budget(27, date(30, 21)).compactPercentText == "-13%")
        // Same target throughout a local day, independent of current spending.
        precondition(budget(100, date(30)).targetRemainingPercent == 40)
        precondition(budget(0, date(30, 23)).conservativePercent == -40)
        precondition(budget(21, date(1, month: 10)).conservativePercent == -5)
        precondition(budget(21, date(2, month: 10)).conservativePercent == 9)
        precondition(budget(21, date(3, month: 10)).conservativePercent == 21)
        precondition(budget(21, date(3, month: 10)).endsAtReset)
        // Starting the app midweek does not redefine the weekly allowance.
        precondition(budget(21, date(30, 23)).targetRemainingPercent == today.targetRemainingPercent)
        precondition(CodexDailyBudgetCalculator.calculate(remainingPercent: 21,
            resetsAt: reset, at: reset, calendar: calendar) == nil)
        precondition(CodexDailyBudgetCalculator.calculate(remainingPercent: 21,
            resetsAt: reset, at: date(30), calendar: calendar, windowDurationMinutes: 0) == nil)
        let earlyReset = date(3, 4, month: 10)
        precondition(budget(9, date(2, 18, month: 10), resetAt: earlyReset).targetRemainingPercent == 0)
        // Local midnight uses the actual 25-hour day at the DST transition.
        let dst = budget(75, date(25, month: 10), resetAt: date(29, 8, month: 10))
        precondition(dst.periodEnd.timeIntervalSince(date(25, month: 10)) == 25 * 3600)
        precondition(dst.targetRemainingPercent == budget(75, date(25, 20, month: 10), resetAt: date(29, 8, month: 10)).targetRemainingPercent)
        print("PASS: weekly pacing, negative debt, savings, midnight rollover, early reset, DST and expired reset")
    }
}
