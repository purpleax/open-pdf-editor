import Foundation

/// PDF dates: D:YYYYMMDDHHmmSSOHH'mm', with everything after the year
/// optional. The text comes from the document, so every field is range
/// checked rather than trusted.
public enum PDFDate {
    /// The date, or nil when the text isn't a valid PDF date.
    public static func parse(_ string: String) -> Date? {
        var s = Substring(string.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("D:") { s = s.dropFirst(2) }
        let digits = Array(s.prefix { $0.isASCII && $0.isNumber })
        guard digits.count >= 4, digits.count <= 14 else { return nil }
        func field(_ offset: Int, _ length: Int, default value: Int, range: ClosedRange<Int>) -> Int? {
            guard digits.count >= offset + length else { return value }
            guard let number = Int(String(digits[offset..<offset + length])), range.contains(number) else { return nil }
            return number
        }
        guard let year = field(0, 4, default: 0, range: 1...9999),
              let month = field(4, 2, default: 1, range: 1...12),
              let day = field(6, 2, default: 1, range: 1...31),
              let hour = field(8, 2, default: 0, range: 0...23),
              let minute = field(10, 2, default: 0, range: 0...59),
              let second = field(12, 2, default: 0, range: 0...59) else { return nil }

        // Time zone: Z, or +HH'mm' / -HH'mm', each part at most two digits.
        var offset = 0
        let rest = s.dropFirst(digits.count)
        if let sign = rest.first, sign == "+" || sign == "-" {
            let parts = rest.dropFirst().split(whereSeparator: { !($0.isASCII && $0.isNumber) }).prefix(2)
            guard let hours = parts.first.flatMap({ $0.count <= 2 ? Int($0) : nil }), hours <= 18 else { return nil }
            var minutes = 0
            if parts.count > 1 {
                guard let m = parts.last.flatMap({ $0.count <= 2 ? Int($0) : nil }), m <= 59 else { return nil }
                minutes = m
            }
            // Time zones run to ±18 hours; beyond that the date isn't valid.
            guard hours * 3600 + minutes * 60 <= 18 * 3600 else { return nil }
            offset = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(secondsFromGMT: offset)
        return Calendar(identifier: .gregorian).date(from: components)
    }
}
