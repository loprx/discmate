import SwiftUI

enum DiscMateShortcutAction: String, CaseIterable, Identifiable {
    case refresh, summary, burn

    var id: Self { self }

    var title: String {
        switch self {
        case .refresh: "刷新设备"
        case .summary: "查看刻录摘要"
        case .burn: "开始刻录"
        }
    }

    var defaultChoice: String {
        switch self {
        case .refresh: "command-r"
        case .summary: "shift-r"
        case .burn: "shift-return"
        }
    }
}

struct DiscMateShortcutChoice: Identifiable {
    let id: String
    let label: String
    let shortcut: KeyboardShortcut?

    static let all: [Self] = [
        .init(id: "off", label: "关闭", shortcut: nil),
        .init(id: "command-r", label: "⌘R", shortcut: KeyboardShortcut("r", modifiers: .command))
    ] + choices(prefix: "shift", symbol: "⌘⇧", modifiers: [.command, .shift],
                keys: "rb1234567890") +
        choices(prefix: "option-shift", symbol: "⌘⌥⇧", modifiers: [.command, .option, .shift],
                keys: "abcdefghijklmnopqrstuvwxyz1234567890")

    private static func choices(prefix: String, symbol: String, modifiers: SwiftUI.EventModifiers,
                                keys: String) -> [Self] {
        [.init(id: prefix + "-return", label: symbol + "↩",
               shortcut: KeyboardShortcut(.return, modifiers: modifiers))] + keys.map { key in
            Self(id: prefix + "-" + String(key), label: symbol + key.uppercased(),
                 shortcut: KeyboardShortcut(KeyEquivalent(key), modifiers: modifiers))
        }
    }
}

@MainActor
final class DiscMateShortcuts: ObservableObject {
    @Published private var choices: [DiscMateShortcutAction: String] = [:]
    private let defaults: UserDefaults
    private let storageKey = "discMate.keyboardShortcuts"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        // Validate the whole saved set, including shortcuts reassigned from
        // another action, without depending on the order of edits.
        let restored = DiscMateShortcutAction.allCases.map { saved[$0.rawValue] ?? $0.defaultChoice }
        let active = restored.filter { $0 != "off" }
        if Set(active).count == active.count,
           restored.allSatisfy({ id in DiscMateShortcutChoice.all.contains { $0.id == id } }) {
            choices = Dictionary(uniqueKeysWithValues: zip(DiscMateShortcutAction.allCases, restored))
        }
    }

    func selectedID(for action: DiscMateShortcutAction) -> String {
        choices[action] ?? action.defaultChoice
    }

    func choice(for action: DiscMateShortcutAction) -> DiscMateShortcutChoice {
        DiscMateShortcutChoice.all.first { $0.id == selectedID(for: action) } ?? DiscMateShortcutChoice.all[0]
    }

    func availableChoices(for action: DiscMateShortcutAction) -> [DiscMateShortcutChoice] {
        let used = Set(DiscMateShortcutAction.allCases.filter { $0 != action }.map { selectedID(for: $0) })
        return DiscMateShortcutChoice.all.filter { $0.id == "off" || !used.contains($0.id) }
    }

    func set(_ id: String, for action: DiscMateShortcutAction) {
        guard availableChoices(for: action).contains(where: { $0.id == id }) else { return }
        choices[action] = id
        defaults.set(Dictionary(uniqueKeysWithValues: choices.map { ($0.key.rawValue, $0.value) }),
                     forKey: storageKey)
    }

    func reset() {
        defaults.removeObject(forKey: storageKey)
        choices = [:]
    }

    func helpTitle(for action: DiscMateShortcutAction) -> String {
        let selected = choice(for: action)
        return selected.shortcut == nil ? action.title : "\(action.title)（\(selected.label)）"
    }
}

struct ShortcutSettingsView: View {
    @ObservedObject var shortcuts: DiscMateShortcuts

    var body: some View {
        Form {
            Section("快捷键") {
                ForEach(DiscMateShortcutAction.allCases) { action in
                    Picker(action.title, selection: Binding(
                        get: { shortcuts.selectedID(for: action) },
                        set: { shortcuts.set($0, for: action) }
                    )) {
                        ForEach(shortcuts.availableChoices(for: action)) { choice in
                            Text(choice.label).tag(choice.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Button("恢复默认快捷键") { shortcuts.reset() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 410)
    }
}
