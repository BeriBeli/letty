#ifndef LETTY_ACCESSIBILITY_INTERNAL_H
#define LETTY_ACCESSIBILITY_INTERNAL_H
#include "accessibility.h"
typedef struct {
  size_t count;
  LtAxNode nodes[LT_AX_MAX_NODES];
  char bytes[LT_AX_MAX_BYTES];
} LtAxSnapshot;
struct LtAxBridge {
  void *host, *platform;
  LtAxAction callback;
  void *context;
  LtAxSnapshot *snapshot;
};
typedef struct {
  LtAxBridge *bridge;
  uint64_t id;
} LtAxLink;
const LtAxNode *lt_ax_find(const LtAxBridge *, uint64_t);
int lt_ax_invoke(LtAxBridge *, uint64_t, uint32_t);
int lt_ax_can_invoke(const LtAxBridge *, uint64_t, uint32_t);
size_t lt_ax_scalars(const char *, size_t);
size_t lt_ax_byte_at(const char *, size_t, size_t);
int lt_ax_platform_capability(void);
int lt_ax_platform_attach(LtAxBridge *);
int lt_ax_platform_update(LtAxBridge *, unsigned);
void lt_ax_platform_detach(LtAxBridge *);
#endif
