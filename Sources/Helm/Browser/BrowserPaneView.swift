import AppKit
import SwiftUI

/// A browser pane: the shared browser's tabs, a thin address bar, and the tab it shows.
struct BrowserPaneView: View {
    @ObservedObject var model: BrowserPaneModel
    /// Whether the bench says this pane holds the keyboard. Same contract as a terminal's:
    /// acted on only when it becomes true, so a pane that merely appears never takes focus.
    let holdsKeyboard: Bool

    @State private var address = ""
    @State private var findShown = false
    @State private var findText = ""
    /// The pane's own fields. One focus state for both, so which of them has the keyboard is one
    /// value, and `BrowserKeyboard` is told once when the pane starts or stops editing.
    @FocusState private var field: Field?

    enum Field: Hashable {
        case address
        case find
    }

    var body: some View {
        VStack(spacing: 0) {
            BrowserTabStrip(model: model)
                .disabled(model.status != .connected)
            bar
            if findShown {
                BrowserFindBar(model: model, text: $findText, field: $field) { closeFind() }
            }
            if let notice = model.notice {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.textFaint)
                    Text(notice).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.dismissNotice() }.buttonStyle(.chrome)
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            Divider()
            ZStack {
                BrowserSurface(model: model, holdsKeyboard: holdsKeyboard)
                BrowserFormPickerView(picker: model.pageInput.forms, page: { model.surface })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                if let shown = model.tabs.showing, let dialog = model.dialogs[shown] {
                    BrowserDialogStrip(dialog: dialog, takesKeyboard: pageHasKeyboard) {
                        accept, text, hadKeyboard in
                        model.answer(accept: accept, text: text)
                        if hadKeyboard { returnKeyboardToPage() }
                    }
                    .id(dialog)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                if model.status != .connected {
                    notice
                }
            }
        }
        .background(Color.surface)
        .onChange(of: model.tabs.current?.url) { _, url in
            // A blank tab's field is empty and waits for typing, as ⌘T's does in Chrome — and
            // is refilled even while focused, since ⌘T focuses it before the tab exists.
            if url == "about:blank" {
                address = ""
            } else if field != .address {
                address = url ?? ""
            }
        }
        .onChange(of: model.addressRequests) { focus(.address) }
        .onChange(of: model.findRequests) {
            findShown = true
            focus(.find)
        }
        .onChange(of: field) { _, now in
            if now != nil {
                BrowserKeyboard.editingField = model
            } else if BrowserKeyboard.editingField === model {
                BrowserKeyboard.editingField = nil
            }
        }
        .onDisappear {
            if BrowserKeyboard.editingField === model { BrowserKeyboard.editingField = nil }
        }
    }

    /// Puts the keyboard in one of the pane's fields, with what is in it selected — ⌘L or ⌘F on
    /// a field that already has focus still selects it, as in Chrome. Only to the field editor:
    /// sent to the page, select-all would select the page.
    private func focus(_ target: Field) {
        field = target
        DispatchQueue.main.async {
            guard BrowserKeyboard.editingField === model,
                let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                editor.isFieldEditor
            else { return }
            editor.selectAll(nil)
        }
    }

    /// Esc or the close button: the find row goes, and the page has the keyboard again. The last
    /// match stays selected, as in Chrome.
    private func closeFind() {
        findShown = false
        returnKeyboardToPage()
    }

    private var bar: some View {
        HStack(spacing: 6) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left").frame(width: 20, height: 20)
            }
            .help("Back (⌘[)")
            Button {
                model.goForward()
            } label: {
                Image(systemName: "chevron.right").frame(width: 20, height: 20)
            }
            .help("Forward (⌘])")
            Button {
                model.loading ? model.stopLoading() : model.reload()
            } label: {
                Image(systemName: model.loading ? "xmark" : "arrow.clockwise")
                    .frame(width: 20, height: 20)
            }
            .help(model.loading ? "Stop loading" : "Reload (⌘R)")
            TextField("Address", text: $address)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.textPrimary)
                .focused($field, equals: .address)
                .onSubmit {
                    model.navigate(to: address)
                    returnKeyboardToPage()
                }
                .onExitCommand {
                    address = model.tabs.current?.url ?? ""
                    returnKeyboardToPage()
                }
            BrowserDownloadsButton(downloads: model.downloads)
            if let shown = model.tabs.showing, let zoom = model.zoom[shown] {
                Button("\(Int((zoom * 100).rounded()))%") { model.perform(.zoom(.reset)) }
                    .font(.system(size: 11).monospacedDigit())
                    .help("Page zoom. Click, or ⌘0, for 100%.")
            }
        }
        .buttonStyle(.chrome)
        .foregroundStyle(Color.textMuted)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .disabled(model.status != .connected)
    }

    /// Whether the operator is typing into this pane's page right now.
    private var pageHasKeyboard: Bool {
        guard let surface = model.surface else { return false }
        return surface.window?.firstResponder === surface
    }

    /// Done with the address: the keyboard goes back to the page, as a browser's does.
    private func returnKeyboardToPage() {
        field = nil
        if let surface = model.surface { surface.window?.makeFirstResponder(surface) }
    }

    @ViewBuilder
    private var notice: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 22))
                .foregroundStyle(Color.textFaint)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .textSelection(.enabled)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surface)
    }

    private var message: String {
        switch model.status {
        case let .waiting(why): why
        case .connecting: "Connecting to the shared browser…"
        case .connected: ""
        }
    }
}

// MARK: - The surface

/// Hosts the pane-owned `BrowserSurfaceView` and keeps the model pointed at it.
struct BrowserSurface: NSViewRepresentable {
    let model: BrowserPaneModel
    let holdsKeyboard: Bool

    func makeNSView(context _: Context) -> BrowserSurfaceView {
        let view = BrowserSurfaceView()
        view.model = model
        model.surface = view
        return view
    }

    func updateNSView(_ view: BrowserSurfaceView, context _: Context) {
        view.model = model
        view.claimsKeyboard = holdsKeyboard
    }
}

/// Where the tab is drawn and where the operator's hands go in.
///
/// A plain layer showing the latest screencast frame, aspect-fit. Input is mapped back from
/// the drawn rectangle to the page's CSS pixels (`BrowserGeometry`). Keys go through AppKit's
/// own text input (`interpretKeyEvents`), so the text a key types — dead keys, ⌥-characters,
/// any layout — is the operator's, and editing keys arrive as the commands his key bindings
/// name (`BrowserEditingCommand`).
final class BrowserSurfaceView: NSView, @preconcurrency NSTextInputClient {
    /// Where input goes: the pane's model, or a recorder in a test.
    weak var model: (any BrowserInputSink)?

    /// helm's intent that this pane own the keyboard. Acted on only on `false → true` and when
    /// the view gains a window — `FocusClaimingTerminalView`'s rule, for its reason: a claim
    /// that ran on every render would steal focus from the address bar.
    var claimsKeyboard = false {
        didSet {
            guard claimsKeyboard, !oldValue else { return }
            claimKeyboard()
        }
    }

    /// The clipboard ⌘C/⌘V use. The general one in the app; a private one in a test, which
    /// must not touch the operator's clipboard.
    var pasteboard: NSPasteboard = .general

    /// The key table in force, asked at each key equivalent. The operator's in the app; the
    /// built-in one in a test, which must not read his keymap file.
    var keyTable: @MainActor () -> [KeyBinding] = { Keymap.shared.table }

    /// Shows the right-click menu (`BrowserPointer.swift`); a test records it instead, since a
    /// real one tracks the mouse until it closes.
    var presentMenu: @MainActor (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: nil, at: point, in: view)
    }

    /// The page's cursor under the pointer (`BrowserCursor`).
    private(set) var pageCursor = NSCursor.arrow
    /// One cursor ask at a time; a move made while one is out is kept, the latest only.
    private var cursorAsking = false
    private var nextCursorPoint: CGPoint?
    /// Mouse events that arrived while a gesture's press waits for its listener
    /// (`BrowserGesture`), sent after the press in order; nil when no press waits.
    private var held: [BrowserPaneModel.MouseEvent]?

    private var currentFrame: BrowserFrame?
    private var markedText = ""
    private var markedSelection = NSRange(location: NSNotFound, length: 0)
    private var caretRect: CGRect?
    private var caretRequest: Task<Void, Never>?
    /// The key being interpreted, while `interpretKeyEvents` runs.
    private var pendingKey: NSEvent?
    private var pendingHandled = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
    }

    required init?(coder _: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func show(_ frame: BrowserFrame) {
        currentFrame = frame
        layer?.contents = frame.image
    }

    /// Nothing to draw: a tab whose page is stopped under a dialog has sent no frame yet.
    func clear() {
        currentFrame = nil
        layer?.contents = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claimKeyboard()
        reportViewport()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportViewport()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        reportViewport()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }

    private func reportViewport() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        model?.viewportChanged(size: bounds.size, scale: window?.backingScaleFactor ?? 2)
    }

    private func claimKeyboard() {
        guard claimsKeyboard, let window, window.firstResponder !== self else { return }
        if !window.makeFirstResponder(self) {
            NSLog(
                "helm: browser pane could not take the keyboard — %@ refused to resign",
                String(describing: window.firstResponder))
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        press(event, button: "left")
    }
    override func mouseUp(with event: NSEvent) {
        send(event, type: "mouseReleased", button: "left")
    }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        press(event, button: "right")
    }
    override func rightMouseUp(with event: NSEvent) {
        send(event, type: "mouseReleased", button: "right")
    }
    override func mouseDragged(with event: NSEvent) {
        send(event, type: "mouseMoved", button: "left")
    }
    override func mouseMoved(with event: NSEvent) {
        send(event, type: "mouseMoved", button: "none")
        askCursor(at: pagePoint(event))
    }
    /// The middle button; AppKit numbers it 2. Other buttons (back, forward) are not sent.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        window?.makeFirstResponder(self)
        press(event, button: "middle")
    }
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        send(event, type: "mouseReleased", button: "middle")
    }
    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDragged(with: event) }
        send(event, type: "mouseMoved", button: "middle")
    }

    override func cursorUpdate(with _: NSEvent) { pageCursor.set() }

    /// A press that is a gesture (`BrowserGesture`) waits for its listener on the page before
    /// it is sent; every other press goes at once.
    private func press(_ event: NSEvent, button: String) {
        finishComposition()
        guard held == nil, let model,
            let gesture = BrowserGesture(button: button, modifiers: event.modifierFlags),
            let pressed = mouseEvent(event, type: "mousePressed", button: button)
        else { return send(event, type: "mousePressed", button: button) }
        held = []
        let point = convert(event.locationInWindow, from: nil)
        Task { [weak self] in
            let report = await model.gesture(gesture) {
                model.mouse(pressed)
                for later in self?.held ?? [] { model.mouse(later) }
                self?.held = nil
            }
            guard let self, let report else { return }
            act(on: report, of: gesture, at: point)
        }
    }

    /// Asks the page for its cursor at `point`, the pane's edge outside the page being the
    /// arrow, and shows it while the pointer is over the pane.
    private func askCursor(at point: CGPoint?) {
        guard let point else {
            nextCursorPoint = nil
            return showCursor(.arrow)
        }
        guard !cursorAsking else {
            nextCursorPoint = point
            return
        }
        cursorAsking = true
        Task { [weak self] in
            var point = point
            while let self {
                showCursor(BrowserCursor.cursor(css: await model?.cursor(at: point)))
                guard let next = nextCursorPoint else { return cursorAsking = false }
                nextCursorPoint = nil
                point = next
            }
        }
    }

    private func showCursor(_ cursor: NSCursor) {
        pageCursor = cursor
        guard let window,
            bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        else { return }
        cursor.set()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = pagePoint(event) else { return }
        // DOM wheel deltas are positive when content moves up (scrolling down); AppKit's
        // scrolling deltas are the other sign. A trackpad reports pixels; a mouse wheel reports
        // lines, one per notch, and Chrome on a Mac scrolls 40 px for each (#544).
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : Self.pixelsPerWheelNotch
        model?.mouse(
            .init(
                type: "mouseWheel", x: point.x, y: point.y,
                modifiers: Self.modifiers(event.modifierFlags).rawValue,
                deltaX: -event.scrollingDeltaX * scale, deltaY: -event.scrollingDeltaY * scale))
    }

    /// Chromium's `kScrollbarPixelsPerCocoaTick`.
    private static let pixelsPerWheelNotch: CGFloat = 40

    private func send(_ event: NSEvent, type: String, button: String) {
        guard let params = mouseEvent(event, type: type, button: button) else { return }
        if held != nil {
            held?.append(params)
        } else {
            model?.mouse(params)
        }
    }

    private func mouseEvent(
        _ event: NSEvent, type: String, button: String
    ) -> BrowserPaneModel.MouseEvent? {
        guard let point = pagePoint(event) else { return nil }
        // Which buttons are down *after* this event, as a DOM `buttons` bitmask.
        let down = ["left": 1, "right": 2, "middle": 4][button] ?? 0
        return .init(
            type: type, x: point.x, y: point.y, button: button,
            buttons: type == "mouseReleased" ? 0 : down,
            clickCount: type == "mouseMoved" ? 0 : event.clickCount,
            modifiers: Self.modifiers(event.modifierFlags).rawValue)
    }

    private func pagePoint(_ event: NSEvent) -> CGPoint? {
        guard let frame = currentFrame else { return nil }
        return BrowserGeometry.pagePoint(
            convert(event.locationInWindow, from: nil), in: bounds.size,
            image: CGSize(width: frame.image.width, height: frame.image.height),
            page: frame.pageSize)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = Self.modifiers(event.modifierFlags)
        if modifiers.contains(.meta) || modifiers.contains(.control) {
            // A ⌘- or ⌃-combination no menu claimed. It types nothing; the page sees the key.
            sendKey(
                event, type: "rawKeyDown", text: nil,
                commands: Self.metaCommand(event, modifiers).map { [$0] })
            return
        }
        pendingKey = event
        pendingHandled = false
        interpretKeyEvents([event])
        // A key AppKit neither typed with nor bound to a command (F5, a bare arrow with no
        // binding) still reaches the page — unless it started a composition.
        if !pendingHandled, markedText.isEmpty {
            sendKey(event, type: "rawKeyDown", text: nil, commands: nil)
        }
        pendingKey = nil
    }

    /// A chord helm binds elsewhere but leaves to the page here (⌘K, ⌘N, ⌘D, ⌘O; #548) goes to
    /// the page now. AppKit offers a key equivalent to the key window's views before the main
    /// menu, and the menu mirrors those rows with their chords (`KeyBindingMenu`), so left to
    /// the menu ⌘K would open the palette instead of reaching the page. Every other chord goes
    /// on as before: helm's own rows were taken by the key monitor already, and one helm never
    /// binds (⌘Q, ⌘C) is the menu's.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
            KeyBindings.bindsElsewhere(
                characters: event.charactersIgnoringModifiers, keyCode: event.keyCode,
                modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
                focus: .browser, in: keyTable())
        else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event, type: "keyUp", text: nil, commands: nil)
    }

    private func sendKey(_ event: NSEvent, type: String, text: String?, commands: [String]?) {
        let key = BrowserKey(
            macKeyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers, text: text)
        model?.key(
            .init(
                type: type, modifiers: Self.modifiers(event.modifierFlags).rawValue, key: key.key,
                code: key.code, windowsVirtualKeyCode: key.windowsVirtualKeyCode,
                text: text, unmodifiedText: text,
                autoRepeat: type == "keyUp" ? nil : event.isARepeat, commands: commands))
    }

    /// The editing commands ⌘-keys stand for on a Mac, for the ones no menu item takes first.
    private static func metaCommand(_ event: NSEvent, _ modifiers: BrowserModifiers) -> String? {
        guard modifiers.contains(.meta) else { return nil }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": return "selectAll"
        case "z": return modifiers.contains(.shift) ? "redo" : "undo"
        default: return nil
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> BrowserModifiers {
        var m: BrowserModifiers = []
        if flags.contains(.option) { m.insert(.alt) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.command) { m.insert(.meta) }
        if flags.contains(.shift) { m.insert(.shift) }
        return m
    }

    // MARK: NSTextInputClient

    override func resignFirstResponder() -> Bool {
        finishComposition()
        return super.resignFirstResponder()
    }

    /// Chrome finalizes on a click independently of AppKit. Commit before focus moves,
    /// then discard AppKit's composition so the next key cannot unmark the same text again.
    private func finishComposition() {
        guard hasMarkedText() else { return }
        unmarkText()
        inputContext?.discardMarkedText()
    }

    /// A replaced input destination cannot receive the old page's preedit.
    func discardComposition() {
        clearMarkedText()
        inputContext?.discardMarkedText()
    }

    func insertText(_ string: Any, replacementRange _: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let wasComposing = hasMarkedText()
        clearMarkedText()
        guard !text.isEmpty else { return }
        if let event = pendingKey, !pendingHandled, !wasComposing, text.count == 1 {
            pendingHandled = true
            sendKey(event, type: "keyDown", text: text, commands: nil)
        } else {
            // A composition committing, or several characters from one press.
            pendingHandled = true
            model?.insertText(text)
        }
    }

    override func doCommand(by selector: Selector) {
        guard let event = pendingKey else { return }
        pendingHandled = true
        let command = BrowserEditingCommand.name(forSelector: NSStringFromSelector(selector))
        // Enter types a carriage return, as a browser's own Enter does — forms submit on it.
        let text = BrowserKey.enterText(macKeyCode: event.keyCode)
        sendKey(
            event, type: text == nil ? "rawKeyDown" : "keyDown", text: text,
            commands: command.map { [$0] })
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange _: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedSelection =
            markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0) : selectedRange
        pendingHandled = true
        model?.setComposition(markedText, selection: selectedRange)
        if markedText.isEmpty {
            clearMarkedText()
        } else {
            refreshCaret()
        }
    }

    func unmarkText() {
        guard hasMarkedText() else { return }
        model?.insertText(markedText)
        clearMarkedText()
    }

    private func clearMarkedText() {
        markedText = ""
        markedSelection = NSRange(location: NSNotFound, length: 0)
        caretRequest?.cancel()
        caretRect = nil
    }

    private func refreshCaret() {
        caretRequest?.cancel()
        caretRequest = Task { @MainActor [weak self] in
            guard let self else { return }
            let rect = await model?.textCaretRect()
            guard !Task.isCancelled else { return }
            caretRect = rect
            inputContext?.invalidateCharacterCoordinates()
        }
    }
    func hasMarkedText() -> Bool { !markedText.isEmpty }
    func markedRange() -> NSRange {
        markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedText.utf16.count)
    }
    func selectedRange() -> NSRange { markedSelection }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(
        forProposedRange _: NSRange, actualRange _: NSRangePointer?
    )
        -> NSAttributedString?
    { nil }
    func characterIndex(for _: NSPoint) -> Int { NSNotFound }
    func firstRect(forCharacterRange _: NSRange, actualRange _: NSRangePointer?) -> NSRect {
        let rect: CGRect
        if let caretRect, let frame = currentFrame {
            rect = BrowserGeometry.viewRect(
                caretRect, in: bounds.size,
                image: CGSize(width: frame.image.width, height: frame.image.height),
                page: frame.pageSize)
        } else {
            rect = bounds
        }
        return window?.convertToScreen(convert(rect, to: nil)) ?? .zero
    }
}

/// What the surface sends its input to — the seam `BrowserSurfaceTests` records at, so the
/// whole path from an `NSEvent` to the CDP event is tested without a browser.
@MainActor
protocol BrowserInputSink: AnyObject {
    func mouse(_ params: BrowserPaneModel.MouseEvent)
    func key(_ params: BrowserPaneModel.KeyEvent)
    func insertText(_ text: String)
    func paste(_ payload: BrowserPaste)
    func setComposition(_ text: String, selection: NSRange)
    func textCaretRect() async -> CGRect?
    func selectedText() async -> String?
    func viewportChanged(size: CGSize, scale: CGFloat)
    /// What a gesture landed on (`BrowserPointer.swift`); `dispatch` sends its mouse events.
    func gesture(_ gesture: BrowserGesture, dispatch: () -> Void) async -> BrowserPointerReport?
    func cursor(at point: CGPoint) async -> String?
    func open(_ url: URL)
    func perform(_ command: BrowserCommand)
}

// MARK: - The tab

/// A browser pane's tab: the page it is showing, so two glances tell the operator where an
/// agent has got to without selecting the pane.
struct BrowserTabLabel: View {
    @ObservedObject var model: BrowserPaneModel
    let slot: SurfaceSlot

    var body: some View {
        PaneTab(
            title: slot.pane.name.text ?? label, truncation: .middle,
            closeHelp: "Close the pane (the browser keeps running)", slot: slot
        ) {
            Image(systemName: "globe")
                .font(.system(size: 9))
                .foregroundStyle(model.status == .connected ? Color.accent : Color.textMuted)
        }
    }

    private var label: String {
        guard let tab = model.tabs.current else { return "Browser" }
        if !tab.title.isEmpty { return tab.title }
        return URL(string: tab.url)?.host() ?? tab.url
    }
}
