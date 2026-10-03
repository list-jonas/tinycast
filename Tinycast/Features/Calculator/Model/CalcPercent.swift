import Foundation

/// Percentage phrasings the arithmetic parser misses: `20% off 500`, `50 as % of 200`.
enum CalcPercent {
    static func evaluate(_ tokens: [CalcToken], query: String) -> CalcResult? {
        let parsers = [
            parseOff, parseAsPercentOf, parseTip, parseWhatPercentOf, parseIsPercentOfWhat, parseRatio,
            parseAggregate, parseRoundToNearest
        ]
        return parsers.lazy.compactMap { $0(tokens, query) }.first
    }

    /// `<pct>% off <value>` → the value reduced by pct percent (`20% off 500` → 400).
    private static func parseOff(_ tokens: [CalcToken], query: String) -> CalcResult? {
        guard let off = tokens.firstIndex(of: .ident("off")), off >= 2, tokens[off - 1] == .op(.percent),
            let pct = CalcExpressionParser.scalar(Array(tokens[0..<(off - 1)])),
            let base = CalcExpressionParser.scalar(Array(tokens[(off + 1)...]))
        else { return nil }
        return card(query, base * (1 - pct / 100), target: "Discounted")
    }

    /// `<x> as % of <y>` → x / y × 100, rendered as a percentage (`50 as % of 200` → 25%).
    private static func parseAsPercentOf(_ tokens: [CalcToken], query: String) -> CalcResult? {
        guard let asIdx = tokens.firstIndex(of: .ident("as")), asIdx + 2 < tokens.count,
            tokens[asIdx + 1] == .op(.percent), tokens[asIdx + 2] == .ident("of"),
            let x = CalcExpressionParser.scalar(Array(tokens[0..<asIdx])),
            let y = CalcExpressionParser.scalar(Array(tokens[(asIdx + 3)...])), y != 0
        else { return nil }
        return card(query, x / y * 100, suffix: "%", target: "Percentage")
    }

    private static func card(_ query: String, _ payload: CalcResult.Payload, target: String) -> CalcResult {
        CalcResult(
            expression: query.split(whereSeparator: \.isWhitespace).joined(separator: " "),
            sourceBadge: "Expression", targetBadge: target, payload: payload)
    }

    private static func card(_ query: String, _ value: Double, suffix: String = "", target: String) -> CalcResult? {
        value.isFinite ? card(query, .number(value, suffix: suffix), target: target) : nil
    }

    /// The tip alone, not the total: it is the number the phrase asks for.
    private static func parseTip(_ tokens: [CalcToken], query: String) -> CalcResult? {
        guard let tip = tokens.firstIndex(of: .ident("tip")), tip >= 2, tip + 2 < tokens.count,
            tokens[tip - 1] == .op(.percent),
            tokens[tip + 1] == .ident("on") || tokens[tip + 1] == .ident("of"),
            let pct = CalcExpressionParser.scalar(Array(tokens[0..<(tip - 1)])),
            let bill = CalcExpressionParser.scalar(Array(tokens[(tip + 2)...]))
        else { return nil }
        return card(query, bill * pct / 100, target: "Tip")
    }

    private static func parseWhatPercentOf(_ tokens: [CalcToken], query: String) -> CalcResult? {
        guard let isIdx = tokens.firstIndex(of: .ident("is")), isIdx + 4 <= tokens.count,
            isIdx + 3 < tokens.count, tokens[isIdx + 1] == .ident("what"), tokens[isIdx + 2] == .op(.percent),
            tokens[isIdx + 3] == .ident("of"), let x = CalcExpressionParser.scalar(Array(tokens[0..<isIdx])),
            let y = CalcExpressionParser.scalar(Array(tokens[(isIdx + 4)...])), y != 0
        else { return nil }
        return card(query, x / y * 100, suffix: "%", target: "Percentage")
    }

    private static func parseIsPercentOfWhat(_ tokens: [CalcToken], query: String) -> CalcResult? {
        guard tokens.count >= 6, tokens.last == .ident("what"), tokens[tokens.count - 2] == .ident("of"),
            tokens[tokens.count - 3] == .op(.percent), let isIdx = tokens.firstIndex(of: .ident("is")),
            let x = CalcExpressionParser.scalar(Array(tokens[0..<isIdx])),
            let pct = CalcExpressionParser.scalar(Array(tokens[(isIdx + 1)..<(tokens.count - 3)])), pct != 0
        else { return nil }
        return card(query, x / (pct / 100), target: "Total")
    }

    /// Integers only, so the reduced pair stays exact.
    private static func parseRatio(_ tokens: [CalcToken], query: String) -> CalcResult? {
        guard tokens.count >= 5, tokens[0] == .ident("ratio"), tokens[1] == .ident("of"),
            let toIdx = tokens.firstIndex(of: .ident("to")),
            let a = CalcExpressionParser.scalar(Array(tokens[2..<toIdx])),
            let b = CalcExpressionParser.scalar(Array(tokens[(toIdx + 1)...])), a.rounded() == a,
            b.rounded() == b, abs(a) <= 1e15, abs(b) <= 1e15, a != 0 || b != 0
        else { return nil }
        let divisor = greatestCommonDivisor(abs(a), abs(b))
        guard divisor > 0 else { return nil }
        let text = "\(CalcFormatter.display(a / divisor)) : \(CalcFormatter.display(b / divisor))"
        return card(query, .text(text), target: "Ratio")
    }

    private static func greatestCommonDivisor(_ a: Double, _ b: Double) -> Double {
        var (x, y) = (a, b)
        while y > 0 { (x, y) = (y, x.truncatingRemainder(dividingBy: y)) }
        return x
    }

    private static func parseAggregate(_ tokens: [CalcToken], query: String) -> CalcResult? {
        guard tokens.count >= 3, case .ident(let name) = tokens[0], let aggregate = aggregates[name],
            tokens[1] == .ident("of")
        else { return nil }
        let values = splitList(Array(tokens[2...]))
        guard values.count >= 2, let result = aggregate.reduce(values) else { return nil }
        return card(query, result, target: aggregate.name)
    }

    /// Snaps to a step, not to a digit count, so `nearest 5` means multiples of 5.
    private static func parseRoundToNearest(_ tokens: [CalcToken], query: String) -> CalcResult? {
        guard tokens.count >= 5, tokens[0] == .ident("round"),
            let toIdx = tokens.firstIndex(of: .ident("to")), toIdx + 2 < tokens.count,
            tokens[toIdx + 1] == .ident("nearest"),
            let value = CalcExpressionParser.scalar(Array(tokens[1..<toIdx])),
            let step = CalcExpressionParser.scalar(Array(tokens[(toIdx + 2)...])), step != 0
        else { return nil }
        return card(query, (value / step).rounded() * step, target: "Rounded")
    }

    /// The badge names which reduction ran, so `min` and `max` are told apart on the card.
    private struct Aggregate {
        let name: String
        let reduce: @Sendable ([Double]) -> Double?
    }

    private static let aggregates: [String: Aggregate] = {
        let average = Aggregate(name: "Average") { $0.reduce(0, +) / Double($0.count) }
        let sum = Aggregate(name: "Sum") { $0.reduce(0, +) }
        return [
            "average": average, "avg": average, "mean": average, "sum": sum, "total": sum,
            "min": Aggregate(name: "Minimum") { $0.min() }, "max": Aggregate(name: "Maximum") { $0.max() }
        ]
    }()

    /// Each run is evaluated whole, so `sum of 2*3, 4` stays two operands.
    private static func splitList(_ tokens: [CalcToken]) -> [Double] {
        var values: [Double] = []
        var current: [CalcToken] = []
        for token in tokens {
            if token == .comma || token == .ident("and") {
                guard let value = CalcExpressionParser.scalar(current) else { return [] }
                values.append(value)
                current = []
            } else {
                current.append(token)
            }
        }
        guard let last = CalcExpressionParser.scalar(current) else { return [] }
        values.append(last)
        return values
    }
}
