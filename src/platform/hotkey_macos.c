#ifdef __APPLE__
#include "hotkey_internal.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Fixed public Carbon/CoreFoundation ABI; resolve dynamically so linking Letty
 * does not introduce another framework prerequisite. Carbon uses ANSI UInt32,
 * OSStatus=int32, opaque refs, and UniCharCount=unsigned long on macOS. */
typedef struct { uint32_t signature, id; } HotKeyID;
typedef struct { uint32_t event_class, event_kind; } EventType;
typedef int32_t (*EventHandler)(void *, void *, void *);
typedef struct { void *ref; uint32_t native_id, key, mods, code; uint64_t token, handle; bool pressed; } Registration;
typedef struct {
  void *carbon, *core, *services, *handler;
  int32_t (*register_key)(uint32_t, uint32_t, HotKeyID, void *, uint32_t, void **);
  int32_t (*unregister_key)(void *);
  void *(*event_target)(void);
  int32_t (*install_handler)(void *, EventHandler, uint32_t, const EventType *, void *, void **);
  int32_t (*remove_handler)(void *);
  uint32_t (*event_kind)(void *);
  int32_t (*get_parameter)(void *, uint32_t, uint32_t, uint32_t *, uint32_t, uint32_t *, void *);
  void *(*keyboard_source)(void);
  void *(*source_property)(void *, const void *);
  const void **layout_property;
  const uint8_t *(*data_bytes)(const void *);
  void (*release)(const void *);
  int32_t (*translate)(const void *, uint16_t, uint16_t, uint32_t, uint32_t, uint32_t, uint32_t *, unsigned long, unsigned long *, uint16_t *);
  uint8_t (*keyboard_type)(void);
  Registration entries[LT_HOTKEY_NATIVE_LIMIT];
} Mac;
static uint32_t next_native_id = 1; /* all backend use is on the main thread */
static const char carbon_path[] = "/System/Library/Frameworks/Carbon.framework/Carbon";
static const char core_path[] = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";
int lt_hotkey_platform_capability(char *out, size_t cap) {
  void *lib = dlopen(carbon_path, RTLD_NOW | RTLD_LOCAL);
  bool yes = lib && dlsym(lib, "RegisterEventHotKey") && dlsym(lib, "InstallEventHandler");
  if (lib) dlclose(lib);
  if (out && cap) snprintf(out, cap, "%s", yes ? "Carbon application hotkey events available; registration may conflict with system shortcuts" : "Carbon hotkey APIs unavailable");
  return yes ? LT_HOTKEY_OK : LT_HOTKEY_UNAVAILABLE;
}
static int32_t event(void *call, void *event_ref, void *ctx) {
  (void)call;
  LtHotkeyBackend *b = ctx;
  Mac *m = b->platform;
  HotKeyID id = {0};
  if (m->get_parameter(event_ref, 0x2d2d2d2du, 0x686b6964u, NULL, sizeof id, NULL, &id) || id.signature != 0x6c747948u) return -9874;
  for (unsigned i = 0; i < LT_HOTKEY_NATIVE_LIMIT; ++i) if (m->entries[i].ref && m->entries[i].native_id == id.id) {
    if (m->event_kind(event_ref) == 6) { m->entries[i].pressed = false; return 0; }
    if (!m->entries[i].pressed) {
      m->entries[i].pressed = true;
      if (b->callback) b->callback(b->context, m->entries[i].token);
    }
    return 0;
  }
  return -9874; /* eventNotHandledErr: allow another backend's handler */
}
#define LOAD(target, lib, symbol) do { *(void **)(&(target)) = dlsym((lib), (symbol)); if (!(target)) return lt_hotkey_diag(b, LT_HOTKEY_UNAVAILABLE, "Missing Carbon keyboard/layout function: " symbol); } while (0)
int lt_hotkey_platform_open(LtHotkeyBackend *b) {
  Mac *m = calloc(1, sizeof *m);
  if (!m) return lt_hotkey_diag(b, LT_HOTKEY_SYSTEM, "Carbon hotkey allocation failed");
  b->platform = m;
  m->carbon = dlopen(carbon_path, RTLD_NOW | RTLD_LOCAL);
  m->core = dlopen(core_path, RTLD_NOW | RTLD_LOCAL);
  m->services = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW | RTLD_LOCAL);
  if (!m->carbon || !m->core || !m->services) return lt_hotkey_diag(b, LT_HOTKEY_UNAVAILABLE, "Carbon, CoreServices, or CoreFoundation could not be loaded");
  LOAD(m->register_key, m->carbon, "RegisterEventHotKey"); LOAD(m->unregister_key, m->carbon, "UnregisterEventHotKey");
  LOAD(m->event_target, m->carbon, "GetApplicationEventTarget"); LOAD(m->install_handler, m->carbon, "InstallEventHandler");
  LOAD(m->remove_handler, m->carbon, "RemoveEventHandler"); LOAD(m->event_kind, m->carbon, "GetEventKind"); LOAD(m->get_parameter, m->carbon, "GetEventParameter");
  LOAD(m->keyboard_source, m->carbon, "TISCopyCurrentKeyboardLayoutInputSource"); LOAD(m->source_property, m->carbon, "TISGetInputSourceProperty");
  LOAD(m->layout_property, m->carbon, "kTISPropertyUnicodeKeyLayoutData"); LOAD(m->translate, m->services, "UCKeyTranslate");
  LOAD(m->keyboard_type, m->carbon, "LMGetKbdType"); LOAD(m->data_bytes, m->core, "CFDataGetBytePtr"); LOAD(m->release, m->core, "CFRelease");
  const EventType types[2] = {{0x6b657962u, 5}, {0x6b657962u, 6}};
  int32_t rc = m->install_handler(m->event_target(), event, 2, types, b, &m->handler);
  if (rc) return lt_hotkey_diag(b, LT_HOTKEY_SYSTEM, "Carbon event handler installation failed");
  return LT_HOTKEY_OK;
}
static int keycode(Mac *m, uint32_t key) {
  switch (key) {
    case '\r': return 36; case '\t': return 48; case 0x1b: return 53; case 0x7f: case '\b': return 51;
    case 0xf700: return 126; case 0xf701: return 125; case 0xf702: return 123; case 0xf703: return 124;
    case 0xf727: return 117; case 0xf729: return 115; case 0xf72b: return 119; case 0xf72c: return 116; case 0xf72d: return 121;
  }
  static const int function_keys[] = {122,120,99,118,96,97,98,100,101,109,103,111};
  if (key >= 0xf704 && key <= 0xf70f) return function_keys[key - 0xf704];
  if (key > 0xffff) return -1;
  if (key >= 'A' && key <= 'Z') key += 'a' - 'A';
  void *source = m->keyboard_source();
  if (!source) return -1;
  const void *data = m->source_property(source, *m->layout_property);
  const void *layout = data ? m->data_bytes(data) : NULL;
  int result = -1;
  for (uint16_t code = 0; layout && code < 128; ++code) {
    uint32_t dead = 0;
    unsigned long count = 0;
    uint16_t chars[4] = {0};
    if (!m->translate(layout, code, 0, 0, m->keyboard_type(), 1, &dead, 4, &count, chars) && count == 1 && chars[0] == key) { result = code; break; }
  }
  m->release(source);
  return result;
}
int lt_hotkey_platform_register(LtHotkeyBackend *b, uint32_t key, uint32_t mods, uint64_t token, uint64_t *handle) {
  Mac *m = b->platform;
  Registration *entry = NULL;
  for (unsigned i = 0; i < LT_HOTKEY_NATIVE_LIMIT; ++i) {
    if (m->entries[i].ref && (m->entries[i].token == token || (m->entries[i].key == key && m->entries[i].mods == mods)))
      return lt_hotkey_diag(b, LT_HOTKEY_INVALID, "Duplicate global hotkey token or chord");
    if (!m->entries[i].ref && !entry) entry = &m->entries[i];
  }
  if (!entry || !next_native_id) return lt_hotkey_diag(b, LT_HOTKEY_LIMIT, "Carbon hotkey registration budget exhausted");
  int code = keycode(m, key);
  if (code < 0) return lt_hotkey_diag(b, LT_HOTKEY_UNSUPPORTED, "Key is absent from the current macOS keyboard layout");
  for (unsigned i = 0; i < LT_HOTKEY_NATIVE_LIMIT; ++i)
    if (m->entries[i].ref && m->entries[i].code == (uint32_t)code && m->entries[i].mods == mods)
      return lt_hotkey_diag(b, LT_HOTKEY_INVALID, "Two global chords resolve to the same physical macOS key");
  uint32_t native_mods = ((mods & LT_HOTKEY_CTRL) ? 1u << 12 : 0) | ((mods & LT_HOTKEY_ALT) ? 1u << 11 : 0) |
                         ((mods & LT_HOTKEY_SHIFT) ? 1u << 9 : 0) | ((mods & LT_HOTKEY_SUPER) ? 1u << 8 : 0);
  HotKeyID id = {0x6c747948u, next_native_id++};
  void *ref = NULL;
  int32_t rc = m->register_key((uint32_t)code, native_mods, id, m->event_target(), 1, &ref);
  if (rc) {
    snprintf(b->diagnostic, sizeof b->diagnostic, "RegisterEventHotKey failed (OSStatus %d); shortcut may be reserved or in use", rc);
    return rc == -9878 ? LT_HOTKEY_CONFLICT : LT_HOTKEY_SYSTEM;
  }
  *entry = (Registration){ref, id.id, key, mods, (uint32_t)code, token, id.id, false};
  *handle = entry->handle;
  b->diagnostic[0] = 0;
  return LT_HOTKEY_OK;
}
int lt_hotkey_platform_unregister(LtHotkeyBackend *b, uint64_t handle) {
  Mac *m = b->platform;
  for (unsigned i = 0; i < LT_HOTKEY_NATIVE_LIMIT; ++i) if (m->entries[i].ref && m->entries[i].handle == handle) {
    int32_t rc = m->unregister_key(m->entries[i].ref);
    if (rc) return lt_hotkey_diag(b, LT_HOTKEY_SYSTEM, "UnregisterEventHotKey failed; registration retained for teardown retry");
    memset(&m->entries[i], 0, sizeof m->entries[i]); return LT_HOTKEY_OK;
  }
  return lt_hotkey_diag(b, LT_HOTKEY_INVALID, "Unknown Carbon registration handle");
}
void lt_hotkey_platform_close(LtHotkeyBackend *b) {
  Mac *m = b->platform;
  if (!m) return;
  if (m->handler && m->remove_handler) m->remove_handler(m->handler);
  for (unsigned i = 0; i < LT_HOTKEY_NATIVE_LIMIT; ++i) if (m->entries[i].ref && m->unregister_key) m->unregister_key(m->entries[i].ref);
  if (m->carbon) dlclose(m->carbon);
  if (m->core) dlclose(m->core);
  if (m->services) dlclose(m->services);
  free(m); b->platform = NULL;
}
#endif
