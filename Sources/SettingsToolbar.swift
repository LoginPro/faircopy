import AppKit
import Combine

/// Панель инструментов окна настроек на родном NSToolbar: кнопки-капсулы на Liquid Glass,
/// как у Finder. SwiftUI-`.toolbar` из окна, собранного вручную, не переносится (и даже
/// вызывал действие кнопки при запуске), поэтому здесь — явный делегат.
@MainActor
final class SettingsToolbar: NSObject, NSToolbarDelegate {
    private static let voice = NSToolbarItem.Identifier("voice")
    private static let add = NSToolbarItem.Identifier("add")

    let toolbar = NSToolbar(identifier: "settings")
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private var subscription: AnyCancellable?

    override init() {
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        // кнопки нужны только в разделе «Стили»
        subscription = AppSettings.shared.$tab.sink { [weak self] tab in
            self?.items.values.forEach { $0.isHidden = tab != .styles }
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.voice, Self.add]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.isBordered = true
        item.target = self
        switch id {
        case Self.voice:
            item.label = String(localized: "Мой стиль")
            item.toolTip = String(localized: "Создать стиль по моим сообщениям")
            item.image = NSImage(systemSymbolName: "person.wave.2", accessibilityDescription: item.label)
            item.action = #selector(voice)
        case Self.add:
            item.label = String(localized: "Новый стиль")
            item.toolTip = String(localized: "Новый стиль")
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: item.label)
            item.action = #selector(addStyle)
        default:
            return nil
        }
        item.isHidden = AppSettings.shared.tab != .styles
        items[id] = item
        return item
    }

    @objc private func voice() { AppSettings.shared.showVoiceSheet = true }

    @objc private func addStyle() { AppSettings.shared.selectedStyleID = StyleStore.shared.add().id }
}
