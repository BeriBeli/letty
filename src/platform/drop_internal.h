#ifndef LETTY_DROP_INTERNAL_H
#define LETTY_DROP_INTERNAL_H
#include "drop.h"
struct LtDropBridge {
  bool live, native_registered;
  void *host, *context;
  LtDropCallback callback;
  uint64_t token;
  double x, y, expected_width, expected_height;
  void *saved_types;
  void *drag_context;
  unsigned long signals[3];
};
LtDropBridge *lt_drop_find(void *host);
bool lt_drop_probe(LtDropBridge *bridge, double x, double y);
bool lt_drop_reserve(LtDropBridge *bridge, double x, double y);
bool lt_drop_deliver(LtDropBridge *bridge, const char *const *paths, size_t count,
                     double x, double y, bool are_uris);
void lt_drop_cancel(LtDropBridge *bridge);
bool lt_drop_platform_attach(LtDropBridge *, char *, size_t);
void lt_drop_platform_detach(LtDropBridge *);
bool lt_drop_platform_geometry(LtDropBridge *);
#endif
