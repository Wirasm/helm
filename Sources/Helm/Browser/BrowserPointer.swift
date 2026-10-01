import AppKit
import Foundation

// What is under the operator's pointer in a browser pane (#610): a ⌘- or middle-clicked link
// opens as his tab, a right-click gets a native menu, and the cursor follows the page.
//
// CDP says none of this, so the pane asks the page. A gesture still reaches the page as a real
// `Input.dispatchMouseEvent`, so a site's own menu and click handlers keep working; the pane only
// arms a one-shot listener first, which runs after the page's handlers and reports what the
// gesture landed on and whether the page claimed it (`preventDefault`). Measured against headless
// Chrome 154: the listener sees `click`, `auxclick` and `contextmenu` (⌃-click included), and its
// own `preventDefault` stops the tab Chrome would otherwise open for a ⌘- or middle-click. That
// tab has no opener, so the pane could not tell it from an agent's and would leave it badged in
// the strip (#543). The pane opens the link itself instead, through `BrowserPaneModel.open`.
//
// Limits: the listener is on the top document, so a click inside an iframe gets Chrome's own
// behaviour, as does one whose propagation the page stops.

/// A press the pane asks the page about before it lands.
enum BrowserGesture: Equatable {
    /// ⌘-click: opens a link as a new tab.
    case commandClick
    /// Middle-click: the same.
    case middleClick
    /// Right-click or ⌃-click: the native menu, unless the page draws its own.
    case contextMenu

    /// The gesture a press starts, or nil for a press that is only a press.
    init?(button: String, modifiers: NSEvent.ModifierFlags) {
        switch button {
        case "middle": self = .middleClick
        case "right": self = .contextMenu
        case "left" where modifiers.contains(.control): self = .contextMenu
        case "left" where modifiers.contains(.command): self = .commandClick
        default: return nil
        }
    }

    var opensLinks: Bool { self != .contextMenu }

    /// A promise for the gesture's DOM event: `BrowserPointerReport` once it fires, null after
    /// 10 s without one. An event of the same name that is not this gesture (a plain click) is
    /// left alone. Only a link the page did not claim, and only for the two open gestures, is
    /// claimed here, so the pane must then open it.
    var armScript: String {
        let (name, matches) =
            switch self {
            case .commandClick: ("click", "e.metaKey")
            case .middleClick: ("auxclick", "e.button === 1")
            case .contextMenu: ("contextmenu", "true")
            }
        return """
            new Promise(done => {
              const name = '\(name)';
              const timer = setTimeout(() => { removeEventListener(name, on); done(null); }, 10000);
              function on(e) {
                if (!(\(matches))) return;
                removeEventListener(name, on);
                clearTimeout(timer);
                const t = e.target instanceof Element ? e.target : null;
                const a = t && t.closest('a[href]');
                const link = a && typeof a.href === 'string' ? a.href : null;
                const prevented = e.defaultPrevented;
                const claimed = \(opensLinks) && !prevented && !!link && /^https?:/i.test(link);
                if (claimed) e.preventDefault();
                if (\(opensLinks))
                  return done({ prevented, link, claimed, selection: '', editable: false });
                const f = document.activeElement;
                const field = !!f && typeof f.selectionStart === 'number' && typeof f.value === 'string';
                const selection = field
                  ? f.value.substring(f.selectionStart, f.selectionEnd) : String(getSelection());
                const editable = !!t && (t.isContentEditable || (t.matches('textarea, input:not('
                  + '[type=checkbox],[type=radio],[type=button],[type=submit],[type=reset],'
                  + '[type=file],[type=image],[type=range],[type=color],[type=hidden])')
                  && !t.readOnly && !t.disabled));
                done({ prevented, link, claimed, selection, editable });
              }
              addEventListener(name, on);
            })
            """
    }
}

/// What a gesture landed on, from the page (`BrowserGesture.armScript`).
struct BrowserPointerReport: Decodable, Equatable {
    /// The page claimed the event: its own menu, its own click handling.
    let prevented: Bool
    /// The link under the pointer, resolved to an absolute URL.
    let link: String?
    /// The listener stopped Chrome opening `link`, so the pane must.
    let claimed: Bool
    /// The page's selection, and whether the pointer is on a field that takes typing: asked for
    /// the menu only, so empty and false for the open gestures.
    let selection: String
    let editable: Bool
}

/// The page's CSS cursor as a Mac cursor.
enum BrowserCursor {
    /// The computed `cursor` under a point; `auto` resolved to `text` over text or a field and
    /// to `default` elsewhere, as the browser itself would.
    static func script(at point: CGPoint) -> String {
        """
        ((x, y) => {
          const e = document.elementFromPoint(x, y);
          if (!e) return 'default';
          const c = getComputedStyle(e).cursor.split(',').pop().trim();
          if (c !== 'auto') return c;
          if (e.isContentEditable) return 'text';
          const r = document.caretRangeFromPoint(x, y);
          const n = r && r.startContainer;
          if (!n || n.nodeType !== Node.TEXT_NODE) return 'default';
          const range = document.createRange();
          range.selectNodeContents(n);
          for (const b of range.getClientRects())
            if (x >= b.left && x <= b.right && y >= b.top && y <= b.bottom) return 'text';
          return 'default';
        })(\(point.x), \(point.y))
        """
    }

    static func cursor(css: String?) -> NSCursor {
        switch css {
        case "pointer": .pointingHand
        case "text": .iBeam
        case "vertical-text": .iBeamCursorForVerticalLayout
        case "crosshair": .crosshair
        case "grab": .openHand
        case "grabbing": .closedHand
        case "not-allowed", "no-drop": .operationNotAllowed
        case "copy": .dragCopy
        case "alias": .dragLink
        case "context-menu": .contextualMenu
        case "col-resize", "ew-resize", "e-resize", "w-resize": .resizeLeftRight
        case "row-resize", "ns-resize", "n-resize", "s-resize": .resizeUpDown
        default: .arrow
        }
    }
}

/// The native right-click menu: Chrome's basics, without Inspect.
enum BrowserContextMenu {
    enum Item: Equatable {
        case openLink(URL)
        case copyLink(String)
        case copy(String)
        case paste
        case back
        case forward
        case reload

        var title: String {
            switch self {
            case .openLink: "Open Link in New Tab"
            case .copyLink: "Copy Link"
            case .copy: "Copy"
            case .paste: "Paste"
            case .back: "Back"
            case .forward: "Forward"
            case .reload: "Reload"
            }
        }
    }

    /// What fits under the pointer: the link's items, Copy for a selection, Paste in a field
    /// when there is text to paste, and the page's own Back, Forward, Reload when none of those
    /// apply. Nothing when the page drew its own menu.
    static func items(for report: BrowserPointerReport, canPaste: Bool) -> [Item] {
        guard !report.prevented else { return [] }
        var items: [Item] = []
        if let link = report.link {
            // Web links only, the rule `armScript` claims by: a tab is no place for a mailto:.
            if let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) {
                items.append(.openLink(url))
            }
            items.append(.copyLink(link))
        }
        if !report.selection.isEmpty { items.append(.copy(report.selection)) }
        if report.editable, canPaste { items.append(.paste) }
        return items.isEmpty ? [.back, .forward, .reload] : items
    }
}

// MARK: - Asking the page

extension BrowserPaneModel {
    /// Arms the gesture's listener on the page, has `dispatch` send the gesture's mouse events,
    /// and returns what the listener reported. `dispatch` always runs, even when the page cannot
    /// be asked (a dialog, no browser): the click then lands as a plain click.
    func gesture(_ gesture: BrowserGesture, dispatch: () -> Void) async -> BrowserPointerReport? {
        let armed = await inputCall(
            "Runtime.evaluate", Evaluate(expression: gesture.armScript, returnByValue: false),
            returning: Armed.self)
        dispatch()
        guard let promise = armed?.result.objectId else { return nil }
        let report = await inputCall(
            "Runtime.awaitPromise", AwaitPromise(promiseObjectId: promise, returnByValue: true),
            returning: Evaluated<BrowserPointerReport>.self)
        Task {
            _ = await inputCall(
                "Runtime.releaseObject", Release(objectId: promise),
                returning: CDPConnection.Ignored.self)
        }
        return report?.result.value
    }

    /// The page's CSS cursor at a point in its viewport, or nil when it cannot be asked.
    func cursor(at point: CGPoint) async -> String? {
        await inputCall(
            "Runtime.evaluate",
            Evaluate(expression: BrowserCursor.script(at: point), returnByValue: true),
            returning: Evaluated<String>.self)?.result.value
    }
}

private struct Armed: Decodable {
    struct Remote: Decodable { let objectId: String? }
    let result: Remote
}
private struct AwaitPromise: Encodable {
    let promiseObjectId: String
    let returnByValue: Bool
}
private struct Release: Encodable { let objectId: String }

// MARK: - Acting on the report

extension BrowserSurfaceView {
    /// What the pane does once the page has said what a gesture landed on.
    func act(on report: BrowserPointerReport, of gesture: BrowserGesture, at point: NSPoint) {
        if gesture.opensLinks {
            if report.claimed, let link = report.link, let url = URL(string: link) {
                model?.open(url)
            }
            return
        }
        let items = BrowserContextMenu.items(
            for: report, canPaste: pasteboard.string(forType: .string)?.isEmpty == false)
        guard !items.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            let entry = NSMenuItem(
                title: item.title, action: #selector(choseMenuItem(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item
            menu.addItem(entry)
        }
        presentMenu(menu, point, self)
    }

    @objc private func choseMenuItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? BrowserContextMenu.Item else { return }
        perform(item)
    }

    func perform(_ item: BrowserContextMenu.Item) {
        switch item {
        case let .openLink(url): model?.open(url)
        case let .copyLink(text), let .copy(text):
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .paste: paste(nil)
        case .back: model?.perform(.back)
        case .forward: model?.perform(.forward)
        case .reload: model?.perform(.reload)
        }
    }
}
