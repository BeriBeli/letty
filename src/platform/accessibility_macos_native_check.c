/* Standalone local AppKit API fixture. No AXUIElement, accessibility trust,
 * input injection, NSWindow, application activation or external process access. */
#include "accessibility.h"
#ifdef __APPLE__
#include <CoreGraphics/CGGeometry.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <string.h>
typedef struct { unsigned long location, length; } Range;
static SEL sel(const char *s) { return sel_registerName(s); }
static id get(id x, const char *s) { return ((id(*)(id,SEL))objc_msgSend)(x,sel(s)); }
static void release(id x) { if(x) ((void(*)(id,SEL))objc_msgSend)(x,sel("release")); }
static id at(id a, unsigned long i) { return ((id(*)(id,SEL,unsigned long))objc_msgSend)(a,sel("objectAtIndex:"),i); }
static unsigned long count(id x) { return ((unsigned long(*)(id,SEL))objc_msgSend)(x,sel("count")); }
static const char *utf8(id x) { return x ? ((const char *(*)(id,SEL))objc_msgSend)(x,sel("UTF8String")) : ""; }
static int equal(id x, const char *s) { return x && strcmp(utf8(x),s)==0; }
static BOOL boolean(id x,const char*s) { return ((BOOL(*)(id,SEL))objc_msgSend)(x,sel(s)); }
static id find(id obj, uint64_t idv) {
  char label[48]; snprintf(label,sizeof(label),"letty-%llu",(unsigned long long)idv);
  if(equal(get(obj,"accessibilityIdentifier"),label)) return obj;
  id children=get(obj,"accessibilityChildren");
  for(unsigned long i=0;i<count(children);i++) { id result=find(at(children,i),idv); if(result)return result; }
  return nil;
}
static unsigned calls, last_action;
static uint64_t last_id;
static int action(void *ctx,uint64_t idv,uint32_t a) {
  (void)ctx; calls++; last_id=idv; last_action=a; return 1;
}
static unsigned checks;
#define CHECK(e,s) do { if(!(e)) { fprintf(stderr,"FAIL AX AppKit: %s (line %d)\n",s,__LINE__); return 1; } checks++; fprintf(stderr,"PASS AX AppKit: %s\n",s); } while(0)
int main(void) {
  id pool=get(get((id)objc_getClass("NSAutoreleasePool"),"alloc"),"init");
  id view=((id(*)(id,SEL,CGRect))objc_msgSend)(get((id)objc_getClass("NSView"),"alloc"),sel("initWithFrame:"),CGRectMake(0,0,640,480));
  CHECK(view && !get(view,"window"),"owned unattached NSView (no window)");
  Class original=object_getClass(view);
  id original_children=get(view,"accessibilityChildren");
  if(original_children)get(original_children,"retain");
  CHECK(lt_ax_capability()==1,"real NSAccessibilityElement available");
  LtAxBridge *b=lt_ax_attach(view,action,NULL);
  CHECK(b && !lt_ax_attach(view,action,NULL),"real bridge attach and duplicate rejection");
  LtAxNode nodes[13]={0};
  const char *roles[]={"AXGroup","AXTabGroup","AXRadioButton","AXGroup","AXTextField","AXDialog","AXButton","AXMenu","AXMenuItem","AXScrollBar","AXTextArea","AXStaticText","AXTextArea"};
  for(unsigned i=0;i<13;i++) {
    nodes[i].id=i+1; nodes[i].parent=i?1:0; nodes[i].role=i;
    nodes[i].state=LT_AX_ENABLED|LT_AX_VISIBLE;
    nodes[i].label="Owned label"; nodes[i].label_len=strlen(nodes[i].label);
    nodes[i].value=""; nodes[i].bounds=(LtAxBounds){10,20,200,40};
  }
  nodes[2].state|=LT_AX_SELECTED;
  nodes[6].actions=LT_AX_PRESS|LT_AX_DISMISS;
  nodes[9].actions=LT_AX_INCREMENT|LT_AX_DECREMENT;
  char text[]="A中e\xcc\x81🙂";
  nodes[10].value=text; nodes[10].value_len=strlen(text);
  nodes[10].state|=LT_AX_FOCUSABLE|LT_AX_FOCUSED|LT_AX_READ_ONLY;
  nodes[10].actions=LT_AX_COPY|LT_AX_FOCUS;
  nodes[10].caret=(uint32_t)strlen(text);nodes[10].selection_start=1;nodes[10].selection_end=4;
  nodes[12].value="Doc中"; nodes[12].value_len=strlen(nodes[12].value); nodes[12].state|=LT_AX_READ_ONLY|LT_AX_FOCUSABLE; nodes[12].actions=LT_AX_COPY|LT_AX_FOCUS;
  CHECK(lt_ax_update(b,nodes,13,LT_AX_NOTIFY_TREE|LT_AX_NOTIFY_FOCUS|LT_AX_NOTIFY_VALUE)==0,"actual platform publishes full bounded tree");
  CHECK(count(get(view,"accessibilityChildren"))==1 && count(get(find(view,1),"accessibilityChildren"))==12,"native root/child hierarchy");
  for(unsigned i=0;i<13;i++) CHECK(equal(get(find(view,i+1),"accessibilityRole"),roles[i]),roles[i]);
  CHECK(equal(get(find(view,13),"accessibilityValue"),"Doc中") && ((long(*)(id,SEL))objc_msgSend)(find(view,13),sel("accessibilityNumberOfCharacters"))==4,"native document exposes bounded Unicode text");
  id terminal=find(view,11),button=find(view,7),scroll=find(view,10),search=find(view,5);
  CHECK(equal(get(terminal,"accessibilityValue"),text),"owned Unicode terminal text");
  memset(text,'x',sizeof(text)-1);
  CHECK(equal(get(terminal,"accessibilityValue"),"A中e\xcc\x81🙂"),"native text survives source mutation");
  CHECK(((long(*)(id,SEL))objc_msgSend)(terminal,sel("accessibilityNumberOfCharacters"))==6,"UTF16 CJK/combining/emoji character count");
  Range range=((Range(*)(id,SEL))objc_msgSend)(terminal,sel("accessibilitySelectedTextRange"));
  CHECK(range.location==1 && range.length==1 && equal(get(terminal,"accessibilitySelectedText"),"中"),"byte selection converts to UTF16 range");
  id emoji=((id(*)(id,SEL,Range))objc_msgSend)(terminal,sel("accessibilityStringForRange:"),(Range){4,2});
  CHECK(equal(emoji,"🙂") && !((id(*)(id,SEL,Range))objc_msgSend)(terminal,sel("accessibilityStringForRange:"),(Range){6,1}),"UTF16 text ranges and bounds");
  CHECK(get(view,"accessibilityFocusedUIElement")==terminal && boolean(terminal,"isAccessibilityFocused"),"native focus points to terminal");
  CHECK(boolean(find(view,3),"isAccessibilitySelected") && equal(get(search,"accessibilitySubrole"),"AXSearchField"),"tab selection and search subrole");
  CGRect frame;
#if defined(__x86_64__)
  ((void(*)(CGRect*,id,SEL))objc_msgSend_stret)(&frame,terminal,sel("accessibilityFrame"));
#else
  frame=((CGRect(*)(id,SEL))objc_msgSend)(terminal,sel("accessibilityFrame"));
#endif
  CHECK(frame.origin.x==10 && frame.origin.y==420 && frame.size.width==200 && frame.size.height==40,"logical top-left geometry converts to NSView coordinates");
  CHECK(boolean(button,"accessibilityPerformPress") && last_id==7 && last_action==LT_AX_PRESS,"native press callback stable ID");
  CHECK(boolean(scroll,"accessibilityPerformIncrement") && last_action==LT_AX_INCREMENT && boolean(scroll,"accessibilityPerformDecrement") && last_action==LT_AX_DECREMENT,"native scrollbar increment/decrement");
  CHECK(boolean(terminal,"lettyCopy") && last_id==11 && last_action==LT_AX_COPY && boolean(button,"lettyDismiss") && last_action==LT_AX_DISMISS,"native custom copy/dismiss actions");
  ((void(*)(id,SEL,BOOL))objc_msgSend)(terminal,sel("setAccessibilityFocused:"),YES);
  CHECK(last_id==11 && last_action==LT_AX_FOCUS,"native focus callback");
  CHECK(count(get(terminal,"accessibilityCustomActions"))==2,"custom actions exposed through AppKit");
  get(button,"retain"); get(terminal,"retain");
  nodes[10].value="A中e\xcc\x81🙂";
  nodes[10].state&=~LT_AX_FOCUSED;
  nodes[5].state|=LT_AX_MODAL;
  nodes[6].parent=6;
  CHECK(lt_ax_update(b,nodes,13,LT_AX_NOTIFY_TREE|LT_AX_NOTIFY_STATE|LT_AX_NOTIFY_FOCUS)==0 && !boolean(terminal,"lettyCopy") && boolean(button,"accessibilityPerformPress"),"native modal excludes underlying terminal actions");
  nodes[4].role=LT_AX_BUTTON;
  CHECK(lt_ax_update(b,nodes,13,0)==0 && !get(search,"accessibilitySubrole"),"reused node clears obsolete search subrole");
  nodes[6].parent=1;nodes[5].state&=~LT_AX_MODAL;
  CHECK(lt_ax_update(b,nodes,6,LT_AX_NOTIFY_TREE)==0 && !boolean(button,"accessibilityPerformPress"),"retained removed element cannot dispatch");
  lt_ax_detach(b);
  CHECK(object_getClass(view)==original && get(view,"accessibilityChildren")==original_children,"detach restores original host class/children");
  unsigned before=calls;
  CHECK(!boolean(terminal,"lettyCopy") && !boolean(button,"accessibilityPerformPress") && calls==before,"retained elements reject actions after bridge free");
  release(button);release(terminal);release(original_children);release(view);release(pool);
  fprintf(stderr,"PASS AX APPKIT NATIVE %u checks; no external AX or window\n",checks);
  return 0;
}
#endif
