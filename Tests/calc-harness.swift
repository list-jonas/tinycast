// Shared by the calc-* harnesses: a fixed clock and rate table, and the expectations they check.
import Foundation

@MainActor var passes = 0
@MainActor var failures = 0

// Fri 2026-07-24 00:18:00 UTC
let clock: (now: Date, calendar: Calendar) = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US")
    let components = DateComponents(year: 2026, month: 7, day: 24, hour: 0, minute: 18, second: 0)
    return (calendar.date(from: components)!, calendar)
}()

/// Absent on purpose: a recognized code must reach "no exchange rate", not no card.
let fx = CurrencyRates(
    base: "USD",
    rates: [
        "USD": 1, "EUR": 0.92, "GBP": 0.79, "JPY": 157, "INR": 83.5, "CAD": 1.36,
        "KRW": 1330, "IDR": 18053, "CHF": 0.81, "AED": 3.6725, "SGD": 1.35,
        "BTC": 1.0 / 60_000, "ETH": 1.0 / 2_000, "SOL": 1.0 / 100, "DOGE": 10
    ],
    fetchedAt: Date(timeIntervalSince1970: 1_785_000_000))

let italian = CalcNumberFormat(decimalSeparator: ",", groupingSeparator: ".")!

@MainActor func finish() -> Never {
    print("\n\(passes) passed, \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}

@MainActor func check(_ query: String, expected: String, got: String) {
    if got == expected { passes += 1 } else { fail(query, expected: expected, got: got) }
}

@MainActor func fail(_ query: String, expected: String, got: String) {
    failures += 1
    print("FAIL  \(query)\n      expected: \(expected)\n      got:      \(got)")
}

@MainActor func expectNone(_ label: String, _ result: CalcResult?) {
    if let result { fail(label, expected: "nil", got: "\(result.payload)") } else { passes += 1 }
}

private func display(_ result: CalcResult?) -> String {
    guard case .value(let display, _)? = result?.payload else { return "nil / error" }
    return display
}

private func copy(_ result: CalcResult?) -> String {
    guard case .value(_, let copy)? = result?.payload else { return "nil / error" }
    return copy
}

@MainActor private func expectBadges(_ label: String, _ result: CalcResult?, _ source: String, _ target: String) {
    guard let result else { return fail(label, expected: "\(source) → \(target)", got: "nil") }
    check(label + " [source badge]", expected: source, got: result.sourceBadge ?? "nil")
    check(label + " [target badge]", expected: target, got: result.targetBadge ?? "nil")
}

/// The region currency is injected, so the suite ignores the host's region.
private func label(_ query: String, _ region: String?) -> String {
    region.map { "\(query) [region \($0)]" } ?? query
}

private func evaluate(_ query: String, region: String? = nil, rates: CurrencyRates? = fx) -> CalcResult? {
    CalcEngine.evaluate(query, now: clock.now, calendar: clock.calendar, rates: rates, region: region)
}

private func evaluateAt(_ query: String, _ now: Date, _ calendar: Calendar?) -> CalcResult? {
    CalcEngine.evaluate(query, now: now, calendar: calendar ?? clock.calendar)
}

@MainActor func expectDisplay(_ query: String, _ expected: String, region: String? = nil) {
    check(label(query, region), expected: expected, got: display(evaluate(query, region: region)))
}

@MainActor func expectCopy(_ query: String, _ expected: String, region: String? = nil) {
    check(label(query, region), expected: expected, got: copy(evaluate(query, region: region)))
}

@MainActor func expectBadges(_ query: String, source: String, target: String, region: String? = nil) {
    expectBadges(label(query, region), evaluate(query, region: region), source, target)
}

@MainActor func expectExpression(_ query: String, _ expected: String, region: String? = nil) {
    check(label(query, region), expected: expected, got: evaluate(query, region: region)?.expression ?? "nil")
}

@MainActor func expectNil(_ query: String, region: String? = nil) {
    expectNone(label(query, region), evaluate(query, region: region))
}

@MainActor func expectError(_ query: String, _ expected: String) {
    expectError(query, expected, evaluate(query))
}

/// No snapshot has landed yet — first run, or still offline.
@MainActor func expectErrorWithoutRates(_ query: String, _ expected: String) {
    expectError(query, expected, evaluate(query, rates: nil))
}

@MainActor private func expectError(_ query: String, _ expected: String, _ result: CalcResult?) {
    guard case .error(let message)? = result?.payload else {
        return fail(query, expected: "error: \(expected)", got: "nil / value")
    }
    check(query, expected: expected, got: message)
}

@MainActor func expectDisplayAt(
    _ query: String, _ expected: String, now: Date = clock.now, calendar: Calendar? = nil
) {
    check(query, expected: expected, got: display(evaluateAt(query, now, calendar)))
}

@MainActor func expectBadgesAt(
    _ query: String, source: String, target: String, now: Date = clock.now, calendar: Calendar? = nil
) {
    expectBadges(query, evaluateAt(query, now, calendar), source, target)
}

@MainActor func expectNilAt(_ query: String, now: Date = clock.now, calendar: Calendar? = nil) {
    expectNone(query, evaluateAt(query, now, calendar))
}

func evaluateLocalized(_ query: String, _ format: CalcNumberFormat) -> CalcResult? {
    CalcEngine.evaluate(query, now: clock.now, calendar: clock.calendar, rates: fx, format: format)
        .map(format.localized)
}

func formatLabel(_ query: String, _ format: CalcNumberFormat) -> String {
    "\(query) [decimal \(format.decimalSeparator)]"
}

@MainActor func expectLocalized(_ query: String, _ expected: String, _ format: CalcNumberFormat) {
    check(formatLabel(query, format), expected: expected, got: display(evaluateLocalized(query, format)))
}
