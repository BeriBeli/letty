#ifndef LETTY_ACCESSIBILITY_H
#define LETTY_ACCESSIBILITY_H
#include <stddef.h>
#include <stdint.h>
#define LT_AX_MAX_NODES 128
#define LT_AX_MAX_BYTES 65536
#define LT_AX_MAX_LABEL 256
#define LT_AX_MAX_VALUE 16384
enum {
  LT_AX_GROUP,
  LT_AX_TAB_GROUP,
  LT_AX_TAB,
  LT_AX_PANE,
  LT_AX_SEARCH,
  LT_AX_DIALOG,
  LT_AX_BUTTON,
  LT_AX_MENU,
  LT_AX_MENU_ITEM,
  LT_AX_SCROLLBAR,
  LT_AX_TERMINAL,
  LT_AX_LABEL,
  LT_AX_DOCUMENT,
  LT_AX_TEXT_FIELD
};
enum {
  LT_AX_ENABLED = 1,
  LT_AX_FOCUSABLE = 2,
  LT_AX_FOCUSED = 4,
  LT_AX_SELECTED = 8,
  LT_AX_EXPANDED = 16,
  LT_AX_VISIBLE = 32,
  LT_AX_CHECKED = 64,
  LT_AX_READ_ONLY = 128,
  LT_AX_MODAL = 256,
  LT_AX_TRUNCATED = 512
};
enum {
  LT_AX_PRESS = 1,
  LT_AX_FOCUS = 2,
  LT_AX_INCREMENT = 4,
  LT_AX_DECREMENT = 8,
  LT_AX_COPY = 16,
  LT_AX_DISMISS = 32
};
enum {
  LT_AX_NOTIFY_TREE = 1,
  LT_AX_NOTIFY_FOCUS = 2,
  LT_AX_NOTIFY_VALUE = 4,
  LT_AX_NOTIFY_STATE = 8
};
typedef struct {
  float x, y, width, height;
} LtAxBounds;
typedef struct {
  uint64_t id, parent;
  uint32_t role, state, actions;
  LtAxBounds bounds;
  const char *label;
  size_t label_len;
  const char *value;
  size_t value_len;
  uint32_t caret, selection_start, selection_end; /* UTF-8 byte offsets */
} LtAxNode;
typedef struct LtAxBridge LtAxBridge;
/* All calls on the UI thread, detach before host destruction. The callback must
 * queue work by stable IDs and never reenter VT or update the accessibility
 * tree. NSView* on macOS, GtkDrawingArea* on Linux. No screen-reader/permission
 * request. */
typedef int (*LtAxAction)(void *context, uint64_t node_id, uint32_t action);
int lt_ax_capability(
    void); /* 1 real backend available; 0 unsupported/unavailable */
LtAxBridge *lt_ax_attach(void *host, LtAxAction callback, void *context);
/* Copies input transactionally. 0 success, -1 invalid/over budget, -2
 * allocation or backend failure. Flags are explicit: do not announce each
 * output byte. */
int lt_ax_update(LtAxBridge *, const LtAxNode *, size_t count, unsigned flags);
void lt_ax_detach(LtAxBridge *);
#endif
