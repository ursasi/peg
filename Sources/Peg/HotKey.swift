import AppKit
import Carbon.HIToolbox

/// A global shortcut registered through Carbon. No Accessibility permission is
/// needed for this, unlike a CGEventTap.
private let hotKeyEventHandler: EventHandlerUPP = { callRef, _, _ in
    guard let callRef else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let err = GetEventParameter(callRef,
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

    init?(_ shortcut: Shortcut, action: @escaping () -> Void) {
        let id = HotKey.nextID
        HotKey.nextID += 1
        self.id = id
        HotKey.actions[id] = action
        HotKey.installHandler()

        var hkRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5045_4721), id: id) // 'PEG!'
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode),
                                         shortcut.carbonModifiers,
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

struct Shortcut {
    let keyCode: Int
    let carbonModifiers: UInt32

    static let snip = Shortcut(keyCode: kVK_ANSI_X, carbonModifiers: UInt32(controlKey | optionKey))
    static let shelf = Shortcut(keyCode: kVK_ANSI_S, carbonModifiers: UInt32(controlKey | optionKey))
}
