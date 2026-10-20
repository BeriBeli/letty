#ifndef LETTY_DROP_H
#define LETTY_DROP_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef struct LtDropBridge LtDropBridge;
enum { LT_DROP_PROBE = 0, LT_DROP_RESERVE = 1, LT_DROP_DELIVER = 2, LT_DROP_CANCEL = 3 };
/* UI thread only. PROBE never allocates/queues; RESERVE binds a stable target
 * at mouse-up BEFORE asynchronous GTK selection transfer. DELIVER owns no
 * strings: callback must synchronously validate/copy. CANCEL retires token.
 * No callback may detach/destroy this bridge or its host synchronously.
 * x/y are logical top-left view coordinates; URIs are un-decoded GTK strings. */
typedef bool (*LtDropCallback)(void *context, int phase, uint64_t token,
                             const char *const *paths, size_t count,
                             double x, double y, bool are_uris);
/* host = app-owned flipped NanoUIView / GtkDrawingArea, NOT NSWindow/GtkWindow.
 * At most8 live bridges. No permission prompt or native event is synthesized. */
LtDropBridge *lt_drop_attach(void *host, LtDropCallback callback, void *context,
                             char *diagnostic, size_t capacity);
/* Mutes/disconnects native callbacks before return. Call BEFORE host/context
 * destruction, on the same UI thread. Registry slots remain allocated forever
 * so a retired native callback cannot dereference freed bridge storage. */
void lt_drop_detach(LtDropBridge *bridge);
/* UI publishes complete logical view size with its copied pane rectangles.
 * Zero invalidates. Reject native resize before the next frame has published
 * fresh geometry; current() is also checked before draining accepted work. */
void lt_drop_set_geometry(LtDropBridge *, double width, double height);
bool lt_drop_geometry_current(LtDropBridge *);
#endif
