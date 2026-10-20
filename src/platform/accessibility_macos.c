#include "accessibility_internal.h"
#ifdef __APPLE__
#include <CoreGraphics/CGGeometry.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* Public NSAccessibilityElement API, implemented with the ObjC runtime so this
 * remains a C bridge and needs no generated Objective-C source or ARC mode. */
extern void NSAccessibilityPostNotification(id, id);
typedef struct {
  unsigned long location, length;
} Range;
typedef struct {
  id objects[LT_AX_MAX_NODES];
  uint64_t ids[LT_AX_MAX_NODES];
  size_t count;
  Class original;
  id old_children;
  BOOL old_element, updating;
} Mac;
#if OBJC_BOOL_IS_BOOL
#define BOOL_ENC "B"
#else
#define BOOL_ENC "c"
#endif
static char association;
static SEL sel(const char *s) { return sel_registerName(s); }
static id send0(id x, const char *s) {
  return ((id (*)(id, SEL))objc_msgSend)(x, sel(s));
}
static void setid(id x, const char *s, id value) {
  ((void (*)(id, SEL, id))objc_msgSend)(x, sel(s), value);
}
static void setbool(id x, const char *s, BOOL value) {
  ((void (*)(id, SEL, BOOL))objc_msgSend)(x, sel(s), value);
}
static void release(id x) {
  if (x)
    ((void (*)(id, SEL))objc_msgSend)(x, sel("release"));
}
static id retain(id x) { return x ? send0(x, "retain") : nil; }
static id str(const char *s) {
  return ((id (*)(id, SEL, const char *))objc_msgSend)(
      (id)objc_getClass("NSString"), sel("stringWithUTF8String:"), s ? s : "");
}
static CGRect getrect(id x, const char *s) {
#if defined(__x86_64__)
  CGRect r;
  ((void (*)(CGRect *, id, SEL))objc_msgSend_stret)(&r, x, sel(s));
  return r;
#else
  return ((CGRect (*)(id, SEL))objc_msgSend)(x, sel(s));
#endif
}
static CGRect convert(id view, CGRect r) {
#if defined(__x86_64__)
  CGRect out;
  ((void (*)(CGRect *, id, SEL, CGRect, id))objc_msgSend_stret)(
      &out, view, sel("convertRect:toView:"), r, nil);
  return out;
#else
  return ((CGRect (*)(id, SEL, CGRect, id))objc_msgSend)(
      view, sel("convertRect:toView:"), r, nil);
#endif
}
static CGRect screen(id window, CGRect r) {
#if defined(__x86_64__)
  CGRect out;
  ((void (*)(CGRect *, id, SEL, CGRect))objc_msgSend_stret)(
      &out, window, sel("convertRectToScreen:"), r);
  return out;
#else
  return ((CGRect (*)(id, SEL, CGRect))objc_msgSend)(
      window, sel("convertRectToScreen:"), r);
#endif
}
static CGRect nodeframe(LtAxBridge *b, const LtAxNode *n) {
  CGRect r =
      CGRectMake(n->bounds.x, n->bounds.y, n->bounds.width, n->bounds.height);
  id view = (id)b->host;
  BOOL flipped = ((BOOL (*)(id, SEL))objc_msgSend)(view, sel("isFlipped"));
  if (!flipped)
    r.origin.y =
        getrect(view, "bounds").size.height - r.origin.y - r.size.height;
  id window = send0(view, "window");
  return window ? screen(window, convert(view, r)) : r;
}
static LtAxLink *linkof(id x) {
  void *p = NULL;
  object_getInstanceVariable(x, "_lt_ax_link", &p);
  return p;
}
static LtAxBridge *hostbridge(id x) {
  id box = objc_getAssociatedObject(x, &association);
  return box ? ((void *(*)(id, SEL))objc_msgSend)(box, sel("pointerValue"))
             : NULL;
}
static id objectfor(LtAxBridge *b, uint64_t idv) {
  Mac *m = b->platform;
  for (size_t i = 0; i < m->count; i++)
    if (m->ids[i] == idv)
      return m->objects[i];
  return nil;
}
static BOOL act(id x, uint32_t action) {
  LtAxLink *l = linkof(x);
  return l && l->bridge ? (BOOL)lt_ax_invoke(l->bridge, l->id, action) : NO;
}
static BOOL press(id x, SEL s) {
  (void)s;
  return act(x, LT_AX_PRESS);
}
static BOOL increment(id x, SEL s) {
  (void)s;
  return act(x, LT_AX_INCREMENT);
}
static BOOL decrement(id x, SEL s) {
  (void)s;
  return act(x, LT_AX_DECREMENT);
}
static BOOL copy_action(id x, SEL s) {
  (void)s;
  return act(x, LT_AX_COPY);
}
static BOOL dismiss(id x, SEL s) {
  (void)s;
  return act(x, LT_AX_DISMISS);
}
static BOOL focus_action(id x, SEL s) {
  (void)s;
  return act(x, LT_AX_FOCUS);
}
static void focused(id x, SEL s, BOOL value) {
  LtAxLink *l = linkof(x);
  if (l && l->bridge && ((Mac *)l->bridge->platform)->updating) {
    struct objc_super sup = {
        x, class_getSuperclass(objc_getClass("LettyAXElement"))};
    ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, s,
                                                                  value);
  } else if (value)
    act(x, LT_AX_FOCUS);
}
static id focused_child(id x, SEL s) {
  (void)s;
  LtAxBridge *b = hostbridge(x);
  if (!b) {
    LtAxLink *l = linkof(x);
    if (l)
      b = l->bridge;
  }
  if (b && b->snapshot)
    for (size_t i = 0; i < b->snapshot->count; i++)
      if (b->snapshot->nodes[i].state & LT_AX_FOCUSED)
        return objectfor(b, b->snapshot->nodes[i].id);
  return nil;
}
static id hit_test(id x, SEL command, CGPoint point) {
  (void)command;
  LtAxBridge *b = hostbridge(x);
  if (!b) {
    LtAxLink *l = linkof(x);
    if (l)
      b = l->bridge;
  }
  if (!b || !b->snapshot)
    return nil;
  for (size_t i = b->snapshot->count; i > 0; i--) {
    const LtAxNode *n = &b->snapshot->nodes[i - 1];
    if (!(n->state & LT_AX_VISIBLE))
      continue;
    CGRect rect = nodeframe(b, n);
    if (point.x >= rect.origin.x && point.y >= rect.origin.y &&
        point.x < rect.origin.x + rect.size.width &&
        point.y < rect.origin.y + rect.size.height)
      return objectfor(b, n->id);
  }
  return nil;
}
static id string_range(id x, SEL s, Range range) {
  (void)s;
  id value = send0(x, "accessibilityValue");
  unsigned long length =
      ((unsigned long (*)(id, SEL))objc_msgSend)(value, sel("length"));
  if (range.location > length || range.length > length - range.location)
    return nil;
  return ((id (*)(id, SEL, Range))objc_msgSend)(
      value, sel("substringWithRange:"), range);
}
static BOOL allowed(id x, SEL command, SEL requested) {
  LtAxLink *l = linkof(x);
  const LtAxNode *n = l ? lt_ax_find(l->bridge, l->id) : NULL;
  if (!n)
    return NO;
  if (requested == sel("accessibilityPerformPress"))
    return lt_ax_can_invoke(l->bridge, l->id, LT_AX_PRESS);
  if (requested == sel("accessibilityPerformIncrement"))
    return lt_ax_can_invoke(l->bridge, l->id, LT_AX_INCREMENT);
  if (requested == sel("accessibilityPerformDecrement"))
    return lt_ax_can_invoke(l->bridge, l->id, LT_AX_DECREMENT);
  if (requested == sel("setAccessibilityFocused:"))
    return lt_ax_can_invoke(l->bridge, l->id, LT_AX_FOCUS);
  if (requested == sel("setAccessibilityValue:") ||
      requested == sel("setAccessibilitySelectedText:") ||
      requested == sel("setAccessibilitySelectedTextRange:"))
    return NO;
  struct objc_super sup = {
      x, class_getSuperclass(objc_getClass("LettyAXElement"))};
  return ((BOOL (*)(struct objc_super *, SEL, SEL))objc_msgSendSuper)(
      &sup, command, requested);
}
static void dealloc(id x, SEL s) {
  LtAxLink *l = linkof(x);
  free(l);
  object_setInstanceVariable(x, "_lt_ax_link", NULL);
  struct objc_super sup = {
      x, class_getSuperclass(objc_getClass("LettyAXElement"))};
  ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, s);
}
static Class element_class(void) {
  Class c = objc_getClass("LettyAXElement");
  if (c)
    return c;
  c = objc_allocateClassPair(objc_getClass("NSAccessibilityElement"),
                             "LettyAXElement", 0);
  if (!c)
    return Nil;
  class_addIvar(c, "_lt_ax_link", sizeof(void *), sizeof(void *) == 8 ? 3 : 2,
                "^v");
  class_addMethod(c, sel("dealloc"), (IMP)dealloc, "v@:");
  class_addMethod(c, sel("accessibilityPerformPress"), (IMP)press,
                  BOOL_ENC "@:");
  class_addMethod(c, sel("accessibilityPerformIncrement"), (IMP)increment,
                  BOOL_ENC "@:");
  class_addMethod(c, sel("accessibilityPerformDecrement"), (IMP)decrement,
                  BOOL_ENC "@:");
  class_addMethod(c, sel("lettyCopy"), (IMP)copy_action, BOOL_ENC "@:");
  class_addMethod(c, sel("lettyDismiss"), (IMP)dismiss, BOOL_ENC "@:");
  class_addMethod(c, sel("lettyFocus"), (IMP)focus_action, BOOL_ENC "@:");
  class_addMethod(c, sel("setAccessibilityFocused:"), (IMP)focused,
                  "v@:" BOOL_ENC);
  class_addMethod(c, sel("accessibilityFocusedUIElement"), (IMP)focused_child,
                  "@@:");
  class_addMethod(c, sel("accessibilityHitTest:"), (IMP)hit_test,
                  "@@:{CGPoint=dd}");
  class_addMethod(c, sel("accessibilityStringForRange:"), (IMP)string_range,
                  "@@:{_NSRange=QQ}");
  class_addMethod(c, sel("isAccessibilitySelectorAllowed:"), (IMP)allowed,
                  BOOL_ENC "@::");
  objc_registerClassPair(c);
  return c;
}
int lt_ax_platform_capability(void) {
  return objc_getClass("NSAccessibilityElement") != Nil;
}
int lt_ax_platform_attach(LtAxBridge *b) {
  if (hostbridge((id)b->host))
    return 0;
  Mac *m = calloc(1, sizeof(*m));
  if (!m)
    return 0;
  b->platform = m;
  id host = retain((id)b->host);
  m->old_children = retain(send0(host, "accessibilityChildren"));
  m->old_element =
      ((BOOL (*)(id, SEL))objc_msgSend)(host, sel("isAccessibilityElement"));
  m->original = object_getClass(host);
  char name[256];
  const char *base = class_getName(m->original);
  if (strlen(base) > 220) {
    release(host);
    release(m->old_children);
    free(m);
    b->platform = NULL;
    return 0;
  }
  snprintf(name, sizeof(name), "LettyAXHost_%s", base);
  Class subclass = objc_getClass(name);
  if (!subclass) {
    subclass = objc_allocateClassPair(m->original, name, 0);
    if (subclass) {
      class_addMethod(subclass, sel("accessibilityFocusedUIElement"),
                      (IMP)focused_child, "@@:");
      class_addMethod(subclass, sel("accessibilityHitTest:"), (IMP)hit_test,
                      "@@:{CGPoint=dd}");
      objc_registerClassPair(subclass);
    }
  }
  if (!subclass || !element_class()) {
    release(host);
    release(m->old_children);
    free(m);
    b->platform = NULL;
    return 0;
  }
  id box = ((id (*)(id, SEL, void *))objc_msgSend)((id)objc_getClass("NSValue"),
                                                   sel("valueWithPointer:"), b);
  objc_setAssociatedObject(host, &association, box,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  object_setClass(host, subclass);
  setbool(host, "setAccessibilityElement:", NO);
  return 1;
}
static void retired(id object) {
  LtAxLink *l = linkof(object);
  if (l)
    l->bridge = NULL;
  setbool(object, "setAccessibilityElement:", NO);
  setbool(object, "setAccessibilityEnabled:", NO);
  setid(object, "setAccessibilityValue:", nil);
  setid(object, "setAccessibilityCustomActions:", nil);
  setid(object, "setAccessibilityParent:", nil);
  setid(object, "setAccessibilityChildren:", nil);
  release(object);
}
static const char *roles[] = {"AXGroup",     "AXTabGroup",  "AXRadioButton",
                              "AXGroup",     "AXTextField", "AXDialog",
                              "AXButton",    "AXMenu",      "AXMenuItem",
                              "AXScrollBar", "AXTextArea",  "AXStaticText", "AXTextArea", "AXTextField"};
static size_t utf16(const char *s, size_t len) {
  size_t units = 0;
  for (size_t i = 0; i < len; i++) {
    unsigned c = (unsigned char)s[i];
    if ((c & 192) != 128)
      units += c >= 240 ? 2 : 1;
  }
  return units;
}
int lt_ax_platform_update(LtAxBridge *b, unsigned flags) {
  Mac *m = b->platform;
  LtAxSnapshot *s = b->snapshot;
  id next[LT_AX_MAX_NODES] = {0};
  for (size_t i = 0; i < s->count; i++) {
    next[i] = objectfor(b, s->nodes[i].id);
    if (next[i])
      continue;
    next[i] = send0(send0((id)element_class(), "alloc"), "init");
    LtAxLink *l = calloc(1, sizeof(*l));
    if (!next[i] || !l) {
      free(l);
      for (size_t j = 0; j <= i; j++)
        if (next[j] && !objectfor(b, s->nodes[j].id))
          retired(next[j]);
      return 0;
    }
    l->bridge = b;
    l->id = s->nodes[i].id;
    object_setInstanceVariable(next[i], "_lt_ax_link", l);
  }
  for (size_t i = 0; i < m->count; i++) {
    int keep = 0;
    for (size_t j = 0; j < s->count; j++)
      if (m->objects[i] == next[j])
        keep = 1;
    if (!keep)
      retired(m->objects[i]);
  }
  m->count = s->count;
  for (size_t i = 0; i < s->count; i++) {
    m->objects[i] = next[i];
    m->ids[i] = s->nodes[i].id;
  }
  m->updating = YES;
  for (size_t i = 0; i < s->count; i++) {
    const LtAxNode *n = &s->nodes[i];
    id obj = next[i];
    setbool(obj, "setAccessibilityElement:", (n->state & LT_AX_VISIBLE) != 0);
    setid(obj, "setAccessibilityRole:", str(roles[n->role]));
    setid(obj, "setAccessibilitySubrole:",
          n->role == LT_AX_SEARCH ? str("AXSearchField") : nil);
    setid(obj, "setAccessibilityLabel:", str(n->label));
    setid(obj, "setAccessibilityValue:", str(n->value));
    char identifier[48];
    snprintf(identifier, sizeof(identifier), "letty-%llu",
             (unsigned long long)n->id);
    setid(obj, "setAccessibilityIdentifier:", str(identifier));
    setid(obj, "setAccessibilityParent:",
          n->parent ? objectfor(b, n->parent) : (id)b->host);
    setbool(obj, "setAccessibilityEnabled:", (n->state & LT_AX_ENABLED) != 0);
    setbool(obj, "setAccessibilityFocused:", (n->state & LT_AX_FOCUSED) != 0);
    setbool(obj, "setAccessibilitySelected:", (n->state & LT_AX_SELECTED) != 0);
    setbool(obj, "setAccessibilityExpanded:", (n->state & LT_AX_EXPANDED) != 0);
    setbool(obj, "setAccessibilityModal:", (n->state & LT_AX_MODAL) != 0);
    ((void (*)(id, SEL, CGRect))objc_msgSend)(
        obj, sel("setAccessibilityFrame:"), nodeframe(b, n));
    if (n->role == LT_AX_TERMINAL || n->role == LT_AX_SEARCH || n->role == LT_AX_DOCUMENT || n->role == LT_AX_TEXT_FIELD) {
      size_t start = n->selection_start, end = n->selection_end;
      if (start == end)
        start = end = n->caret;
      Range range = {utf16(n->value, start),
                     utf16(n->value, end) - utf16(n->value, start)};
      ((void (*)(id, SEL, Range))objc_msgSend)(
          obj, sel("setAccessibilitySelectedTextRange:"), range);
      ((void (*)(id, SEL, long))objc_msgSend)(
          obj, sel("setAccessibilityNumberOfCharacters:"),
          (long)utf16(n->value, n->value_len));
      id value = str(n->value);
      id selection = ((id (*)(id, SEL, Range))objc_msgSend)(
          value, sel("substringWithRange:"), range);
      setid(obj, "setAccessibilitySelectedText:", selection);
    }
    id children = send0((id)objc_getClass("NSMutableArray"), "array");
    for (size_t j = 0; j < s->count; j++)
      if (s->nodes[j].parent == n->id)
        ((void (*)(id, SEL, id))objc_msgSend)(children, sel("addObject:"),
                                              next[j]);
    setid(obj, "setAccessibilityChildren:", children);
    id actions = send0((id)objc_getClass("NSMutableArray"), "array");
    const char *names[] = {"Copy visible content", "Dismiss", "Focus"};
    const char *selectors[] = {"lettyCopy", "lettyDismiss", "lettyFocus"};
    unsigned bits[] = {LT_AX_COPY, LT_AX_DISMISS, LT_AX_FOCUS};
    for (size_t j = 0; j < 3; j++)
      if (n->actions & bits[j]) {
        id action = ((id (*)(id, SEL, id, id, SEL))objc_msgSend)(
            send0((id)objc_getClass("NSAccessibilityCustomAction"), "alloc"),
            sel("initWithName:target:selector:"), str(names[j]), obj,
            sel(selectors[j]));
        if (action) {
          ((void (*)(id, SEL, id))objc_msgSend)(actions, sel("addObject:"),
                                                action);
          release(action);
        }
      }
    setid(obj, "setAccessibilityCustomActions:", actions);
  }
  id roots = send0((id)objc_getClass("NSArray"), "array");
  if (s->count)
    roots = ((id (*)(id, SEL, id))objc_msgSend)(
        (id)objc_getClass("NSArray"), sel("arrayWithObject:"), next[0]);
  setid((id)b->host, "setAccessibilityChildren:", roots);
  m->updating = NO;
  if (flags & (LT_AX_NOTIFY_TREE | LT_AX_NOTIFY_STATE))
    NSAccessibilityPostNotification((id)b->host, str("AXLayoutChanged"));
  if (flags & LT_AX_NOTIFY_FOCUS) {
    id focus = focused_child((id)b->host, NULL);
    if (focus)
      NSAccessibilityPostNotification(focus, str("AXFocusedUIElementChanged"));
  }
  if (flags & LT_AX_NOTIFY_VALUE) {
    id focus = focused_child((id)b->host, NULL);
    if (focus)
      NSAccessibilityPostNotification(focus, str("AXValueChanged"));
  }
  return 1;
}
void lt_ax_platform_detach(LtAxBridge *b) {
  Mac *m = b->platform;
  if (!m)
    return;
  id host = (id)b->host;
  objc_setAssociatedObject(host, &association, nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  object_setClass(host, m->original);
  setid(host, "setAccessibilityChildren:", m->old_children);
  setbool(host, "setAccessibilityElement:", m->old_element);
  for (size_t i = 0; i < m->count; i++)
    retired(m->objects[i]);
  release(m->old_children);
  release(host);
  free(m);
  b->platform = NULL;
}
#endif
