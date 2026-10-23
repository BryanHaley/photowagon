import Foundation

/// A document saved for recovery by an earlier run that didn't save or close it.
struct RecoveredFile: Identifiable, Equatable {
    let url: URL
    let name: String
    let date: Date
    var id: URL { url }
}

/// Recovery: the front document, when it has unsaved changes, is saved every few minutes (and
/// when the app leaves the screen) into a folder for this run. Saving or closing it removes the
/// copy; after a crash or the app being closed, the next run lists what's left on Home.
extension EditorModel {
    static let recoveryChoices = [0, 1, 5, 10, 15, 30, 60]
    /// Home lists this many; older copies are discarded.
    static let recoveredLimit = 10

    /// Minutes between recovery saves; 0 = off.
    var recoveryMinutes: Int {
        get { defaults.object(forKey: "recoveryMinutes") as? Int ?? 10 }
        set {
            defaults.set(newValue, forKey: "recoveryMinutes")
            objectWillChange.send()
        }
    }

    private var recoveryFolder: URL { recoveryRoot.appendingPathComponent(recoveryRun, isDirectory: true) }

    private func recoveryFile(_ id: UInt64) -> URL { recoveryFolder.appendingPathComponent("\(id).pcraft") }

    /// What earlier runs left behind, newest first.
    func loadRecovered() {
        let fm = FileManager.default
        let runs = (try? fm.contentsOfDirectory(at: recoveryRoot, includingPropertiesForKeys: nil)) ?? []
        var out: [RecoveredFile] = []
        for run in runs where run.lastPathComponent != recoveryRun {
            for f in (try? fm.contentsOfDirectory(at: run, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "pcraft" {
                let name = (try? String(contentsOf: f.appendingPathExtension("name"), encoding: .utf8)) ?? "Untitled"
                let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                out.append(RecoveredFile(url: f, name: name, date: date))
            }
        }
        recovered = out.sorted { $0.date > $1.date }
        for r in recovered.dropFirst(Self.recoveredLimit) { discardRecovered(r) }
    }

    /// Every minute; saves when the interval has passed.
    func recoveryTick(now: Date = Date()) {
        guard recoveryMinutes > 0, now.timeIntervalSince(lastRecovery) >= Double(recoveryMinutes) * 60 else { return }
        saveRecovery()
    }

    /// Save the front document for recovery now, if it has unsaved changes.
    func saveRecovery(wait: Bool = false) {
        guard recoveryMinutes > 0, let d = doc, isDirty(d) else { return }
        lastRecovery = Date()
        let (editor, folder, file, name) = (editor, recoveryFolder, recoveryFile(d.id), d.name)
        let work = {
            guard let data = try? editor.export(format: "pcraft", quality: nil) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            try? name.write(to: file.appendingPathExtension("name"), atomically: true, encoding: .utf8)
        }
        if wait { work() } else { Task.detached(priority: .utility) { work() } }
    }

    /// The document was saved or closed: its recovery copy goes.
    func clearRecovery(_ id: UInt64) {
        let f = recoveryFile(id)
        try? FileManager.default.removeItem(at: f)
        try? FileManager.default.removeItem(at: f.appendingPathExtension("name"))
    }

    /// Open a recovered document (unsaved, under its old name) and drop its copy.
    func openRecovered(_ r: RecoveredFile) {
        guard let data = try? Data(contentsOf: r.url) else {
            toast = "\(r.name) can't be read"
            discardRecovered(r)
            return
        }
        open(data: data, name: r.name, url: nil, develop: false)
        discardRecovered(r)
    }

    func discardRecovered(_ r: RecoveredFile) {
        let fm = FileManager.default
        try? fm.removeItem(at: r.url)
        try? fm.removeItem(at: r.url.appendingPathExtension("name"))
        let run = r.url.deletingLastPathComponent()
        if (try? fm.contentsOfDirectory(atPath: run.path))?.isEmpty == true { try? fm.removeItem(at: run) }
        recovered.removeAll { $0 == r }
    }
}
