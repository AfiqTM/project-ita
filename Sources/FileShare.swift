import SwiftUI

// MARK: - Share a course file
//
// The file viewer's share button. A course file's address carries the login token, so the address itself is never
// shared: the file is saved to a temporary copy (or the downloaded copy is used) and that file goes to the share sheet.

struct ShareableFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct FileShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

enum FileSharePrep {
    /// A temporary copy of the file, named like the original, ready for the share sheet
    static func prepare(url: URL, title: String, modified: Int?) async throws -> URL {
        var name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if name.isEmpty || name == "pluginfile.php" { name = title }
        name = name.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "file" }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)

        // the downloaded copy, when there is one (works with no internet too)
        let key = OfflineFileStore.key(url)
        if let e = OfflineFileStore.shared.entry(key), let local = OfflineFileStore.shared.localFile(e),
           !OfflineNet.shared.online || modified == nil || modified == e.modified {
            try FileManager.default.copyItem(at: local, to: dest)
            return dest
        }

        let (data, resp) = try await URLSession.shared.data(from: url)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw URLError(.badServerResponse) }
        try data.write(to: dest)
        return dest
    }
}
