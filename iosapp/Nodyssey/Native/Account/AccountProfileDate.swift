import Foundation

/// `createdAt` is account registration, not last activity. Date-only legacy values
/// are calendar days in the display zone; timestamp values represent instants.
enum AccountProfileDate {
    struct RegistrationMonth: Equatable {
        let year: Int
        let month: Int
    }

    /// The My directory mirrors ProfileViewModel's anchored year/month prefix.
    /// This is site calendar metadata, not an instant to shift across time zones.
    /// Full dates on user spaces and author cards retain the formatter below.
    static func registrationMonth(_ raw: String) -> RegistrationMonth? {
        guard let range = raw.range(of: #"^([0-9]{4})-([0-9]{2})"#, options: .regularExpression) else { return nil }
        let parts = raw[range].split(separator: "-")
        guard let year = Int(parts[0]), let month = Int(parts[1]) else { return nil }
        return RegistrationMonth(year: year, month: month)
    }

    static func date(_ raw: String, timeZone: TimeZone = .current) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.count == 10 {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.calendar = Calendar(identifier: .gregorian)
            parser.timeZone = timeZone
            parser.dateFormat = "yyyy-MM-dd"
            parser.isLenient = false
            guard let date = parser.date(from: value), parser.string(from: date) == value else { return nil }
            return date
        }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value)
    }

    static func formatted(_ raw: String, locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let date = date(raw, timeZone: timeZone) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
