import AppKit
import Carbon.HIToolbox

/// Registers a system-wide hotkey via Carbon's `RegisterEventHotKey`.
///
/// We use Carbon (not `NSEvent.addGlobalMonitorForEvents`) deliberately:
/// Carbon's hotkey API doesn't require Accessibility permission, which we'd
/// otherwise have to ask the user for on top of Screen Recording.
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onFire: () -> Void
    // SAFETY-2: stored so the C callback can verify the firing ID matches what we registered.
    private var registeredID: EventHotKeyID?

    init?(keyCode: Int, modifiers: Int, _ onFire: @escaping () -> Void) {
        self.onFire = onFire

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        // passUnretained is safe here: deinit calls RemoveEventHandler synchronously before
        // the object is freed, so the C callback cannot fire after deinit begins.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let eventRef = eventRef, let userData = userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return noErr }
                // SAFETY-2: reject events that don't belong to this instance's hotkey.
                let unmanaged = Unmanaged<GlobalHotkey>.fromOpaque(userData)
                let target = unmanaged.takeUnretainedValue()
                guard let registered = target.registeredID,
                      hotKeyID.id == registered.id,
                      hotKeyID.signature == registered.signature else { return noErr }
                // SAFETY-1: retain for the async hop so the instance lives until the
                // closure executes, even if the caller releases its reference first.
                _ = unmanaged.retain()
                DispatchQueue.main.async {
                    target.onFire()
                    unmanaged.release()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )
        if installStatus != noErr { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x47494652 /* "GIFR" */), id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus != noErr { return nil }
        self.registeredID = hotKeyID
    }

    deinit {
        // Order matters: unregister the hotkey first so no new events are queued,
        // then remove the handler so any in-flight C callbacks cannot fire.
        if let hotKeyRef = hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef = handlerRef { RemoveEventHandler(handlerRef) }
    }
}
