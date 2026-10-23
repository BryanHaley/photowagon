import SwiftUI

@main
struct PhotoWagonApp: App {
    init() {
        // UI tests: `-resetSettings` starts from default settings and an empty app folder (no
        // saved files, brushes or actions), `-seedSamples <folder>` copies that folder's files into the app's Documents
        // (On My iPhone › PhotoWagon in Files), and `-resetRecents` forgets the recent files.
        let args = UserDefaults.standard
        if args.bool(forKey: "resetSettings"), let id = Bundle.main.bundleIdentifier {
            args.removePersistentDomain(forName: id)
            if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                try? FileManager.default.removeItem(at: support.appendingPathComponent("Presets"))
                try? FileManager.default.removeItem(at: support.appendingPathComponent("Recovery"))
            }
            for f in (try? FileManager.default.contentsOfDirectory(at: AppFolder.url, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: f)
            }
        }
        if let dir = args.string(forKey: "seedSamples"), let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let kinds = AppFolder.openable.union(AppFolder.brushes).union(["atn"])
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where kinds.contains((name as NSString).pathExtension.lowercased()) {
                let to = docs.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: to)
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: dir).appendingPathComponent(name), to: to)
            }
        }
        if args.bool(forKey: "resetRecents") { RecentFile.save([]) }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
