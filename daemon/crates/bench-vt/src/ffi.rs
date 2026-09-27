//! The part of libghostty-vt's C API benchd uses, written by hand against the vendored
//! header (`vendor/libghostty-vt/include/ghostty/vt`). `abi.c` restates each of these
//! against that header and build.rs compiles it, so a drifted declaration fails the build.
//! The sizes asserted at the bottom are the same numbers `abi.c` asserts.

use std::ffi::c_void;

pub type Terminal = *mut c_void;
pub type Formatter = *mut c_void;
/// `GhosttyResult`, a C enum typed `int`.
pub type Result = i32;
pub const SUCCESS: Result = 0;

pub const OPT_USERDATA: i32 = 0;
pub const OPT_WRITE_PTY: i32 = 1;
pub const OPT_XTVERSION: i32 = 4;
pub const OPT_DEVICE_ATTRIBUTES: i32 = 8;
pub const OPT_SCROLLBACK_MAX_BYTES: i32 = 27;
pub const OPT_CONTINUATION_MAX_BYTES: i32 = 31;
pub const OPT_MODE: i32 = 34;
pub const OPT_RENDER_HOLD: i32 = 41;

pub const DATA_COLS: i32 = 1;
pub const DATA_ROWS: i32 = 2;
pub const DATA_CURSOR_X: i32 = 3;
pub const DATA_CURSOR_Y: i32 = 4;
pub const DATA_ACTIVE_SCREEN: i32 = 6;
pub const DATA_CURSOR_VISIBLE: i32 = 7;
pub const DATA_TITLE: i32 = 12;
pub const DATA_PWD: i32 = 13;
pub const DATA_SCROLLBACK_ROWS: i32 = 15;
pub const DATA_MODE: i32 = 37;

pub const SCREEN_ALTERNATE: i32 = 1;
pub const FORMAT_PLAIN: i32 = 0;
pub const FORMAT_VT: i32 = 1;

/// `ghostty_mode_new(value, ansi)`, a static inline in the header.
pub const fn mode(value: u16, ansi: bool) -> u16 {
    (value & 0x7FFF) | ((ansi as u16) << 15)
}

#[repr(C)]
pub struct GString {
    pub ptr: *const u8,
    pub len: usize,
}

#[repr(C)]
pub struct ModeConfig {
    pub mode: u16,
    pub value: bool,
}

#[repr(C)]
pub struct DaPrimary {
    pub conformance_level: u16,
    pub features: [u16; 64],
    pub num_features: usize,
}

#[repr(C)]
pub struct DaSecondary {
    pub device_type: u16,
    pub firmware_version: u16,
    pub rom_cartridge: u16,
}

#[repr(C)]
pub struct DaTertiary {
    pub unit_id: u32,
}

#[repr(C)]
pub struct DeviceAttributes {
    pub primary: DaPrimary,
    pub secondary: DaSecondary,
    pub tertiary: DaTertiary,
}

#[repr(C)]
pub struct ScreenExtra {
    pub size: usize,
    pub cursor: bool,
    pub style: bool,
    pub hyperlink: bool,
    pub protection: bool,
    pub kitty_keyboard: bool,
    pub charsets: bool,
}

#[repr(C)]
pub struct TerminalExtra {
    pub size: usize,
    pub palette: bool,
    pub modes: bool,
    pub scrolling_region: bool,
    pub tabstops: bool,
    pub pwd: bool,
    pub keyboard: bool,
    pub screen: ScreenExtra,
}

#[repr(C)]
pub struct FormatterOptions {
    pub size: usize,
    pub emit: i32,
    pub unwrap: bool,
    pub trim: bool,
    pub extra: TerminalExtra,
    pub selection: *const c_void,
}

pub type WritePtyFn = unsafe extern "C" fn(Terminal, *mut c_void, *const u8, usize);
pub type RenderHoldFn = unsafe extern "C" fn(Terminal, *mut c_void, bool);
pub type DeviceAttributesFn =
    unsafe extern "C" fn(Terminal, *mut c_void, *mut DeviceAttributes) -> bool;
pub type XtversionFn = unsafe extern "C" fn(Terminal, *mut c_void) -> GString;

unsafe extern "C" {
    pub fn ghostty_terminal_new(
        alloc: *const c_void,
        out: *mut Terminal,
        cols: u16,
        rows: u16,
    ) -> Result;
    pub fn ghostty_terminal_free(t: Terminal);
    pub fn ghostty_terminal_resize(
        t: Terminal,
        cols: u16,
        rows: u16,
        cell_w: u32,
        cell_h: u32,
    ) -> Result;
    pub fn ghostty_terminal_set(t: Terminal, option: i32, value: *const c_void) -> Result;
    pub fn ghostty_terminal_vt_write(t: Terminal, data: *const u8, len: usize);
    pub fn ghostty_terminal_get(t: Terminal, data: i32, out: *mut c_void) -> Result;
    pub fn ghostty_terminal_continuation_alloc(
        t: Terminal,
        alloc: *const c_void,
        out_ptr: *mut *mut u8,
        out_len: *mut usize,
    ) -> Result;
    pub fn ghostty_formatter_terminal_new(
        alloc: *const c_void,
        out: *mut Formatter,
        t: Terminal,
        options: FormatterOptions,
    ) -> Result;
    pub fn ghostty_formatter_format_alloc(
        f: Formatter,
        alloc: *const c_void,
        out_ptr: *mut *mut u8,
        out_len: *mut usize,
    ) -> Result;
    pub fn ghostty_formatter_free(f: Formatter);
    pub fn ghostty_free(alloc: *const c_void, ptr: *mut u8, len: usize);
}

const _: () = {
    use std::mem::{offset_of, size_of};
    assert!(size_of::<GString>() == 16);
    assert!(size_of::<ModeConfig>() == 4);
    assert!(offset_of!(ModeConfig, value) == 2);
    assert!(size_of::<DeviceAttributes>() == 160);
    assert!(offset_of!(DeviceAttributes, secondary) == 144);
    assert!(offset_of!(DeviceAttributes, tertiary) == 152);
    assert!(offset_of!(DaPrimary, num_features) == 136);
    assert!(size_of::<ScreenExtra>() == 16);
    assert!(size_of::<TerminalExtra>() == 32);
    assert!(offset_of!(TerminalExtra, screen) == 16);
    assert!(size_of::<FormatterOptions>() == 56);
    assert!(offset_of!(FormatterOptions, emit) == 8);
    assert!(offset_of!(FormatterOptions, extra) == 16);
    assert!(offset_of!(FormatterOptions, selection) == 48);
};
