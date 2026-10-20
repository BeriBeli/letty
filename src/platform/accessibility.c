/* Letty-owned accessibility glue; system AppKit/ATK are used via their public
 * ABI. No upstream implementation is copied or new runtime library bundled. */
#include "accessibility_internal.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
const LtAxNode *lt_ax_find(const LtAxBridge *b, uint64_t id) {
  if (!b || !b->snapshot)
    return NULL;
  for (size_t i = 0; i < b->snapshot->count; i++)
    if (b->snapshot->nodes[i].id == id)
      return &b->snapshot->nodes[i];
  return NULL;
}
static int interactable(const LtAxBridge *b, const LtAxNode *n) {
  for (const LtAxNode *p = n; p; p = lt_ax_find(b, p->parent))
    if ((p->state & (LT_AX_ENABLED | LT_AX_VISIBLE)) !=
        (LT_AX_ENABLED | LT_AX_VISIBLE))
      return 0;
  uint64_t modal = 0;
  for (size_t i = 0; i < b->snapshot->count; i++)
    if ((b->snapshot->nodes[i].state & (LT_AX_MODAL | LT_AX_VISIBLE)) ==
        (LT_AX_MODAL | LT_AX_VISIBLE))
      modal = b->snapshot->nodes[i].id;
  if (modal) {
    const LtAxNode *next = n;
    while (next && next->id != modal)
      next = lt_ax_find(b, next->parent);
    if (!next)
      return 0;
  }
  return 1;
}
int lt_ax_can_invoke(const LtAxBridge *b, uint64_t id, uint32_t action) {
  const LtAxNode *n = lt_ax_find(b, id);
  return n && (n->actions & action) && action && !(action & (action - 1)) &&
         interactable(b, n);
}
int lt_ax_invoke(LtAxBridge *b, uint64_t id, uint32_t action) {
  if (!lt_ax_can_invoke(b, id, action))
    return 0;
  LtAxAction fn = b->callback;
  void *ctx = b->context;
  return fn ? fn(ctx, id, action) : 0;
}
static int utf8(const char *s, size_t len) {
  for (size_t i = 0; i < len;) {
    unsigned c = (unsigned char)s[i++], need = 0, value = 0, minimum = 0;
    if (!c)
      return 0;
    if (c < 128)
      continue;
    if (c >= 194 && c <= 223) {
      need = 1;
      value = c & 31;
      minimum = 128;
    } else if (c >= 224 && c <= 239) {
      need = 2;
      value = c & 15;
      minimum = 2048;
    } else if (c >= 240 && c <= 244) {
      need = 3;
      value = c & 7;
      minimum = 65536;
    } else
      return 0;
    if (need > len - i)
      return 0;
    while (need--) {
      unsigned d = (unsigned char)s[i++];
      if ((d & 192) != 128)
        return 0;
      value = (value << 6) | (d & 63);
    }
    if (value < minimum || value > 0x10ffff ||
        (value >= 0xd800 && value <= 0xdfff))
      return 0;
  }
  return 1;
}
static int boundary(const char *s, size_t len, uint32_t offset) {
  return offset <= len &&
         (offset == len || ((unsigned char)s[offset] & 192) != 128);
}
size_t lt_ax_scalars(const char *s, size_t n) {
  size_t count = 0;
  for (size_t i = 0; i < n; i++)
    if (((unsigned char)s[i] & 192) != 128)
      count++;
  return count;
}
size_t lt_ax_byte_at(const char *s, size_t n, size_t chars) {
  size_t i = 0;
  while (i < n && chars) {
    i++;
    while (i < n && ((unsigned char)s[i] & 192) == 128)
      i++;
    chars--;
  }
  return i;
}
int lt_ax_capability(void) { return lt_ax_platform_capability(); }
LtAxBridge *lt_ax_attach(void *host, LtAxAction callback, void *context) {
  if (!host || !lt_ax_capability())
    return NULL;
  LtAxBridge *b = calloc(1, sizeof(*b));
  if (!b)
    return NULL;
  b->host = host;
  b->callback = callback;
  b->context = context;
  if (!lt_ax_platform_attach(b)) {
    free(b);
    return NULL;
  }
  return b;
}
int lt_ax_update(LtAxBridge *b, const LtAxNode *nodes, size_t count,
                 unsigned flags) {
  if (!b || !nodes || !count || count > LT_AX_MAX_NODES)
    return -1;
  LtAxSnapshot *s = calloc(1, sizeof(*s));
  if (!s)
    return -2;
  size_t used = 0;
  unsigned focused = 0;
  for (size_t i = 0; i < count; i++) {
    LtAxNode n = nodes[i];
    if (!n.id || n.role > LT_AX_TEXT_FIELD || n.actions & ~63u ||
        n.label_len > LT_AX_MAX_LABEL || n.value_len > LT_AX_MAX_VALUE ||
        (!n.label && n.label_len) || (!n.value && n.value_len))
      goto invalid;
    if ((i == 0) != (n.parent == 0))
      goto invalid;
    size_t parent = count;
    for (size_t j = 0; j < i; j++) {
      if (s->nodes[j].id == n.id)
        goto invalid;
      if (s->nodes[j].id == n.parent)
        parent = j;
    }
    if (i && parent == count)
      goto invalid;
    unsigned depth = 0;
    uint64_t next = n.parent;
    while (next) {
      if (++depth >= 16)
        goto invalid;
      size_t j = 0;
      while (j < i && s->nodes[j].id != next)
        j++;
      if (j == i)
        goto invalid;
      next = s->nodes[j].parent;
    }
    if (!isfinite(n.bounds.x) || !isfinite(n.bounds.y) ||
        !isfinite(n.bounds.width) || !isfinite(n.bounds.height) ||
        n.bounds.width < 0 || n.bounds.height < 0)
      goto invalid;
    if (!utf8(n.label, n.label_len) || !utf8(n.value, n.value_len) ||
        n.selection_start > n.selection_end ||
        !boundary(n.value, n.value_len, n.caret) ||
        !boundary(n.value, n.value_len, n.selection_start) ||
        !boundary(n.value, n.value_len, n.selection_end))
      goto invalid;
    if (n.state & LT_AX_FOCUSED) {
      if (++focused > 1 ||
          (n.state & (LT_AX_FOCUSABLE | LT_AX_ENABLED | LT_AX_VISIBLE)) !=
              (LT_AX_FOCUSABLE | LT_AX_ENABLED | LT_AX_VISIBLE))
        goto invalid;
    }
    if (n.label_len + n.value_len + 2 > sizeof(s->bytes) - used)
      goto invalid;
    n.label = s->bytes + used;
    if (n.label_len)
      memcpy(s->bytes + used, nodes[i].label, n.label_len);
    used += n.label_len;
    s->bytes[used++] = 0;
    n.value = s->bytes + used;
    if (n.value_len)
      memcpy(s->bytes + used, nodes[i].value, n.value_len);
    used += n.value_len;
    s->bytes[used++] = 0;
    s->nodes[i] = n;
  }
  s->count = count;
  /* Match the host Adapter contract even for direct C callers: a focused
   * descendant of a hidden/disabled parent or behind a modal is invalid.
   * Validate the complete candidate before exposing it to a native backend. */
  LtAxBridge candidate = *b;
  candidate.snapshot = s;
  for (size_t i = 0; i < count; i++)
    if ((s->nodes[i].state & LT_AX_FOCUSED) &&
        !interactable(&candidate, &s->nodes[i]))
      goto invalid;
  LtAxSnapshot *old = b->snapshot;
  b->snapshot = s;
  if (!lt_ax_platform_update(b, flags)) {
    b->snapshot = old;
    free(s);
    return -2;
  }
  free(old);
  return 0;
invalid:
  free(s);
  return -1;
}
void lt_ax_detach(LtAxBridge *b) {
  if (!b)
    return;
  b->callback = NULL;
  lt_ax_platform_detach(b);
  free(b->snapshot);
  free(b);
}
