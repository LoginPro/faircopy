import AppKit
import ApplicationServices

/// Достаёт выделенный текст из любого приложения и вставляет результат обратно.
/// Нужен доступ «Универсальный доступ» (Accessibility): и для AX, и для синтетических ⌘C/⌘V.
@MainActor
enum TextBridge {
    private static let keyA: CGKeyCode = 0, keyC: CGKeyCode = 8, keyV: CGKeyCode = 9

    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Сначала пробуем AX (не трогает буфер обмена), затем ⌘C, затем ⌘A+⌘C —
    /// последнее нужно для поля ввода мессенджера, где ничего не выделено.
    static func grabText() async -> String? {
        await waitForModifiersRelease()
        if let s = selectedTextViaAX() { return s }
        if let s = await copyViaPasteboard() { return s }
        postKey(keyA)
        try? await Task.sleep(nanoseconds: 80_000_000)
        return await copyViaPasteboard()
    }

    static func paste(_ text: String, into app: NSRunningApplication?) async {
        app?.activate()
        try? await Task.sleep(nanoseconds: 150_000_000)
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        postKey(keyV)
        try? await Task.sleep(nanoseconds: 500_000_000)
        restore(pb, saved)
    }

    /// Где на экране строка с текстовым курсором (координаты Cocoa). Сначала просим у поля рамку
    /// выделенного диапазона, если приложение её не отдаёт — рамку самого поля. nil — ничего не нашлось.
    static func focusedTextRect() -> NSRect? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let ref = focused, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let element = ref as! AXUIElement

        var rect = CGRect.null
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
           let range {
            var bounds: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                          range, &bounds) == .success,
               let b = bounds, CFGetTypeID(b) == AXValueGetTypeID() {
                AXValueGetValue(b as! AXValue, .cgRect, &rect)
            }
        }
        if rect.isNull || rect.height <= 0 {
            var pos: CFTypeRef?, size: CFTypeRef?
            var p = CGPoint.zero, sz = CGSize.zero
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
                  let pos, let size,
                  AXValueGetValue(pos as! AXValue, .cgPoint, &p),
                  AXValueGetValue(size as! AXValue, .cgSize, &sz), sz.height > 0 else { return nil }
            // у огромных полей (документ на весь экран) берём только верхнюю строку
            rect = CGRect(origin: p, size: CGSize(width: sz.width, height: min(sz.height, 40)))
        }
        // AX считает y от верха главного экрана, Cocoa — от низа
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func selectedTextViaAX() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let s = selected as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    private static func copyViaPasteboard() async -> String? {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        postKey(keyC)
        for _ in 0..<20 where pb.changeCount == before {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let text = pb.changeCount != before ? pb.string(forType: .string) : nil
        restore(pb, saved)
        guard let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return t
    }

    /// Хоткей срабатывает, пока ⌃⌥ ещё зажаты — ждём отпускания, иначе ⌘C превратится в ⌃⌥⌘C.
    private static func waitForModifiersRelease() async {
        for _ in 0..<50 {
            let flags = NSEvent.modifierFlags.intersection([.control, .option, .shift, .command])
            if flags.isEmpty { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func postKey(_ key: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
    }

    private static func restore(_ pb: NSPasteboard, _ saved: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        let items = saved.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, data) in dict { item.setData(data, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
