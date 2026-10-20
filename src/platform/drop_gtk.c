#if defined(__linux__)
#include "drop_internal.h"
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
typedef struct { const char *target; unsigned int flags, info; } Target;
typedef void (*Callback)(void);
typedef struct { int x, y, width, height; } Allocation;
static struct {
  void (*dest_set)(void *, unsigned int, const Target *, int, unsigned int);
  void (*dest_unset)(void *);
  void *(*find_target)(void *, void *, void *);
  void (*get_data)(void *, void *, void *, unsigned int);
  char **(*get_uris)(void *);
  const unsigned char *(*get_bytes)(void *);
  int (*get_length)(void *);
  void (*finish)(void *, int, int, unsigned int);
  void (*freev)(char **);
  void *(*ref)(void *);
  void (*unref)(void *);
  unsigned long (*connect)(void *, const char *, Callback, void *, void *, unsigned int);
  void (*disconnect)(void *, unsigned long);
  unsigned long (*drawing_type)(void);
  int (*is_a)(void *, unsigned long);
  void (*allocation)(void *, Allocation *);
} api;
static int loaded;
static bool load(void) {
  if (loaded) return loaded > 0;
  loaded = -1;
  void *gtk = dlopen("libgtk-3.so.0",RTLD_LAZY | RTLD_LOCAL);
  void *obj = dlopen("libgobject-2.0.so.0",RTLD_LAZY | RTLD_LOCAL);
  void *glib = dlopen("libglib-2.0.so.0",RTLD_LAZY | RTLD_LOCAL);
  if (!gtk || !obj || !glib) return false;
#define SYM(field,lib,name) do { *(void **)(&api.field) = dlsym(lib,name); if (!api.field) return false; } while(0)
  SYM(allocation,gtk,"gtk_widget_get_allocation");
  SYM(dest_set,gtk,"gtk_drag_dest_set"); SYM(dest_unset,gtk,"gtk_drag_dest_unset");
  SYM(find_target,gtk,"gtk_drag_dest_find_target"); SYM(get_data,gtk,"gtk_drag_get_data");
  SYM(get_bytes,gtk,"gtk_selection_data_get_data"); SYM(get_length,gtk,"gtk_selection_data_get_length");
  SYM(get_uris,gtk,"gtk_selection_data_get_uris"); SYM(finish,gtk,"gtk_drag_finish");
  SYM(freev,glib,"g_strfreev"); SYM(ref,obj,"g_object_ref"); SYM(unref,obj,"g_object_unref");
  SYM(connect,obj,"g_signal_connect_data"); SYM(disconnect,obj,"g_signal_handler_disconnect");
  SYM(drawing_type,gtk,"gtk_drawing_area_get_type"); SYM(is_a,obj,"g_type_check_instance_is_a");
#undef SYM
  loaded = 1; return true;
}
static void clear_drag(LtDropBridge *b, bool finish) {
  if (b->drag_context) {
    if (finish) api.finish(b->drag_context,0,0,0);
    api.unref(b->drag_context); b->drag_context = NULL;
  }
  lt_drop_cancel(b);
}
static int dropped(void *widget, void *context, int x, int y, unsigned int time, void *raw) {
  LtDropBridge *b = raw;
  if (!b->live || b->host != widget) return 0;
  clear_drag(b,true);
  void *target = api.find_target(widget,context,NULL);
  if (!target || !lt_drop_reserve(b,x,y)) return 0;
  b->drag_context = api.ref(context);
  // Manual DROP path: reserve above precedes the asynchronous selection read.
  api.get_data(widget,context,target,time);
  return 1;
}
static void received(void *widget, void *context, int x, int y, void *selection,
                     unsigned int info, unsigned int time, void *raw) {
  LtDropBridge *b = raw;
  (void)x; (void)y;
  if (!b->live || b->host != widget || b->drag_context != context || !b->token) return;
  bool accepted = false;
  int length = api.get_length(selection);
  const unsigned char *bytes = api.get_bytes(selection);
  // URI extraction allocates: bound its raw input first, and reject embedded
  // NUL rather than letting C string parsing silently truncate a pathname.
  bool valid = info == 0x4c54 && length > 0 && length <= 16 * (4095 * 3 + 34) && bytes && !memchr(bytes,0,(size_t)length);
  char **uris = valid ? api.get_uris(selection) : NULL;
  if (uris) {
    size_t count = 0;
    while (count <= 16 && uris[count]) ++count;
    if (count && count <= 16) accepted = lt_drop_deliver(b,(const char *const *)uris,count,b->x,b->y,true);
    api.freev(uris);
  }
  api.finish(context,accepted ? 1 : 0,0,time); // Never request source deletion.
  clear_drag(b,false);
}
static void destroyed(void *widget, void *raw) {
  LtDropBridge *b = raw;
  if (b->live && b->host == widget) lt_drop_detach(b);
}
bool lt_drop_platform_attach(LtDropBridge *b, char *diag, size_t cap) {
  if (!load()) { if (diag && cap) snprintf(diag,cap,"GTK3 file drop symbols unavailable"); return false; }
  if (!api.is_a(b->host,api.drawing_type())) { if (diag && cap) snprintf(diag,cap,"File drop requires the app-owned GtkDrawingArea"); return false; }
  Target target = { "text/uri-list",0,0x4c54 };
  // MOTION|HIGHLIGHT only. Our drop handler reserves the target and requests
  // data; GTK_DEST_DEFAULT_DROP would race that reservation.
  api.dest_set(b->host,3,&target,1,2); // GDK_ACTION_COPY, including Wayland GTK.
  b->native_registered = true;
  b->signals[0] = api.connect(b->host,"drag-drop",(Callback)dropped,b,NULL,0);
  b->signals[1] = api.connect(b->host,"drag-data-received",(Callback)received,b,NULL,0);
  b->signals[2] = api.connect(b->host,"destroy",(Callback)destroyed,b,NULL,0);
  if (!b->signals[0] || !b->signals[1] || !b->signals[2]) { if (diag && cap) snprintf(diag,cap,"GTK3 file drop signal connection failed"); return false; }
  return true;
}
bool lt_drop_platform_geometry(LtDropBridge *b) {
  Allocation a; api.allocation(b->host,&a);
  return (double)a.width == b->expected_width && (double)a.height == b->expected_height;
}
void lt_drop_platform_detach(LtDropBridge *b) {
  if (loaded <= 0) return;
  clear_drag(b,true);
  for (size_t i=0;i<3;++i) if (b->signals[i]) { api.disconnect(b->host,b->signals[i]); b->signals[i] = 0; }
  if (b->native_registered) api.dest_unset(b->host);
  b->native_registered = false;
}
#endif
