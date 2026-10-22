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
        return t.isEmpty ? base : t
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
        guard let all: [Person] = try? await MoodleAPI.shared.call("core_enrol_get_enrolled_users", ["courseid": courseId]) else { return }
        let teachers = all.filter(\.isLecturer)
        let withPictures = await ProfileImages.upgraded(teachers)
        Self.cache[courseId] = withPictures
        people = withPictures
    }
}

struct CourseHeaderView: View {
    let course: Course
    @StateObject private var lecturers = CourseLecturers()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(course.headerCode)
                .foregroundStyle(LinearGradient(colors: [Theme.txt, Theme.accent.opacity(0.85)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                .lineLimit(2).minimumScaleFactor(0.6)
                .pixelHeading(24, normal: .system(size: 46, weight: .bold), pt: 46)
            if !course.headerLine.isEmpty {
                Text(course.headerLine)
                    .font(Theme.read(.body)).foregroundColor(Theme.txt)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.5),
                                         .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .offset(y: -min(max(scroll.y, 0), height))
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
