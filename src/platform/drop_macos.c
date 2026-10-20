#if defined(__APPLE__)
#include "drop_internal.h"
#include <CoreGraphics/CoreGraphics.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
extern id const NSPasteboardURLReadingFileURLsOnlyKey;
extern id const NSPasteboardTypeFileURL;
#if OBJC_BOOL_IS_BOOL
#define BOOL_ENC "B"
#else
#define BOOL_ENC "c"
#endif
static SEL sel(const char *s) { return sel_registerName(s); }
static id get(id o, const char *s) { return ((id(*)(id,SEL))objc_msgSend)(o,sel(s)); }
static id string(const char *s) { return ((id(*)(id,SEL,const char*))objc_msgSend)((id)objc_getClass("NSString"),sel("stringWithUTF8String:"),s); }
static void release(id x) { if (x) ((void(*)(id,SEL))objc_msgSend)(x,sel("release")); }
static id retain(id x) { return x ? get(x,"retain") : nil; }
static CGPoint position(id view, id dragging) {
  CGPoint p = ((CGPoint(*)(id,SEL))objc_msgSend)(dragging,sel("draggingLocation"));
  return ((CGPoint(*)(id,SEL,CGPoint,id))objc_msgSend)(view,sel("convertPoint:fromView:"),p,nil);
}
static id classes(void) {
  return ((id(*)(id,SEL,id))objc_msgSend)((id)objc_getClass("NSArray"),sel("arrayWithObject:"),(id)objc_getClass("NSURL"));
}
static id options(void) {
  id yes = ((id(*)(id,SEL,BOOL))objc_msgSend)((id)objc_getClass("NSNumber"),sel("numberWithBool:"),YES);
  return ((id(*)(id,SEL,id,id))objc_msgSend)((id)objc_getClass("NSDictionary"),sel("dictionaryWithObject:forKey:"),yes,NSPasteboardURLReadingFileURLsOnlyKey);
}
static bool files(id dragging) {
  id pb = get(dragging,"draggingPasteboard");
  return pb && ((BOOL(*)(id,SEL,id,id))objc_msgSend)(pb,sel("canReadObjectForClasses:options:"),classes(),options());
}
static unsigned long entered(id view, SEL cmd, id dragging) {
  (void)cmd;
  LtDropBridge *b = lt_drop_find(view);
  if (!b || !files(dragging)) return 0;
  const unsigned long mask = ((unsigned long(*)(id,SEL))objc_msgSend)(dragging,sel("draggingSourceOperationMask"));
  CGPoint p = position(view,dragging);
  return (mask & 1) && lt_drop_probe(b,p.x,p.y) ? 1 : 0;
}
static BOOL prepare(id view, SEL cmd, id dragging) {
  (void)cmd;
  LtDropBridge *b = lt_drop_find(view);
  if (!b || !files(dragging)) return NO;
  CGPoint p = position(view,dragging);
  return lt_drop_reserve(b,p.x,p.y) ? YES : NO;
}
static BOOL perform(id view, SEL cmd, id dragging) {
  (void)cmd;
  LtDropBridge *b = lt_drop_find(view);
  if (!b || !b->token) return NO;
  id pool = get(get((id)objc_getClass("NSAutoreleasePool"),"alloc"),"init");
  id pb = get(dragging,"draggingPasteboard");
  id items = get(pb,"pasteboardItems");
  unsigned long n = ((unsigned long(*)(id,SEL))objc_msgSend)(items,sel("count"));
  bool accepted = false;
  if (!n || n > 16) goto done;
  id urls = ((id(*)(id,SEL,id,id))objc_msgSend)(pb,sel("readObjectsForClasses:options:"),classes(),options());
  unsigned long count = ((unsigned long(*)(id,SEL))objc_msgSend)(urls,sel("count"));
  if (count != n || count > 16) goto done;
  const char *paths[16];
  for (unsigned long i = 0; i < count; ++i) {
    id url = ((id(*)(id,SEL,unsigned long))objc_msgSend)(urls,sel("objectAtIndex:"),i);
    if (!((BOOL(*)(id,SEL))objc_msgSend)(url,sel("isFileURL"))) goto done;
    if (get(url,"user") || get(url,"password") || get(url,"query") || get(url,"fragment")) goto done;
    id host = get(url,"host");
    const char *host_utf8 = host ? ((const char*(*)(id,SEL))objc_msgSend)(host,sel("UTF8String")) : NULL;
    if (host && !host_utf8) goto done;
    if (host) {
      unsigned long bytes = ((unsigned long(*)(id,SEL,unsigned long))objc_msgSend)(host,sel("lengthOfBytesUsingEncoding:"),4);
      if (bytes > 255 || strlen(host_utf8) != bytes) goto done;
    }
    bool remote = host_utf8 && *host_utf8 && strcasecmp(host_utf8,"localhost");
    // Preserve a remote authority as raw URI for the host's preview fallback.
    // Local file-reference URLs still need NSURL's ordinary pathname URL form.
    if (!remote) url = get(url,"filePathURL");
    id uri = get(url,"absoluteString");
    paths[i] = uri ? ((const char*(*)(id,SEL))objc_msgSend)(uri,sel("UTF8String")) : NULL;
    if (!paths[i] || strncmp(paths[i],"file://",7)) goto done;
    unsigned long bytes = ((unsigned long(*)(id,SEL,unsigned long))objc_msgSend)(uri,sel("lengthOfBytesUsingEncoding:"),4);
    if (bytes == 0 || bytes > 4095 * 3 + 32 || strlen(paths[i]) != bytes) goto done;
  }
  CGPoint p = position(view,dragging);
  accepted = lt_drop_deliver(b,paths,count,p.x,p.y,true);
done:
  if (!accepted) lt_drop_cancel(b);
  release(pool);
  return accepted ? YES : NO;
}
static void exited(id view, SEL cmd, id dragging) { (void)cmd; (void)dragging; lt_drop_cancel(lt_drop_find(view)); }
static bool method(Class c, const char *name, IMP imp, const char *types) {
  SEL selector = sel(name);
  unsigned int n = 0;
  Method *methods = class_copyMethodList(c,&n);
  bool existing = false, ours = false;
  for (unsigned int i=0;i<n;++i) if (method_getName(methods[i]) == selector) { existing = true; ours = method_getImplementation(methods[i]) == imp; break; }
  free(methods);
  return existing ? ours : class_addMethod(c,selector,imp,types);
}
bool lt_drop_platform_attach(LtDropBridge *b, char *diag, size_t cap) {
  id host = (id)b->host;
  Class c = objc_getClass("NanoUIView");
  if (!c || !((BOOL(*)(id,SEL,Class))objc_msgSend)(host,sel("isKindOfClass:"),c) || !((BOOL(*)(id,SEL))objc_msgSend)(host,sel("isFlipped"))) {
    if (diag && cap) snprintf(diag,cap,"File drop requires the app-owned flipped NanoUIView"); return false;
  }
  // Add guarded methods to the dedicated app view class, never change isa.
  // Accessibility subclasses inherit them; its detach cannot remove drops.
  if (!method(c,"draggingEntered:",(IMP)entered,"Q@:@") || !method(c,"draggingUpdated:",(IMP)entered,"Q@:@") || !method(c,"prepareForDragOperation:",(IMP)prepare,BOOL_ENC "@:@") || !method(c,"performDragOperation:",(IMP)perform,BOOL_ENC "@:@") || !method(c,"draggingExited:",(IMP)exited,"v@:@")) {
    if (diag && cap) snprintf(diag,cap,"NanoUIView already owns conflicting dragging methods"); return false;
  }
  b->saved_types = retain(get(host,"registeredDraggedTypes"));
  id types = ((id(*)(id,SEL,id))objc_msgSend)((id)objc_getClass("NSArray"),sel("arrayWithObject:"),NSPasteboardTypeFileURL ? NSPasteboardTypeFileURL : string("public.file-url"));
  ((void(*)(id,SEL,id))objc_msgSend)(host,sel("registerForDraggedTypes:"),types);
  b->native_registered = true;
  return true;
}
bool lt_drop_platform_geometry(LtDropBridge *b) {
  CGRect bounds;
#if defined(__x86_64__)
  ((void(*)(CGRect *,id,SEL))objc_msgSend_stret)(&bounds,(id)b->host,sel("bounds"));
#else
  bounds = ((CGRect(*)(id,SEL))objc_msgSend)((id)b->host,sel("bounds"));
#endif
  return fabs(bounds.size.width-b->expected_width) < 0.01 && fabs(bounds.size.height-b->expected_height) < 0.01;
}
void lt_drop_platform_detach(LtDropBridge *b) {
  if (b->native_registered) {
    ((void(*)(id,SEL))objc_msgSend)((id)b->host,sel("unregisterDraggedTypes"));
    if (b->saved_types) ((void(*)(id,SEL,id))objc_msgSend)((id)b->host,sel("registerForDraggedTypes:"),(id)b->saved_types);
  }
  release((id)b->saved_types); b->saved_types = NULL; b->native_registered = false;
}
#endif
