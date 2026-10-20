#ifndef LETTY_HOTKEY_H
#define LETTY_HOTKEY_H
#include <stddef.h>
#include <stdint.h>
/* Modifier bits describe semantic modifiers, not native platform masks. */
enum { LT_HOTKEY_CTRL = 1, LT_HOTKEY_ALT = 2, LT_HOTKEY_SHIFT = 4, LT_HOTKEY_SUPER = 8 };
enum { LT_HOTKEY_OK = 0, LT_HOTKEY_UNSUPPORTED = 1, LT_HOTKEY_UNAVAILABLE = 2,
       LT_HOTKEY_CONFLICT = 3, LT_HOTKEY_INVALID = 4, LT_HOTKEY_SYSTEM = 5,
       LT_HOTKEY_LIMIT = 6 };
typedef struct LtHotkeyBackend LtHotkeyBackend;
typedef void (*LtHotkeyCallback)(void *context, uint64_t token);
/* Main thread only. Capability does not connect to X11 or register a key.
 * open/register are for the app's explicitly enabled normal entry, never a
 * build check. No Accessibility/Input Monitoring permission prompt is used. */
int lt_hotkey_capability(char *diagnostic, size_t capacity);
LtHotkeyBackend *lt_hotkey_open(LtHotkeyCallback callback, void *context,
                               char *diagnostic, size_t capacity);
/* token is owned scalar routing identity. Duplicate tokens/chords are rejected.
 * The backend has room for 64 native registrations, allowing a 32-key manager
 * to stage replacement while old registrations remain active. */
int lt_hotkey_register(LtHotkeyBackend *backend, uint32_t key, uint32_t modifiers,
                       uint64_t token, uint64_t *handle);
int lt_hotkey_unregister(LtHotkeyBackend *backend, uint64_t handle);
const char *lt_hotkey_last_error(const LtHotkeyBackend *backend);
/* Mutes callback, removes event source, unregisters keys, closes owned display.
 * Call before freeing callback context; no callback may destroy its backend
 * synchronously (queue application work instead). */
void lt_hotkey_close(LtHotkeyBackend *backend);
#endif
