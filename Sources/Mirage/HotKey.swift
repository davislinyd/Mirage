import Carbon.HIToolbox

/// 全域快捷鍵。Carbon 的 RegisterEventHotKey 不需要額外權限，App 不在前景時也有效；回呼在主執行緒。
/// 只支援一組快捷鍵。
@MainActor
final class HotKey {
    private static var action: (() -> Void)?
    private var ref: EventHotKeyRef?

    /// `keyCode` 如 `kVK_ANSI_M`，`modifiers` 如 `controlKey | optionKey | cmdKey`。
    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        // 簽章 "MRGE"，只用來辨識這組快捷鍵。
        RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: 0x4D52_4745, id: 1), GetApplicationEventTarget(), 0, &ref
        )
    }
}
