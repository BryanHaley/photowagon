import SwiftUI
import WebKit

/// Help › Manual: the manual bundled with the app (Book/index.html), with Find.
struct ManualView: View {
    @State private var web = WKWebView()

    var body: some View {
        NavigationStack {
            ManualPage(web: web)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Manual")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { web.findInteraction?.presentFindNavigator(showingReplace: false) } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel("Find")
                        .accessibilityIdentifier("manual.find")
                    }
                    ToolbarItem(placement: .confirmationAction) { DoneButton() }
                }
        }
    }
}

private struct ManualPage: UIViewRepresentable {
    let web: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        web.isFindInteractionEnabled = true
        web.isOpaque = false
        web.backgroundColor = .clear
        web.accessibilityIdentifier = "manual.page"
        if let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Book") {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
}

/// Help › Acknowledgements: every library inside the app and its licence (made by `cargo xtask ios`).
struct Acknowledgements: Decodable {
    struct Group: Decodable, Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    struct Entry: Decodable, Identifiable, Hashable {
        let name: String
        let license: String
        let note: String
        let texts: [Int]
        var id: String { name }
    }

    let groups: [Group]
    let texts: [String]

    static func load(from bundle: Bundle = .main) -> Acknowledgements? {
        bundle.url(forResource: "Acknowledgements", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Acknowledgements.self, from: $0) }
    }

    func texts(of entry: Entry) -> [String] {
        entry.texts.compactMap { texts.indices.contains($0) ? Self.reflow(texts[$0]) : nil }
    }

    /// Joins hard-wrapped lines into paragraphs. Keeps blank lines, rules (`----`), list items and
    /// lines indented less than the one before (centred titles) on lines of their own.
    static func reflow(_ text: String) -> String {
        var out: [String] = []
        var lastIndent = 0
        var joinable = false
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            let rule = !line.isEmpty && line.allSatisfy { "-=*_".contains($0) }
            let starts = line.hasPrefix("Copyright")
                || line.range(of: #"^([-*•]|\(?[0-9a-zA-Z]{1,3}[.)])\s"#, options: .regularExpression) != nil
            if line.isEmpty {
                out.append("")
                joinable = false
            } else if rule {
                joinable = false
            } else if joinable, !starts, indent >= lastIndent, let last = out.popLast() {
                out.append(last + " " + line)
            } else {
                out.append(line)
                lastIndent = indent
                joinable = true
            }
        }
        return out.joined(separator: "\n").replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }
}

struct AcknowledgementsView: View {
    @State private var query = ""
    private let acknowledgements = Acknowledgements.load()

    var body: some View {
        List {
            if let acknowledgements {
                ForEach(acknowledgements.groups) { group in
                    let entries = group.entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.license.localizedCaseInsensitiveContains(query) }
                    if !entries.isEmpty {
                        Section(group.title) {
                            ForEach(entries) { entry in
                                NavigationLink {
                                    LicenseView(entry: entry, texts: acknowledgements.texts(of: entry))
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name)
                                        Text(entry.license).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                Text("The acknowledgements are missing from this build.")
            }
        }
        .searchable(text: $query)
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("acknowledgements.list")
    }
}

private struct LicenseView: View {
    let entry: Acknowledgements.Entry
    let texts: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(entry.license).font(.headline)
                Text(entry.note).font(.subheadline)
                ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
                    Divider()
                    Text(text).font(.footnote)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
