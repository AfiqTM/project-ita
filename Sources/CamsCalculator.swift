import SwiftUI

// MARK: - Model + storage (saved per course in UserDefaults)

struct CamsEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var score = ""
    var outOf = ""

    /// What the mark is out of. Left empty it counts as 20 (the grey "20" shown in the box).
    var maxValue: Double? { outOf.trimmingCharacters(in: .whitespaces).isEmpty ? 20 : camsNumber(outOf) }
}

struct CamsGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind = "Quiz"
    var customName = ""      // only used when kind == "Others"
    var weight = ""          // what this component is worth overall, in %
    var entries: [CamsEntry] = [CamsEntry()]

    static let kinds = ["Quiz", "Assignment", "Lab", "Practical", "Others"]

    var title: String {
        if kind == "Others" {
            let n = customName.trimmingCharacters(in: .whitespaces)
            return n.isEmpty ? "Others" : n
        }
        return kind
    }
    var weightValue: Double? { camsNumber(weight) }

    /// Average of the filled-in entries as a percentage (each entry counts equally).
    var percent: Double? {
        let p = entries.compactMap { e -> Double? in
            guard let s = camsNumber(e.score), let m = e.maxValue, m > 0 else { return nil }
            return s / m * 100
        }
        return p.isEmpty ? nil : p.reduce(0, +) / Double(p.count)
    }
    /// Tells the user why a component isn't being counted yet (nil when everything needed is filled in)
    var hint: String? {
        let started = entries.contains { !$0.score.isEmpty }
        guard started else { return nil }
        let bad = entries.contains {
            (!$0.score.isEmpty && camsNumber($0.score) == nil)
                || (!$0.outOf.isEmpty && (camsNumber($0.outOf) ?? 0) <= 0)
        }
        if bad { return "Check the boxes: marks and \"out of\" need to be numbers (out of must be above 0)." }
        if weightValue == nil { return "Set this one's weight % (top right) so it counts in the total." }
        return nil
    }
    /// Marks this component adds to the overall result, e.g. 75% of a 10% component = 7.5
    var earned: Double? {
        guard let p = percent, let w = weightValue else { return nil }
        return p / 100 * w
    }
}

func camsNumber(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    return t.isEmpty ? nil : Double(t)
}
func camsFormat(_ d: Double) -> String { d.formatted(.number.precision(.fractionLength(0...2))) }

enum CamsStore {
    private static func key(_ id: Int) -> String { "cams.course.\(id)" }
    static func load(_ id: Int) -> [CamsGroup] {
        guard let d = UserDefaults.standard.data(forKey: key(id)),
              let g = try? JSONDecoder().decode([CamsGroup].self, from: d) else { return [] }
        return g
    }
    private static func stampKey(_ id: Int) -> String { "cams.upd.\(id)" }

    /// Saves a change made on this device (stamps it so it syncs). Does nothing when nothing changed.
    static func save(_ groups: [CamsGroup], _ id: Int) {
        guard groups != load(id) else { return }
        write(groups, id, at: Date())
        NotificationCenter.default.post(name: .syncLocalChanged, object: nil)
    }
    /// Newer data from Drive
    static func applySync(_ id: Int, _ groups: [CamsGroup], at: Date) { write(groups, id, at: at) }

    private static func write(_ groups: [CamsGroup], _ id: Int, at: Date) {
        if let d = try? JSONEncoder().encode(groups) { UserDefaults.standard.set(d, forKey: key(id)) }
        UserDefaults.standard.set(at.timeIntervalSince1970, forKey: stampKey(id))
    }

    /// Every subject that has marks saved: (course id, groups, last change)
    static func all() -> [(Int, [CamsGroup], Date)] {
        let ud = UserDefaults.standard
        let prefix = "cams.course."
        return ud.dictionaryRepresentation().keys.compactMap { k in
            guard k.hasPrefix(prefix), let id = Int(k.dropFirst(prefix.count)) else { return nil }
            let at = ud.double(forKey: stampKey(id))
            return (id, load(id), Date(timeIntervalSince1970: at > 0 ? at : 1))   // marks saved before sync existed count as oldest
        }
    }
}

// MARK: - Card (sits on the Grades page, collapsed by default)

struct CamsCalculatorCard: View {
    let courseId: Int
    @State private var open = false
    @State private var groups: [CamsGroup]

    init(courseId: Int) {
        self.courseId = courseId
        _groups = State(initialValue: CamsStore.load(courseId))
    }

    private var totalEarned: Double { groups.compactMap(\.earned).reduce(0, +) }
    private var totalWeight: Double { groups.compactMap(\.weightValue).reduce(0, +) }

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { open.toggle() } } label: {
                HStack {
                    Image(systemName: "function").foregroundColor(Theme.accent).frame(width: 24)
                    Text("CAMS Calculator").fontWeight(.semibold).foregroundColor(Theme.txt)
                    Spacer()
                    if !open, totalWeight > 0 {
                        Text("\(camsFormat(totalEarned)) / \(camsFormat(totalWeight))")
                            .font(.caption).foregroundColor(Theme.muted)
                    }
                    Image(systemName: open ? "chevron.up" : "chevron.down").foregroundColor(Theme.accent)
                }
                .padding(14)
                .background(Theme.titleBar)
            }
            if open {
                VStack(spacing: 14) {
                    if groups.isEmpty {
                        Text("Add work (quizzes, assignments, ...) to start.")
                            .font(.footnote).foregroundColor(Theme.muted)
                    }
                    ForEach($groups) { $g in
                        CamsGroupBox(group: $g) { groups.removeAll { $0.id == g.id } }
                    }
                    Menu {
                        ForEach(CamsGroup.kinds, id: \.self) { k in
                            Button(k) { groups.append(CamsGroup(kind: k)) }
                        }
                    } label: {
                        Label("Add work", systemImage: "plus.circle").foregroundColor(Theme.accent)
                    }
                    if !groups.isEmpty {
                        Rectangle().fill(Theme.line).frame(height: 1)
                        HStack {
                            Text("Total so far").foregroundColor(Theme.txt)
                            Spacer()
                            Text("\(camsFormat(totalEarned)) / \(camsFormat(totalWeight))")
                                .fontWeight(.semibold).foregroundColor(Theme.accent)
                        }
                    }
                }
                .padding(14)
            }
        }
        .glowCard()
        .onChange(of: groups) { _ in CamsStore.save(groups, courseId) }
        .onReceive(NotificationCenter.default.publisher(for: .syncApplied)) { _ in
            let fresh = CamsStore.load(courseId)
            if fresh != groups { groups = fresh }
        }
    }
}

private struct CamsGroupBox: View {
    @Binding var group: CamsGroup
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(CamsGroup.kinds, id: \.self) { k in Button(k) { group.kind = k } }
                } label: {
                    HStack(spacing: 4) {
                        Text(group.kind).fontWeight(.semibold)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .foregroundColor(Theme.accent)
                }
                Spacer()
                Text("Weight").font(.caption).foregroundColor(Theme.muted)
                CamsField(text: $group.weight, placeholder: "10", width: 52)
                Text("%").foregroundColor(Theme.muted)
                Button(action: onDelete) { Image(systemName: "trash").foregroundColor(Theme.muted) }
                    .padding(.leading, 4)
            }

            if group.kind == "Others" {
                TextField("", text: $group.customName,
                          prompt: Text("Name (e.g. Presentation)").foregroundColor(Theme.muted))
                    .foregroundColor(Theme.txt)
                    .padding(8)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            }

            ForEach($group.entries) { $e in
                HStack(spacing: 8) {
                    Text("\(group.title) \((group.entries.firstIndex(where: { $0.id == e.id }) ?? 0) + 1)")
                        .font(.subheadline).foregroundColor(Theme.txt).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CamsField(text: $e.score, placeholder: "10")
                    Text("/").foregroundColor(Theme.muted)
                    CamsField(text: $e.outOf, placeholder: "20")
                    Button { group.entries.removeAll { $0.id == e.id } } label: {
                        Image(systemName: "minus.circle").foregroundColor(Theme.muted)
                    }
                }
            }

            HStack {
                Button { group.entries.append(CamsEntry(outOf: group.entries.last?.outOf ?? "")) } label: {
                    Label("Add \(group.title.lowercased())", systemImage: "plus")
                        .font(.footnote).foregroundColor(Theme.accent)
                }
                Spacer()
                if let p = group.percent {
                    if let e = group.earned, let w = group.weightValue {
                        Text("\(camsFormat(p))%  →  \(camsFormat(e)) / \(camsFormat(w))")
                            .font(.footnote.weight(.semibold)).foregroundColor(Theme.accent)
                    } else {
                        Text("\(camsFormat(p))%").font(.footnote.weight(.semibold)).foregroundColor(Theme.accent)
                    }
                }
            }
            if let hint = group.hint {
                Text(hint).font(.caption).foregroundColor(.orange.opacity(0.85))
            }
        }
        .padding(12)
        .background(Theme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }
}

private struct CamsField: View {
    @Binding var text: String
    var placeholder = ""
    var width: CGFloat = 56

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Theme.muted))
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.center)
            .foregroundColor(Theme.txt)
            .padding(.vertical, 7)
            .frame(width: width)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}

// MARK: - Small "Done" button above the keyboard (only covers its own corner, unlike the full-width keyboard bar)

private struct KeyboardDoneButton: ViewModifier {
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if visible {
                    Button {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                        to: nil, from: nil, for: nil)
                    } label: {
                        Text("Done").fontWeight(.semibold).foregroundColor(Theme.onAccent)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Theme.accent).clipShape(Capsule())
                    }
                    .padding(12)
                    .transition(.opacity)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                withAnimation(.easeOut(duration: 0.15)) { visible = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(.easeOut(duration: 0.15)) { visible = false }
            }
    }
}

extension View {
    /// Floating "Done" button just above the keyboard (bottom-right) while it is open.
    func keyboardDoneButton() -> some View { modifier(KeyboardDoneButton()) }
}
