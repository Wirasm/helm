/// Resolve a shadow leaf to its control once; answers then use that captured element.
enum BrowserFormScript {
    static let control = """
        function() {
          let e = this;
          while (e && !e.matches?.('select,input,label'))
            e = e.parentElement || e.getRootNode().host;
          if (e?.tagName === 'LABEL') e = e.control;
          if (!e || !e.isConnected || e.matches(':disabled') || e.readOnly) return null;
          return (e.tagName === 'SELECT' && !e.multiple && e.size <= 1) ||
            (e.tagName === 'INPUT' && e.type === 'date') ? e : null;
        }
        """

    static let read = """
        function() {
          const e = this;
          if (!e.isConnected || e.matches(':disabled') || e.readOnly) return null;
          if (e.tagName === 'SELECT' && !e.multiple && e.size <= 1) {
            e.focus();
            return {kind:'select', selectedIndex:e.selectedIndex,
              options:[...e.options].map((o,index) => ({index, label:
                (o.parentElement.tagName === 'OPTGROUP' ? o.parentElement.label + ' — ' : '') + o.label, value:o.value,
                disabled:o.disabled || (o.parentElement.tagName === 'OPTGROUP' && o.parentElement.disabled)}))};
          }
          if (e.tagName === 'INPUT' && e.type === 'date') {
            e.focus();
            return {kind:'date', value:e.value, min:e.min, max:e.max};
          }
          return null;
        }
        """

    /// Give page handlers the pointer gesture before opening our UI. Cancelling the gesture
    /// leaves a page's own widget in charge. Synthetic clicks do not open Chrome's native menu.
    static let activate = """
        function() {
          const r = this.getBoundingClientRect(), w = this.ownerDocument.defaultView;
          const p = {bubbles:true, cancelable:true, composed:true, button:0,
            clientX:r.x+r.width/2, clientY:r.y+r.height/2, pointerType:'mouse'};
          let allowed = true;
          for (const type of ['pointerdown','mousedown','pointerup','mouseup','click']) {
            const C = type.startsWith('pointer') ? w.PointerEvent : w.MouseEvent;
            if (!this.dispatchEvent(new C(type,p))) allowed = false;
          }
          return allowed;
        }
        """

    static let commit = """
        function(answer) {
          const e = this;
          if (!e.isConnected || e.matches(':disabled') || e.readOnly) return 'This field is no longer editable.';
          let old = e.value;
          if (answer.index != null && e.tagName === 'SELECT' && !e.multiple && e.size <= 1) {
            const o = e.options[answer.index];
            if (!o || o.disabled || (o.parentElement.tagName === 'OPTGROUP' && o.parentElement.disabled))
              return 'This option is no longer available.';
            const label = (o.parentElement.tagName === 'OPTGROUP' ? o.parentElement.label + ' — ' : '') + o.label;
            if (o.value !== answer.value || label !== answer.label) return 'The options have changed. Reopen this picker.';
            old = e.selectedIndex;
            Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'selectedIndex').set.call(e, answer.index);
            if (e.selectedIndex === old) return 'ok';
          } else if (answer.value != null && e.tagName === 'INPUT' && e.type === 'date') {
            const check = e.cloneNode();
            check.value = answer.value;
            if (check.value !== answer.value || check.validity.rangeUnderflow ||
                check.validity.rangeOverflow || check.validity.stepMismatch)
              return 'Choose a date allowed by this field.';
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(e, answer.value);
            if (e.value === old) return 'ok';
          } else return 'This field has changed.';
          e.dispatchEvent(new Event('input', {bubbles:true, composed:true}));
          e.dispatchEvent(new Event('change', {bubbles:true}));
          return 'ok';
        }
        """
}
