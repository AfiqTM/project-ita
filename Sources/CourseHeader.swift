import SwiftUI

// MARK: - Course page header
//
// A blurred photo behind the navigation bar, the tab strip and the top of the Course tab, fading into the page.
// Under it: the course code in large letters, "Subject • Section 02 • Semester 1", and the lecturer(s).
// The photo is Assets.xcassets/CourseHeader.imageset/header.jpg: replace that file to change it.
// Light theme keeps the plain page (a dark photo would not fit it).

extension Course {
    /// "BICS 1306 04 SEM1" -> "BICS 1306 04"
    var headerCode: String {
        let base = prettyShort ?? prettyFull
        let t = base.replacingOccurrences(of: "\\s*\\bSEM\\s*\\d+\\b", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        // "BICS 1306 04" -> "BICS 1306" (the section is shown in the line below)
        let short = t.replacingOccurrences(of: "(?<=\\d{4})\\s+\\d{1,2}$", with: "", options: .regularExpression)
        return short.isEmpty ? (t.isEmpty ? base : t) : short
    }
    /// "Section 02" (from "... Section 2 ..." in the full name)
    var sectionLabel: String? {
        guard let r = fullname.range(of: "section\\s*0*(\\d+)", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let digits = fullname[r].filter(\.isNumber)
        guard let n = Int(digits) else { return nil }
        return String(format: "Section %02d", n)
    }
    /// "Semester 1" (from "SEM 1" / "SEM1")
    var semesterLabel: String? {
        for s in [fullname, shortname ?? ""] {
            if let r = s.range(of: "\\bSEM\\s*(\\d+)", options: [.regularExpression, .caseInsensitive]) {
                let digits = s[r].filter(\.isNumber)
                if !digits.isEmpty { return "Semester \(digits)" }
            }
        }
        return nil
    }
    /// "Digital & Embedded Systems • Section 02 • Semester 1"
    var headerLine: String {
        [subjectName, sectionLabel, semesterLabel].compactMap { $0 }.joined(separator: "  •  ")
    }
}

extension Person {
    /// "ASMARANI BINTI AHMAD PUZI 10324" -> "Asmarani Binti Ahmad Puzi" (staff / matric number dropped, words capitalised)
    var displayName: String {
        var words = fullname.split(whereSeparator: \.isWhitespace).map(String.init)
        while let last = words.last, last.allSatisfy(\.isNumber) { words.removeLast() }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }
    var isLecturer: Bool {
        (roles ?? []).contains { ["editingteacher", "teacher"].contains(($0.shortname ?? "").lowercased()) }
    }
}

/// The course's lecturers, from the participant list (people with a teacher role)
@MainActor final class CourseLecturers: ObservableObject {
    @Published private(set) var people: [Person] = []
    private static var cache: [Int: [Person]] = [:]

    func load(courseId: Int) async {
        if let c = Self.cache[courseId] { people = c }
        var teachers: [Person] = []
        if let all: [Person] = try? await MoodleAPI.shared.call("core_enrol_get_enrolled_users", ["courseid": courseId]) {
            teachers = all.filter(\.isLecturer)
        }
        if teachers.isEmpty { teachers = await contacts(courseId) }     // the participant list may not show roles
        let withPictures = await ProfileImages.upgraded(teachers)
        guard !withPictures.isEmpty else { return }
        Self.cache[courseId] = withPictures
        people = withPictures
    }

    private struct ContactCourse: Decodable { let contacts: [Contact]?; struct Contact: Decodable { let id: Int } }
    private struct ContactResp: Decodable { let courses: [ContactCourse] }

    /// The course's "contacts" (its teachers, as the site lists them on the course card), with their profiles
    private func contacts(_ courseId: Int) async -> [Person] {
        guard let r: ContactResp = try? await MoodleAPI.shared.call(
                "core_course_get_courses_by_field", ["field": "id", "value": courseId]),
              let ids = r.courses.first?.contacts?.map(\.id), !ids.isEmpty,
              let users: [Person] = try? await MoodleAPI.shared.call(
                "core_user_get_users_by_field", ["field": "id", "values": ids]) else { return [] }
        return users
    }
}

struct CourseHeaderView: View {
    let course: Course
    @StateObject private var lecturers = CourseLecturers()

    /// "Subject • Section 02 • Semester 1" on one line when it fits; otherwise the subject, then the section and semester
    /// on the next line (so a line never starts or ends with a loose dot)
    @ViewBuilder private var subtitle: some View {
        let rest = [course.sectionLabel, course.semesterLabel].compactMap { $0 }.joined(separator: "  •  ")
        if !course.subjectName.isEmpty {
            ViewThatFits(in: .horizontal) {
                Text(([course.subjectName] + (rest.isEmpty ? [] : [rest])).joined(separator: "  •  "))
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(course.subjectName).fixedSize(horizontal: false, vertical: true)
                    if !rest.isEmpty { Text(rest) }
                }
            }
            .font(Theme.read(.body)).foregroundColor(Theme.txt)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(course.headerCode)
                .foregroundStyle(LinearGradient(colors: [Theme.txt, Theme.accent.opacity(0.85)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                .lineLimit(2).minimumScaleFactor(0.6)
                .pixelHeading(22, normal: .system(size: 38, weight: .bold), pt: 38)
            subtitle
            ForEach(lecturers.people) { p in
                HStack(spacing: 10) {
                    ProfilePhoto(name: p.fullname, urls: [p.profileimageurlsmall, p.profileimageurl], size: 30,
                                 sizeKey: "f1", outline: false)
                    Text(p.displayName).font(Theme.read(.subheadline)).foregroundColor(Theme.txt.opacity(0.9))
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4).padding(.top, 26).padding(.bottom, 6)
        .task { await lecturers.load(courseId: course.id) }
    }
}

/// Where the Course tab's list has scrolled to, so the photo can move up with it
struct CourseScrollKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

final class CourseScrollModel: ObservableObject {
    @Published var y: CGFloat = 0
}

/// Remembers the Course list's last scroll position without redrawing anything (a plain reference, not observed), so the
/// photo can be put back in the right place when the Course page comes back on screen
final class CourseScrollBox {
    var y: CGFloat = 0
}

/// The solid cover behind the status bar, the navigation bar AND the tab strip, drawn as one view with one opacity, so the
/// whole top area fades in and out together with exactly the same timing (no part of it can lag behind another).
/// On the Course tab it follows the scroll (clear at the top so the photo shows through; solid once the photo has moved
/// away); on every other tab it is solid. Switching tabs fades it quickly and straight away.
struct CourseChromeBackground: View {
    @ObservedObject var scroll: CourseScrollModel
    let onCourse: Bool

    var body: some View {
        let scrolled = min(max(scroll.y / 260, 0), 1)
        Theme.bg
            .opacity(onCourse ? scrolled : 1)
            .animation(.easeOut(duration: 0.14), value: onCourse)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }
}

struct CourseBackdrop: View {
    @ObservedObject var scroll: CourseScrollModel
    @ObservedObject private var themes = ThemeStore.shared
    private let height: CGFloat = 560

    var body: some View {
        let t = themes.theme
        Color.clear
            .frame(maxWidth: .infinity).frame(height: height)
            .overlay {
                Image("CourseHeader").resizable().scaledToFill()
                    .saturation(t.coverSaturation)
                    .brightness(t.coverBrightness * 0.5)
                    .overlay { if let c = t.coverTint { Color(hex: c).opacity(0.35).blendMode(.multiply) } }
            }
            .clipped()
            // darker at the top so the title bar and tabs stay readable, fading into the page at the bottom
            .overlay(LinearGradient(colors: [Color.black.opacity(0.45), Color.black.opacity(0)],
                                    startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)))
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.38),
                .init(color: Color.black.opacity(0.6), location: 0.62),
                .init(color: Color.black.opacity(0.2), location: 0.82),
                .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom))
            // moves up 1:1 with the list and slides off under the status bar, like the reference video
            .offset(y: -min(max(scroll.y, 0), height))
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}


/// The course sections on the photo pages: a dark, slightly see-through card with a fine accent outline
struct GlassCard: ViewModifier {
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(Theme.surface.opacity(0.62))
            .background(.ultraThinMaterial)
            .clipShape(shape)
            .overlay(shape.stroke(Theme.accent.opacity(0.28), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.35), radius: 14, y: 6)
    }
}

extension View {
    func glassCard(radius: CGFloat = 20) -> some View { modifier(GlassCard(radius: radius)) }

    /// iOS 26 draws a hairline where a scroll view meets the navigation bar; the photo header wants none
    @ViewBuilder func noTopEdgeEffect(_ on: Bool = true) -> some View {
        #if compiler(>=6.2)
        if on, #available(iOS 26.0, *) { self.scrollEdgeEffectHidden(true, for: .top) } else { self }
        #else
        self
        #endif
    }
}
