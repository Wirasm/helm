import AppKit

/// AppKit's edit menu at the browser input seam. Clipboard data is sent through BrowserPaste.
extension BrowserSurfaceView {
    @objc func copy(_: Any?) {
        Task { @MainActor [weak self] in
            guard let self, let text = await model?.selectedText(), !text.isEmpty else { return }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        model?.key(Self.command("deleteBackward", key: "Backspace", code: "Backspace", vk: 8))
    }

    @objc func paste(_: Any?) {
        guard let payload = BrowserPaste(pasteboard: pasteboard) else { return }
        model?.paste(payload)
    }

    @objc override func selectAll(_: Any?) {
        model?.key(Self.command("selectAll", key: "a", code: "KeyA", vk: 65, meta: true))
    }

    private static func command(
        _ name: String, key: String, code: String, vk: Int, meta: Bool = false
    ) -> BrowserPaneModel.KeyEvent {
        .init(
            type: "rawKeyDown", modifiers: meta ? BrowserModifiers.meta.rawValue : 0, key: key,
            code: code, windowsVirtualKeyCode: vk, commands: [name])
    }
}
