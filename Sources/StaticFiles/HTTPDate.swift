/// Parses an HTTP-date (RFC 9110 §5.6.7) into whole seconds since the Unix epoch, without
/// Foundation and without allocating: every field sits at a fixed offset.
///
/// Accepted formats:
///
/// | Format | Example |
/// |---|---|
/// | IMF-fixdate (preferred) | `Sun, 06 Nov 1994 08:49:37 GMT` |
/// | obsolete RFC 850 | `Sunday, 06-Nov-94 08:49:37 GMT` |
/// | obsolete asctime | `Sun Nov  6 08:49:37 1994` |
///
/// A value in any other shape, with an unknown day or month name, or with an impossible
/// date or time (`31 Feb`, `25:00:00`) is invalid (`nil`); RFC 9110 says such a conditional
/// field is ignored. The weekday name is checked for spelling but not against the date.
/// Leading and trailing spaces and tabs are skipped. A two-digit RFC 850 year `00`-`69` means
/// 20xx and `70`-`99` means 19xx. A leap second (`:60`) counts as `:59`.
///
/// Rendering is ``IMFFixdate`` in HTTPCore.
public enum HTTPDate {
    /// Seconds since 1970-01-01T00:00:00Z for `value`, or `nil` when it is not an HTTP-date.
    public static func parse(_ value: Span<UInt8>) -> Int64? {
        var start = 0
        var end = value.count
        while start < end, value[start] == 0x20 || value[start] == 0x09 { start &+= 1 }
        while end > start, value[end &- 1] == 0x20 || value[end &- 1] == 0x09 { end &-= 1 }
        let bytes = value.extracting(start..<end)
        let count = bytes.count
        guard count >= 24 else { return nil }
        if bytes[3] == UInt8(ascii: ",") {
            return count == 29 ? imfFixdate(bytes) : nil
        }
        if bytes[3] == UInt8(ascii: " ") {
            return count == 24 ? asctime(bytes) : nil
        }
        return rfc850(bytes)
    }

    /// `parse` for a `String`. May allocate; for tests and edges, not the hot path.
    public static func parse(_ value: String) -> Int64? {
        var copy = value
        return copy.withUTF8 { parse($0.span) }
    }

    // MARK: Formats

    /// `Sun, 06 Nov 1994 08:49:37 GMT`
    static func imfFixdate(_ b: Span<UInt8>) -> Int64? {
        guard shortWeekday(b, at: 0),
              b[4] == 0x20, b[7] == 0x20, b[11] == 0x20, b[16] == 0x20, b[25] == 0x20,
              b[26] == UInt8(ascii: "G"), b[27] == UInt8(ascii: "M"), b[28] == UInt8(ascii: "T"),
              let day = digits(b, 5, 2), let month = month(b, at: 8), let year = digits(b, 12, 4),
              let time = timeOfDay(b, at: 17)
        else { return nil }
        return seconds(year: year, month: month, day: day, timeOfDay: time)
    }

    /// `Sunday, 06-Nov-94 08:49:37 GMT`: a full weekday name, then 24 fixed bytes.
    static func rfc850(_ b: Span<UInt8>) -> Int64? {
        let n = b.count &- 24          // length of the weekday name
        guard n >= 6, n <= 9, longWeekday(b, length: n),
              b[n] == UInt8(ascii: ","), b[n &+ 1] == 0x20,
              b[n &+ 4] == UInt8(ascii: "-"), b[n &+ 8] == UInt8(ascii: "-"), b[n &+ 11] == 0x20,
              b[n &+ 20] == 0x20,
              b[n &+ 21] == UInt8(ascii: "G"), b[n &+ 22] == UInt8(ascii: "M"), b[n &+ 23] == UInt8(ascii: "T"),
              let day = digits(b, n &+ 2, 2), let month = month(b, at: n &+ 5), let yy = digits(b, n &+ 9, 2),
              let time = timeOfDay(b, at: n &+ 12)
        else { return nil }
        return seconds(year: yy < 70 ? 2000 &+ yy : 1900 &+ yy, month: month, day: day, timeOfDay: time)
    }

    /// `Sun Nov  6 08:49:37 1994`: the day is two digits or a space and one digit.
    static func asctime(_ b: Span<UInt8>) -> Int64? {
        guard shortWeekday(b, at: 0), b[7] == 0x20, b[10] == 0x20, b[19] == 0x20,
              let month = month(b, at: 4), let time = timeOfDay(b, at: 11), let year = digits(b, 20, 4)
        else { return nil }
        let day: Int
        if b[8] == 0x20 {
            guard let d = digits(b, 9, 1) else { return nil }
            day = d
        } else {
            guard let d = digits(b, 8, 2) else { return nil }
            day = d
        }
        return seconds(year: year, month: month, day: day, timeOfDay: time)
    }

    // MARK: Fields

    /// `count` ASCII digits at `offset` as a number, or `nil`.
    static func digits(_ b: Span<UInt8>, _ offset: Int, _ count: Int) -> Int? {
        var value = 0
        for i in offset..<(offset &+ count) {
            let d = b[i] &- UInt8(ascii: "0")
            guard d < 10 else { return nil }
            value = value &* 10 &+ Int(d)
        }
        return value
    }

    /// `hh:mm:ss` at `offset` as seconds into the day.
    static func timeOfDay(_ b: Span<UInt8>, at offset: Int) -> Int? {
        guard b[offset &+ 2] == UInt8(ascii: ":"), b[offset &+ 5] == UInt8(ascii: ":"),
              let h = digits(b, offset, 2), let m = digits(b, offset &+ 3, 2), let s = digits(b, offset &+ 6, 2),
              h < 24, m < 60, s <= 60
        else { return nil }
        return h &* 3_600 &+ m &* 60 &+ Swift.min(s, 59)
    }

    /// Three-letter month name at `offset` (case-sensitive, as RFC 9110 specifies) as 1...12.
    static func month(_ b: Span<UInt8>, at offset: Int) -> Int? {
        let key = UInt32(b[offset]) << 16 | UInt32(b[offset &+ 1]) << 8 | UInt32(b[offset &+ 2])
        switch key {
        case 0x4A616E: return 1   // Jan
        case 0x466562: return 2   // Feb
        case 0x4D6172: return 3   // Mar
        case 0x417072: return 4   // Apr
        case 0x4D6179: return 5   // May
        case 0x4A756E: return 6   // Jun
        case 0x4A756C: return 7   // Jul
        case 0x417567: return 8   // Aug
        case 0x536570: return 9   // Sep
        case 0x4F6374: return 10  // Oct
        case 0x4E6F76: return 11  // Nov
        case 0x446563: return 12  // Dec
        default: return nil
        }
    }

    /// True for `Mon` ... `Sun` at `offset`.
    static func shortWeekday(_ b: Span<UInt8>, at offset: Int) -> Bool {
        let key = UInt32(b[offset]) << 16 | UInt32(b[offset &+ 1]) << 8 | UInt32(b[offset &+ 2])
        switch key {
        case 0x4D6F6E, 0x547565, 0x576564, 0x546875, 0x467269, 0x536174, 0x53756E: return true
        default: return false
        }
    }

    /// True when the first `length` bytes are a full weekday name (`Monday` ... `Sunday`).
    static func longWeekday(_ b: Span<UInt8>, length: Int) -> Bool {
        guard shortWeekday(b, at: 0) else { return false }
        let names: StaticString = "Monday Tuesday Wednesday Thursday Friday Saturday Sunday "
        return names.withUTF8Buffer { all in
            var start = 0
            for i in 0..<all.count where all[i] == 0x20 {
                if i &- start == length {
                    var same = true
                    for j in 0..<length where all[start &+ j] != b[j] { same = false; break }
                    if same { return true }
                }
                start = i &+ 1
            }
            return false
        }
    }

    /// Seconds since the epoch for a civil date and time (UTC), or `nil` for a day the month
    /// does not have.
    static func seconds(year: Int, month: Int, day: Int, timeOfDay: Int) -> Int64? {
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let daysInMonth: Int
        switch month {
        case 2: daysInMonth = leap ? 29 : 28
        case 4, 6, 9, 11: daysInMonth = 30
        default: daysInMonth = 31
        }
        guard day >= 1, day <= daysInMonth else { return nil }
        // days_from_civil (http://howardhinnant.github.io/date_algorithms.html).
        let y = month <= 2 ? year &- 1 : year
        let era = (y >= 0 ? y : y &- 399) / 400
        let yearOfEra = y &- era &* 400
        let monthPrime = month > 2 ? month &- 3 : month &+ 9
        let dayOfYear = (153 &* monthPrime &+ 2) / 5 &+ day &- 1
        let dayOfEra = yearOfEra &* 365 &+ yearOfEra / 4 &- yearOfEra / 100 &+ dayOfYear
        let days = era &* 146_097 &+ dayOfEra &- 719_468
        return Int64(days) &* 86_400 &+ Int64(timeOfDay)
    }
}
