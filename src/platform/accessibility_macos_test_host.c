/* Private fixture host, never linked into the application. Unattached NSView
 * only; no NSApplication activation, window, AX client or permission request. */
#ifdef __APPLE__
#include <CoreGraphics/CGGeometry.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct { id pool, view; } Host;
static SEL sel(const char *s) { return sel_registerName(s); }
static id get(id o,const char*s) { return ((id(*)(id,SEL))objc_msgSend)(o,sel(s)); }
static id find(id o,uint64_t idv) {
  char wanted[48];snprintf(wanted,sizeof(wanted),"letty-%llu",(unsigned long long)idv);
  id identifier=get(o,"accessibilityIdentifier");
  const char *name=identifier?((const char*(*)(id,SEL))objc_msgSend)(identifier,sel("UTF8String")):NULL;
  if(name&&!strcmp(name,wanted))return o;
  id children=get(o,"accessibilityChildren");
  unsigned long n=((unsigned long(*)(id,SEL))objc_msgSend)(children,sel("count"));
  for(unsigned long i=0;i<n;i++) {
    id child=((id(*)(id,SEL,unsigned long))objc_msgSend)(children,sel("objectAtIndex:"),i);
    id result=find(child,idv);if(result)return result;
  }
  return nil;
}
void *lt_ax_native_host_new(void) {
  Host*h=calloc(1,sizeof(*h));if(!h)return NULL;
  h->pool=get(get((id)objc_getClass("NSAutoreleasePool"),"alloc"),"init");
  h->view=((id(*)(id,SEL,CGRect))objc_msgSend)(get((id)objc_getClass("NSView"),"alloc"),sel("initWithFrame:"),CGRectMake(0,0,640,480));
  if(!h->view) {get(h->pool,"release");free(h);return NULL;}
  return h;
}
void *lt_ax_native_host_view(void*p) { return ((Host*)p)->view; }
int lt_ax_native_host_action(void*p,uint64_t idv,unsigned a) {
  id node=find(((Host*)p)->view,idv);if(!node)return 0;
  const char*s=a==1?"accessibilityPerformPress":a==2?"lettyFocus":a==4?"accessibilityPerformIncrement":a==8?"accessibilityPerformDecrement":a==16?"lettyCopy":a==32?"lettyDismiss":NULL;
  return s?((BOOL(*)(id,SEL))objc_msgSend)(node,sel(s)):0;
}
void lt_ax_native_host_free(void*p) {
  Host*h=p;if(!h)return;get(h->view,"release");get(h->pool,"release");free(h);
}
#endif
