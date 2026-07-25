import Foundation
import SwiftUI

nonisolated enum AppDateFormat: String, CaseIterable, Codable, Identifiable {
    case localizedLong
    case yearMonthDaySlashes
    case yearMonthDayHyphens
    case monthDayYearSlashes
    case monthDayYearHyphens

    static let userDefaultsKey = "com.deskbrief.settings.dateFormat"

    var id: String { rawValue }

    static var current: AppDateFormat {
        guard let rawValue = UserDefaults.standard.string(forKey: userDefaultsKey) else {
            return .localizedLong
        }
        return AppDateFormat(rawValue: rawValue) ?? .localizedLong
    }

    func preview(for date: Date, language: AppLanguage) -> String {
        AppDateFormatting.string(from: date, format: self, language: language)
    }
}

nonisolated enum AppTimeFormat: String, CaseIterable, Codable, Identifiable {
    case twelveHour
    case twentyFourHour

    static let userDefaultsKey = "com.deskbrief.settings.timeFormat"

    var id: String { rawValue }

    static var current: AppTimeFormat {
        guard let rawValue = UserDefaults.standard.string(forKey: userDefaultsKey) else {
            return .twentyFourHour
        }
        return AppTimeFormat(rawValue: rawValue) ?? .twentyFourHour
    }

    func preview(for date: Date, language: AppLanguage) -> String {
        AppTimeFormatting.string(from: date, format: self, language: language)
    }

    func pickerLabel(for date: Date, language: AppLanguage) -> String {
        let cycle = self == .twelveHour ? "12h" : "24h"
        return "\(cycle) — \(preview(for: date, language: language))"
    }
}

nonisolated enum AppDateFormatting {
    enum Style {
        case fullDate
        case monthDay
        case yearMonth
        case year
        case weekday
    }

    static func string(
        from date: Date,
        style: Style = .fullDate,
        format: AppDateFormat = .current,
        language: AppLanguage = .current,
        timeZone: TimeZone = .current
    ) -> String {
        switch style {
        case .fullDate:
            return fullDateString(from: date, format: format, language: language, timeZone: timeZone)
        case .monthDay:
            return monthDayString(from: date, format: format, language: language, timeZone: timeZone)
        case .yearMonth:
            return yearMonthString(from: date, format: format, language: language, timeZone: timeZone)
        case .year:
            return yearString(from: date, format: format, language: language, timeZone: timeZone)
        case .weekday:
            return formatter(template: "EEEE", language: language, timeZone: timeZone).string(from: date)
        }
    }

    static func dayWithWeekdayString(
        from date: Date,
        format: AppDateFormat = .current,
        language: AppLanguage = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let day = string(from: date, format: format, language: language, timeZone: timeZone)
        let weekday = string(from: date, style: .weekday, format: format, language: language, timeZone: timeZone)
        return "\(day)·\(weekday)"
    }

    private static func fullDateString(
        from date: Date,
        format: AppDateFormat,
        language: AppLanguage,
        timeZone: TimeZone
    ) -> String {
        if format == .localizedLong {
            return localizedLongDateString(from: date, language: language, timeZone: timeZone)
        }
        return fixedFormatter(pattern: pattern(for: format, style: .fullDate), timeZone: timeZone).string(from: date)
    }

    private static func monthDayString(
        from date: Date,
        format: AppDateFormat,
        language: AppLanguage,
        timeZone: TimeZone
    ) -> String {
        if format == .localizedLong {
            switch language {
            case .simplifiedChinese:
                return fixedFormatter(pattern: "M月d日", timeZone: timeZone).string(from: date)
            case .english:
                let components = dateComponents(from: date, timeZone: timeZone)
                return "\(englishAbbreviatedMonth(components.month)) \(ordinal(components.day))"
            }
        }
        return fixedFormatter(pattern: pattern(for: format, style: .monthDay), timeZone: timeZone).string(from: date)
    }

    private static func yearMonthString(
        from date: Date,
        format: AppDateFormat,
        language: AppLanguage,
        timeZone: TimeZone
    ) -> String {
        if format == .localizedLong {
            switch language {
            case .simplifiedChinese:
                return fixedFormatter(pattern: "yyyy年M月", timeZone: timeZone).string(from: date)
            case .english:
                let components = dateComponents(from: date, timeZone: timeZone)
                return "\(englishFullMonth(components.month)) \(components.year)"
            }
        }
        return fixedFormatter(pattern: pattern(for: format, style: .yearMonth), timeZone: timeZone).string(from: date)
    }

    private static func yearString(
        from date: Date,
        format: AppDateFormat,
        language: AppLanguage,
        timeZone: TimeZone
    ) -> String {
        let year = dateComponents(from: date, timeZone: timeZone).year
        if format == .localizedLong, language == .simplifiedChinese {
            return "\(year)年"
        }
        return "\(year)"
    }

    private static func localizedLongDateString(
        from date: Date,
        language: AppLanguage,
        timeZone: TimeZone
    ) -> String {
        let components = dateComponents(from: date, timeZone: timeZone)
        switch language {
        case .simplifiedChinese:
            return "\(components.year)年\(components.month)月\(components.day)日"
        case .english:
            return "\(englishAbbreviatedMonth(components.month)) \(ordinal(components.day)), \(components.year)"
        }
    }

    private static func pattern(for format: AppDateFormat, style: Style) -> String {
        switch (format, style) {
        case (.yearMonthDaySlashes, .fullDate):
            return "yyyy/M/d"
        case (.yearMonthDayHyphens, .fullDate):
            return "yyyy-M-d"
        case (.monthDayYearSlashes, .fullDate):
            return "M/d/yyyy"
        case (.monthDayYearHyphens, .fullDate):
            return "M-d-yyyy"
        case (.yearMonthDaySlashes, .monthDay), (.monthDayYearSlashes, .monthDay):
            return "M/d"
        case (.yearMonthDayHyphens, .monthDay), (.monthDayYearHyphens, .monthDay):
            return "M-d"
        case (.yearMonthDaySlashes, .yearMonth), (.yearMonthDayHyphens, .yearMonth):
            return format == .yearMonthDaySlashes ? "yyyy/M" : "yyyy-M"
        case (.monthDayYearSlashes, .yearMonth), (.monthDayYearHyphens, .yearMonth):
            return format == .monthDayYearSlashes ? "M/yyyy" : "M-yyyy"
        default:
            preconditionFailure("Unsupported date format style")
        }
    }

    private static func dateComponents(from date: Date, timeZone: TimeZone) -> (year: Int, month: Int, day: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return (components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func fixedFormatter(pattern: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter
    }

    private static func formatter(template: String, language: AppLanguage, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static func ordinal(_ day: Int) -> String {
        let remainder100 = day % 100
        let suffix: String
        if 11...13 ~= remainder100 {
            suffix = "th"
        } else {
            switch day % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(day)\(suffix)"
    }

    private static func englishAbbreviatedMonth(_ month: Int) -> String {
        let months = ["Jan.", "Feb.", "Mar.", "Apr.", "May", "Jun.", "Jul.", "Aug.", "Sep.", "Oct.", "Nov.", "Dec."]
        guard months.indices.contains(month - 1) else { return "" }
        return months[month - 1]
    }

    private static func englishFullMonth(_ month: Int) -> String {
        let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        guard months.indices.contains(month - 1) else { return "" }
        return months[month - 1]
    }
}

nonisolated enum AppTimeFormatting {
    enum Precision {
        case minute
        case second
        case millisecond
    }

    static func string(
        from date: Date,
        precision: Precision = .minute,
        format: AppTimeFormat = .current,
        language: AppLanguage = .current,
        timeZone: TimeZone = .current
    ) -> String {
        formatter(precision: precision, format: format, language: language, timeZone: timeZone).string(from: date)
    }

    static func dateTimeString(
        from date: Date,
        precision: Precision = .minute,
        dateFormat: AppDateFormat = .current,
        timeFormat: AppTimeFormat = .current,
        language: AppLanguage = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let dateText = AppDateFormatting.string(
            from: date,
            format: dateFormat,
            language: language,
            timeZone: timeZone
        )
        let timeText = string(
            from: date,
            precision: precision,
            format: timeFormat,
            language: language,
            timeZone: timeZone
        )
        return "\(dateText) \(timeText)"
    }

    static func endOfDayString(
        for intervalEnd: Date,
        format: AppTimeFormat = .current,
        language: AppLanguage = .current,
        timeZone: TimeZone = .current
    ) -> String {
        if format == .twentyFourHour {
            return "24:00"
        }
        return string(from: intervalEnd, format: format, language: language, timeZone: timeZone)
    }

    static func pickerLocale(language: AppLanguage, format: AppTimeFormat) -> Locale {
        let hourCycle = format == .twelveHour ? "h12" : "h23"
        return Locale(identifier: "\(language.rawValue)-u-hc-\(hourCycle)")
    }

    private static func formatter(
        precision: Precision,
        format: AppTimeFormat,
        language: AppLanguage,
        timeZone: TimeZone
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone

        switch (format, precision, language) {
        case (.twelveHour, .minute, .simplifiedChinese): formatter.dateFormat = "a h:mm"
        case (.twelveHour, .second, .simplifiedChinese): formatter.dateFormat = "a h:mm:ss"
        case (.twelveHour, .millisecond, .simplifiedChinese): formatter.dateFormat = "a h:mm:ss.SSS"
        case (.twelveHour, .minute, .english): formatter.dateFormat = "h:mm a"
        case (.twelveHour, .second, .english): formatter.dateFormat = "h:mm:ss a"
        case (.twelveHour, .millisecond, .english): formatter.dateFormat = "h:mm:ss.SSS a"
        case (.twentyFourHour, .minute, _): formatter.dateFormat = "HH:mm"
        case (.twentyFourHour, .second, _): formatter.dateFormat = "HH:mm:ss"
        case (.twentyFourHour, .millisecond, _): formatter.dateFormat = "HH:mm:ss.SSS"
        }
        return formatter
    }
}

struct AppTimePicker: View {
    let title: String
    @Binding var selection: Date
    let format: AppTimeFormat
    let language: AppLanguage

    var body: some View {
        DatePicker(
            title,
            selection: $selection,
            displayedComponents: [.hourAndMinute]
        )
        .environment(\.locale, AppTimeFormatting.pickerLocale(language: language, format: format))
    }
}
