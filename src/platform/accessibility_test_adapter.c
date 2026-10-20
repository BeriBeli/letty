/* Test-only in-process backend: never links AppKit/GTK or opens an OS surface.
 */
#include "accessibility_internal.h"
static unsigned attached, detached;
int lt_ax_platform_capability(void) { return 1; }
int lt_ax_platform_attach(LtAxBridge *b) {
  (void)b;
  attached++;
  return 1;
}
int lt_ax_platform_update(LtAxBridge *b, unsigned flags) {
  (void)b;
  return !(flags & 0x80000000u);
}
void lt_ax_platform_detach(LtAxBridge *b) {
  (void)b;
  detached++;
}
const LtAxNode *lt_ax_test_node(LtAxBridge *b, uint64_t id) {
  return lt_ax_find(b, id);
}
int lt_ax_test_invoke(LtAxBridge *b, uint64_t id, uint32_t action) {
  return lt_ax_invoke(b, id, action);
}
unsigned lt_ax_test_attached(void) { return attached; }
unsigned lt_ax_test_detached(void) { return detached; }
