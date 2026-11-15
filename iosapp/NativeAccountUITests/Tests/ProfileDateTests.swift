import Foundation
import Testing
@testable import AccountBehavior

struct ProfileDateTests {
    @Test func directoryMembershipKeepsSiteYearMonthRatherThanConvertingTheInstant() throws {
        let month = try #require(AccountProfileDate.registrationMonth("2025-01-01T00:00:00+14:00"))
        #expect(month.year == 2025)
        #expect(month.month == 1)
        #expect(AccountProfileDate.registrationMonth("2025-01") == month)
        for raw in ["", "unknown", "2025", "2025-1", "prefix 2025-01"] {
            #expect(AccountProfileDate.registrationMonth(raw) == nil)
        }
    }

    @Test func registrationTimestampAcceptsFractionalAndOffsetForms() throws {
        let fractional = try #require(AccountProfileDate.date("2025-01-05T04:07:29.000Z"))
        #expect(AccountProfileDate.date("2025-01-05T04:07:29Z") == fractional)
        #expect(AccountProfileDate.date("2025-01-05T12:07:29+08:00") == fractional)
    }

    @Test func dateOnlyDoesNotMoveToPreviousDayInWesternTimeZones() throws {
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let date = try #require(AccountProfileDate.date("2025-01-05", timeZone: zone))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        #expect(calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: 2025, month: 1, day: 5))
    }

    @Test func absentAndMalformedDatesDoNotInventMembershipDates() {
        for raw in ["", " ", "not a date", "2025-02-30", "2025-01-05 trailing"] {
            #expect(AccountProfileDate.date(raw) == nil)
        }
    }

    @Test func timestampFormattingUsesRequestedLocaleAndTimeZone() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let west = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let raw = "2025-01-05T04:07:29.000Z"
        let english = try #require(AccountProfileDate.formatted(raw, locale: Locale(identifier: "en_US"), timeZone: utc))
        for identifier in ["zh_Hans", "zh_Hant"] {
            let localized = try #require(AccountProfileDate.formatted(raw, locale: Locale(identifier: identifier), timeZone: utc))
            #expect(english != localized)
        }
        #expect(english != AccountProfileDate.formatted(raw, locale: Locale(identifier: "en_US"), timeZone: west))
    }
}
