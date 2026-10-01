import AppKit

/// Clipboard formats carried from the Mac to the page, rather than mistaken for typing.
struct BrowserPaste: Encodable, Equatable {
    let text: String?
    let html: String?
    let png: Data?

    init(text: String? = nil, html: String? = nil, png: Data? = nil) {
        self.text = text
        self.html = html
        self.png = png
    }

    init?(pasteboard: NSPasteboard) {
        text = pasteboard.string(forType: .string)
        html = pasteboard.string(forType: .html)
        if let data = pasteboard.data(forType: .png) {
            png = data
        } else if let data = pasteboard.data(forType: .tiff),
            let image = NSBitmapImageRep(data: data)
        {
            png = image.representation(using: .png, properties: [:])
        } else {
            png = nil
        }
        guard text != nil || html != nil || png != nil else { return nil }
    }

    /// Headless Chrome uses its own in-memory clipboard. A user gesture permits writing it
    /// without granting a site lasting clipboard permissions. HTTP pages without the API
    /// still get a cancellable clipboard event; only that fallback's event is untrusted.
    func expression() throws -> String {
        let payload = String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        return """
            (async () => {
              const p = \(payload), data = {}, transfer = new DataTransfer();
              if (p.text != null) {
                data['text/plain'] = new Blob([p.text], {type:'text/plain'});
                transfer.setData('text/plain', p.text);
              }
              if (p.html != null) {
                data['text/html'] = new Blob([p.html], {type:'text/html'});
                transfer.setData('text/html', p.html);
              }
              if (p.png) {
                const bytes = Uint8Array.from(atob(p.png), c => c.charCodeAt(0));
                data['image/png'] = new Blob([bytes], {type:'image/png'});
                transfer.items.add(new File([bytes], 'image.png', {type:'image/png'}));
              }
              if (navigator.clipboard && typeof ClipboardItem !== 'undefined') {
                try {
                  await navigator.clipboard.write([new ClipboardItem(data)]);
                  return 'native';
                } catch (_) { /* No paste has happened; use the page event below. */ }
              }
              let a = document.activeElement;
              while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement;
              const event = new ClipboardEvent('paste',
                {clipboardData:transfer, bubbles:true, cancelable:true, composed:true});
              if (!(a || document.body).dispatchEvent(event)) return 'handled';
              if (a && a.isContentEditable && p.html != null) {
                if (!document.execCommand('insertHTML', false, p.html))
                  throw new Error('The page could not insert the clipboard HTML');
                return 'handled';
              }
              return p.text != null ? 'text' : 'handled';
            })()
            """
    }
}
