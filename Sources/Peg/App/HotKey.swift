import AppKit
import Carbon.HIToolbox

/// A global shortcut registered through Carbon. No Accessibility permission is
/// needed for this, unlike a CGEventTap.
private let hotKeyEventHandler: EventHandlerUPP = { _, eventRef, _ in
    // The first parameter is the *handler call ref*, not the event. Handing it
    // to GetEventParameter dereferences a bogus pointer and segfaults.
    guard let eventRef else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let err = GetEventParameter(eventRef,
                                EventParamName(kEventParamDirectObject),
                                EventParamType(typeEventHotKeyID),
                                nil,
                                MemoryLayout<EventHotKeyID>.size,
                                nil,
                                &hotKeyID)
    guard err == noErr else { return err }
    DispatchQueue.main.async { HotKey.dispatch(hotKeyID.id) }
    return noErr
}

final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private static var nextID: UInt32 = 1

    private let id: UInt32
    private var ref: EventHotKeyRef?

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        let id = HotKey.nextID
        HotKey.nextID += 1
        self.id = id
        HotKey.actions[id] = action
        HotKey.installHandler()

        var hkRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5045_4721), id: id) // 'PEG!'
        let status = RegisterEventHotKey(keyCode,
                                         modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &hkRef)
        guard status == noErr, let hkRef else {
            HotKey.actions[id] = nil
            return nil
        }
        self.ref = hkRef
    }

    /// Unregisters immediately; `deinit` alone would leave the combination
    /// taken while the object is still alive.
    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        HotKey.actions[id] = nil
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.actions[id] = nil
    }

    fileprivate static func dispatch(_ id: UInt32) {
        actions[id]?()
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}

/// Keeps the Carbon hot keys in sync with the stored bindings: changing a
/// shortcut unregisters everything and registers the new set.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var hotKeys: [HotKey] = []
    private(set) var failed: [ShortcutAction] = []

    func apply(handlers: [ShortcutAction: () -> Void]) {
        hotKeys.forEach { $0.unregister() }
        hotKeys.removeAll()
        failed.removeAll()

        for action in ShortcutAction.allCases {
            guard let handler = handlers[action] else { continue }
            let shortcut = ShortcutStore.shortcut(for: action)
            guard shortcut.isUsable else { failed.append(action); continue }
            if let hotKey = HotKey(keyCode: shortcut.keyCode,
                                   modifiers: shortcut.modifiers,
                                   action: handler) {
                hotKeys.append(hotKey)
            } else {
                failed.append(action)
            }
        }
    }
}
