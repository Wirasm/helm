// Every libghostty-vt declaration src/ffi.rs relies on, restated against the vendored
// header. build.rs compiles this with -fsyntax-only: a redeclaration whose type differs is
// an error, and so is any failed assertion. When this fails, change ffi.rs and this file
// together; the numbers below are the ones ffi.rs asserts too.
#include <stddef.h>
#include <ghostty/vt.h>

GhosttyResult ghostty_terminal_new(const GhosttyAllocator *, GhosttyTerminal *, uint16_t,
                                   uint16_t);
void ghostty_terminal_free(GhosttyTerminal);
GhosttyResult ghostty_terminal_resize(GhosttyTerminal, uint16_t, uint16_t, uint32_t,
                                      uint32_t);
GhosttyResult ghostty_terminal_set(GhosttyTerminal, GhosttyTerminalOption, const void *);
void ghostty_terminal_vt_write(GhosttyTerminal, const uint8_t *, size_t);
GhosttyResult ghostty_terminal_get(GhosttyTerminal, GhosttyTerminalData, void *);
GhosttyResult ghostty_terminal_continuation_alloc(GhosttyTerminal, const GhosttyAllocator *,
                                                  uint8_t **, size_t *);
GhosttyResult ghostty_formatter_terminal_new(const GhosttyAllocator *, GhosttyFormatter *,
                                             GhosttyTerminal, GhosttyFormatterTerminalOptions);
GhosttyResult ghostty_formatter_format_alloc(GhosttyFormatter, const GhosttyAllocator *,
                                             uint8_t **, size_t *);
void ghostty_formatter_free(GhosttyFormatter);
void ghostty_free(const GhosttyAllocator *, uint8_t *, size_t);

// The callback types ffi.rs implements.
static void write_pty(GhosttyTerminal t, void *u, const uint8_t *d, size_t n) {
  (void)t, (void)u, (void)d, (void)n;
}
static void render_hold(GhosttyTerminal t, void *u, bool held) { (void)t, (void)u, (void)held; }
static bool device_attributes(GhosttyTerminal t, void *u, GhosttyDeviceAttributes *a) {
  (void)t, (void)u, (void)a;
  return false;
}
static GhosttyString xtversion(GhosttyTerminal t, void *u) {
  (void)t, (void)u;
  return (GhosttyString){0};
}
GhosttyTerminalWritePtyFn check_write_pty = write_pty;
GhosttyTerminalRenderHoldFn check_render_hold = render_hold;
GhosttyTerminalDeviceAttributesFn check_device_attributes = device_attributes;
GhosttyTerminalXtversionFn check_xtversion = xtversion;

#define SAME(a, b) _Static_assert((a) == (b), #a " is not " #b)

SAME(sizeof(GhosttyResult), 4);
SAME(GHOSTTY_SUCCESS, 0);
SAME(GHOSTTY_OUT_OF_MEMORY, -1);
SAME(GHOSTTY_INVALID_VALUE, -2);

SAME(sizeof(GhosttyTerminalOption), 4);
SAME(GHOSTTY_TERMINAL_OPT_USERDATA, 0);
SAME(GHOSTTY_TERMINAL_OPT_WRITE_PTY, 1);
SAME(GHOSTTY_TERMINAL_OPT_XTVERSION, 4);
SAME(GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, 8);
SAME(GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, 27);
SAME(GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, 31);
SAME(GHOSTTY_TERMINAL_OPT_MODE, 34);
SAME(GHOSTTY_TERMINAL_OPT_RENDER_HOLD, 41);

SAME(sizeof(GhosttyTerminalData), 4);
SAME(GHOSTTY_TERMINAL_DATA_COLS, 1);
SAME(GHOSTTY_TERMINAL_DATA_ROWS, 2);
SAME(GHOSTTY_TERMINAL_DATA_CURSOR_X, 3);
SAME(GHOSTTY_TERMINAL_DATA_CURSOR_Y, 4);
SAME(GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, 6);
SAME(GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, 7);
SAME(GHOSTTY_TERMINAL_DATA_TITLE, 12);
SAME(GHOSTTY_TERMINAL_DATA_PWD, 13);
SAME(GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, 15);
SAME(GHOSTTY_TERMINAL_DATA_MODE, 37);

SAME(sizeof(GhosttyTerminalScreen), 4);
SAME(GHOSTTY_TERMINAL_SCREEN_ALTERNATE, 1);
SAME(sizeof(GhosttyFormatterFormat), 4);
SAME(GHOSTTY_FORMATTER_FORMAT_PLAIN, 0);
SAME(GHOSTTY_FORMATTER_FORMAT_VT, 1);

SAME(sizeof(GhosttyMode), 2);

SAME(sizeof(GhosttyString), 16);
SAME(sizeof(GhosttyTerminalModeConfig), 4);
SAME(offsetof(GhosttyTerminalModeConfig, value), 2);

SAME(sizeof(GhosttyDeviceAttributes), 160);
SAME(offsetof(GhosttyDeviceAttributes, secondary), 144);
SAME(offsetof(GhosttyDeviceAttributes, tertiary), 152);
SAME(offsetof(GhosttyDeviceAttributesPrimary, num_features), 136);

SAME(sizeof(GhosttyFormatterScreenExtra), 16);
SAME(sizeof(GhosttyFormatterTerminalExtra), 32);
SAME(offsetof(GhosttyFormatterTerminalExtra, screen), 16);
SAME(sizeof(GhosttyFormatterTerminalOptions), 56);
SAME(offsetof(GhosttyFormatterTerminalOptions, emit), 8);
SAME(offsetof(GhosttyFormatterTerminalOptions, extra), 16);
SAME(offsetof(GhosttyFormatterTerminalOptions, selection), 48);
