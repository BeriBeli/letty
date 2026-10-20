#ifndef LETTY_HOTKEY_INTERNAL_H
#define LETTY_HOTKEY_INTERNAL_H
#include "hotkey.h"
#include <stdbool.h>
#define LT_HOTKEY_NATIVE_LIMIT 64
struct LtHotkeyBackend {
  LtHotkeyCallback callback;
  void *context;
  char diagnostic[256];
  void *platform;
};
int lt_hotkey_diag(LtHotkeyBackend *backend, int code, const char *message);
int lt_hotkey_platform_capability(char *diagnostic, size_t capacity);
int lt_hotkey_platform_open(LtHotkeyBackend *backend);
int lt_hotkey_platform_register(LtHotkeyBackend *backend, uint32_t key, uint32_t modifiers, uint64_t token, uint64_t *handle);
int lt_hotkey_platform_unregister(LtHotkeyBackend *backend, uint64_t handle);
void lt_hotkey_platform_close(LtHotkeyBackend *backend);
#endif
