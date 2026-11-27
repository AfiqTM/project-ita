import Foundation

struct AlertCopy {
    let title: String
    let message: String
    var activities: [Activity] = []
    var isFormatted = true

    struct Activity {
        let name: String
        var course: String?
        var href: String?

        var line: String {
            let subject = course.map { Course.cleanSubject($0.replacingOccurrences(of: "_", with: " ")) }
            return [subject, name + " is due"].compactMap { $0 }.joined(separator: " - ")
        }
    }

    init(_ notification: Notif) {
        let subject = (notification.subject ?? "").plainText
        let original = notification.smallmessage ?? ""
        let lower = subject.lowercased()

        if lower.hasPrefix("assignment submission confirmation") {
            title = "Submission confirmation" + subject.dropFirst("Assignment submission confirmation".count)
            message = "You recently submitted a work"
        } else if lower.hasPrefix("new sign in to your ") || lower.hasPrefix("new sign-in to your ") {
            title = "New sign in to your iTa’leem account"
            message = "Your account was just signed in to from a new device."
        } else if lower.hasPrefix("you have upcoming activities due") || lower.hasPrefix("you have an upcoming activity due") {
            let upcoming = Self.upcoming(notification)
            activities = upcoming
            title = upcoming.count == 1 ? "You have an upcoming activity due" : "You have upcoming activities due"
            message = upcoming.map(\.line).joined(separator: "\n")
        } else if notification.component == "mod_forum" || subject.range(of: Self.coursePrefix, options: .regularExpression) != nil {
            title = subject.isEmpty ? "Alert" : subject.replacingOccurrences(of: Self.coursePrefix, with: "$1:", options: .regularExpression)
            message = original.replacingOccurrences(of: Self.postedInCourse, with: "$1", options: .regularExpression)
        } else {
            title = subject.isEmpty ? "Alert" : subject
            message = original
            isFormatted = false
        }
    }

    private static let coursePrefix = #"^([A-Z]{2,6}\s*\d{3,4})(?:[_\s]+\d{1,3})?[_\s]+SEM\s*\d+\s*:"#
    private static let postedInCourse = #"(?i)(\bposted in\s+)[A-Z]{2,6}\s*\d{3,4}(?:[_\s]+\d{1,3})?[_\s]+SEM\s*\d+\s*:\s*"#

    private static func upcoming(_ notification: Notif) -> [Activity] {
        for source in [notification.fullmessagehtml, notification.fullmessage, notification.smallmessage] {
            guard let source, !source.isEmpty else { continue }
            let activities = parseActivities(source)
            if !activities.isEmpty { return activities }
        }
        return []
    }

    private static func parseActivities(_ source: String) -> [Activity] {
        let html = source.range(of: #"<[a-z][^>]*>"#, options: [.regularExpression, .caseInsensitive]) != nil
        let rows = html
            ? source.replacingOccurrences(of: #"(?is)<(?:head|style)\b[^>]*>.*?</(?:head|style)\s*>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"<br\s*/?>|</(?:tr|p|div|li|h[1-6])\s*>"#, with: "\n",
                                      options: [.regularExpression, .caseInsensitive])
            : source
        var result: [Activity] = []
        for row in rows.split(whereSeparator: \.isNewline) {
            let raw = String(row)
            let text = raw.plainText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let href = AppLinks.attribute("href", in: raw)
            if text.lowercased().hasSuffix(" is due") {
                let name = String(text.dropLast(" is due".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { result.append(Activity(name: name, href: href)) }
            } else if let index = result.indices.last {
                if text.lowercased().hasPrefix("course:") {
                    let course = text.dropFirst("course:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !course.isEmpty { result[index].course = course }
                } else if text.lowercased().hasPrefix("go to activity"), let href {
                    result[index].href = href
                }
            }
        }
        return result
    }
}
