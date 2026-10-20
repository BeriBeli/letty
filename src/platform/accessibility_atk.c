#include "accessibility_internal.h"
#if defined(__linux__)
#include <dlfcn.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
/* Public GObject/ATK ABI prefix offsets, queried against runtime class sizes.
 * API references: docs.gtk.org/atk/class.Object.html and
 * iface.{Action,Text,Component}. No upstream implementation/header is vendored;
 * ATK/GTK remain optional system LGPL libraries, loaded dynamically like the
 * existing nanoui GTK backend. */
typedef uintptr_t Type;
typedef struct {
  Type type;
  const char *name;
  unsigned class_size, instance_size;
} Query;
typedef struct {
  void (*init)(void *, void *);
  void (*finish)(void *, void *);
  void *data;
} Interface;
typedef struct {
  void *gtk, *atk, *gobj, *glib;
  Type (*object_type)(void);
  Type (*atk_type)(void);
  Type (*action_type)(void);
  Type (*text_type)(void);
  Type (*component_type)(void);
  void (*query)(Type, Query *);
  Type (*register_type)(Type, const char *, unsigned, void (*)(void *, void *),
                        unsigned, void (*)(void *, void *), unsigned);
  void (*add_interface)(Type, Type, const Interface *);
  void *(*new_object)(Type, const char *, ...);
  void *(*ref)(void *);
  void (*unref)(void *);
  void *(*get_data)(void *, const char *);
  void (*set_data)(void *, const char *, void *);
  void (*set_data_full)(void *, const char *, void *, void (*)(void *));
  void *(*accessible)(void *);
  void *(*toplevel)(void *);
  void *(*window)(void *);
  int (*translate)(void *, void *, int, int, int *, int *);
  int (*origin)(void *, int *, int *);
  void *(*states_new)(void);
  int (*state_for)(const char *);
  int (*add_state)(void *, int);
  int (*role_for)(const char *);
  void (*notify_state)(void *, int, int);
  void (*initialize)(void *, void *);
  void (*notify)(void *, const char *);
  void (*emit)(void *, const char *, ...);
  void *(*malloc)(size_t);
  unsigned base_class;
  Type node_type;
} Api;
static Api api;
static int loaded;
#define LOAD(lib, member, name)                                                \
  do {                                                                         \
    *(void **)(&api.member) = dlsym(api.lib, name);                            \
    if (!api.member)                                                           \
      return 0;                                                                \
  } while (0)
static int load(void) {
  if (loaded)
    return loaded > 0;
  loaded = -1;
  api.gtk = dlopen("libgtk-3.so.0", RTLD_LAZY | RTLD_LOCAL);
  api.atk = dlopen("libatk-1.0.so.0", RTLD_LAZY | RTLD_LOCAL);
  api.gobj = dlopen("libgobject-2.0.so.0", RTLD_LAZY | RTLD_LOCAL);
  api.glib = dlopen("libglib-2.0.so.0", RTLD_LAZY | RTLD_LOCAL);
  if (!api.gtk || !api.atk || !api.gobj || !api.glib)
    return 0;
  LOAD(gobj, object_type, "g_object_get_type");
  LOAD(atk, atk_type, "atk_object_get_type");
  LOAD(atk, action_type, "atk_action_get_type");
  LOAD(atk, text_type, "atk_text_get_type");
  LOAD(atk, component_type, "atk_component_get_type");
  LOAD(gobj, query, "g_type_query");
  LOAD(gobj, register_type, "g_type_register_static_simple");
  LOAD(gobj, add_interface, "g_type_add_interface_static");
  LOAD(gobj, new_object, "g_object_new");
  LOAD(gobj, ref, "g_object_ref");
  LOAD(gobj, unref, "g_object_unref");
  LOAD(gobj, get_data, "g_object_get_data");
  LOAD(gobj, set_data, "g_object_set_data");
  LOAD(gobj, set_data_full, "g_object_set_data_full");
  LOAD(gobj, emit, "g_signal_emit_by_name");
  LOAD(gtk, accessible, "gtk_widget_get_accessible");
  LOAD(gtk, toplevel, "gtk_widget_get_toplevel");
  LOAD(gtk, window, "gtk_widget_get_window");
  LOAD(gtk, translate, "gtk_widget_translate_coordinates");
  *(void **)(&api.origin) = dlsym(api.gtk, "gdk_window_get_origin");
  if (!api.origin)
    return 0;
  LOAD(atk, states_new, "atk_state_set_new");
  LOAD(atk, state_for, "atk_state_type_for_name");
  LOAD(atk, add_state, "atk_state_set_add_state");
  LOAD(atk, role_for, "atk_role_for_name");
  LOAD(atk, notify_state, "atk_object_notify_state_change");
  LOAD(atk, initialize, "atk_object_initialize");
  LOAD(gobj, notify, "g_object_notify");
  LOAD(glib, malloc, "g_malloc");
  Query q = {0};
  api.query(api.object_type(), &q);
  api.base_class = q.class_size;
  if (!api.base_class)
    return 0;
  loaded = 1;
  return 1;
}
typedef struct {
  void *klass;
  void *original_count;
  void *original_child;
  unsigned refs;
} Hook;
static Hook hooks[8];
typedef struct {
  void *objects[LT_AX_MAX_NODES];
  uint64_t ids[LT_AX_MAX_NODES];
  size_t count;
  uint64_t parents[LT_AX_MAX_NODES];
  unsigned visible[LT_AX_MAX_NODES];
  unsigned states[LT_AX_MAX_NODES];
  void *host_ax;
  Hook *hook;
  uint64_t focused;
} Gtk;
static LtAxLink *linkof(void *o) { return api.get_data(o, "letty-ax-node"); }
static const LtAxNode *nodeof(void *o) {
  LtAxLink *l = linkof(o);
  return l ? lt_ax_find(l->bridge, l->id) : NULL;
}
static void *objectfor(LtAxBridge *b, uint64_t id) {
  Gtk *g = b->platform;
  for (size_t i = 0; i < g->count; i++)
    if (g->ids[i] == id)
      return g->objects[i];
  return NULL;
}
static void **slots(void *klass) {
  return (void **)((char *)klass + api.base_class);
}
static const char *name(void *o) {
  const LtAxNode *n = nodeof(o);
  return n ? n->label : "";
}
static const char *description(void *o) {
  const LtAxNode *n = nodeof(o);
  return n && (n->state & LT_AX_TRUNCATED)
             ? "Visible content truncated to accessibility budget"
             : "";
}
static void *parent(void *o) {
  LtAxLink *l = linkof(o);
  const LtAxNode *n = nodeof(o);
  if (!n)
    return NULL;
  return n->parent ? objectfor(l->bridge, n->parent)
                   : ((Gtk *)l->bridge->platform)->host_ax;
}
static int children(void *o) {
  LtAxLink *l = linkof(o);
  const LtAxNode *n = nodeof(o);
  if (!n)
    return 0;
  int count = 0;
  for (size_t i = 0; i < l->bridge->snapshot->count; i++)
    if (l->bridge->snapshot->nodes[i].parent == n->id &&
        (l->bridge->snapshot->nodes[i].state & LT_AX_VISIBLE))
      count++;
  return count;
}
static void *child(void *o, int index) {
  LtAxLink *l = linkof(o);
  const LtAxNode *n = nodeof(o);
  if (!n || index < 0)
    return NULL;
  for (size_t i = 0; i < l->bridge->snapshot->count; i++) {
    const LtAxNode *c = &l->bridge->snapshot->nodes[i];
    if (c->parent == n->id && (c->state & LT_AX_VISIBLE) && index-- == 0)
      return api.ref(objectfor(l->bridge, c->id));
  }
  return NULL;
}
static Hook *hookfor(void *o) {
  void *k = *(void **)o;
  for (size_t i = 0; i < 8; i++)
    if (hooks[i].klass == k)
      return &hooks[i];
  return NULL;
}
static int old_count(void *o, Hook *h) {
  int count =
      h && h->original_count ? ((int (*)(void *))h->original_count)(o) : 0;
  return count > 0 ? count : 0;
}
static int host_count(void *o) {
  Hook *h = hookfor(o);
  LtAxBridge *b = api.get_data(o, "letty-ax-host");
  return old_count(o, h) + (b && b->snapshot ? 1 : 0);
}
static void *host_child(void *o, int index) {
  Hook *h = hookfor(o);
  LtAxBridge *b = api.get_data(o, "letty-ax-host");
  int old = old_count(o, h);
  if (index >= 0 && index < old)
    return h && h->original_child
               ? ((void *(*)(void *, int))h->original_child)(o, index)
               : NULL;
  if (b && b->snapshot && index == old)
    return api.ref(objectfor(b, b->snapshot->nodes[0].id));
  return NULL;
}
static int index_in_parent(void *o) {
  LtAxLink *l = linkof(o);
  const LtAxNode *n = nodeof(o);
  if (!n)
    return -1;
  if (!n->parent) {
    Gtk *g = l->bridge->platform;
    return old_count(g->host_ax, g->hook);
  }
  int index = 0;
  for (size_t i = 0; i < l->bridge->snapshot->count; i++) {
    const LtAxNode *c = &l->bridge->snapshot->nodes[i];
    if (c->parent == n->parent && (c->state & LT_AX_VISIBLE)) {
      if (c->id == n->id)
        return index;
      index++;
    }
  }
  return -1;
}
static int role(void *o) {
  static const char *names[] = {"panel",       "page tab list", "page tab",
                                "panel",       "text",          "dialog",
                                "push button", "menu",          "menu item",
                                "scroll bar",  "terminal",      "label", "text", "entry"};
  const LtAxNode *n = nodeof(o);
  return api.role_for(n ? names[n->role] : "unknown");
}
static void state(void *set, const char *namev) {
  int s = api.state_for(namev);
  if (s > 0)
    api.add_state(set, s);
}
static void *states(void *o) {
  void *set = api.states_new();
  const LtAxNode *n = nodeof(o);
  if (!n) {
    state(set, "defunct");
    return set;
  }
  if (n->state & LT_AX_ENABLED) {
    state(set, "enabled");
    state(set, "sensitive");
  }
  if (n->state & LT_AX_VISIBLE) {
    state(set, "visible");
    state(set, "showing");
  }
  if (n->state & LT_AX_FOCUSABLE)
    state(set, "focusable");
  if (n->state & LT_AX_FOCUSED)
    state(set, "focused");
  if (n->role == LT_AX_TAB)
    state(set, "selectable");
  if (n->state & LT_AX_SELECTED) {
    state(set, "selectable");
    state(set, "selected");
  }
  if (n->state & LT_AX_EXPANDED) {
    state(set, "expandable");
    state(set, "expanded");
  }
  if (n->state & LT_AX_MODAL)
    state(set, "modal");
  if (n->state & LT_AX_CHECKED)
    state(set, "checked");
  if (n->state & LT_AX_READ_ONLY)
    state(set, "read-only");
  if (n->role == LT_AX_TERMINAL || n->role == LT_AX_DOCUMENT) {
    state(set, "multi-line");
    state(set, "selectable-text");
  }
  return set;
}
static void class_init(void *klass, void *data) {
  (void)data;
  void **v = slots(klass);
  v[0] = (void *)name;
  v[1] = (void *)description;
  v[2] = (void *)parent;
  v[3] = (void *)children;
  v[4] = (void *)child;
  v[5] = (void *)index_in_parent;
  v[7] = (void *)role;
  v[10] = (void *)states;
}
static unsigned action_at(const LtAxNode *n, int index) {
  if (!n || index < 0)
    return 0;
  for (unsigned bit = 1; bit <= 32; bit <<= 1)
    if (n->actions & bit) {
      if (index-- == 0)
        return bit;
    }
  return 0;
}
static int action_count(void *o) {
  const LtAxNode *n = nodeof(o);
  int count = 0;
  if (n)
    for (unsigned bit = 1; bit <= 32; bit <<= 1)
      if (n->actions & bit)
        count++;
  return count;
}
static int do_action(void *o, int index) {
  LtAxLink *l = linkof(o);
  return l ? lt_ax_invoke(l->bridge, l->id, action_at(nodeof(o), index)) : 0;
}
static const char *action_name(void *o, int index) {
  switch (action_at(nodeof(o), index)) {
  case LT_AX_PRESS:
    return "press";
  case LT_AX_FOCUS:
    return "focus";
  case LT_AX_INCREMENT:
    return "increment";
  case LT_AX_DECREMENT:
    return "decrement";
  case LT_AX_COPY:
    return "copy visible content";
  case LT_AX_DISMISS:
    return "dismiss";
  default:
    return NULL;
  }
}
static const char *keybinding(void *o, int index) {
  (void)o;
  (void)index;
  return NULL;
}
static void action_init(void *iface, void *data) {
  (void)data;
  void **v = (void **)((Type *)iface + 2);
  v[0] = (void *)do_action;
  v[1] = (void *)action_count;
  v[2] = (void *)action_name;
  v[3] = (void *)action_name;
  v[4] = (void *)keybinding;
  v[6] = (void *)action_name;
}
static char *text_range(void *o, int start, int end) {
  const LtAxNode *n = nodeof(o);
  if (!n || start < 0)
    return NULL;
  size_t count = lt_ax_scalars(n->value, n->value_len);
  if ((size_t)start > count || end < -1 || (end >= 0 && end < start))
    return NULL;
  size_t first = lt_ax_byte_at(n->value, n->value_len, (size_t)start),
         last = lt_ax_byte_at(n->value, n->value_len,
                              end < 0 ? count : (size_t)end);
  char *text = api.malloc(last - first + 1);
  if (!text)
    return NULL;
  memcpy(text, n->value + first, last - first);
  text[last - first] = 0;
  return text;
}
static int text_count(void *o) {
  const LtAxNode *n = nodeof(o);
  return n ? (int)lt_ax_scalars(n->value, n->value_len) : 0;
}
static unsigned character(void *o, int offset) {
  const LtAxNode *n = nodeof(o);
  if (!n || offset < 0)
    return 0;
  size_t at = lt_ax_byte_at(n->value, n->value_len, (size_t)offset);
  if (at == n->value_len)
    return 0;
  unsigned c = (unsigned char)n->value[at++], value = c;
  if (c >= 192) {
    unsigned need = c < 224 ? 1 : c < 240 ? 2 : 3;
    value = c & ((1u << (6 - need)) - 1);
    while (need--)
      value = (value << 6) | ((unsigned char)n->value[at++] & 63);
  }
  return value;
}
static int caret(void *o) {
  const LtAxNode *n = nodeof(o);
  return n ? (int)lt_ax_scalars(n->value, n->caret) : 0;
}
static int selection_count(void *o) {
  const LtAxNode *n = nodeof(o);
  return n && n->selection_start != n->selection_end ? 1 : 0;
}
static char *selection(void *o, int index, int *start, int *end) {
  const LtAxNode *n = nodeof(o);
  if (!n || index != 0 || !selection_count(o))
    return NULL;
  *start = (int)lt_ax_scalars(n->value, n->selection_start);
  *end = (int)lt_ax_scalars(n->value, n->selection_end);
  return text_range(o, *start, *end);
}
static void text_init(void *iface, void *data) {
  (void)data;
  void **v = (void **)((Type *)iface + 2);
  v[0] = (void *)text_range;
  v[3] = (void *)character;
  v[5] = (void *)caret;
  v[9] = (void *)text_count;
  v[11] = (void *)selection_count;
  v[12] = (void *)selection;
}
static int integer(double x) {
  return x < INT_MIN ? INT_MIN : x > INT_MAX ? INT_MAX : (int)x;
}
static int floor_integer(double x) {
  int result = integer(x);
  return result > INT_MIN && x < result ? result - 1 : result;
}
static int ceil_integer(double x) {
  int result = integer(x);
  return result < INT_MAX && x > result ? result + 1 : result;
}
static void extents(void *o, int *x, int *y, int *w, int *h, int coord) {
  const LtAxNode *n = nodeof(o);
  LtAxLink *l = linkof(o);
  if (!n) {
    *x = *y = *w = *h = 0;
    return;
  }
  int bx = 0, by = 0;
  void *top = api.toplevel(l->bridge->host);
  api.translate(l->bridge->host, top, 0, 0, &bx, &by);
  if (coord == 0) {
    int sx = 0, sy = 0;
    void *window = api.window(top);
    if (window)
      api.origin(window, &sx, &sy);
    bx += sx;
    by += sy;
  }
  double px = n->bounds.x, py = n->bounds.y;
  if (coord == 2) {
    bx = by = 0;
    const LtAxNode *p = lt_ax_find(l->bridge, n->parent);
    if (p) {
      px -= p->bounds.x;
      py -= p->bounds.y;
    }
  }
  *x = floor_integer(px + bx);
  *y = floor_integer(py + by);
  *w = ceil_integer(n->bounds.width);
  *h = ceil_integer(n->bounds.height);
}
static int contains(void *o, int x, int y, int coord) {
  int bx, by, w, h;
  extents(o, &bx, &by, &w, &h, coord);
  return (int64_t)x >= bx && (int64_t)y >= by && (int64_t)x < (int64_t)bx + w &&
         (int64_t)y < (int64_t)by + h;
}
static void *at_point(void *o, int x, int y, int coord) {
  LtAxLink *l = linkof(o);
  const LtAxNode *n = nodeof(o);
  if (!n)
    return NULL;
  if (coord == 2) {
    const LtAxNode *p = lt_ax_find(l->bridge, n->parent);
    x = integer((double)x - n->bounds.x + (p ? p->bounds.x : 0));
    y = integer((double)y - n->bounds.y + (p ? p->bounds.y : 0));
  }
  for (size_t i = l->bridge->snapshot->count; i > 0; i--) {
    const LtAxNode *c = &l->bridge->snapshot->nodes[i - 1];
    void *object = objectfor(l->bridge, c->id);
    if (c->parent == n->id && (c->state & LT_AX_VISIBLE) &&
        contains(object, x, y, coord))
      return api.ref(object);
  }
  return NULL;
}
static int grab_focus(void *o) {
  LtAxLink *l = linkof(o);
  return l ? lt_ax_invoke(l->bridge, l->id, LT_AX_FOCUS) : 0;
}
static void component_init(void *iface, void *data) {
  (void)data;
  void **v = (void **)((Type *)iface + 2);
  v[1] = (void *)contains;
  v[2] = (void *)at_point;
  v[3] = (void *)extents;
  v[6] = (void *)grab_focus;
}
static int register_nodes(void) {
  if (api.node_type)
    return 1;
  Query q = {0};
  api.query(api.atk_type(), &q);
  if (q.class_size < api.base_class + 11 * sizeof(void *) || !q.instance_size)
    return 0;
  api.node_type =
      api.register_type(api.atk_type(), "LettyAccessibleNode", q.class_size,
                        class_init, q.instance_size, NULL, 0);
  if (!api.node_type)
    return 0;
  Interface action = {action_init, NULL, NULL}, text = {text_init, NULL, NULL},
            component = {component_init, NULL, NULL};
  api.add_interface(api.node_type, api.action_type(), &action);
  api.add_interface(api.node_type, api.text_type(), &text);
  api.add_interface(api.node_type, api.component_type(), &component);
  return 1;
}
int lt_ax_platform_capability(void) { return load(); }
int lt_ax_platform_attach(LtAxBridge *b) {
  if (!load() || !register_nodes())
    return 0;
  Gtk *g = calloc(1, sizeof(*g));
  if (!g)
    return 0;
  g->host_ax = api.accessible(b->host);
  if (!g->host_ax || api.get_data(g->host_ax, "letty-ax-host")) {
    free(g);
    return 0;
  }
  void *klass = *(void **)g->host_ax;
  Hook *hook = NULL;
  for (size_t i = 0; i < 8; i++)
    if (hooks[i].klass == klass) {
      hook = &hooks[i];
      break;
    }
  if (!hook)
    for (size_t i = 0; i < 8; i++)
      if (!hooks[i].klass) {
        hook = &hooks[i];
        hook->klass = klass;
        hook->original_count = slots(klass)[3];
        hook->original_child = slots(klass)[4];
        slots(klass)[3] = (void *)host_count;
        slots(klass)[4] = (void *)host_child;
        break;
      }
  if (!hook) {
    free(g);
    return 0;
  }
  hook->refs++;
  g->hook = hook;
  api.ref(b->host);
  api.ref(g->host_ax);
  api.set_data(g->host_ax, "letty-ax-host", b);
  b->platform = g;
  return 1;
}
static void retire(void *o) {
  LtAxLink *l = linkof(o);
  if (l)
    l->bridge = NULL;
  int defunct = api.state_for("defunct");
  if (defunct > 0)
    api.notify_state(o, defunct, 1);
  api.unref(o);
}
int lt_ax_platform_update(LtAxBridge *b, unsigned flags) {
  Gtk *g = b->platform;
  LtAxSnapshot *s = b->snapshot;
  void *next[LT_AX_MAX_NODES] = {0};
  for (size_t i = 0; i < s->count; i++) {
    next[i] = objectfor(b, s->nodes[i].id);
    if (next[i])
      continue;
    next[i] = api.new_object(api.node_type, NULL);
    LtAxLink *l = calloc(1, sizeof(*l));
    if (!next[i] || !l) {
      free(l);
      for (size_t j = 0; j <= i; j++)
        if (next[j] && !objectfor(b, s->nodes[j].id))
          retire(next[j]);
      return 0;
    }
    l->bridge = b;
    l->id = s->nodes[i].id;
    api.set_data_full(next[i], "letty-ax-node", l, free);
    api.initialize(next[i], b);
  }
  if (flags & LT_AX_NOTIFY_TREE)
    for (size_t i = 0; i < g->count; i++) {
      const LtAxNode *n = lt_ax_find(b, g->ids[i]);
      if (g->visible[i] &&
          (!n || n->parent != g->parents[i] || !(n->state & LT_AX_VISIBLE))) {
        void *p = g->parents[i] ? objectfor(b, g->parents[i]) : g->host_ax;
        unsigned index = 0;
        if (!g->parents[i])
          index = (unsigned)old_count(g->host_ax, g->hook);
        else
          for (size_t j = 0; j < i; j++)
            if (g->parents[j] == g->parents[i] && g->visible[j])
              index++;
        if (p)
          api.emit(p, "children-changed::remove", index, g->objects[i]);
      }
    }
  unsigned changed[LT_AX_MAX_NODES] = {0};
  for (size_t i = 0; i < s->count; i++)
    for (size_t j = 0; j < g->count; j++)
      if (s->nodes[i].id == g->ids[j])
        changed[i] = g->states[j] ^ s->nodes[i].state;
  unsigned added[LT_AX_MAX_NODES] = {0};
  for (size_t i = 0; i < s->count; i++) {
    if (!(s->nodes[i].state & LT_AX_VISIBLE))
      continue;
    added[i] = 1;
    for (size_t j = 0; j < g->count; j++)
      if (g->ids[j] == s->nodes[i].id && g->parents[j] == s->nodes[i].parent &&
          g->visible[j]) {
        added[i] = 0;
        break;
      }
  }
  for (size_t i = 0; i < g->count; i++) {
    int keep = 0;
    for (size_t j = 0; j < s->count; j++)
      if (g->objects[i] == next[j])
        keep = 1;
    if (!keep)
      retire(g->objects[i]);
  }
  uint64_t old_focus = g->focused;
  g->count = s->count;
  g->focused = 0;
  for (size_t i = 0; i < s->count; i++) {
    g->objects[i] = next[i];
    g->ids[i] = s->nodes[i].id;
    g->parents[i] = s->nodes[i].parent;
    g->visible[i] = (s->nodes[i].state & LT_AX_VISIBLE) != 0;
    g->states[i] = s->nodes[i].state;
    if (s->nodes[i].state & LT_AX_FOCUSED)
      g->focused = s->nodes[i].id;
  }
  if (flags & LT_AX_NOTIFY_TREE) {
    for (size_t i = 0; i < s->count; i++) {
      api.notify(next[i], "accessible-name");
      api.notify(next[i], "accessible-role");
      if (added[i]) {
        void *p =
            s->nodes[i].parent ? objectfor(b, s->nodes[i].parent) : g->host_ax;
        if (p)
          api.emit(p, "children-changed::add",
                   (unsigned)index_in_parent(next[i]), next[i]);
      }
    }
    api.emit(g->host_ax, "visible-data-changed");
  }
  if (flags & LT_AX_NOTIFY_STATE) {
    const unsigned bits[] = {LT_AX_ENABLED,  LT_AX_ENABLED, LT_AX_SELECTED,
                             LT_AX_EXPANDED, LT_AX_CHECKED, LT_AX_VISIBLE,
                             LT_AX_VISIBLE,  LT_AX_MODAL};
    const char *names[] = {"enabled", "sensitive", "selected", "expanded",
                           "checked", "visible",   "showing",  "modal"};
    for (size_t i = 0; i < s->count; i++)
      for (size_t j = 0; j < sizeof(bits) / sizeof(bits[0]); j++)
        if (changed[i] & bits[j]) {
          int state_type = api.state_for(names[j]);
          if (state_type > 0)
            api.notify_state(next[i], state_type,
                             (s->nodes[i].state & bits[j]) != 0);
        }
  }
  if (flags & LT_AX_NOTIFY_FOCUS) {
    int focused_state = api.state_for("focused");
    void *old = objectfor(b, old_focus);
    if (old && old_focus != g->focused)
      api.notify_state(old, focused_state, 0);
    void *focus = objectfor(b, g->focused);
    if (focus) {
      api.notify_state(focus, focused_state, 1);
      api.emit(g->host_ax, "active-descendant-changed", focus);
    }
  }
  if (flags & LT_AX_NOTIFY_VALUE) {
    void *focus = objectfor(b, g->focused);
    if (focus)
      api.emit(focus, "visible-data-changed");
  }
  return 1;
}
void lt_ax_platform_detach(LtAxBridge *b) {
  Gtk *g = b->platform;
  if (!g)
    return;
  api.set_data(g->host_ax, "letty-ax-host", NULL);
  Hook *h = g->hook;
  if (h && !--h->refs) {
    if (slots(h->klass)[3] == (void *)host_count)
      slots(h->klass)[3] = h->original_count;
    if (slots(h->klass)[4] == (void *)host_child)
      slots(h->klass)[4] = h->original_child;
    memset(h, 0, sizeof(*h));
  }
  for (size_t i = 0; i < g->count; i++)
    retire(g->objects[i]);
  api.unref(g->host_ax);
  api.unref(b->host);
  free(g);
  b->platform = NULL;
}
#elif !defined(__APPLE__)
int lt_ax_platform_capability(void) { return 0; }
int lt_ax_platform_attach(LtAxBridge *b) {
  (void)b;
  return 0;
}
int lt_ax_platform_update(LtAxBridge *b, unsigned f) {
  (void)b;
  (void)f;
  return 0;
}
void lt_ax_platform_detach(LtAxBridge *b) { (void)b; }
#endif
