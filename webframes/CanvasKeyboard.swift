import AppKit

/// Physical shortcuts keep working with Russian input and Caps Lock.
enum CanvasKeyboard {
    static func modifiers(_ event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection([.command, .control, .option, .shift])
    }
    static func isPaste(_ event: NSEvent) -> Bool {
        event.keyCode == 9 && (modifiers(event) == .command || modifiers(event) == .control)
    }
    static func isUndo(_ event: NSEvent) -> Bool {
        event.keyCode == 6 && (modifiers(event) == .command || modifiers(event) == [.command, .shift])
    }
    static func allowsCanvasShortcut(_ event: NSEvent) -> Bool {
        let flags = modifiers(event)
        if [24, 27, 29, 69, 78, 82].contains(event.keyCode) {
            return flags.isSubset(of: [.command, .shift])
        }
        return flags.isEmpty
    }
}
