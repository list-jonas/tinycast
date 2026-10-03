// The calculator's currencies, rate feed, phrasings and number formats.
import Foundation

@main
@MainActor
struct CalcCurrencyTests {
    static func main() {
        // Currency — against the fixed `fx` table below (1 USD = 0.92 EUR = 0.79 GBP = 157 JPY)
        expectDisplay("1 euro to dollars", "1.09 USD")
        expectExpression("1 euro to dollars", "1 EUR")
        expectBadges("1 euro to dollars", source: "Euro", target: "US Dollar")
        expectDisplay("50 GBP in euros", "58.23 EUR")
        expectDisplay("100 dollars to yen", "15,700.00 JPY")
        expectDisplay("100 usd -> eur", "92.00 EUR")
        expectDisplay("2*50 usd to eur", "92.00 EUR")  // expression on the value side
        expectDisplay("eur to usd", "1.09 USD")  // implied amount of 1
        expectCopy("100 dollars to yen", "15700.00 JPY")
        // Currency signs, prefixed and suffixed
        expectDisplay("€20 to GBP", "17.17 GBP")
        expectDisplay("20€ to GBP", "17.17 GBP")
        expectDisplay("USD1K to EUR", "920.00 EUR")
        expectDisplay("1kUSD to EUR", "920.00 EUR")
        expectDisplay("£50 in dollars", "63.29 USD")
        expectDisplay("$100 to yen", "15,700.00 JPY")
        // Sub-cent cross-rates widen instead of collapsing to 0.00
        expectDisplay("1 jpy to usd", "0.006369 USD")
        // …and stay in plain notation past 1e-5, where "%g" would flip to "5.539e-05"
        expectDisplay("1 idr to usd", "0.00005539 USD")
        expectCopy("1 idr to usd", "0.00005539 USD")
        // Currency never steals a query the unit table can answer
        expectDisplay("10 pounds to kilograms", "4.5359237 kg")
        expectDisplay("10 pounds", "4.5359237 kg")
        expectDisplay("10 pounds to euros", "11.65 EUR")
        expectBadges("10 pounds to euros", source: "British Pound", target: "Euro")
        // Currency ↔ unit is a friendly category error, like Weight ↔ Time
        expectError("10 usd to kg", "Cannot convert Currency to Weight.")
        expectError("10 kg to usd", "Cannot convert Weight to Currency.")
        // A known currency the snapshot doesn't quote, and no snapshot at all
        expectError("5 usd to npr", "No exchange rate for NPR.")
        expectErrorWithoutRates(
            "1 eur to usd", "Exchange rates unavailable — check your connection.")
        expectNil("10 usd to nonsense")
        expectNil("usd")  // a lone code is still an app search
        expectNil("btc")  // …and a lone ticker no more than a lone code
        // The table is generated from the feed, so "no rate" is what proves recognition.
        expectError("5 usd to zmw", "No exchange rate for ZMW.")
        expectError("5 usd to afn", "No exchange rate for AFN.")
        check(
            "CurrencyData sizes", expected: "true",
            got:
                "\(CurrencyData.all.count >= 150 && CurrencyData.signs.count >= 20 && CurrencyData.aliases.count >= 100)"
        )
        // Retired codes are filtered out, so a currency nobody spends can't shadow a live one
        expectNil("1 hrk to usd")
        expectNil("1 kuna to usd")
        // Badges come from CLDR's label, which is shorter than the registry name where it matters
        expectBadges("1 chf to usd", source: "Swiss Franc", target: "US Dollar")
        expectBadges("1 aed to usd", source: "UAE Dirham", target: "US Dollar")
        // Nouns only one currency claims are generated — nobody hand-typed these
        expectError("1 zloty to usd", "No exchange rate for PLN.")
        expectError("1 forint to usd", "No exchange rate for HUF.")
        expectError("1 taka to usd", "No exchange rate for BDT.")
        expectError("1 rand to usd", "No exchange rate for ZAR.")
        // Accented nouns resolve with or without the accent
        expectError("1 krónur to usd", "No exchange rate for ISK.")
        expectError("1 kronur to usd", "No exchange rate for ISK.")
        // Nouns several currencies share are the hand-written part, and they must still win
        expectDisplay("1 franc to usd", "1.23 USD")
        expectError("1 peso to usd", "No exchange rate for MXN.")
        // `krona` is contested (SEK vs ISK) and deliberately assigned to neither
        expectNil("1 krona to usd")
        // ISO 4217's own name for CNY is "Yuan Renminbi"; CLDR carries only "Chinese Yuan"
        expectError("1 rmb to usd", "No exchange rate for CNY.")
        expectError("1 renminbi to usd", "No exchange rate for CNY.")
        // CLDR signs TWD "NT$", so `ntd` is what Taiwan types; `twd` keeps working
        expectError("1 ntd to usd", "No exchange rate for TWD.")
        expectError("1299 usd to ntd", "No exchange rate for TWD.")
        // Slang is no longer carried: CLDR has no "quid", and we don't hand-maintain synonyms
        expectNil("50 quid to usd")
        expectNil("100 bucks to eur")
        // The last word of a name isn't always its noun — Special Drawing Rights.
        expectNil("1 rights to usd")
        // A result too small to show at all reads as a clean zero, never "-0.00"
        expectDisplay("-0.0000000000001 usd to eur", "0.00 EUR")
        expectDisplay("0 usd to eur", "0.00 EUR")
        expectDisplay("-5 usd to eur", "-4.60 EUR")
        // CUP (Cuban peso) is a generated code that collides with a unit; volume still wins
        expectDisplay("1 cup to ml", "236.5882365 mL")

        // Currency expressions — still pure and deterministic against the injected rate table
        expectDisplay("10$", "10.00 USD")
        expectExpression("10$", "10 USD")
        expectBadges("10$", source: "Expression", target: "US Dollar")
        expectDisplay("$10 + $5", "15.00 USD")
        expectDisplay("10$ + 5$", "15.00 USD")
        expectDisplay("$10 + €5", "14.20 EUR")
        expectDisplay("€5 + $10", "15.43 USD")
        // Sign-first money echoes amount-first, like every other quantity
        expectExpression("$10 + €5", "10 USD + 5 EUR")
        expectExpression("10$ + 5€", "10 USD + 5 EUR")
        expectDisplay("$10 * 2", "20.00 USD")
        expectDisplay("$10 / 4", "2.50 USD")
        expectDisplay("$10 / $2", "5")
        expectDisplay("$100 * 3%", "3.00 USD")
        expectDisplay("3% * $100", "3.00 USD")
        expectDisplay("$100 / 25%", "400.00 USD")
        expectDisplay("($100 * 3%) to eur", "2.76 EUR")
        expectDisplay("($10 + $5) to eur", "13.80 EUR")
        // A parenthesized conversion is a quantity, so it can be multiplied or added.
        expectDisplay("(20 eur to usd) * 30", "652.17 USD")
        expectDisplay("(20 eur to usd) * 20", "434.78 USD")
        expectDisplay("(20 sgd to usd) * 30", "444.44 USD")
        expectDisplay("2 * (20 eur to usd)", "43.48 USD")
        expectDisplay("(20 eur to usd) / 2", "10.87 USD")
        expectDisplay("(eur to usd) * 2", "2.17 USD")  // implied amount of 1
        expectDisplay("(20 eur to usd) + (10 gbp to usd)", "34.40 USD")
        expectDisplay("((20 eur to usd) + 1) * 2", "45.48 USD")
        expectDisplay("(10km to mi) * 2", "12.42742384 mi")
        expectDisplay("(1hr + 30min to s) * 2", "10,800 s")
        expectExpression("(20 eur to usd) * 30", "(20 EUR to USD) × 30")
        expectBadges("(20 eur to usd) * 30", source: "Expression", target: "US Dollar")
        expectDisplay("(20 eur to usd) *", "21.74 USD")
        expectError("(10 kg to usd) * 2", "Cannot convert Weight to Currency.")
        // A trailing suffix reports through the same conversion the group uses.
        expectError("($10 + $5) to npr", "No exchange rate for NPR.")
        expectError("(1kg + 500g) to usd", "Cannot convert Weight to Currency.")
        // A mid-expression `to` converts before it adds; `* 30` stays ambiguous, so it needs parens
        expectNil("20 eur to usd * 30")
        expectNil("20 eur to usd / 2")
        expectDisplay("20 eur to usd + 5 usd", "26.74 USD")
        expectDisplay("$10 +", "10.00 USD")
        expectBadges("$10 +", source: "Expression", target: "US Dollar")
        // Juxtaposition multiplies on either side of the amount, same as an explicit "*"
        expectDisplay("$5(2)", "10.00 USD")
        expectDisplay("5(2)$", "10.00 USD")
        expectDisplay("$5(2) to eur", "9.20 EUR")
        expectError("$10 + 5kg", "Cannot add Currency and Weight.")
        expectErrorWithoutRates(
            "$10 + $5", "Exchange rates unavailable — check your connection.")
        expectErrorWithoutRates(
            "$100 * 3%", "Exchange rates unavailable — check your connection.")
        expectErrorWithoutRates(
            "10$", "Exchange rates unavailable — check your connection.")

        // Crypto — priced by the same table, so a coin converts against fiat with no special case
        expectDisplay("1 btc to usd", "60,000.00 USD")
        expectDisplay("1 bitcoin to usd", "60,000.00 USD")
        expectDisplay("0.5 sol to eur", "46.00 EUR")
        expectDisplay("2 eth to gbp", "3,160.00 GBP")
        expectBadges("1 eth to usd", source: "Ethereum", target: "US Dollar")
        // Sub-cent widening covers a coin the same way it covers IDR
        expectDisplay("1 usd to btc", "0.00001667 BTC")
        expectCopy("1 usd to btc", "0.00001667 BTC")
        // A symbol the feed omits behaves exactly like an unquoted fiat code
        expectError("1 shib to usd", "No exchange rate for SHIB.")
        // Tickers are recognized rather than swallowed by the unit table
        expectError("1 dash to usd", "No exchange rate for DASH.")
        expectError("1 neo to usd", "No exchange rate for NEO.")
        // A ticker outranks a generated noun, and only that noun: `soles` still reaches PEN
        expectBadges("1 sol to usd", source: "Solana", target: "US Dollar")
        expectError("1 soles to usd", "No exchange rate for PEN.")
        check(
            "crypto is absent from the generated fiat table", expected: "true",
            got: "\(CurrencyData.all.allSatisfy { !CalcCurrency.cryptoCodes.contains($0.code) })")

        // A bare amount answers in the Mac's region currency, which is injected, never read
        expectDisplay("1 usd", "83.50 INR", region: "INR")
        expectExpression("1 usd", "1 USD", region: "INR")
        expectBadges("1 usd", source: "US Dollar", target: "Indian Rupee", region: "INR")
        expectDisplay("10$", "835.00 INR", region: "INR")
        expectDisplay("1 btc", "5,010,000.00 INR", region: "INR")
        expectCopy("1 usd", "83.50 INR", region: "INR")
        // The region names the currency written, so the dollar pairs with the euro instead
        expectDisplay("1 usd", "0.92 EUR", region: "USD")
        expectBadges("1 usd", source: "US Dollar", target: "Euro", region: "USD")
        expectDisplay("1 eur", "1.09 USD", region: "EUR")
        expectBadges("1 eur", source: "Euro", target: "US Dollar", region: "EUR")
        // Nothing to say: the region names one nobody quotes, or none at all
        expectDisplay("1 usd", "1.00 USD", region: "NPR")
        expectDisplay("1 usd", "1.00 USD", region: "ZZZ")
        expectDisplay("1 usd", "1.00 USD")
        // An operator, a target or a half-typed expression all keep the currency written
        expectDisplay("$10 + €5", "14.20 EUR", region: "INR")
        expectDisplay("$10 +", "10.00 USD", region: "INR")
        expectBadges("$10 +", source: "Expression", target: "US Dollar", region: "INR")
        expectDisplay("1 usd to eur", "0.92 EUR", region: "INR")
        expectDisplay("10 pounds", "4.5359237 kg", region: "INR")
        expectNil("usd", region: "INR")
        expectNil("btc", region: "INR")

        // The feed decoding, exercised the way the store hands it over
        expectSnapshot(
            "fiat only", fiat: fiatJSON, crypto: nil,
            expected: "USD=1 EUR=0.9 BTC=nil complete=false")
        expectSnapshot(
            "both feeds", fiat: fiatJSON, crypto: cryptoJSON,
            expected: "USD=1 EUR=0.9 BTC=5e-05 complete=true")
        // A coin payload quoted against another base is ignored rather than folded in wrongly
        expectSnapshot(
            "mismatched base", fiat: fiatJSON,
            crypto: Data(#"{"success":true,"target":"EUR","rates":{"BTC":20000}}"#.utf8),
            expected: "USD=1 EUR=0.9 BTC=nil complete=false")
        expectSnapshotThrows("no quotes", fiat: Data(#"{"success":true,"source":"USD","quotes":{}}"#.utf8))
        // A cached snapshot that prices no coin predates them, whatever its `fetchedAt` claims
        let coinless = CurrencyRates(base: "USD", rates: ["EUR": 0.9], fetchedAt: clock.now)
        check(
            "a coin-less snapshot is rejected on load", expected: "false",
            got: "\(CurrencyFeed.pricesCoins(coinless))")
        check("the fixture prices coins", expected: "true", got: "\(CurrencyFeed.pricesCoins(fx))")
        expectSnapshotThrows(
            "feed reported failure",
            fiat: Data(#"{"success":false,"source":"USD","quotes":{"USDEUR":0.9}}"#.utf8))

        // Slashed rate spellings — the tokenizer keeps a known `unit/unit` whole
        expectDisplay("100 km/h to mph", "62.13711922 mph")
        expectDisplay("60 mph in km/h", "96.56064 km/h")
        expectDisplay("5 m/s to km/h", "18 km/h")
        expectDisplay("100 km/h", "62.13711922 mph")
        expectExpression("100 km/h to mph", "100 km/h")
        expectBadges("5 m/s to km/h", source: "Meters per Second", target: "Kilometers per Hour")
        expectDisplay("100 mbit/s to mbps", "100 Mbps")
        // An unknown pairing leaves the slash as division, so ordinary arithmetic is untouched
        expectDisplay("10/2", "5")
        expectDisplay("6/2(1+2)", "9")
        expectDisplay("10 m / 2", "5 m")
        expectNil("1 km/x")

        // Workdays are 8 hours; weekends and holidays are a calendar's business, not a unit's
        expectDisplay("55h in workdays", "6.875 workdays")
        expectDisplay("3 workdays in hours", "24 hr")
        expectDisplay("2 businessdays to hours", "16 hr")
        expectBadges("55h in workdays", source: "Hours", target: "Workdays")

        // The rest of the trig set, plus the constants that come with it
        expectDisplay("cot(1)", "0.6420926159")
        expectDisplay("sec(1)", "1.850815718")
        expectDisplay("csc(1)", "1.188395106")
        expectDisplay("asin(1)", "1.570796327")
        expectDisplay("acos(1)", "0")
        expectDisplay("arctan(1)", "0.7853981634")
        expectDisplay("sinh(1)", "1.175201194")
        expectDisplay("tanh(0)", "0")
        expectDisplay("cbrt(27)", "3")
        expectDisplay("log2(1024)", "10")
        expectDisplay("exp(0)", "1")
        expectDisplay("sign(-5)", "-1")
        expectDisplay("trunc(3.7)", "3")
        expectDisplay("2 tau", "12.56637061")
        expectDisplay("phi * 2", "3.236067977")
        // `sec` is also seconds, and a unit position still wins
        expectDisplay("10 sec to min", "0.1666666667 min")
        expectDisplay("30 sec + 1 min", "1.5 min")

        // Percentage and ratio phrasings
        expectDisplay("15% tip on 42", "6.3")
        expectDisplay("20% tip of 80", "16")
        expectDisplay("50 is what % of 200", "25%")
        expectDisplay("30 is 20% of what", "150")
        expectDisplay("ratio of 3 to 5", "3 : 5")
        expectDisplay("ratio of 4 to 6", "2 : 3")
        expectDisplay("ratio of 1920 to 1080", "16 : 9")
        expectBadges("15% tip on 42", source: "Expression", target: "Tip")

        // List aggregates and snapping, both of which need the comma token
        expectDisplay("average of 10, 20, 30", "20")
        expectDisplay("avg of 1 and 2 and 3", "2")
        expectDisplay("sum of 10, 20, 30", "60")
        expectDisplay("max of 4, 9, 2", "9")
        expectDisplay("min of 4, 9, 2", "2")
        expectDisplay("sum of 2*3, 4", "10")
        expectDisplay("round 47 to nearest 5", "45")
        expectDisplay("round 12.3 to nearest 0.5", "12.5")
        // A comma between digits is still a grouping separator, and one operand is not a list
        expectDisplay("1,000 + 234", "1,234")
        expectNil("average of 5")
        expectNil("10,5")


        localeTests()
        finish()
    }

    static let french = CalcNumberFormat(decimalSeparator: ",", groupingSeparator: "\u{202F}")!
    static let swiss = CalcNumberFormat(decimalSeparator: ".", groupingSeparator: "\u{2019}")!
    static let ungrouped = CalcNumberFormat(decimalSeparator: ",", groupingSeparator: nil)!

    /// A pair whose base isn't the source and a nonsense rate, both of which must be dropped.
    static let fiatJSON = Data(
        #"{"success":true,"source":"USD","quotes":{"USDEUR":0.9,"EURGBP":0.8,"USDBAD":-1}}"#.utf8)
    /// Quoted the other way round — 1 BTC costs 20,000 USD, so the table stores 0.00005.
    static let cryptoJSON = Data(#"{"success":true,"target":"USD","rates":{"BTC":20000}}"#.utf8)

    static func localeTests() {
        // Resolving a format from the Mac's separators
        check(
            "format [en separators]", expected: "true",
            got: "\(CalcNumberFormat(decimalSeparator: ".", groupingSeparator: ",") == .english)")
        check(
            "format [arabic decimal]", expected: "nil",
            got: "\(CalcNumberFormat(decimalSeparator: "\u{066B}", groupingSeparator: "\u{066C}") as Any)")
        check(
            "format [grouping equal to decimal]", expected: "nil",
            got:
                "\(CalcNumberFormat(decimalSeparator: ",", groupingSeparator: ",")?.groupingSeparator as Any)"
        )
        check(
            "format [ascii space grouping]", expected: "nil",
            got:
                "\(CalcNumberFormat(decimalSeparator: ",", groupingSeparator: " ")?.groupingSeparator as Any)"
        )
        check("format [it argument separator]", expected: ";", got: String(italian.argumentSeparator))
        check("format [ch argument separator]", expected: ",", got: String(swiss.argumentSeparator))

        // The issue's own examples
        expectLocalized("2,3 + 1,5", "3,8", italian)
        expectLocalized("1.234,56 + 0,44", "1.235", italian)
        expectLocalized("10/4", "2,5", italian)
        expectLocalizedCopy("1.234,56 + 0,44", "1235", italian)
        expectLocalizedCopy("10/4", "2,5", italian)

        // Decimal comma, dot grouping
        expectLocalized("2^20", "1.048.576", italian)
        expectLocalized("1.000.000 / 3", "333.333,3333", italian)
        expectLocalized("1/3", "0,3333333333", italian)
        expectLocalized(",5 + 1", "1,5", italian)
        expectLocalized("1,5e3", "1.500", italian)
        expectLocalized("2,5k", "2.500", italian)
        expectLocalized("12.345.678 + 1", "12.345.679", italian)
        expectLocalized("-1.234,5 * 2", "-2.469", italian)
        expectLocalized("2 + 2 =", "4", italian)
        expectLocalizedCopy("2^20", "1048576", italian)
        expectLocalizedCopy("1/3", "0,3333333333", italian)

        // Function arguments take `;`; a comma between digits is always the decimal
        expectLocalized("max(2,5; 3)", "3", italian)
        expectLocalized("max(2,5;3,5)", "3,5", italian)
        expectLocalized("hypot(3;4)", "5", italian)
        expectLocalized("round(3,14159; 2)", "3,14", italian)
        expectLocalized("gcd(12;18;8)", "2", italian)
        expectLocalized("log(8;2)", "3", italian)
        expectLocalized("max(1.000; 999)", "1.000", italian)
        expectLocalized("max(2,3)", "2,3", italian)
        expectLocalized("hypot(3m;400cm)", "5 m", italian)
        expectLocalizedExpression("hypot(3m;400cm)", "hypot(3 m; 400 cm)", italian)
        expectLocalizedExpression("max(2,5;3)", "max(2,5; 3)", italian)
        // A spaced comma can't sit between two digits, so it still separates
        expectLocalized("max(2, 3)", "3", italian)
        expectLocalized("average of 10; 20; 30", "20", italian)
        expectLocalized("average of 10, 20, 30", "20", italian)
        expectLocalized("sum of 1,5; 2,5", "4", italian)

        // A number with no single reading earns no card rather than a guess
        expectLocalizedNil("1,2,3", italian)
        expectLocalizedNil("1.5 + 1", italian)
        expectLocalizedNil("1.23,4 + 1", italian)
        expectLocalizedNil("1,234.5 + 1", italian)
        expectLocalizedNil("12.34 * 2", italian)
        expectLocalizedNil("1.2345 + 1", italian)

        // Partial input keeps the card while the next digits are still coming
        expectLocalized("1 + 2,", "3", italian)
        expectLocalized("2,5 +", "2,5", italian)
        expectLocalizedExpression("2,5 +", "2,5 +", italian)
        expectLocalizedExpression("1.234,5 *", "1234,5 ×", italian)

        // Units, currency and percent render through the same formatter
        expectLocalized("1,5km to m", "1.500 m", italian)
        expectLocalized("10kg + 500g", "10.500 g", italian)
        expectLocalized("2,5 hours to min", "150 min", italian)
        expectLocalized("5feet + 1m", "2,524 m", italian)
        expectLocalizedCopy("1,5km to m", "1500 m", italian)
        expectLocalized("€1.234,50 to usd", "1.341,85 USD", italian)
        expectLocalizedCopy("€1.234,50 to usd", "1341,85 USD", italian)
        expectLocalized("$10 + 5", "15,00 USD", italian)
        expectLocalized("20% off 1.500", "1.200", italian)
        expectLocalized("0x1000", "4.096", italian)
        expectLocalized("255 to hex", "0xFF", italian)
        expectLocalizedCopy("0x1000", "4096", italian)
        expectLocalizedExpression("1,5km to m", "1,5 km", italian)

        // Dates, clocks and zones never reach the number rewrite
        for query in [
            "17.2.26 + 100 weekdays", "25.8.27", "25. aug", "25. aug + 3",
            "time in Tokyo", "1970-01-01T00:00:00.125Z to unix ms", "1.2.3 + 1", "7:30 - 13:30"
        ] {
            expectSameAsEnglish(query, italian)
        }
        expectLocalized("1970-01-01T00:00:00Z + 1h to unix", "3.600", italian)
        expectLocalized("hrs till 9am", "8,7 hours", italian)

        // Space grouping: the Mac's narrow no-break space, never a typed space
        expectLocalized("1\u{202F}234,5 + 0,5", "1\u{202F}235", french)
        expectLocalized("2^20", "1\u{202F}048\u{202F}576", french)
        expectLocalized("max(1,5; 2)", "2", french)
        expectLocalized("1.5 + 1", "2,5", french)

        // Decimal dot with apostrophe grouping keeps the comma for arguments
        expectLocalized("1\u{2019}234.5 + 0.5", "1\u{2019}235", swiss)
        expectLocalized("max(1,2)", "2", swiss)
        expectLocalized("1,000 + 234", "1\u{2019}234", swiss)
        expectLocalized("10/4", "2.5", swiss)
        expectSameAsEnglish("19.2.27", swiss)
        expectSameAsEnglish("1.2.3 + 1", swiss)

        // A format without grouping neither reads nor writes one
        expectLocalized("1234,5 * 2", "2469", ungrouped)
        expectLocalized("2^20", "1048576", ungrouped)
        expectLocalized("1.234 + 1", "2,234", ungrouped)

        // English stays byte-for-byte what it was
        expectLocalized("1,000 + 234", "1,234", .english)
        expectLocalized("max(2,3)", "3", .english)
        expectLocalizedNil("max(2;3)", .english)

        // Canonical history text, localized for display
        check("history [grouped]", expected: "1.234,5 kg", got: italian.localized("1,234.5 kg"))
        check("history [dotted date]", expected: "19.2.27", got: italian.localized("19.2.27"))
        check("history [clock]", expected: "00:18:00.123", got: italian.localized("00:18:00.123"))
        check(
            "history [date prose]", expected: "Friday, 24 July 2026",
            got: italian.localized("Friday, 24 July 2026"))
        check(
            "history [arguments]", expected: "max(1,5; 2)",
            got: italian.localizedExpression("max(1.5, 2)"))
        // Inside a call a canonical comma is an argument, even where it looks like grouping
        check(
            "history [unspaced arguments]", expected: "max(2;3)", got: italian.localizedExpression("max(2,3)")
        )
        check(
            "history [grouping-shaped argument]", expected: "max(1;234) + 1.234",
            got: italian.localizedExpression("max(1,234) + 1,234"))
        check(
            "history [decimal argument]", expected: "round(3,14159;2)",
            got: italian.localizedExpression("round(3.14159,2)"))
        check(
            "history [nested call]", expected: "2max(1; min(2;3))",
            got: italian.localizedExpression("2max(1, min(2,3))"))
        check("history [ch arguments]", expected: "max(1,234)", got: swiss.localizedExpression("max(1,234)"))
        expectLocalizedExpression("max(1,234)", "max(1,234)", swiss)
        expectLocalized("max(1;234)", "234", italian)
        check("history [exponent]", expected: "1,524157875e+16", got: italian.localized("1.524157875e+16"))
        check("history [english]", expected: "1,234.5", got: CalcNumberFormat.english.localized("1,234.5"))
        check("history [search]", expected: "3.8", got: italian.canonical("3,8") ?? "nil")
    }

    static func expectLocalizedCopy(_ query: String, _ expected: String, _ format: CalcNumberFormat) {
        guard case .value(_, let copy)? = evaluateLocalized(query, format)?.payload else {
            fail(formatLabel(query, format), expected: expected, got: "nil / error")
            return
        }
        check(formatLabel(query, format) + " [copy]", expected: expected, got: copy)
    }

    static func expectLocalizedExpression(
        _ query: String, _ expected: String, _ format: CalcNumberFormat
    ) {
        guard let result = evaluateLocalized(query, format) else {
            fail(formatLabel(query, format), expected: expected, got: "nil")
            return
        }
        check(formatLabel(query, format) + " [expression]", expected: expected, got: result.expression)
    }

    static func expectLocalizedNil(_ query: String, _ format: CalcNumberFormat) {
        if let result = evaluateLocalized(query, format) {
            fail(formatLabel(query, format), expected: "nil", got: "\(result.payload)")
        } else {
            passes += 1
        }
    }

    /// Text with no decimal in it must come out exactly as English renders it.
    static func expectSameAsEnglish(_ query: String, _ format: CalcNumberFormat) {
        let english = CalcEngine.evaluate(query, now: clock.now, calendar: clock.calendar, rates: fx)
        check(
            formatLabel(query, format) + " [same as English]", expected: "\(english as Any)",
            got: "\(evaluateLocalized(query, format) as Any)")
    }

    /// `CurrencyFeed` is handed the two payloads exactly as the store receives them.
    static func expectSnapshot(_ name: String, fiat: Data, crypto: Data?, expected: String) {
        guard let result = try? CurrencyFeed.snapshot(fiat: fiat, crypto: crypto, now: clock.now)
        else {
            fail(name, expected: expected, got: "threw")
            return
        }
        let show = { (code: String) in result.rates.rates[code].map(CalcFormatter.copyText) ?? "nil" }
        check(
            name, expected: expected,
            got: "USD=\(show("USD")) EUR=\(show("EUR")) BTC=\(show("BTC")) "
                + "complete=\(result.complete)")
    }

    static func expectSnapshotThrows(_ name: String, fiat: Data) {
        if let result = try? CurrencyFeed.snapshot(fiat: fiat, crypto: nil, now: clock.now) {
            fail(name, expected: "throws", got: "\(result.rates.rates.count) rates")
        } else {
            passes += 1
        }
    }
}
