import Foundation

/// CDP uses UTF-16 offsets, just like AppKit's NSRange. Omitted replacement offsets let
/// Chrome replace its current composition rather than treating a local marked range as
/// an absolute offset in the page's document.
struct BrowserComposition: Encodable {
    let text: String
    let selectionStart: Int
    let selectionEnd: Int

    init(text: String, selection: NSRange) {
        self.text = text
        selectionStart = min(selection.location, text.utf16.count)
        selectionEnd = selectionStart + min(selection.length, text.utf16.count - selectionStart)
    }
}

enum BrowserTextInput {
    static func viewRect(_ rect: CGRect, in view: CGSize, image: CGSize, page: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, page.width > 0, page.height > 0 else {
            return .zero
        }
        let scale = min(view.width / image.width, view.height / image.height)
        let width = image.width * scale
        let height = image.height * scale
        return CGRect(
            x: (view.width - width) / 2 + rect.minX * width / page.width,
            y: (view.height - height) / 2 + rect.minY * height / page.height,
            width: max(1, rect.width * width / page.width),
            height: rect.height * height / page.height)
    }

    /// Text controls do not expose a DOM Range at their caret. A transient, invisible mirror
    /// uses their computed typography and wrapping; it never changes the control or selection.
    static let caretExpression = """
        (() => {
          const a = document.activeElement;
          if (!a) return null;
          const pack = r => ({x:r.x, y:r.y, width:r.width, height:r.height});
          if (typeof a.selectionStart !== 'number') {
            const s = getSelection();
            if (!s || !s.rangeCount) return null;
            const r = s.getRangeAt(0).cloneRange(); r.collapse(false);
            return pack(r.getBoundingClientRect());
          }
          const style = getComputedStyle(a), box = a.getBoundingClientRect();
          const mirror = document.createElement('div');
          for (const name of style) mirror.style.setProperty(name, style.getPropertyValue(name));
          Object.assign(mirror.style, {position:'fixed', visibility:'hidden',
            left:box.left+'px', top:box.top+'px', width:box.width+'px',
            height:'auto', transform:'none', overflow:'visible',
            whiteSpace:a.tagName === 'INPUT' ? 'pre' : 'pre-wrap'});
          mirror.textContent = a.value.slice(0, a.selectionEnd);
          const marker = document.createElement('span');
          marker.textContent = '\\u200b'; mirror.append(marker);
          document.body.append(mirror);
          try {
            const r = marker.getBoundingClientRect();
            return {x:r.x-a.scrollLeft, y:r.y-a.scrollTop, width:1,
              height:r.height || parseFloat(style.lineHeight) || parseFloat(style.fontSize)};
          } finally { mirror.remove(); }
        })()
        """
}
