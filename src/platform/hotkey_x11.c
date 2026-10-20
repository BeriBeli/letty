#ifdef __linux__
#include "hotkey_internal.h"
#include "compat.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
/* Minimal public Xlib ABI (Xlib.h, The Open Group MIT permission): no X11
 * headers or libraries become build/runtime dependencies on other platforms. */
typedef struct _XDisplay Display;
typedef unsigned long Window, KeySym;
typedef unsigned char KeyCode;
typedef struct {
  int type; unsigned long serial; int send_event; Display *display;
  Window window, root, subwindow; unsigned long time;
  int x, y, x_root, y_root; unsigned int state, keycode; int same_screen;
} KeyEvent;
typedef struct {
  int type; Display *display; unsigned long resourceid, serial;
  unsigned char error_code, request_code, minor_code;
} ErrorEvent;
typedef union { int type; KeyEvent key; long pad[24]; } Event;
typedef struct { int max_keypermod; KeyCode *modifiermap; } ModifierMap;
typedef int (*ErrorHandler)(Display *, ErrorEvent *);
typedef struct {
  uint32_t key, mods; unsigned int code, native_mods;
  uint64_t token, handle; unsigned long min_serial; bool pressed;
} Registration;
typedef struct {
  void *lib, *glib; Display *display;
  unsigned source, idle_source; int fd, screens;
  bool dead;
  Window roots[8];
  unsigned lock_masks[8], lock_count, ignored_locks, alt_mask, super_mask;
  int (*close_display)(Display *);
  int (*connection)(Display *);
  unsigned long (*next_request)(Display *);
  int (*screen_count)(Display *);
  Window (*root)(Display *, int);
  KeyCode (*keysym_code)(Display *, KeySym);
  KeySym (*keycode_sym)(Display *, KeyCode, int, int);
  ModifierMap *(*modifier_map)(Display *);
  int (*free_modifier_map)(ModifierMap *);
  int (*grab)(Display *, int, unsigned int, Window, int, int, int);
  int (*ungrab)(Display *, int, unsigned int, Window);
  int (*sync)(Display *, int);
  ErrorHandler (*set_error_handler)(ErrorHandler);
  int (*pending)(Display *);
  int (*next)(Display *, Event *);
  int (*peek)(Display *, Event *);
  unsigned (*idle_add)(int, int (*)(void *), void *, void (*)(void *));
  Registration entries[LT_HOTKEY_NATIVE_LIMIT];
  uint64_t next_handle;
  unsigned request_error;
  ErrorHandler previous_error;
} X11;
static X11 *error_scope; /* serialized main-thread XSync error scope */
static int on_error(Display *display, ErrorEvent *error) {
  X11 *x = error_scope;
  if (x && x->display == display) { x->request_error = error->error_code; return 0; }
  return x && x->previous_error ? x->previous_error(display, error) : 0;
}
static void begin_request(X11 *x) {
  x->sync(x->display, 0); x->request_error = 0;
  error_scope = x; x->previous_error = x->set_error_handler(on_error);
}
static unsigned end_request(X11 *x) {
  x->sync(x->display, 0); x->set_error_handler(x->previous_error); error_scope = NULL;
  return x->request_error;
}
int lt_hotkey_platform_capability(char *out, size_t cap) {
  const char *session = getenv("XDG_SESSION_TYPE"), *wayland = getenv("WAYLAND_DISPLAY"), *display = getenv("DISPLAY");
  const char *reason = NULL;
  int rc = LT_HOTKEY_UNSUPPORTED;
  if ((session && !strcmp(session, "wayland")) || (wayland && *wayland)) reason = "Global hotkeys require an X11 session; Wayland/Xwayland registration is unsupported";
  else if (!display || !*display) reason = "Global hotkeys require DISPLAY; no X11 session is available";
  else {
    void *lib = dlopen("libX11.so.6", RTLD_NOW | RTLD_LOCAL);
    bool yes = lib && dlsym(lib, "XOpenDisplay") && dlsym(lib, "XGrabKey");
    if (lib) dlclose(lib);
    rc = yes ? LT_HOTKEY_OK : LT_HOTKEY_UNAVAILABLE;
    reason = yes ? "X11 passive grabs available; server connection and shortcut ownership are checked when enabled" : "libX11.so.6 or XGrabKey unavailable";
  }
  if (out && cap) snprintf(out, cap, "%s", reason);
  return rc;
}
static unsigned modifier_mask(X11 *x, ModifierMap *map, KeySym symbol) {
  KeyCode code = x->keysym_code(x->display, symbol);
  unsigned result = 0;
  if (code) for (int mod = 0; mod < 8; ++mod) for (int key = 0; key < map->max_keypermod; ++key)
    if (map->modifiermap[mod * map->max_keypermod + key] == code) result |= 1u << mod;
  return result;
}
static bool process(LtHotkeyBackend *b) {
  X11 *x = b->platform;
  unsigned count = 0;
  while (!x->dead && count++ < 256 && x->pending(x->display)) {
    Event event;
    x->next(x->display, &event);
    if (event.type != 2 && event.type != 3) continue;
    /* Ignore synthetic events and legacy auto-repeat release/press pairs. */
    if (event.key.send_event) continue;
    if (event.type == 3 && x->pending(x->display)) {
      Event next; x->peek(x->display, &next);
      if (next.type == 2 && next.key.keycode == event.key.keycode && next.key.time == event.key.time) {
        x->next(x->display, &next); continue;
      }
    }
    for (unsigned i = 0; i < LT_HOTKEY_NATIVE_LIMIT; ++i) {
      Registration *entry = &x->entries[i];
      if (!entry->handle || event.key.keycode != entry->code || event.key.serial < entry->min_serial) continue;
      if (event.type == 3) { entry->pressed = false; continue; }
      if ((event.key.state & (255u & ~x->ignored_locks)) != entry->native_mods || entry->pressed) continue;
      entry->pressed = true;
      if (b->callback) b->callback(b->context, entry->token);
    }
  }
  return !x->dead && x->pending(x->display) != 0;
}
static int on_idle(void *ctx) {
  LtHotkeyBackend *b = ctx;
  X11 *x = b->platform;
  if (process(b)) return 1;
  x->idle_source = 0; return 0;
}
static int on_fd(int fd, unsigned flags, void *ctx) {
  (void)fd;
  LtHotkeyBackend *b = ctx;
  X11 *x = b->platform;
  if (flags & (8 | 16 | 32)) {
    x->dead = true; x->source = 0;
    if (x->idle_source) { lt_unwatch(x->idle_source); x->idle_source = 0; }
    lt_hotkey_diag(b, LT_HOTKEY_UNAVAILABLE, "X11 hotkey connection closed; disable and enable global bindings to reconnect");
    return 0;
  }
  if (!x->idle_source && process(b)) x->idle_source = x->idle_add(200, on_idle, b, NULL);
  return 1;
}
#define LOAD(target, lib, symbol) do { *(void **)(&(target)) = dlsym((lib), (symbol)); if (!(target)) return lt_hotkey_diag(b, LT_HOTKEY_UNAVAILABLE, "Missing X11/GLib function: " symbol); } while (0)
int lt_hotkey_platform_open(LtHotkeyBackend *b) {
  int rc = lt_hotkey_platform_capability(b->diagnostic, sizeof b->diagnostic);
  if (rc) return rc;
  X11 *x = calloc(1, sizeof *x);
  if (!x) return lt_hotkey_diag(b, LT_HOTKEY_SYSTEM, "X11 hotkey allocation failed");
  x->fd = -1; x->next_handle = 1; b->platform = x;
  x->lib = dlopen("libX11.so.6", RTLD_NOW | RTLD_LOCAL);
  x->glib = dlopen("libglib-2.0.so.0", RTLD_NOW | RTLD_LOCAL);
  if (!x->lib || !x->glib) return lt_hotkey_diag(b, LT_HOTKEY_UNAVAILABLE, "X11 or GLib runtime library unavailable");
  Display *(*open_display)(const char *);
  LOAD(open_display, x->lib, "XOpenDisplay"); LOAD(x->close_display, x->lib, "XCloseDisplay");
  LOAD(x->connection, x->lib, "XConnectionNumber"); LOAD(x->next_request, x->lib, "XNextRequest"); LOAD(x->screen_count, x->lib, "XScreenCount"); LOAD(x->root, x->lib, "XRootWindow");
  LOAD(x->keysym_code, x->lib, "XKeysymToKeycode"); LOAD(x->keycode_sym, x->lib, "XkbKeycodeToKeysym"); LOAD(x->modifier_map, x->lib, "XGetModifierMapping"); LOAD(x->free_modifier_map, x->lib, "XFreeModifiermap");
  LOAD(x->grab, x->lib, "XGrabKey"); LOAD(x->ungrab, x->lib, "XUngrabKey"); LOAD(x->sync, x->lib, "XSync");
  LOAD(x->set_error_handler, x->lib, "XSetErrorHandler"); LOAD(x->pending, x->lib, "XPending"); LOAD(x->next, x->lib, "XNextEvent"); LOAD(x->peek, x->lib, "XPeekEvent");
  LOAD(x->idle_add, x->glib, "g_idle_add_full");
  x->display = open_display(NULL);
  if (!x->display) return lt_hotkey_diag(b, LT_HOTKEY_UNAVAILABLE, "XOpenDisplay failed; check DISPLAY and Xauthority for this application");
  x->screens = x->screen_count(x->display);
  if (x->screens < 1 || x->screens > 8) return lt_hotkey_diag(b, LT_HOTKEY_UNSUPPORTED, "X11 screen count exceeds hotkey backend capacity");
  for (int i = 0; i < x->screens; ++i) x->roots[i] = x->root(x->display, i);
  ModifierMap *map = x->modifier_map(x->display);
  if (!map || map->max_keypermod < 1 || map->max_keypermod > 64) {
    if (map) x->free_modifier_map(map);
    return lt_hotkey_diag(b, LT_HOTKEY_UNSUPPORTED, "X11 modifier map cannot be inspected safely");
  }
  unsigned num = modifier_mask(x, map, 0xff7f), scroll = modifier_mask(x, map, 0xff14);
  x->alt_mask = modifier_mask(x, map, 0xffe9);
  if (!x->alt_mask) x->alt_mask = modifier_mask(x, map, 0xffea);
  x->super_mask = modifier_mask(x, map, 0xffeb);
  if (!x->super_mask) x->super_mask = modifier_mask(x, map, 0xffec);
  x->free_modifier_map(map);
  unsigned lock_bits[3] = {2, num, scroll};
  x->ignored_locks = 2 | num | scroll;
  for (unsigned mask = 0; mask < 8; ++mask) {
    unsigned actual = 0;
    for (unsigned bit = 0; bit < 3; ++bit) if (mask & (1u << bit)) actual |= lock_bits[bit];
    bool duplicate = false;
    for (unsigned i = 0; i < x->lock_count; ++i) if (x->lock_masks[i] == actual) duplicate = true;
    if (!duplicate) x->lock_masks[x->lock_count++] = actual;
  }
  x->fd = x->connection(x->display);
  x->source = lt_fd_watch(x->fd, 1 | 8 | 16 | 32, on_fd, b);
  if (!x->source) return lt_hotkey_diag(b, LT_HOTKEY_UNAVAILABLE, "GLib X11 descriptor watch could not be installed");
  b->diagnostic[0] = 0;
  return LT_HOTKEY_OK;
}
static KeySym symbol_for(uint32_t key) {
  switch (key) {
    case '\r': return 0xff0d; case '\t': return 0xff09; case 0x1b: return 0xff1b; case 0x7f: case '\b': return 0xff08;
    case 0xf700: return 0xff52; case 0xf701: return 0xff54; case 0xf702: return 0xff51; case 0xf703: return 0xff53;
    case 0xf727: return 0xffff; case 0xf729: return 0xff50; case 0xf72b: return 0xff57; case 0xf72c: return 0xff55; case 0xf72d: return 0xff56;
  }
  if (key >= 0xf704 && key <= 0xf70f) return 0xffbe + key - 0xf704;
  if (key >= 'A' && key <= 'Z') key += 'a' - 'A';
  return key <= 0xff ? key : key <= 0x10ffff ? 0x01000000u | key : 0;
}
static void ungrab_all(X11 *x, const Registration *entry) {
  for (int screen = 0; screen < x->screens; ++screen) for (unsigned lock = 0; lock < x->lock_count; ++lock)
    x->ungrab(x->display, (int)entry->code, entry->native_mods | x->lock_masks[lock], x->roots[screen]);
}
int lt_hotkey_platform_register(LtHotkeyBackend *b, uint32_t key, uint32_t mods, uint64_t token, uint64_t *handle) {
  X11 *x = b->platform;
  if (x->dead) return lt_hotkey_diag(b, LT_HOTKEY_UNAVAILABLE, "X11 connection is closed");
  Registration *entry = NULL;
  for (unsigned i = 0; i < LT_HOTKEY_NATIVE_LIMIT; ++i) {
    if (x->entries[i].handle && (x->entries[i].token == token || (x->entries[i].key == key && x->entries[i].mods == mods)))
      return lt_hotkey_diag(b, LT_HOTKEY_INVALID, "Duplicate global hotkey token or chord");
    if (!x->entries[i].handle && !entry) entry = &x->entries[i];
  }
  if (!entry || !x->next_handle) return lt_hotkey_diag(b, LT_HOTKEY_LIMIT, "X11 hotkey registration budget exhausted");
  KeyCode code = x->keysym_code(x->display, symbol_for(key));
  if (!code || ((mods & LT_HOTKEY_ALT) && !x->alt_mask) || ((mods & LT_HOTKEY_SUPER) && !x->super_mask))
    return lt_hotkey_diag(b, LT_HOTKEY_UNSUPPORTED, "Key or requested modifier is absent from the current X11 keyboard map");
  if (x->keycode_sym(x->display, code, 0, 0) != symbol_for(key))
    return lt_hotkey_diag(b, LT_HOTKEY_UNSUPPORTED, "X11 global key requires an implicit layout modifier; use the base key with explicit modifiers");
  if (((mods & LT_HOTKEY_ALT) && (x->alt_mask & (x->alt_mask - 1))) ||
      ((mods & LT_HOTKEY_SUPER) && (x->super_mask & (x->super_mask - 1))))
    return lt_hotkey_diag(b, LT_HOTKEY_UNSUPPORTED, "Requested modifier has an ambiguous X11 modifier map");
  unsigned native = ((mods & LT_HOTKEY_CTRL) ? 4u : 0) | ((mods & LT_HOTKEY_SHIFT) ? 1u : 0) |
                    ((mods & LT_HOTKEY_ALT) ? x->alt_mask : 0) | ((mods & LT_HOTKEY_SUPER) ? x->super_mask : 0);
  if (native & x->ignored_locks) return lt_hotkey_diag(b, LT_HOTKEY_UNSUPPORTED, "Requested modifier overlaps a lock modifier in the current X11 map");
  for (unsigned i = 0; i < LT_HOTKEY_NATIVE_LIMIT; ++i)
    if (x->entries[i].handle && x->entries[i].code == code && x->entries[i].native_mods == native)
      return lt_hotkey_diag(b, LT_HOTKEY_INVALID, "Two global chords resolve to the same physical X11 key");
  Registration staged = {key, mods, code, native, token, x->next_handle++, 0, false};
  begin_request(x);
  staged.min_serial = x->next_request(x->display);
  for (int screen = 0; screen < x->screens; ++screen) for (unsigned lock = 0; lock < x->lock_count; ++lock)
    x->grab(x->display, code, native | x->lock_masks[lock], x->roots[screen], 0, 1, 1);
  unsigned error = end_request(x);
  if (error) {
    begin_request(x); ungrab_all(x, &staged); end_request(x);
    snprintf(b->diagnostic, sizeof b->diagnostic, "XGrabKey failed (X11 error %u); shortcut may be owned by another application", error);
    return error == 10 ? LT_HOTKEY_CONFLICT : LT_HOTKEY_SYSTEM;
  }
  *entry = staged; *handle = staged.handle; b->diagnostic[0] = 0;
  return LT_HOTKEY_OK;
}
int lt_hotkey_platform_unregister(LtHotkeyBackend *b, uint64_t handle) {
  X11 *x = b->platform;
  for (unsigned i = 0; i < LT_HOTKEY_NATIVE_LIMIT; ++i) if (x->entries[i].handle == handle) {
    if (!x->dead) {
      begin_request(x); ungrab_all(x, &x->entries[i]); unsigned error = end_request(x);
      if (error) return lt_hotkey_diag(b, LT_HOTKEY_SYSTEM, "XUngrabKey failed; registration retained for teardown retry");
    }
    memset(&x->entries[i], 0, sizeof x->entries[i]); return LT_HOTKEY_OK;
  }
  return lt_hotkey_diag(b, LT_HOTKEY_INVALID, "Unknown X11 registration handle");
}
void lt_hotkey_platform_close(LtHotkeyBackend *b) {
  X11 *x = b->platform;
  if (!x) return;
  if (x->source) lt_unwatch(x->source);
  if (x->idle_source) lt_unwatch(x->idle_source);
  if (x->display && !x->dead && x->close_display) {
    /* XCloseDisplay also releases every passive grab on this owned connection. */
    x->close_display(x->display);
  } else if (x->dead && x->fd >= 0) {
    /* Xlib's I/O-error path terminates the process. Do not re-enter a known
     * disconnected Display: close its fd and abandon its small Xlib bookkeeping.
     * The server already released all grabs on disconnect. */
    close(x->fd);
  }
  if (x->lib) dlclose(x->lib);
  if (x->glib) dlclose(x->glib);
  free(x); b->platform = NULL;
}
#endif
