// The calculator's dates, durations, timestamps and time zones, against a fixed clock.
import Foundation

@main
@MainActor
struct CalcDateTests {
    static func main() {
        // Date/time — evaluated against a fixed clock: Fri 2026-07-24 00:18 UTC
        expectDisplayAt("hrs till 9am", "8.7 hours")
        expectBadgesAt("hrs till 9am", source: "12:18 AM", target: "9:00 AM")
        expectDisplayAt("hrs till july", "8,207.7 hours")
        expectBadgesAt("hrs till july", source: "12:18 AM", target: "12:00 AM")
        expectDisplayAt("days till 9april", "259 days")
        expectBadgesAt("days till 9april", source: "Friday, 24 July", target: "Friday, 9 April, 2027")
        expectDisplayAt("days till july", "342 days")
        expectBadgesAt("days till july", source: "Friday, 24 July", target: "Thursday, 1 July, 2027")
        expectDisplayAt("days until tomorrow", "1 day")
        expectDisplayAt("weeks till 9april", "37 weeks")  // 259 / 7
        expectDisplayAt("today + 3 weeks", "14 August")
        expectDisplayAt("now + 90 min", "24 July at 1:48 AM")
        expectDisplayAt("jul 4 - today", "345 days")
        expectBadgesAt("jul 4 - today", source: "Sunday, 4 July, 2027", target: "Friday, 24 July")
        // Arithmetic with spaced operators must still be plain math, not date math
        expectDisplayAt("10 - 3", "7")
        expectDisplayAt("450 + 20%", "540")
        // Letter-free `m/d - m/d` is fraction math, not a date difference.
        expectDisplayAt("5/2 - 1/2", "2")
        expectDisplayAt("3/4 - 1/4", "0.5")
        expectDisplayAt("1/2 - 1/4", "0.25")
        // A slash date still reads as a date when the other side names a keyword
        expectDisplayAt("9/4 - today", "42 days")
        expectDisplayAt("today - 9/4", "-42 days")
        // Bare date/unit words alone are app searches, not cards
        expectNilAt("today")
        expectNilAt("july")
        expectNilAt("tomorrow")

        // days since — past elapsed, against the fixed clock (Fri 2026-07-24)
        expectDisplayAt("days since 9jul", "15 days")
        expectBadgesAt("days since 9jul", source: "Thursday, 9 July", target: "Friday, 24 July")
        expectDisplayAt("weeks since 3jul", "3 weeks")
        expectDisplayAt("days since yesterday", "1 day")
        // The answer's weekday is the badge, so the date itself does not repeat it.
        expectBadgesAt("today + 3 weeks", source: "Friday, 24 July", target: "Friday")

        // Timespans break a duration into the units that fit it
        expectDisplay("145 mins to timespan", "2 hr 25 min")
        expectDisplay("8700 s to timespan", "2 hr 25 min")
        expectDisplay("90000 s to timespan", "1 day 1 hr")
        expectDisplay("55 h to timespan", "2 day 7 hr")
        expectDisplay("1000000 s to timespan", "1 wk 4 day 13 hr 46 min 40 s")
        expectBadges("145 mins to timespan", source: "Minutes", target: "Timespan")
        expectNil("10 km to timespan")

        expectDisplayAt("1970-01-01T00:00:00Z to unix", "0")
        expectDisplayAt("1970-01-01T01:00:00+01:00 to unix", "0")
        expectDisplayAt("1970-01-01T00:00:00.125Z to unix ms", "125")
        expectDisplayAt("1970-01-01T00:00:00.002Z to unix ms", "2")
        expectDisplayAt("1969-12-31T23:59:59.999Z to unix ms", "-1")
        expectDisplayAt("unix 1234567890.125 to unix ms", "1,234,567,890,125")
        expectDisplayAt("1970-01-01T00:00:00Z + 1h to unix", "3,600")
        expectDisplayAt("unix 0 to date", "1 January, 1970 at 12:00 AM")
        expectDisplayAt("1970-01-01T00:00:00Z to date", "1 January, 1970 at 12:00 AM")
        expectDisplayAt("1000 unix ms", "1 January, 1970 at 12:00:01 AM")
        expectDisplayAt("unix -1", "31 December, 1969 at 11:59:59 PM")
        expectDisplayAt("2026-07-24T07:30:00+02:00 + 30min", "24 July at 6:00 AM")
        expectNilAt("2026-02-30T00:00:00Z")
        expectNilAt("2026-07-24T00:00:00Z junk")
        expectNilAt("unix 1e30")

        // Time zones. The clock is UTC-pinned, so every one of these is exact.
        expectDisplayAt("time in tokyo", "9:18 AM")
        expectDisplayAt("time in sf", "5:18 PM (yesterday)")
        expectDisplayAt("what time is it in london", "1:18 AM")
        expectDisplayAt("time in kolkata", "5:48 AM")
        expectDisplayAt("time in utc", "12:18 AM")
        expectBadgesAt("time in tokyo", source: "UTC", target: "Tokyo")
        expectBadgesAt("time in sf", source: "UTC", target: "Los Angeles")
        // A named source zone overrides the Mac's own, so neither side has to be local
        expectDisplayAt("5pm london in sf", "9:00 AM")
        expectDisplayAt("9:30am in nyc", "5:30 AM")
        expectDisplayAt("5pm in tokyo", "2:00 AM (tomorrow)")
        expectBadgesAt("5pm london in sf", source: "London", target: "Los Angeles")
        // The locale's hour cycle, which the 24-hour switch overrides, picks the clock
        var hour24 = clock.calendar
        hour24.locale = Locale(identifier: "en_US@hours=h23")
        var britain = clock.calendar
        britain.locale = Locale(identifier: "en_GB")
        var britain12 = clock.calendar
        britain12.locale = Locale(identifier: "en_GB@hours=h12")
        expectDisplayAt("time in tokyo", "09:18", calendar: hour24)
        expectDisplayAt("5pm in tokyo", "02:00 (tomorrow)", calendar: hour24)
        expectDisplayAt("unix -1", "31 December, 1969 at 23:59:59", calendar: hour24)
        expectDisplayAt("now + 90 min", "24 July at 01:48", calendar: hour24)
        expectDisplayAt("time in sf", "17:18 (yesterday)", calendar: britain)
        expectBadgesAt("hrs till 9am", source: "00:18", target: "09:00", calendar: britain)
        expectDisplayAt("time in sf", "5:18 pm (yesterday)", calendar: britain12)

        let zoneNow = clock.calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 12))!
        for home in ["UTC", "Asia/Shanghai", "America/Los_Angeles"] {
            var calendar = clock.calendar
            calendar.timeZone = TimeZone(identifier: home)!
            for query in [
                "5:30pm SF to London", "5:30 pm SF to London", "5:30 pm in SF to London",
                "5:30 PM in San Francisco to London", "5:30\u{a0}pm SF to London",
                "5:30 pm SF in London", "5:30 pm SF at London", "5:30 pm at SF to London",
                "17:30 SF to London"
            ] {
                expectDisplayAt(query, "1:30 AM (tomorrow)", now: zoneNow, calendar: calendar)
                expectBadgesAt(
                    query, source: "Los Angeles", target: "London", now: zoneNow, calendar: calendar)
            }
            for query in ["5pm SF to London", "5pm in SF to London", "5 pm in SF to London"] {
                expectDisplayAt(query, "1:00 AM (tomorrow)", now: zoneNow, calendar: calendar)
            }
            for query in [
                "5pm PSTT to London", "5:30 pm PSTT to London", "5pm in PSTT to London",
                "5pm SF junk to London", "5pm in to London", "5pm at to London",
                "5pm pm SF to London", "5pm am SF to London",
                "time in sf in 4 hours", "now in tokyo in 2h",
                "time at sf in 4 hours", "now at tokyo in 2h"
            ] {
                expectNilAt(query, now: zoneNow, calendar: calendar)
            }
        }
        expectDisplayAt("5:30 pm to London", "6:30 PM")
        expectDisplayAt("5 pm in Tokyo", "2:00 AM (tomorrow)")
        expectDisplayAt("5:30 am SF to London", "1:30 PM")
        expectDisplayAt("12 am SF to London", "8:00 AM")
        expectDisplayAt("12 pm SF to London", "8:00 PM")
        expectDisplayAt("5:30 pm in SF to London + 30 min", "2:00 AM (tomorrow)")
        expectCopy("5:30 pm SF to London", "1:30 AM")
        expectNilAt("13 pm SF to London")
        expectNilAt("5:60 pm SF to London")

        let localConversionNow = clock.calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 15, hour: 12))!
        for (home, target, time, dayNote) in [
            ("Asia/Shanghai", "Shanghai", "8:30 AM", " (tomorrow)"),
            ("UTC", "UTC", "12:30 AM", " (tomorrow)"),
            ("America/Los_Angeles", "Los Angeles", "5:30 PM", "")
        ] {
            var calendar = clock.calendar
            calendar.timeZone = TimeZone(identifier: home)!
            let expected = CalcResult(
                expression: "5:30 PM", sourceBadge: "Los Angeles", targetBadge: target,
                payload: .value(display: time + dayNote, copyText: time))
            for query in [
                "5:30pm SF", "5:30 pm SF", "17:30 San Francisco", "5:30 PM SFO",
                "  5:30\tpm\u{00A0}sf  "
            ] {
                let result = CalcEngine.evaluate(query, now: localConversionNow, calendar: calendar)
                check("\(query) [home \(home)]", expected: "true", got: "\(result == expected)")
            }
        }
        for components in [
            DateComponents(year: 2026, month: 9, day: 15, hour: 12),
            DateComponents(year: 2026, month: 1, day: 1, hour: 0),
            DateComponents(year: 2026, month: 11, day: 1, hour: 12)
        ] {
            let now = clock.calendar.date(from: components)!
            for (home, destination) in [
                ("UTC", "UTC"), ("Asia/Shanghai", "Shanghai"),
                ("Pacific/Kiritimati", "Kiritimati"), ("Pacific/Pago_Pago", "Pago Pago")
            ] {
                var calendar = clock.calendar
                calendar.timeZone = TimeZone(identifier: home)!
                for (query, explicit) in [
                    ("5 pm SF", "5pm SF"), ("12 am Canada", "12am Canada"),
                    ("12 pm CDG", "12pm CDG"), ("09:15 Kathmandu", "09:15 Kathmandu"),
                    ("23:30 Pago Pago", "23:30 Pago Pago"), ("00:30 Kiritimati", "00:30 Kiritimati"),
                    ("1:30 am SF", "1:30am SF"), ("17:30 São Paulo", "17:30 São Paulo")
                ] {
                    let expected = CalcEngine.evaluate(
                        "\(explicit) to \(destination)", now: now, calendar: calendar)
                    let result = CalcEngine.evaluate(query, now: now, calendar: calendar)
                    check(
                        "\(query) [home \(home), now \(now)]", expected: "true",
                        got: "\(expected != nil && result == expected)")
                }
            }
        }
        expectDisplayAt("5:30 pm SF + 30 min", "1:00 AM (tomorrow)", now: localConversionNow)
        expectDisplayAt("5:30pm SF - 2h", "10:30 PM", now: localConversionNow)
        expectDisplayAt("5:30pm in SF", "10:30 AM", now: localConversionNow)
        expectDisplayAt("5:30pm SF to London", "1:30 AM (tomorrow)", now: localConversionNow)
        expectNilAt(
            "2:30 am SF",
            now: clock.calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!)
        for query in [
            "5:30 pm PSTT", "5:30pm PSTT", "5:30pm SF junk", "5:30 pm SF London",
            "5pm", "5 pm", "17:30", "17:30 pm", "5 SF", "pm SF", "now SF",
            "13pm SF", "5:60pm SF", "5pm pm SF", "5:30 am pm SF", "25:30 SF",
            "5:30pm SF to", "5:30pm SF to PSTT", "5:30pm SF + 2 kg",
            "time in sf in 4 hours", "now in tokyo in 2h", "Screen Time", "Safari SF"
        ] {
            expectNilAt(query)
        }
        // Aliases cover what the identifiers don't spell, and DST is Foundation's own answer
        expectDisplayAt("time in nyc", "8:18 PM (yesterday)")
        expectDisplayAt("time in cet", "2:18 AM")
        // A zone name never outranks a unit or a currency, and a non-zone stays a search
        expectDisplay("1 cup to ml", "236.5882365 mL")
        expectNil("time in xyzzy")
        expectNil("in tokyo")
        expectNil("time")

        // IATA airport codes, which Foundation has no notion of
        expectDisplayAt("time in vie", "2:18 AM")
        expectDisplayAt("time in lhr", "1:18 AM")
        expectDisplayAt("time in nrt", "9:18 AM")
        expectDisplayAt("time in sfo", "5:18 PM (yesterday)")
        expectBadgesAt("time in vie", source: "UTC", target: "Vienna")
        expectDisplayAt("5pm vie in nrt", "12:00 AM (tomorrow)")
        // `mad` stays the Moroccan dirham, and `ist` stays India Standard Time
        expectError("10 mad to usd", "No exchange rate for MAD.")
        expectBadgesAt("time in ist", source: "UTC", target: "Kolkata")

        // A trailing offset shifts a zone answer, so the whole thing stays one query
        expectDisplayAt("5pm london in sf", "9:00 AM")
        expectDisplayAt("5pm london in sf + 2h", "11:00 AM")
        expectDisplayAt("5pm london in sf - 1 hour", "8:00 AM")
        expectDisplayAt("5pm london in sf + 30 min", "9:30 AM")
        expectBadgesAt("5pm london in sf + 2h", source: "London", target: "Los Angeles")
        // A unit conversion is not a zone offset, and neither is a bare sum
        expectDisplay("1 cup to ml", "236.5882365 mL")
        expectNil("5pm london in sf + 2 kg")

        for components in [
            DateComponents(year: 2026, month: 9, day: 15, hour: 12),
            DateComponents(year: 2026, month: 9, day: 30, hour: 12),
            DateComponents(year: 2026, month: 12, day: 31, hour: 12),
            DateComponents(year: 2026, month: 3, day: 8, hour: 12),
            DateComponents(year: 2026, month: 11, day: 1, hour: 12)
        ] {
            let now = clock.calendar.date(from: components)!
            for home in ["UTC", "Asia/Shanghai", "America/Los_Angeles"] {
                var calendar = clock.calendar
                calendar.timeZone = TimeZone(identifier: home)!
                for (query, expected) in [
                    ("23:30 Pago Pago to Kiritimati", "12:30 AM (in 2 days)"),
                    ("00:30 Kiritimati to Pago Pago", "11:30 PM (2 days ago)"),
                    ("22:59 Pago Pago to Kiritimati", "11:59 PM (tomorrow)"),
                    ("01:00 Kiritimati to Pago Pago", "12:00 AM (yesterday)"),
                    ("12:00 Pago Pago to Pago Pago", "12:00 PM")
                ] {
                    expectDisplayAt(query, expected, now: now, calendar: calendar)
                }
            }
        }
        expectBadgesAt("23:30 Pago Pago to Kiritimati", source: "Pago Pago", target: "Kiritimati")
        expectBadgesAt("00:30 Kiritimati to Pago Pago", source: "Kiritimati", target: "Pago Pago")
        expectCopy("23:30 Pago Pago to Kiritimati", "12:30 AM")
        expectCopy("00:30 Kiritimati to Pago Pago", "11:30 PM")
        expectDisplayAt("23:30 Pago Pago to Kiritimati + 30 min", "1:00 AM (tomorrow)")
        expectDisplayAt("00:30 Kiritimati to Pago Pago + 30 min", "12:00 AM (yesterday)")

        // `<weekday> in <n> weeks` answers that weekday inside the week it lands in
        expectDisplayAt("monday in 3 weeks", "10 August")
        expectDisplayAt("monday in 1 week", "27 July")
        expectDisplayAt("tuesday in 2 weeks", "4 August")
        expectDisplayAt("friday in 2 weeks", "7 August")
        expectBadgesAt("monday in 3 weeks", source: "Friday, 24 July", target: "Monday")
        // A month is not a weekday, and `in` still reaches the unit path
        expectNil("monday in 3 kg")
        expectDisplay("10 in in cm", "25.4 cm")

        // A zone's offset from the Mac's own
        expectDisplayAt("diff paris", "2:18 AM (+2h)")
        expectDisplayAt("time diff tokyo", "9:18 AM (+9h)")
        expectDisplayAt("diff kolkata", "5:48 AM (+5h 30m)")
        expectBadgesAt("diff paris", source: "UTC", target: "Paris")
        expectNil("diff xyzzy")

        // A duration where a zone would go, and both at once
        expectDisplayAt("time in 4 hours", "4:18 AM")
        expectDisplayAt("time in 90 min", "1:48 AM")
        expectDisplayAt("time in 4 hours in san francisco", "9:18 PM (yesterday)")
        expectDisplayAt("time in 4 hours in sf", "9:18 PM (yesterday)")
        expectBadgesAt("time in 4 hours in sf", source: "UTC", target: "Los Angeles")

        // A bare offset on a clock answer is hours, the unit the answer already implies
        expectDisplayAt("time in tokyo + 2", "11:18 AM")
        expectDisplayAt("time in tokyo - 2", "7:18 AM (tomorrow)")
        expectDisplayAt("5pm london in sf + 3", "12:00 PM")
        // Only the offset implies it: a bare number is still no zone, and plain math is untouched
        expectNilAt("time in 4")
        expectDisplay("5 + 3", "8")

        // Dotted dates are day-first, the convention that writes them
        expectDisplayAt("19.2.27 + 3", "22 February, 2027")
        expectDisplayAt("19.02.2027 + 3", "22 February, 2027")
        expectDisplayAt("19.2.27 - 3", "16 February, 2027")
        expectDisplayAt("31.12.26 + 1", "1 January, 2027")
        expectDisplayAt("19.2.27 + 3 weeks", "12 March, 2027")
        expectBadgesAt("19.2.27 + 3", source: "Friday, 19 February, 2027", target: "Monday")
        // A decimal is not a date, and a version number is not one either
        expectDisplay("1.5 + 3", "4.5")
        expectDisplay("99.99 + 0.01", "100")
        expectNilAt("1.2.3 + 1")
        expectNilAt("1.5.5 + 3")
        // An impossible day still earns no card
        expectNilAt("30.2.27 + 1")

        // Malformed input a fuzzer found: both of these read past the end of the token array
        expectNil("round is next round to")
        expectNilAt(": from to at sf")
        expectNil("round to")
        expectNil("round 5 to")
        expectNilAt(": at sf")
        expectNil("is what % of")
        expectNil("tip on")

        // The gate scans for whitespace, not a literal space, so a pasted NBSP still lands.
        expectDisplayAt("time\u{a0}in\u{a0}tokyo", "9:18 AM")
        expectDisplayAt("time\u{9}in\u{9}tokyo", "9:18 AM")
        expectDisplayAt("time\u{2009}in\u{2009}tokyo", "9:18 AM")

        // The ordinal dot German and Austrian dates write after the day
        expectDisplayAt("28. aug + 3", "31 August")
        expectDisplayAt("28. august + 3", "31 August")
        expectDisplayAt("28.aug + 3", "31 August")
        // Nearest, not next: from July, January is six months back rather than six ahead
        expectDisplayAt("1. jan + 1", "2 January")
        expectDisplayAt("28. aug 2027 + 3", "31 August, 2027")
        expectBadgesAt("28. aug + 3", source: "Friday, 28 August", target: "Monday")
        // Only a trailing dot is an ordinal, so a decimal day is still not a date
        expectNilAt("28.5 aug + 1")

        // A written day is its own reason for a card: the weekday is why you typed it
        expectDisplayAt("25. aug", "25 August")
        expectDisplayAt("25 aug", "25 August")
        expectDisplayAt("aug 25", "25 August")
        expectDisplayAt("25.8.27", "25 August, 2027")
        expectDisplayAt("1. jan", "1 January")
        expectBadgesAt("25. aug", source: "Friday, 24 July", target: "Tuesday")
        // A bare date takes the year it is nearest, so it agrees with the same date plus a shift
        expectDisplayAt("25. aug + 3", "28 August")
        // A month or a relative word alone is still an app search
        expectNilAt("july")
        expectNilAt("aug")
        expectNilAt("today")
        expectNilAt("tomorrow")

        // Date arithmetic chains left to right, however many terms it carries
        expectDisplayAt("17.2.26 + 100 week days - 4 + 2", "5 July")
        expectDisplayAt("17.2.26 + 100 weekdays", "7 July")
        expectDisplayAt("17.2.26 + 100 weekdays - 4", "3 July")
        expectDisplayAt("today + 3 weeks - 2 days", "12 August")
        expectDisplayAt("today + 5 + 2", "31 July")
        expectDisplayAt("today + 1 day + 1 day + 1 day", "27 July")
        expectDisplayAt("now + 90 min + 30 min", "24 July at 2:18 AM")
        expectDisplayAt("3:45pm + 5 - 2", "24 July at 6:45 PM")
        expectBadgesAt("17.2.26 + 100 week days - 4 + 2", source: "Tuesday, 17 February", target: "Sunday")
        // Every term must be a duration, so a unit or a stray word still earns no card
        expectNilAt("today + 3 weeks - kg")
        expectNilAt("today + 5 - abc")
        // Two moments are still a difference, and letter-free operands are still arithmetic
        expectDisplayAt("jul 4 - today", "345 days")
        expectDisplay("5 + 3 - 2", "6")
        expectDisplay("5/2 - 1/2", "2")

        // Accented spellings resolve, since the identifiers carry none
        expectDisplayAt("time in são paulo", "9:18 PM (yesterday)")
        expectDisplayAt("time in sao paulo", "9:18 PM (yesterday)")
        expectDisplayAt("time in zürich", "2:18 AM")

        // Cities IANA never names, because their clocks never differed from the zone's own
        expectBadgesAt("time in graz", source: "UTC", target: "Vienna")
        expectBadgesAt("time in salzburg", source: "UTC", target: "Vienna")
        expectBadgesAt("time in klagenfurt", source: "UTC", target: "Vienna")
        expectBadgesAt("time in hannover", source: "UTC", target: "Berlin")
        expectBadgesAt("time in stuttgart", source: "UTC", target: "Berlin")
        expectBadgesAt("time in basel", source: "UTC", target: "Zurich")
        expectBadgesAt("time in manchester", source: "UTC", target: "London")
        expectBadgesAt("time in florence", source: "UTC", target: "Rome")
        expectBadgesAt("time in lyon", source: "UTC", target: "Paris")
        expectBadgesAt("time in krakow", source: "UTC", target: "Warsaw")
        // Their accented spellings fold onto the same entry
        expectBadgesAt("time in düsseldorf", source: "UTC", target: "Berlin")
        expectBadgesAt("time in kraków", source: "UTC", target: "Warsaw")
        expectBadgesAt("time in malmö", source: "UTC", target: "Stockholm")
        expectBadgesAt("5pm graz in basel", source: "Vienna", target: "Zurich")

        // Countries answer with their main clock, badged with the city that clock belongs to
        expectDisplayAt("time in uk", "1:18 AM")
        expectDisplayAt("Time in UK", "1:18 AM")
        expectBadgesAt("time in united kingdom", source: "UTC", target: "London")
        expectBadgesAt("time in japan", source: "UTC", target: "Tokyo")
        expectBadgesAt("what time is it in germany", source: "UTC", target: "Berlin")
        expectBadgesAt("time in côte d’ivoire", source: "UTC", target: "Abidjan")
        expectBadgesAt("time in trinidad and tobago", source: "UTC", target: "Port of Spain")
        expectDisplayAt("5pm uk in japan", "1:00 AM (tomorrow)")
        expectDisplayAt("time in uk + 2", "3:18 AM")
        // A country spanning several clocks answers with its capital's, never a remote edge
        expectBadgesAt("time in usa", source: "UTC", target: "New York")
        expectBadgesAt("time in us", source: "UTC", target: "New York")
        expectBadgesAt("time in australia", source: "UTC", target: "Sydney")
        expectBadgesAt("time in canada", source: "UTC", target: "Toronto")
        expectBadgesAt("time in russia", source: "UTC", target: "Moscow")
        expectBadgesAt("time in uae", source: "UTC", target: "Dubai")
        // A unit spelled like a country code stays a unit
        expectDisplay("10 ms to us", "10,000 µs")
        expectNilAt("time in antarctica")
        check(
            "country zones resolve", expected: "true",
            got: "\(CountryZoneData.zones.values.allSatisfy { TimeZone(identifier: $0) != nil })")

        expectDisplayAt("SF time", "5:18 PM (yesterday)")
        expectDisplayAt("time SF", "5:18 PM (yesterday)")
        expectDisplayAt("current time to Tokyo", "9:18 AM")
        expectDisplayAt("what time is it to Tokyo", "9:18 AM")
        let usaExpected = CalcResult(
            expression: "12:00 PM", sourceBadge: "UTC", targetBadge: "New York",
            payload: .value(display: "8:00 AM", copyText: "8:00 AM"))
        let usaNow = CalcEngine.evaluate("now in usa", now: zoneNow, calendar: clock.calendar)
        check("now in usa", expected: "true", got: "\(usaNow == usaExpected)")
        for query in ["Canada timezone", "Canada time zone", "timezone Canada", "timezone in Canada"] {
            let expected = CalcResult(
                expression: "12:00 PM", sourceBadge: "UTC", targetBadge: "Toronto",
                payload: .value(display: "8:00 AM", copyText: "8:00 AM"))
            let actual = CalcEngine.evaluate(query, now: zoneNow, calendar: clock.calendar)
            check(query, expected: "true", got: "\(actual == expected)")
        }
        for query in ["Canada time to China", "Canada timezone to China", "Canada time zone to China"] {
            let expected = CalcResult(
                expression: "8:00 AM", sourceBadge: "Toronto", targetBadge: "Shanghai",
                payload: .value(display: "8:00 PM", copyText: "8:00 PM"))
            let actual = CalcEngine.evaluate(query, now: zoneNow, calendar: clock.calendar)
            check(query, expected: "true", got: "\(actual == expected)")
        }
        expectDisplayAt("Tokyo time", "9:18 AM")
        expectDisplayAt("  sF\tTiMe  ", "5:18 PM (yesterday)")
        expectDisplayAt("San\u{a0}Francisco\u{2009}time", "5:18 PM (yesterday)")
        expectDisplayAt("Tokyo\ntime", "9:18 AM")
        expectDisplayAt("  TiMe\tSF  ", "5:18 PM (yesterday)")
        expectDisplayAt("SF\u{a0}TiMe\u{2009}ZoNe", "5:18 PM (yesterday)")
        expectDisplayAt("TimeZone\nIn\tTokyo", "9:18 AM")
        expectDisplayAt("Canada\tTiMe\u{a0}ZoNe\tTo\nChina", "8:00 PM", now: zoneNow)
        for components in [
            DateComponents(year: 2026, month: 1, day: 15, hour: 12),
            DateComponents(year: 2026, month: 9, day: 15, hour: 12),
            DateComponents(year: 2026, month: 9, day: 15, hour: 23, minute: 30)
        ] {
            let now = clock.calendar.date(from: components)!
            for home in ["UTC", "Asia/Shanghai", "America/Los_Angeles"] {
                var calendar = clock.calendar
                calendar.timeZone = TimeZone(identifier: home)!
                for place in [
                    "SF", "Tokyo", "London", "Shanghai", "San Francisco", "New York", "Canada",
                    "USA", "United States", "United Kingdom", "India", "South Korea", "PST", "UTC", "GMT",
                    "SFO", "CDG", "LDN", "SÃO PAULO", "Zürich", "Côte d’Ivoire", "Trinidad and Tobago",
                    "Georgia", "Basel", "The Hague", "Swift Current"
                ] {
                    let expected = CalcEngine.evaluate("time in \(place)", now: now, calendar: calendar)
                    for query in [
                        "\(place) TiMe", "time \(place)", "\(place) timezone", "\(place) time zone",
                        "timezone \(place)", "timezone in \(place)", "now in \(place)"
                    ] {
                        let actual = CalcEngine.evaluate(query, now: now, calendar: calendar)
                        check(
                            "\(query) [\(home), \(now)]", expected: "true",
                            got: "\(expected != nil && actual == expected)")
                    }
                }
                for (source, target) in [
                    ("Canada", "China"), ("SFO", "CDG"), ("Tokyo", "SF"), ("SF", "Tokyo"),
                    ("New York", "São Paulo"), ("Kolkata", "Kathmandu"), ("Kiritimati", "Pago Pago")
                ] {
                    let expected = CalcEngine.evaluate(
                        "time \(source) to \(target)", now: now, calendar: calendar)
                    for phrase in ["time", "timezone", "time zone"] {
                        let query = "\(source) \(phrase) to \(target)"
                        let actual = CalcEngine.evaluate(query, now: now, calendar: calendar)
                        check(
                            "\(query) [\(home), \(now)]", expected: "true",
                            got: "\(expected != nil && actual == expected)")
                    }
                }
            }
        }
        for query in [
            "Screen Time", "QuickTime Player", "Time Machine", "FaceTime", "PSTT time", "xyzzy time",
            "SF junk time", "4 hours time", "90 min time", "5pm time", "5pm SF time",
            "SF current time", "SF time now", "SF time + 2h", "time in SF time", "time time"
        ] {
            expectNilAt(query)
        }
        for place in ["PSTT", "xyzzy", "SF junk", "4 hours", "5pm SF", "time"] {
            for query in [
                "time \(place)", "\(place) timezone", "\(place) time zone",
                "timezone \(place)", "timezone in \(place)", "\(place) time to China",
                "\(place) timezone to China", "Canada time zone to \(place)"
            ] {
                expectNilAt(query)
            }
        }
        for query in [
            "timezone", "time zone", "timezone in", "timezone in in SF", "timezone to China",
            "timezone settings", "SF timezone app", "Canada time to",
            "Canada time to China to Tokyo", "time in SF in 4 hours", "now in usa in 2h",
            "Canada timezone to 2h", "timezone in 4 hours", "Canada time to China + 2h"
        ] {
            expectNilAt(query)
        }

        // A bare number takes the unit its moment implies
        expectDisplayAt("3:45pm + 5", "24 July at 8:45 PM")
        expectDisplayAt("3:45pm - 2", "24 July at 1:45 PM")
        expectDisplayAt("august 5 + 5", "10 August")
        expectDisplayAt("august 5 - 5", "31 July")

        // A named moment earns a card once it carries a time or a qualifier
        expectDisplayAt("tomorrow at 9am", "25 July at 9:00 AM")
        expectDisplayAt("next monday", "27 July")
        expectDisplayAt("last friday", "17 July")
        expectBadgesAt("tomorrow at 9am", source: "Friday, 24 July", target: "Saturday")
        expectDisplayAt("next monday at 7:30 + 5", "27 July at 12:30 PM")
        expectDisplayAt("next monday at 7:30 + 1 day 2h 15min - 1", "28 July at 8:45 AM")
        expectDisplayAt("tomorrow at 23:30 + 1.5 hours", "26 July at 1:00 AM")
        expectDisplayAt("3 days from next monday at 7:30", "30 July at 7:30 AM")
        expectDisplayAt("1h 30min ago", "23 July at 10:48 PM")
        expectDisplayAt("31.1.26 at 7:30 + 1 month", "28 February at 7:30 AM")
        expectDisplayAt("29.2.24 + 1 year", "28 February, 2025")
        expectDisplayAt("today + 1 year 2 months - 1 day", "23 September, 2027")
        expectDisplayAt("1. jan + 1 + 1", "3 January")
        expectDisplayAt("hours till tomorrow at 7:30", "31.2 hours")
        expectDisplayAt("hours since yesterday at noon", "12.3 hours")
        expectDisplayAt("hours till friday at midnight", "167.7 hours")
        expectDisplayAt("hours since friday at midnight", "0.3 hours")
        expectDisplayAt("hours till jul 24 at midnight", "8,759.7 hours")
        expectDisplayAt("next monday at 9:30 - next monday at 7:00", "2 hr 30 min")
        expectDisplayAt("next monday at 9:30 - next monday at 7:00 to minutes", "150 min")
        expectDisplayAt("2026-08-01 - 2026-07-24", "8 days")
        expectDisplayAt("today at 9:30 - today at 7:00 to hours", "2.5 hr")
        expectDisplayAt("now + 5 seconds", "24 July at 12:18:05 AM")
        expectDisplayAt("next\u{a0}monday at\t7:30 + 5", "27 July at 12:30 PM")
        expectDisplayAt("tomorrow - 5 weekdays", "20 July")
        expectDisplayAt("today + 10000 weekdays", "21 November, 2064")
        for query in [
            "tomorrow at 7:99", "tomorrow at 7::30", "today + 1.5 months",
            "today + 1h 30", "today + -9223372036854775808 weekdays", "today + 9223372036854775807 weeks"
        ] {
            expectNilAt(query)
        }
        var vienna = clock.calendar
        vienna.timeZone = TimeZone(identifier: "Europe/Vienna")!
        expectDisplayAt("2026-03-28 at 7:30 + 1 day", "29 March at 7:30 AM", calendar: vienna)
        expectDisplayAt("2026-03-28 at 7:30 + 24 hours", "29 March at 8:30 AM", calendar: vienna)
        expectDisplayAt("2026-03-29 at 7:30 - 2026-03-28 at 7:30 to hours", "23 hr", calendar: vienna)
        expectDisplayAt("2026-10-24 at 7:30 + 1 day", "25 October at 7:30 AM", calendar: vienna)
        expectDisplayAt("2026-10-25 at 7:30 - 2026-10-24 at 7:30 to hours", "25 hr", calendar: vienna)
        expectDisplayAt("1:00 - 3:00", "-2 hr", calendar: vienna)
        let springNow = clock.calendar.date(from: DateComponents(year: 2026, month: 3, day: 29))!
        expectNilAt("2:30am vienna in london", now: springNow, calendar: vienna)
        // A lone date word is still an app search
        expectNilAt("tomorrow")
        expectNilAt("today")

        // Business days skip weekends. The clock is Fri 2026-07-24, so every hop crosses one.
        expectDisplayAt("today + 1 business day", "27 July")
        expectDisplayAt("today + 5 business days", "31 July")
        expectDisplayAt("today - 1 business day", "23 July")
        expectDisplayAt("today - 3 business days", "21 July")
        expectDisplayAt("tomorrow + 10 work days", "7 August")
        expectDisplayAt("today + 15 workdays", "14 August")
        expectDisplayAt("today + 5 weekdays", "31 July")
        // The weekday rides the badge rather than the date
        expectBadgesAt("today + 5 business days", source: "Friday, 24 July", target: "Friday")
        expectBadgesAt("today + 1 business day", source: "Friday, 24 July", target: "Monday")
        // The duration may lead, with `from` naming the anchor or `ago` implying today
        expectDisplayAt("5 weekdays from now", "31 July")
        expectDisplayAt("10 business days from today", "7 August")
        expectDisplayAt("3 days from today", "27 July")
        expectDisplayAt("2 weeks ago", "10 July")
        expectDisplayAt("3 days ago", "21 July")
        expectBadgesAt("5 weekdays from now", source: "Friday, 24 July", target: "Friday")
        // A month name with both a day and a year
        expectDisplayAt("august 26 2026 + 15 workdays", "16 September")
        expectDisplayAt("august 26 2026 + 15 days", "10 September")
        expectDisplayAt("26 august 2026 + 1 day", "27 August")
        expectDisplayAt("august 26 2027 + 1 day", "27 August, 2027")
        // The 8-hour unit is a different thing, and keeps answering as one
        expectDisplay("55h in workdays", "6.875 workdays")
        expectDisplay("3 workdays in hours", "24 hr")
        expectNil("5 from 10")

        finish()
    }
}
