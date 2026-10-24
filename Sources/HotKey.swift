import Carbon

/// Глобальный хоткей через Carbon RegisterEventHotKey — работает без прав Accessibility
/// и не перехватывает клавиатуру целиком, в отличие от CGEventTap.
final class HotKey {
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var installed = false
    private var ref: EventHotKeyRef?
    private let id: UInt32
    /// false — сочетание уже занято системой или другим приложением.
    let isRegistered: Bool

    init(id: UInt32, spec: HotKeySpec, handler: @escaping () -> Void) {
        self.id = id
        Self.installHandlerIfNeeded()
        Self.handlers[id] = handler
        let hkID = EventHotKeyID(signature: OSType(0x4149_4544), id: id) // 'AIED'
        let status = RegisterEventHotKey(UInt32(spec.keyCode), UInt32(spec.modifiers), hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        isRegistered = status == noErr
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
