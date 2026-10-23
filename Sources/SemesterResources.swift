import SwiftUI
import PDFKit

// MARK: - Others > Academic Tools > Semester Resources
// PDFs that ship inside the app (Sources/SemesterResources/*.pdf). To update one, replace the file with the same name.

struct SemesterResource: Identifiable {
    let id: String          // file name without ".pdf"
    let title: String
    let subtitle: String
    let icon: String

    var url: URL? { Bundle.main.url(forResource: id, withExtension: "pdf") }
    var pages: Int { url.flatMap { PDFDocument(url: $0)?.pageCount } ?? 0 }

    static let all: [SemesterResource] = [
        .init(id: "academic_calendar", title: "Academic Calendar",
              subtitle: "Semester I, 2026/2027 · lectures, breaks and exams", icon: "calendar"),
        .init(id: "weekly_calendar", title: "Weekly Calendar",
              subtitle: "Week by week, 28 Sep 2026 – 21 Feb 2027", icon: "calendar.day.timeline.left"),
        .init(id: "cs_study_plan", title: "CS Study Plan",
              subtitle: "Computer Science programme structure (batch 241 and above)", icon: "graduationcap")
    ]
}

struct SemesterResourcesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Semester I, 2026/2027")
                        .font(Theme.font(.title3).weight(.bold)).foregroundColor(Theme.txt).textGlow(radius: 4)
                        .rocksHeading(16, pt: 22)
                    Text("Calendars and your programme plan, saved in the app so they open with no internet.")
                        .font(Theme.read(.footnote)).foregroundColor(Theme.muted)
                }
                .padding(.horizontal, 4)

                ForEach(SemesterResource.all) { r in
                    NavigationLink { PDFScreen(resource: r) } label: { card(r) }
                        .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Semester Resources")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func card(_ r: SemesterResource) -> some View {
        HStack(spacing: 14) {
            Image(systemName: r.icon).font(.system(size: 22, weight: .medium)).foregroundColor(Theme.accent).textGlow()
                .frame(width: 52, height: 52)
                .background(Theme.accent.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(r.title).foregroundColor(Theme.txt).fontWeight(.semibold).textGlow(radius: 3).rocksHeading(12, pt: 18)
                Text(r.subtitle).font(Theme.font(.caption)).foregroundColor(Theme.muted).multilineTextAlignment(.leading)
                if r.pages > 0 {
                    Text("PDF · \(r.pages) page\(r.pages == 1 ? "" : "s")")
                        .font(Theme.font(.caption2).weight(.semibold)).foregroundColor(Theme.accent)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(Theme.font(.caption)).foregroundColor(Theme.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .glowCard()
    }
}

struct PDFScreen: View {
    let resource: SemesterResource

    var body: some View {
        Group {
            if let url = resource.url {
                PDFKitView(url: url).ignoresSafeArea(edges: .bottom)
            } else {
                Text("This file is missing from the app.").foregroundColor(Theme.muted)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(resource.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let url = resource.url {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.document = PDFDocument(url: url)
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.pageBreakMargins = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        v.backgroundColor = UIColor(Theme.bg)
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) {}
}
