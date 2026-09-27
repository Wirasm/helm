//! benchd's VT engine: one libghostty-vt terminal per session, at helm's Ghostty commit, so
//! what benchd reads off a session is what the operator's Ghostty draws from the same bytes.
//!
//! [`Terminal`] is `!Send`: a session keeps its terminal on one thread and feeds it there.

mod ffi;

use std::ffi::c_void;
use std::marker::PhantomData;
use std::ptr;

/// A libghostty-vt call that failed, with the call and its result code.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    pub call: &'static str,
    pub code: i32,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "libghostty-vt {} failed ({})", self.call, self.code)
    }
}

impl std::error::Error for Error {}

fn check(call: &'static str, code: ffi::Result) -> Result<(), Error> {
    if code == ffi::SUCCESS {
        Ok(())
    } else {
        Err(Error { call, code })
    }
}

/// What the terminal said while bytes were written to it. Lives behind the userdata pointer.
#[derive(Default)]
struct Effects {
    /// Answers to queries (DA, DSR, mode reports, …), in order, for the pty.
    replies: Vec<u8>,
    /// Inside a synchronized update (mode 2026): the screen is mid-frame.
    held: bool,
}

/// DEC private mode 2026, synchronized output.
const SYNC_OUTPUT: u16 = ffi::mode(2026, false);

/// A mode to ask the terminal about.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// DEC private mode `?n`.
    Dec(u16),
    /// ANSI mode `n`.
    Ansi(u16),
}

impl Mode {
    pub const BRACKETED_PASTE: Mode = Mode::Dec(2004);

    fn packed(self) -> u16 {
        match self {
            Mode::Dec(n) => ffi::mode(n, false),
            Mode::Ansi(n) => ffi::mode(n, true),
        }
    }
}

/// How [`Terminal::format`] writes the screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    /// Text only, soft wraps joined, trailing blanks trimmed: for reading.
    Plain,
    /// The escape sequences that redraw this screen in a fresh terminal of the same size:
    /// scrollback and screen, styles, hyperlinks, the modes that differ from their defaults,
    /// scrolling region, pwd, keyboard modes, palette and cursor.
    Vt,
}

pub struct Terminal {
    raw: ffi::Terminal,
    effects: Box<Effects>,
    _not_send: PhantomData<*mut ()>,
}

impl Terminal {
    /// A terminal of `cols` × `rows` keeping at most `scrollback_bytes` of history.
    pub fn new(cols: u16, rows: u16, scrollback_bytes: usize) -> Result<Terminal, Error> {
        let mut raw = ptr::null_mut();
        check("terminal_new", unsafe {
            ffi::ghostty_terminal_new(ptr::null(), &mut raw, cols.max(1), rows.max(1))
        })?;
        let mut t = Terminal {
            raw,
            effects: Box::default(),
            _not_send: PhantomData,
        };
        let userdata: *mut Effects = &mut *t.effects;
        t.set("userdata", ffi::OPT_USERDATA, userdata as *const c_void)?;
        t.set(
            "write_pty",
            ffi::OPT_WRITE_PTY,
            on_write_pty as ffi::WritePtyFn as *const c_void,
        )?;
        t.set(
            "render_hold",
            ffi::OPT_RENDER_HOLD,
            on_render_hold as ffi::RenderHoldFn as *const c_void,
        )?;
        t.set(
            "device_attributes",
            ffi::OPT_DEVICE_ATTRIBUTES,
            on_device_attributes as ffi::DeviceAttributesFn as *const c_void,
        )?;
        t.set(
            "xtversion",
            ffi::OPT_XTVERSION,
            on_xtversion as ffi::XtversionFn as *const c_void,
        )?;
        let bytes = scrollback_bytes;
        t.set(
            "scrollback_max_bytes",
            ffi::OPT_SCROLLBACK_MAX_BYTES,
            &bytes as *const usize as *const c_void,
        )?;
        // Enough for any sequence cut off mid-write; replay appends it after the screen.
        let continuation: usize = 64 * 1024;
        t.set(
            "continuation_max_bytes",
            ffi::OPT_CONTINUATION_MAX_BYTES,
            &continuation as *const usize as *const c_void,
        )?;
        Ok(t)
    }

    fn set(&mut self, what: &'static str, option: i32, value: *const c_void) -> Result<(), Error> {
        check(what, unsafe {
            ffi::ghostty_terminal_set(self.raw, option, value)
        })
    }

    /// Feed bytes the program wrote.
    pub fn write(&mut self, bytes: &[u8]) {
        unsafe { ffi::ghostty_terminal_vt_write(self.raw, bytes.as_ptr(), bytes.len()) }
    }

    /// Answers to queries written so far, taken: what a terminal would send back to the program.
    pub fn take_replies(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.effects.replies)
    }

    /// Whether the program is inside a synchronized update, so the screen is mid-frame.
    pub fn held(&self) -> bool {
        self.effects.held
    }

    /// End a synchronized update the program has not ended, as Ghostty does after a second.
    pub fn release_hold(&mut self) -> Result<(), Error> {
        let config = ffi::ModeConfig {
            mode: SYNC_OUTPUT,
            value: false,
        };
        self.set("mode", ffi::OPT_MODE, &config as *const _ as *const c_void)?;
        self.effects.held = false;
        Ok(())
    }

    /// Set the default colours, which OSC 10 and 11 report.
    pub fn set_default_colors(&mut self, fg: [u8; 3], bg: [u8; 3]) -> Result<(), Error> {
        let fg = ffi::Rgb {
            r: fg[0],
            g: fg[1],
            b: fg[2],
        };
        let bg = ffi::Rgb {
            r: bg[0],
            g: bg[1],
            b: bg[2],
        };
        self.set(
            "color_foreground",
            ffi::OPT_COLOR_FOREGROUND,
            &fg as *const _ as *const c_void,
        )?;
        self.set(
            "color_background",
            ffi::OPT_COLOR_BACKGROUND,
            &bg as *const _ as *const c_void,
        )
    }

    pub fn resize(&mut self, cols: u16, rows: u16) -> Result<(), Error> {
        check("terminal_resize", unsafe {
            ffi::ghostty_terminal_resize(self.raw, cols.max(1), rows.max(1), 0, 0)
        })
    }

    fn get<T: Default>(&self, data: i32) -> T {
        let mut out = T::default();
        // Every key read here is valid for any live terminal; a failure leaves the default.
        unsafe { ffi::ghostty_terminal_get(self.raw, data, &mut out as *mut T as *mut c_void) };
        out
    }

    /// (cols, rows).
    pub fn size(&self) -> (u16, u16) {
        (self.get(ffi::DATA_COLS), self.get(ffi::DATA_ROWS))
    }

    /// The cursor's (column, row) on the screen, from zero.
    pub fn cursor(&self) -> (u16, u16) {
        (self.get(ffi::DATA_CURSOR_X), self.get(ffi::DATA_CURSOR_Y))
    }

    pub fn cursor_visible(&self) -> bool {
        self.get(ffi::DATA_CURSOR_VISIBLE)
    }

    /// Whether the alternate screen is the active one: a full-screen program is running.
    pub fn alt_screen(&self) -> bool {
        self.get::<i32>(ffi::DATA_ACTIVE_SCREEN) == ffi::SCREEN_ALTERNATE
    }

    pub fn title(&self) -> String {
        self.string(ffi::DATA_TITLE)
    }

    pub fn pwd(&self) -> String {
        self.string(ffi::DATA_PWD)
    }

    fn string(&self, data: i32) -> String {
        let mut s = ffi::GString {
            ptr: ptr::null(),
            len: 0,
        };
        let code =
            unsafe { ffi::ghostty_terminal_get(self.raw, data, &mut s as *mut _ as *mut c_void) };
        if code != ffi::SUCCESS || s.ptr.is_null() || s.len == 0 {
            return String::new();
        }
        let bytes = unsafe { std::slice::from_raw_parts(s.ptr, s.len) };
        String::from_utf8_lossy(bytes).into_owned()
    }

    pub fn mode(&self, mode: Mode) -> bool {
        let mut config = ffi::ModeConfig {
            mode: mode.packed(),
            value: false,
        };
        let code = unsafe {
            ffi::ghostty_terminal_get(
                self.raw,
                ffi::DATA_MODE,
                &mut config as *mut _ as *mut c_void,
            )
        };
        code == ffi::SUCCESS && config.value
    }

    /// The whole active screen, history included, as `format` says.
    pub fn format(&self, format: Format) -> Result<Vec<u8>, Error> {
        let vt = format == Format::Vt;
        let options = ffi::FormatterOptions {
            size: size_of::<ffi::FormatterOptions>(),
            emit: if vt {
                ffi::FORMAT_VT
            } else {
                ffi::FORMAT_PLAIN
            },
            unwrap: !vt,
            trim: !vt,
            extra: ffi::TerminalExtra {
                size: size_of::<ffi::TerminalExtra>(),
                palette: vt,
                modes: vt,
                scrolling_region: vt,
                // A fresh terminal's tabstops are the defaults; programs that move them are rare
                // and the sequence is long.
                tabstops: false,
                pwd: vt,
                keyboard: vt,
                screen: ffi::ScreenExtra {
                    size: size_of::<ffi::ScreenExtra>(),
                    cursor: vt,
                    style: vt,
                    hyperlink: vt,
                    protection: vt,
                    kitty_keyboard: vt,
                    charsets: vt,
                },
            },
            selection: ptr::null(),
        };
        let mut formatter = ptr::null_mut();
        check("formatter_terminal_new", unsafe {
            ffi::ghostty_formatter_terminal_new(ptr::null(), &mut formatter, self.raw, options)
        })?;
        let mut out = ptr::null_mut();
        let mut len = 0usize;
        let code = unsafe {
            ffi::ghostty_formatter_format_alloc(formatter, ptr::null(), &mut out, &mut len)
        };
        unsafe { ffi::ghostty_formatter_free(formatter) };
        check("formatter_format_alloc", code)?;
        Ok(unsafe { take_alloc(out, len) })
    }

    /// The bytes of a sequence the program has begun and not finished, to append after a
    /// [`Format::Vt`] replay so the rest of it lands in the new terminal whole.
    pub fn continuation(&self) -> Result<Vec<u8>, Error> {
        let mut out = ptr::null_mut();
        let mut len = 0usize;
        check("continuation_alloc", unsafe {
            ffi::ghostty_terminal_continuation_alloc(self.raw, ptr::null(), &mut out, &mut len)
        })?;
        Ok(unsafe { take_alloc(out, len) })
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        unsafe { ffi::ghostty_terminal_free(self.raw) }
    }
}

/// Copy out and free a buffer libghostty-vt allocated with the default allocator.
unsafe fn take_alloc(ptr: *mut u8, len: usize) -> Vec<u8> {
    if ptr.is_null() {
        return Vec::new();
    }
    let v = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
    unsafe { ffi::ghostty_free(ptr::null(), ptr, len) };
    v
}

unsafe extern "C" fn on_write_pty(
    _: ffi::Terminal,
    userdata: *mut c_void,
    data: *const u8,
    len: usize,
) {
    let effects = unsafe { &mut *(userdata as *mut Effects) };
    effects
        .replies
        .extend_from_slice(unsafe { std::slice::from_raw_parts(data, len) });
}

unsafe extern "C" fn on_render_hold(_: ffi::Terminal, userdata: *mut c_void, held: bool) {
    unsafe { &mut *(userdata as *mut Effects) }.held = held;
}

/// What Ghostty answers (`termio/stream_handler.zig`): a VT220 with colour text, and for DA2
/// `1;10;0`. Clipboard access (52) is left out: benchd has no clipboard to offer.
unsafe extern "C" fn on_device_attributes(
    _: ffi::Terminal,
    _: *mut c_void,
    out: *mut ffi::DeviceAttributes,
) -> bool {
    let out = unsafe { &mut *out };
    out.primary.conformance_level = 62;
    out.primary.features[0] = 22;
    out.primary.num_features = 1;
    out.secondary = ffi::DaSecondary {
        device_type: 1,
        firmware_version: 10,
        rom_cartridge: 0,
    };
    out.tertiary = ffi::DaTertiary { unit_id: 0 };
    true
}

unsafe extern "C" fn on_xtversion(_: ffi::Terminal, _: *mut c_void) -> ffi::GString {
    const NAME: &[u8] = b"ghostty";
    ffi::GString {
        ptr: NAME.as_ptr(),
        len: NAME.len(),
    }
}

#[cfg(test)]
mod tests;
