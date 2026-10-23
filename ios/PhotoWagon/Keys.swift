import UIKit

/// Keyboard shortcuts from the engine's bindings (Photoshop's defaults plus the user's changes).
enum Keys {
    /// Shell commands the app carries out itself.
    static let shell: Set<String> = [
        "view.zoomIn", "view.zoomOut", "view.fitOnScreen", "view.actualPixels",
        "file.open", "file.save", "file.saveAs", "file.saveACopy", "edit.search", "window.toggle.layers", "edit.freeTransform",
        "layer.new.layer", "filter.cameraRaw", "edit.puppetWarp",
    ]

    /// `Cmd+Shift+N` → the key and modifiers a `UIKeyCommand` takes.
    static func parse(_ shortcut: String) -> (input: String, flags: UIKeyModifierFlags)? {
        var flags: UIKeyModifierFlags = []
        // A "+" key is spelled "Cmd++".
        let plus = shortcut.hasSuffix("++") || shortcut == "+"
        var parts = shortcut.split(separator: "+").map(String.init)
        if plus { parts.append("+") }
        guard let key = parts.popLast() else { return nil }
        for p in parts {
            switch p {
            case "Cmd": flags.insert(.command)
            case "Ctrl": flags.insert(.control)
            case "Alt": flags.insert(.alternate)
            case "Shift": flags.insert(.shift)
            default: return nil
            }
        }
        let named: [String: String] = [
            "Backspace": "\u{8}", "Delete": UIKeyCommand.inputDelete, "Escape": UIKeyCommand.inputEscape,
            "Tab": "\t", "Enter": "\r", "Return": "\r", "Space": " ",
            "Up": UIKeyCommand.inputUpArrow, "Down": UIKeyCommand.inputDownArrow,
            "Left": UIKeyCommand.inputLeftArrow, "Right": UIKeyCommand.inputRightArrow,
            "Home": UIKeyCommand.inputHome, "End": UIKeyCommand.inputEnd,
            "Pageup": UIKeyCommand.inputPageUp, "Pagedown": UIKeyCommand.inputPageDown,
            "F1": UIKeyCommand.f1, "F2": UIKeyCommand.f2, "F3": UIKeyCommand.f3, "F4": UIKeyCommand.f4,
            "F5": UIKeyCommand.f5, "F6": UIKeyCommand.f6, "F7": UIKeyCommand.f7, "F8": UIKeyCommand.f8,
            "F9": UIKeyCommand.f9, "F10": UIKeyCommand.f10, "F11": UIKeyCommand.f11, "F12": UIKeyCommand.f12,
        ]
        if let n = named[key] { return (n, flags) }
        guard key.count == 1 else { return nil }
        return (key.lowercased(), flags)
    }

    /// One key command per binding the app can carry out; the first binding of a key wins.
    /// `propertyList` is `kind:id`.
    static func commands(_ bindings: [KeyBinding], action: Selector) -> [UIKeyCommand] {
        let tools = Set(Tool.allCases.map(\.engineId))
        var seen = Set<String>()
        var out: [UIKeyCommand] = []
        func add(_ title: String, _ shortcut: String, _ value: String) {
            guard let (input, flags) = parse(shortcut), seen.insert("\(input)|\(flags.rawValue)").inserted else { return }
            let c = UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags, propertyList: value)
            c.wantsPriorityOverSystemBehavior = true
            out.append(c)
        }
        // Return and Esc commit and cancel a crop, transform or polygon, before any binding.
        add("Commit", "Enter", "app:commit")
        add("Cancel", "Escape", "app:cancel")
        for b in bindings {
            switch b.kind {
            case "tool" where tools.contains(b.id):
                add(b.label, b.shortcut, "tool:\(b.id)")
                // Shift and the key steps through the tools that share it.
                add("Next \(b.label)", "Shift+\(b.shortcut)", "tool:\(b.id)")
            // View commands are the app's to run, even where the engine registers them too.
            case "command" where shell.contains(b.id), "shell" where shell.contains(b.id):
                add(b.label, b.shortcut, "shell:\(b.id)")
            case "command":
                add(b.label, b.shortcut, "command:\(b.id)")
            default:
                break
            }
        }
        return out
    }
}
