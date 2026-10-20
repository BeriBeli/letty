#include "hotkey_internal.h"
#include <stdio.h>
#include <stdlib.h>

int lt_hotkey_diag(LtHotkeyBackend *b, int code, const char *message) {
  if (b) snprintf(b->diagnostic, sizeof b->diagnostic, "%s", message);
  return code;
}
int lt_hotkey_capability(char *out, size_t cap) {
  return lt_hotkey_platform_capability(out, cap);
}
LtHotkeyBackend *lt_hotkey_open(LtHotkeyCallback cb, void *ctx, char *out, size_t cap) {
  if (!cb) { if (out && cap) snprintf(out, cap, "Global hotkey callback is missing"); return NULL; }
  LtHotkeyBackend *b = calloc(1, sizeof *b);
  if (!b) { if (out && cap) snprintf(out, cap, "Global hotkey backend allocation failed"); return NULL; }
  b->callback = cb; b->context = ctx;
  int rc = lt_hotkey_platform_open(b);
  if (rc) {
    if (out && cap) snprintf(out, cap, "%s", b->diagnostic);
    lt_hotkey_platform_close(b); free(b); return NULL;
  }
  if (out && cap) out[0] = 0;
  return b;
}
int lt_hotkey_register(LtHotkeyBackend *b, uint32_t key, uint32_t mods, uint64_t token, uint64_t *handle) {
  if (!b || !handle || !token || !key || key > 0x10ffffu || (key >= 0xd800u && key <= 0xdfffu) || mods & ~15u || !(mods & (LT_HOTKEY_CTRL | LT_HOTKEY_ALT | LT_HOTKEY_SUPER)))
    return lt_hotkey_diag(b, LT_HOTKEY_INVALID, "A global hotkey requires Ctrl, Alt, or Super and a nonzero key/token");
  return lt_hotkey_platform_register(b, key, mods, token, handle);
}
int lt_hotkey_unregister(LtHotkeyBackend *b, uint64_t handle) {
  if (!b || !handle) return LT_HOTKEY_INVALID;
  return lt_hotkey_platform_unregister(b, handle);
}
const char *lt_hotkey_last_error(const LtHotkeyBackend *b) { return b ? b->diagnostic : "Global hotkey backend unavailable"; }
void lt_hotkey_close(LtHotkeyBackend *b) {
  if (b) { b->callback = NULL; lt_hotkey_platform_close(b); free(b); }
}
#if !defined(__APPLE__) && !defined(__linux__)
int lt_hotkey_platform_capability(char *out, size_t cap) { if (out && cap) snprintf(out, cap, "Global hotkeys are not implemented on this platform"); return LT_HOTKEY_UNSUPPORTED; }
int lt_hotkey_platform_open(LtHotkeyBackend *b) { return lt_hotkey_diag(b, LT_HOTKEY_UNSUPPORTED, "Global hotkeys are not implemented on this platform"); }
int lt_hotkey_platform_register(LtHotkeyBackend *b, uint32_t k, uint32_t m, uint64_t t, uint64_t *h) { (void)k; (void)m; (void)t; (void)h; return lt_hotkey_diag(b, LT_HOTKEY_UNSUPPORTED, "Global hotkeys are not implemented on this platform"); }
int lt_hotkey_platform_unregister(LtHotkeyBackend *b, uint64_t h) { (void)b; (void)h; return LT_HOTKEY_UNSUPPORTED; }
void lt_hotkey_platform_close(LtHotkeyBackend *b) { (void)b; }
#endif
