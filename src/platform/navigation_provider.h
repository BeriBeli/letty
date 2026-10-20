#ifndef LETTY_NAVIGATION_PROVIDER_H
#define LETTY_NAVIGATION_PROVIDER_H
#include <stdint.h>
#include <stddef.h>
/* Short-lived, bounded workers. No UI/global callback and no persistent watcher.
   All strings/results are owned copies. The read fd stays valid until destroy. */
enum LtNavState {
  LT_NAV_DISABLED = 0, LT_NAV_OK = 1, LT_NAV_NON_REPOSITORY = 2,
  LT_NAV_UNAVAILABLE = 3, LT_NAV_PERMISSION = 4, LT_NAV_TIMEOUT = 5,
  LT_NAV_CANCELLED = 6, LT_NAV_STALE = 7, LT_NAV_LIMIT = 8, LT_NAV_FAILED = 9
};
#define LT_NAV_MAX_PORTS 32
#define LT_NAV_MAX_PIDS 256
#define LT_NAV_MAX_FDS 2048
#define LT_NAV_MAX_PATH 4095
#define LT_NAV_BRANCH_BYTES 256
#define LT_NAV_MAX_TIMEOUT_MS 1500
/* Family is 4 or 6, never a platform AF_* value. TCP LISTEN only. */
typedef struct { int32_t pid; uint16_t port; uint8_t family, reserved; uint64_t birth; } LtNavPort;
typedef struct {
  uint64_t session_id, generation, root_birth;
  int32_t root_pid, git_state, ports_state, error_code;
  uint32_t git_dirty, git_detached, port_count, partial, scanned_pids, scanned_fds;
  uint64_t elapsed_us;
  char branch[LT_NAV_BRANCH_BYTES], head[32];
  LtNavPort ports[LT_NAV_MAX_PORTS];
} LtNavSnapshot;
typedef struct LtNavProvider LtNavProvider;
/* Capture one known Session root's OS birth identity. Never enumerate processes. */
LtNavProvider *lt_nav_provider_create(uint64_t session_id, int32_t root_pid);
int lt_nav_provider_fd(const LtNavProvider *);
/* 1 = started; 0 = previous job busy (cancel then drain notification and retry);
   -1 = invalid request/allocation/thread failure, errno supplies the cause.
   cwd must be trusted local text; NULL disables Git for this request. Request
   generation must be nonzero; the caller also checks it against current state. */
int lt_nav_provider_start(LtNavProvider *, uint64_t generation, const char *cwd,
                          int git_enabled, int ports_enabled, uint32_t timeout_ms);
/* Nonblocking. Revokes this job immediately; completion still notifies so that
   the host can join and reclaim it. Disabled state must hide cached metadata. */
void lt_nav_provider_cancel(LtNavProvider *);
/* Only main/event-loop thread: 1 completed owned snapshot, 0 not ready, -1 error.
   Completion is copied after its worker finishes. Cancelled/stale data is never
   promoted to OK, even if cancellation races notification delivery. */
int lt_nav_provider_drain(LtNavProvider *, LtNavSnapshot *);
/* Host unregisters fdwatch first. Nonblocking retire: cancel + detach an active
   short worker. Its independent reference reaps Git and closes/frees resources
   on completion. No callback, host pointer or externally borrowed data survives. */
void lt_nav_provider_destroy(LtNavProvider *);
#endif
