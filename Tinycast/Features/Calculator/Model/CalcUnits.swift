import Foundation

enum CalcUnits {
    static let baseUnits: [CalcDimension: UnitDef] = {
        var units: [CalcDimension: UnitDef] = [:]
        for name in [
            "m", "kg", "s", "m2", "m3", "b", "m/s", "pa", "bps", "m/s2", "n", "j", "w", "hz", "a", "v", "ohm",
            "as", "m3/s", "px", "px2", "ppi"
        ] {
            if let unit = byName[name], let dimension = unit.category.dimension { units[dimension] = unit }
        }
        return units
    }()

    static func productUnit(_ lhs: UnitDef, _ rhs: UnitDef) -> UnitDef? {
        let (measure, duration) = lhs.category == .time ? (rhs, lhs) : (lhs, rhs)
        guard duration.category == .time, duration.factor >= 60 else { return nil }
        switch measure.category {
        case .power: return byName[measure.factor >= 1000 ? "kwh" : "wh"]
        case .electricCurrent: return byName[measure.factor <= 0.001 ? "mah" : "ah"]
        default: return nil
        }
    }

    enum ConversionParse: Equatable {
        case value(input: Double, from: UnitDef, to: UnitDef, output: Double)
        case mismatch(from: UnitDef, to: UnitDef)
    }

    /// A keyword-less conversion to a curated counterpart; `compound` asks for feet+inches.
    struct BareConversion: Equatable {
        let input: Double
        let from: UnitDef
        let to: UnitDef
        let output: Double
        let compound: Bool
    }

    /// `expr unit (to|in|->) unit`. Matching the last position lets "in" double as inches.
    static func parseConversion(_ tokens: [CalcToken]) -> ConversionParse? {
        guard tokens.count >= 3, isConnector(tokens[tokens.count - 2]),
            case .ident(let toName) = tokens[tokens.count - 1], let to = byName[toName],
            case .ident(let fromName) = tokens[tokens.count - 3], let from = byName[fromName]
        else { return nil }

        let valueTokens = Array(tokens[0..<(tokens.count - 3)])
        guard let input = valueTokens.isEmpty ? 1 : CalcExpressionParser.scalar(valueTokens) else { return nil }
        guard from.category == to.category else { return .mismatch(from: from, to: to) }
        let output = CalcQuantity.convertUnit(input, from: from, to: to)
        guard output.isFinite else { return nil }
        return .value(input: input, from: from, to: to, output: output)
    }

    /// `day s` → `1 day` in `s`. Same category only, so two-word searches don't produce a card.
    static func parseUnitPairConversion(_ tokens: [CalcToken]) -> ConversionParse? {
        guard tokens.count == 2, case .ident(let fromName) = tokens[0], let from = byName[fromName],
            case .ident(let toName) = tokens[1], let to = byName[toName], from.category == to.category
        else { return nil }

        let output = CalcQuantity.convertUnit(1, from: from, to: to)
        guard output.isFinite else { return nil }
        return .value(input: 1, from: from, to: to, output: output)
    }

    /// `expr unit` with no connector. c/f/k are excluded, so `5k` stays an app search.
    static func parseBareConversion(_ tokens: [CalcToken]) -> BareConversion? {
        guard tokens.count >= 2, case .ident(let fromName) = tokens[tokens.count - 1],
            !["c", "f", "k"].contains(fromName), let from = byName[fromName],
            let target = autoTargets[from.symbol], let to = byName[target]
        else { return nil }

        let valueTokens = Array(tokens[0..<(tokens.count - 1)])
        guard let input = CalcExpressionParser.scalar(valueTokens) else { return nil }

        let output = CalcQuantity.convertUnit(input, from: from, to: to)
        guard output.isFinite else { return nil }
        return BareConversion(input: input, from: from, to: to, output: output, compound: from.symbol == "m")
    }

    static func isConnector(_ token: CalcToken) -> Bool {
        switch token {
        case .arrow, .ident("to"), .ident("in"): return true
        default: return false
        }
    }

    /// Keyword-less counterpart per unit; only `m→ft` is compound.
    static let autoTargets: [String: String] = [
        "mm": "in", "cm": "in", "m": "ft", "km": "mi", "dm": "cm", "in": "cm", "ft": "m", "yd": "m",
        "mi": "km", "mg": "g", "g": "oz", "kg": "lb", "oz": "g", "lb": "kg", "°C": "f", "°F": "c", "K": "c",
        "ms": "s", "s": "ms", "min": "s", "hr": "min", "day": "hr", "week": "day", "workdays": "hr",
        "mm²": "in2", "cm²": "in2", "m²": "ft2", "km²": "mi2", "in²": "cm2", "ft²": "m2", "yd²": "m2",
        "mi²": "km2", "acre": "m2", "ha": "acre", "dm²": "cm2", "mL": "floz", "L": "gal", "cup": "ml",
        "tbsp": "ml", "tsp": "ml", "gal": "l", "qt": "l", "pt": "ml", "fl oz": "ml", "cL": "ml", "dL": "ml",
        "mm³": "ml", "cm³": "ml", "dm³": "l", "m³": "l", "in³": "ml", "ft³": "l", "yd³": "l", "L/s": "l/min",
        "L/min": "l/h", "L/h": "l/min", "m³/s": "l/s", "m³/h": "l/min", "gal/min": "l/min", "bit": "b",
        "B": "bit", "kB": "kib", "MB": "mib", "GB": "gib", "TB": "tib", "PB": "tb", "KiB": "kb", "MiB": "mb",
        "GiB": "gb", "TiB": "tb", "deg": "rad", "rad": "deg", "grad": "deg", "turn": "deg", "arcmin": "deg",
        "arcsec": "deg", "km/h": "mph", "mph": "kmh", "m/s": "kmh", "kn": "kmh", "ft/s": "mph", "bar": "psi",
        "psi": "bar", "atm": "psi", "mbar": "psi", "kPa": "psi", "hPa": "psi", "mmHg": "psi", "Torr": "psi",
        "Mbps": "kbps", "Gbps": "mbps", "Kbps": "bps", "bps": "kbps", "Tbps": "gbps", "Wh": "kwh",
        "mWh": "wh", "kWh": "wh", "MWh": "kwh", "W": "kw", "mW": "w", "kW": "w", "MW": "kw", "A": "ma",
        "mA": "a", "µA": "ma", "MA": "a", "V": "mv", "mV": "v", "kV": "v", "MV": "kv", "Ω": "kohm",
        "mΩ": "ohm", "kΩ": "ohm", "MΩ": "kohm", "As": "ah", "Ah": "mah", "mAh": "ah", "MAh": "ah",
        "px": "rem", "rem": "px", "em": "px", "ppi": "px/cm", "px/cm": "ppi", "px/mm": "ppi", "px/m": "ppi"
    ]

    static let byName = CalcUnitCatalog.makeIndex()
}
