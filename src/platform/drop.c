#include "drop_internal.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
static LtDropBridge slots[8];
static uint64_t next_token = 1;
static size_t bounded_length(const char *p, size_t cap) { size_t n=0; while (n<cap && p[n]) ++n; return n; }
LtDropBridge *lt_drop_find(void *host) {
  for (size_t i = 0; i < 8; ++i) if (slots[i].live && slots[i].host == host) return &slots[i];
  return NULL;
}
static bool emit(LtDropBridge *b, int phase, uint64_t token,
                 const char *const *p, size_t n, double x, double y, bool uris) {
  return b && b->live && b->callback && b->callback(b->context, phase, token, p, n, x, y, uris);
}
void lt_drop_set_geometry(LtDropBridge *b, double w, double h) {
  if (!b || !b->live) return;
  b->expected_width = isfinite(w) && w > 0 ? w : 0;
  b->expected_height = isfinite(h) && h > 0 ? h : 0;
}
bool lt_drop_geometry_current(LtDropBridge *b) {
  return b && b->live && b->native_registered && b->expected_width > 0 && b->expected_height > 0 && lt_drop_platform_geometry(b);
}
bool lt_drop_probe(LtDropBridge *b, double x, double y) {
  return lt_drop_geometry_current(b) && isfinite(x) && isfinite(y) && emit(b, LT_DROP_PROBE, 0, NULL, 0, x, y, false);
}
void lt_drop_cancel(LtDropBridge *b) {
  if (b && b->token) {
    uint64_t token = b->token; b->token = 0;
    (void)emit(b, LT_DROP_CANCEL, token, NULL, 0, b->x, b->y, false);
  }
}
bool lt_drop_reserve(LtDropBridge *b, double x, double y) {
  lt_drop_cancel(b);
  if (!lt_drop_probe(b, x, y) || !next_token) return false;
  uint64_t token = next_token;
  next_token = token == UINT64_MAX ? 0 : token + 1;
  b->x = x; b->y = y;
  if (!emit(b, LT_DROP_RESERVE, token, NULL, 0, x, y, false)) return false;
  b->token = token;
  return true;
}
bool lt_drop_deliver(LtDropBridge *b, const char *const *paths, size_t n,
                     double x, double y, bool uris) {
  if (!lt_drop_geometry_current(b) || !b->token || !paths || !n || n > 16 || !isfinite(x) || !isfinite(y)) { lt_drop_cancel(b); return false; }
  const size_t max = uris ? 4095 * 3 + 32 : 4095;
  for (size_t i = 0; i < n; ++i) if (!paths[i] || !paths[i][0] || bounded_length(paths[i], max + 1) > max) { lt_drop_cancel(b); return false; }
  uint64_t token = b->token;
  bool accepted = emit(b, LT_DROP_DELIVER, token, paths, n, x, y, uris);
  lt_drop_cancel(b); /* Retire reservation, never the accepted pending payload. */
  return accepted;
}
LtDropBridge *lt_drop_attach(void *host, LtDropCallback cb, void *ctx, char *diag, size_t cap) {
  if (diag && cap) diag[0] = 0;
  const char *reason = "Native file drop bridge limit reached";
  if (!host || !cb) reason = "Native file drop host/callback missing";
  else if (lt_drop_find(host)) reason = "Native file drop already attached";
  else for (size_t i = 0; i < 8; ++i) if (!slots[i].live) {
    LtDropBridge *b = &slots[i];
    memset(b, 0, sizeof *b); b->live = true; b->host = host; b->callback = cb; b->context = ctx;
    if (lt_drop_platform_attach(b, diag, cap)) return b;
    b->callback = NULL; b->live = false;
    lt_drop_platform_detach(b); memset(b, 0, sizeof *b);
    return NULL;
  }
  if (diag && cap) snprintf(diag, cap, "%s", reason);
  return NULL;
}
void lt_drop_detach(LtDropBridge *b) {
  if (!b || !b->live) return;
  lt_drop_cancel(b); b->callback = NULL; b->live = false;
  lt_drop_platform_detach(b);
  b->host = NULL; b->context = NULL;
}
#if !defined(__APPLE__) && !defined(__linux__)
bool lt_drop_platform_attach(LtDropBridge *b, char *d, size_t n) { (void)b; if (d && n) snprintf(d,n,"Native file drop unsupported on this platform"); return false; }
void lt_drop_platform_detach(LtDropBridge *b) { (void)b; }
bool lt_drop_platform_geometry(LtDropBridge *b) { (void)b; return false; }
#endif
