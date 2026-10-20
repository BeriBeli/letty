#define _GNU_SOURCE
#define _DARWIN_C_SOURCE
#include "file_preview.h"
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdio.h>
#include <time.h>
#ifdef __APPLE__
#include <sys/event.h>
#elif defined(__linux__)
#include <sys/inotify.h>
#endif

struct LtPreviewLoader {
  pthread_mutex_t lock;
  atomic_uint references;
  atomic_int stopped;
  int control[2],notify[2];
  uint64_t requested,handled;
  int changed,has_result;
  LtPreviewResult result;
  char path[LT_PREVIEW_MAX_PATH+1],name[LT_PREVIEW_MAX_PATH+1];
  int parent,watch,file;
  struct stat parent_identity;
  struct stat observed;
  int observed_exists,observed_valid;
  int watch_available;
  LtPreviewHooks hooks;
  int resource;
};
static atomic_uint active_workers;
static atomic_size_t encoded_bytes;
static pthread_mutex_t load_lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t load_ready=PTHREAD_COND_INITIALIZER;
static unsigned loading;
static int enter_load(LtPreviewLoader *p) {
  pthread_mutex_lock(&load_lock);
  while(loading>=4 && !atomic_load(&p->stopped))pthread_cond_wait(&load_ready,&load_lock);
  int allowed=!atomic_load(&p->stopped);if(allowed)loading++;pthread_mutex_unlock(&load_lock);return allowed;
}
static void leave_load(void) { pthread_mutex_lock(&load_lock);loading--;pthread_cond_broadcast(&load_ready);pthread_mutex_unlock(&load_lock); }
static unsigned char *allocate_bytes(size_t n) {
  size_t old=atomic_load(&encoded_bytes);
  do{if(n>LT_PREVIEW_GLOBAL_BYTES-old){errno=EFBIG;return NULL;}}while(!atomic_compare_exchange_weak(&encoded_bytes,&old,old+n));
  unsigned char *bytes=malloc(n);if(!bytes)atomic_fetch_sub(&encoded_bytes,n);return bytes;
}
static void free_bytes(unsigned char *bytes,size_t n) { if(bytes){free(bytes);atomic_fetch_sub(&encoded_bytes,n);} }
static void ping(int fd) { const char b=1;(void)write(fd,&b,1); }
static void empty_pipe(int fd) { char bytes[128];while(read(fd,bytes,sizeof bytes)>0){} }
static int channel(int p[2]) {
  if(pipe(p))return -1;
  for(int i=0;i<2;i++)if(fcntl(p[i],F_SETFD,FD_CLOEXEC)<0 || fcntl(p[i],F_SETFL,O_NONBLOCK)<0){int e=errno;close(p[0]);close(p[1]);errno=e;return -1;}
  return 0;
}
static void release(LtPreviewLoader *p) {
  if(atomic_fetch_sub_explicit(&p->references,1,memory_order_acq_rel)==1){
    lt_preview_result_free(&p->result);close(p->control[0]);close(p->control[1]);close(p->notify[0]);close(p->notify[1]);
    pthread_mutex_destroy(&p->lock);free(p);
  }
}
static int error_status(void) {
  switch(errno){case ENOENT:return LT_PREVIEW_MISSING;case EPERM:case EACCES:return LT_PREVIEW_PERMISSION;case ELOOP:return LT_PREVIEW_SYMLINK;default:return LT_PREVIEW_IO_ERROR;}
}
static int utf8(const unsigned char *s,size_t n) {
  for(size_t i=0;i<n;) {
    unsigned b=s[i++];if(b<128)continue;
    unsigned count,value,min;
    if(b>=0xc2 && b<=0xdf){count=1;value=b&31;min=128;}
    else if(b>=0xe0 && b<=0xef){count=2;value=b&15;min=2048;}
    else if(b>=0xf0 && b<=0xf4){count=3;value=b&7;min=65536;}
    else return 0;
    if(count>n-i)return 0;
    for(unsigned j=0;j<count;j++){b=s[i++];if((b&0xc0)!=0x80)return 0;value=(value<<6)|(b&63);}
    if(value<min || value>0x10ffff || (value>=0xd800 && value<=0xdfff))return 0;
  }
  return 1;
}
/* Walk from / with O_NOFOLLOW at every component. This deliberately rejects
   aliases such as macOS /tmp; callers may resolve a trusted input explicitly. */
static int parent_open(LtPreviewLoader *p,int *status) {
  char copy[LT_PREVIEW_MAX_PATH+1];strcpy(copy,p->path);
  char *last=strrchr(copy,'/');strcpy(p->name,last+1);*last=0;
  int fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NONBLOCK);if(fd<0){*status=error_status();return -1;}
  char *save=NULL;unsigned depth=0;
  for(char *part=strtok_r(copy,"/",&save);part;part=strtok_r(NULL,"/",&save)) {
    if(++depth>128 || !strcmp(part,".") || !strcmp(part,"..")){close(fd);*status=LT_PREVIEW_UNSUPPORTED_FORMAT;return -1;}
    int next=openat(fd,part,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NONBLOCK|O_NOFOLLOW);
    if(next<0){int e=errno;struct stat info;if(!fstatat(fd,part,&info,AT_SYMLINK_NOFOLLOW) && S_ISLNK(info.st_mode))*status=LT_PREVIEW_SYMLINK;else{errno=e;*status=error_status();}close(fd);return -1;}
    close(fd);fd=next;
  }
  return fd;
}
static int same_object(const struct stat *a,const struct stat *b) { return a->st_dev==b->st_dev && a->st_ino==b->st_ino; }
static int same_file(const struct stat *a,const struct stat *b) {
  if(!same_object(a,b) || a->st_size!=b->st_size)return 0;
#ifdef __APPLE__
  return a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec && a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
#else
  return a->st_mtim.tv_sec==b->st_mtim.tv_sec && a->st_mtim.tv_nsec==b->st_mtim.tv_nsec && a->st_ctim.tv_sec==b->st_ctim.tv_sec && a->st_ctim.tv_nsec==b->st_ctim.tv_nsec;
#endif
}
static int watch_parent(LtPreviewLoader *p) {
#ifdef __APPLE__
  if(p->watch<0)p->watch=kqueue();if(p->watch<0)return -1;
  (void)fcntl(p->watch,F_SETFD,FD_CLOEXEC);
  struct kevent events[2];EV_SET(&events[0],p->control[0],EVFILT_READ,EV_ADD|EV_ENABLE,0,0,NULL);
  EV_SET(&events[1],p->parent,EVFILT_VNODE,EV_ADD|EV_CLEAR,NOTE_WRITE|NOTE_RENAME|NOTE_DELETE|NOTE_ATTRIB|NOTE_REVOKE,0,NULL);
  return kevent(p->watch,events,2,NULL,0,NULL);
#elif defined(__linux__)
  if(p->watch<0)p->watch=inotify_init1(IN_NONBLOCK|IN_CLOEXEC);if(p->watch<0)return -1;
  /* /proc/self/fd pins the already no-symlink-resolved directory, rather than
     re-following a replaceable path when installing its watch. */
  char path[64];snprintf(path,sizeof path,"/proc/self/fd/%d",p->parent);
  return inotify_add_watch(p->watch,path,IN_CLOSE_WRITE|IN_MODIFY|IN_MOVED_TO|IN_MOVED_FROM|IN_CREATE|IN_DELETE|IN_ATTRIB|IN_DELETE_SELF|IN_MOVE_SELF)<0?-1:0;
#else
  (void)p;return -1;
#endif
}
static void watch_file(LtPreviewLoader *p) {
#ifdef __APPLE__
  if(p->file>=0)close(p->file);p->file=-1;
  if(p->watch<0 || p->parent<0)return;
  p->file=openat(p->parent,p->name,O_EVTONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
  if(p->file>=0){struct kevent e;EV_SET(&e,p->file,EVFILT_VNODE,EV_ADD|EV_CLEAR,NOTE_WRITE|NOTE_EXTEND|NOTE_ATTRIB|NOTE_RENAME|NOTE_DELETE|NOTE_REVOKE,0,NULL);if(kevent(p->watch,&e,1,NULL,0,NULL)<0)p->watch_available=0;}
#else
  (void)p;
#endif
}
static uint32_t be32(const unsigned char *p) { return (uint32_t)p[0]<<24|(uint32_t)p[1]<<16|(uint32_t)p[2]<<8|p[3]; }
static int png(const unsigned char *p,size_t n) { static const unsigned char sig[]={137,80,78,71,13,10,26,10};return n>=8 && !memcmp(p,sig,8); }
static LtPreviewResult load(LtPreviewLoader *p,uint64_t generation) {
  LtPreviewResult r={.generation=generation,.status=LT_PREVIEW_IO_ERROR,.kind=LT_PREVIEW_UNSUPPORTED};
  int status=LT_PREVIEW_IO_ERROR,dir=parent_open(p,&status);
  if(dir<0){r.status=status;return r;}
  struct stat parent;if(fstat(dir,&parent)){close(dir);return r;}
  if(p->parent>=0 && !same_object(&parent,&p->parent_identity)){close(dir);return r;}
  if(p->parent<0){p->parent=dir;p->parent_identity=parent;p->watch_available=p->resource?0:watch_parent(p)==0;}else close(dir);
  if(!p->resource)watch_file(p);r.watch_available=(uint32_t)p->watch_available;
  p->observed_exists=!fstatat(p->parent,p->name,&p->observed,AT_SYMLINK_NOFOLLOW);p->observed_valid=1;
  int fd=openat(p->parent,p->name,O_RDONLY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW);
  if(fd<0){r.status=error_status();return r;}
  struct stat before,after,named;
  if(fstat(fd,&before)){close(fd);return r;}
  if(!S_ISREG(before.st_mode)){close(fd);r.status=LT_PREVIEW_NOT_REGULAR;return r;}
  if(before.st_size<0 || (uint64_t)before.st_size>LT_PREVIEW_MAX_IMAGE){close(fd);r.status=LT_PREVIEW_TOO_LARGE;return r;}
  unsigned char header[32];ssize_t count;
  do{count=read(fd,header,sizeof header);}while(count<0 && errno==EINTR && !atomic_load(&p->stopped));
  if(count<0){r.status=error_status();close(fd);return r;}
  int image=png(header,(size_t)count);size_t limit=image?LT_PREVIEW_MAX_IMAGE:LT_PREVIEW_MAX_TEXT;
  if((uint64_t)before.st_size>limit){close(fd);r.status=LT_PREVIEW_TOO_LARGE;return r;}
  size_t cap=(size_t)before.st_size+1;if(cap<(size_t)count+1)cap=(size_t)count+1;
  unsigned char *bytes=allocate_bytes(cap);if(!bytes){close(fd);r.status=errno==EFBIG?LT_PREVIEW_TOO_LARGE:LT_PREVIEW_IO_ERROR;return r;}
  size_t used=(size_t)count;memcpy(bytes,header,used);
  for(;;) {
    if(atomic_load(&p->stopped)){r.status=LT_PREVIEW_CANCELLED;break;}
    if(used==cap){r.status=LT_PREVIEW_IO_ERROR;break;}
    ssize_t n=read(fd,bytes+used,cap-used);
    if(n>0){used+=(size_t)n;if(used>limit){r.status=LT_PREVIEW_TOO_LARGE;break;}continue;}
    if(n<0 && errno==EINTR)continue;
    if(n<0){r.status=error_status();break;}
    int current=parent_open(p,&status);struct stat current_parent;
    int consistent=current>=0 && !fstat(current,&current_parent) && same_object(&current_parent,&p->parent_identity) && !fstat(fd,&after) && same_file(&before,&after) && !fstatat(p->parent,p->name,&named,AT_SYMLINK_NOFOLLOW) && same_file(&after,&named) && S_ISREG(named.st_mode) && used==(size_t)after.st_size;
    if(current>=0)close(current);
    if(consistent)r.status=LT_PREVIEW_READY;
    break;
  }
  close(fd);
  if(r.status!=LT_PREVIEW_READY){free_bytes(bytes,cap);return r;}
  if(image) {
    if(used<33 || be32(bytes+8)!=13 || memcmp(bytes+12,"IHDR",4)){free_bytes(bytes,cap);r.status=LT_PREVIEW_UNSUPPORTED_FORMAT;return r;}
    r.width=be32(bytes+16);r.height=be32(bytes+20);
    if(!r.width || !r.height || r.width>LT_PREVIEW_MAX_SIDE || r.height>LT_PREVIEW_MAX_SIDE || (uint64_t)r.width*r.height>LT_PREVIEW_MAX_PIXELS){free_bytes(bytes,cap);r.status=LT_PREVIEW_TOO_LARGE;return r;}
    r.kind=LT_PREVIEW_IMAGE;
  } else {
    for(size_t i=0;i<used;i++)if(bytes[i]==0 || (bytes[i]<32 && bytes[i]!='\n' && bytes[i]!='\r' && bytes[i]!='\t')){free_bytes(bytes,cap);r.status=LT_PREVIEW_UNSUPPORTED_FORMAT;return r;}
    if(!utf8(bytes,used)){free_bytes(bytes,cap);r.status=LT_PREVIEW_INVALID_UTF8;return r;}
    size_t from=used>=3 && !memcmp(bytes,"\xef\xbb\xbf",3)?3:0,to=0;r.lines=used>from?1:0;
    while(from<used){unsigned char ch=bytes[from++];if(ch=='\r'){ch='\n';if(from<used && bytes[from]=='\n')from++;}bytes[to++]=ch;if(ch=='\n' && ++r.lines>LT_PREVIEW_MAX_LINES){free_bytes(bytes,cap);r.status=LT_PREVIEW_TOO_LARGE;return r;}}
    used=to;const char *ext=strrchr(p->name,'.');r.kind=ext && (!strcasecmp(ext,".md") || !strcasecmp(ext,".markdown") || !strcasecmp(ext,".mdown"))?LT_PREVIEW_MARKDOWN:LT_PREVIEW_TEXT;
  }
  r.bytes=bytes;r.length=used;r.allocation=cap;
  if(p->hooks.prepare && !atomic_load(&p->stopped)){
    r.hooks=p->hooks;r.status=p->hooks.prepare(p->hooks.context,p->path,bytes,used,r.kind,&r.prepared);
    if(r.status!=LT_PREVIEW_READY){int failure=r.status;uint32_t watching=r.watch_available;lt_preview_result_free(&r);r.generation=generation;r.watch_available=watching;r.status=failure?failure:LT_PREVIEW_IO_ERROR;return r;}
    /* A bounded parse/decode may outlive the read. Reconcile the pathname once
       more so a replaced component or file cannot publish a prepared old view. */
    int current=parent_open(p,&status);struct stat parent_now,file_now;
    int consistent=current>=0 && !fstat(current,&parent_now) && same_object(&parent_now,&p->parent_identity) && !fstatat(p->parent,p->name,&file_now,AT_SYMLINK_NOFOLLOW) && same_file(&before,&file_now) && S_ISREG(file_now.st_mode);
    if(current>=0)close(current);
    if(!consistent){uint32_t watching=r.watch_available;lt_preview_result_free(&r);r.generation=generation;r.watch_available=watching;r.status=LT_PREVIEW_IO_ERROR;return r;}
  }
  p->observed=before;p->observed_exists=1;p->observed_valid=1;
  if(!r.watch_available && !p->resource)r.status=LT_PREVIEW_WATCH_ERROR;return r;
}
static void changed(LtPreviewLoader *p) {
  pthread_mutex_lock(&p->lock);p->changed=1;pthread_mutex_unlock(&p->lock);ping(p->notify[1]);
}
static int target_changed(LtPreviewLoader *p) {
  struct stat current;int exists=p->parent>=0 && !fstatat(p->parent,p->name,&current,AT_SYMLINK_NOFOLLOW);
  return !p->observed_valid || exists!=p->observed_exists || (exists && !same_file(&current,&p->observed));
}
static void wait_event(LtPreviewLoader *p) {
#ifdef __APPLE__
  if(p->watch_available){
    struct kevent events[8];int n=kevent(p->watch,NULL,0,events,8,NULL),dirty=0;
    int forced=0;
    for(int i=0;i<n;i++)if(events[i].filter==EVFILT_READ)empty_pipe(p->control[0]);else if(events[i].filter==EVFILT_VNODE){dirty=1;if(events[i].ident==(uintptr_t)p->parent && (events[i].fflags&(NOTE_RENAME|NOTE_DELETE|NOTE_REVOKE)))forced=1;}
    if(dirty && (forced || target_changed(p)))changed(p);return;
  }
#elif defined(__linux__)
  if(p->watch_available){
    struct pollfd fds[2]={{p->control[0],POLLIN,0},{p->watch,POLLIN,0}};if(poll(fds,2,-1)<0)return;
    if(fds[0].revents)empty_pipe(p->control[0]);
    if(fds[1].revents){char bytes[16384] __attribute__((aligned(__alignof__(struct inotify_event))));ssize_t n;int dirty=0;
      while((n=read(p->watch,bytes,sizeof bytes))>0)for(size_t i=0;i+sizeof(struct inotify_event)<=(size_t)n;){struct inotify_event *event=(struct inotify_event *)(bytes+i);if((event->mask&(IN_DELETE_SELF|IN_MOVE_SELF|IN_IGNORED|IN_Q_OVERFLOW)) || ((!event->len || !strcmp(event->name,p->name)) && target_changed(p)))dirty=1;i+=sizeof *event+event->len;}
      if(dirty)changed(p);
    }return;
  }
#endif
  struct pollfd fd={p->control[0],POLLIN,0};if(poll(&fd,1,-1)>0)empty_pipe(p->control[0]);
}
static void *worker(void *raw) {
  LtPreviewLoader *p=raw;
  while(!atomic_load_explicit(&p->stopped,memory_order_acquire)) {
    pthread_mutex_lock(&p->lock);uint64_t generation=p->requested;int wanted=generation!=p->handled;pthread_mutex_unlock(&p->lock);
    if(wanted){
      if(!enter_load(p))break;
      LtPreviewResult result=load(p,generation);leave_load();
      pthread_mutex_lock(&p->lock);p->handled=generation;
      if(!atomic_load(&p->stopped) && generation==p->requested){lt_preview_result_free(&p->result);p->result=result;p->has_result=1;memset(&result,0,sizeof result);ping(p->notify[1]);}
      pthread_mutex_unlock(&p->lock);lt_preview_result_free(&result);continue;
    }
    wait_event(p);
  }
  if(p->file>=0)close(p->file);if(p->parent>=0)close(p->parent);if(p->watch>=0)close(p->watch);
  release(p);atomic_fetch_sub(&active_workers,1);return NULL;
}
LtPreviewLoader *lt_preview_create_with_hooks(const char *path,uint64_t generation,const LtPreviewHooks *hooks) {
  size_t n=path?strnlen(path,LT_PREVIEW_MAX_PATH+1):0;
  if(!generation || !n || n>LT_PREVIEW_MAX_PATH || path[0]!='/' || path[n-1]=='/' || !utf8((const unsigned char *)path,n)){errno=EINVAL;return NULL;}
  for(size_t i=0;i<n;i++)if((unsigned char)path[i]<32 || path[i]==127){errno=EINVAL;return NULL;}
  const char *name=strrchr(path,'/')+1;if(!strcmp(name,".") || !strcmp(name,"..")){errno=EINVAL;return NULL;}
  atomic_fetch_add(&active_workers,1);
  LtPreviewLoader *p=calloc(1,sizeof *p);if(!p){atomic_fetch_sub(&active_workers,1);return NULL;}
  if(hooks){if(hooks->prepare && !hooks->release){free(p);atomic_fetch_sub(&active_workers,1);errno=EINVAL;return NULL;}p->hooks=*hooks;}
  p->parent=p->watch=p->file=-1;strcpy(p->path,path);p->requested=generation;
  if(channel(p->control)){free(p);atomic_fetch_sub(&active_workers,1);return NULL;}
  if(channel(p->notify)){close(p->control[0]);close(p->control[1]);free(p);atomic_fetch_sub(&active_workers,1);return NULL;}
  int error=pthread_mutex_init(&p->lock,NULL);if(error){close(p->control[0]);close(p->control[1]);close(p->notify[0]);close(p->notify[1]);free(p);atomic_fetch_sub(&active_workers,1);errno=error;return NULL;}
  atomic_init(&p->references,2);atomic_init(&p->stopped,0);pthread_t thread;
  error=pthread_create(&thread,NULL,worker,p);if(error){atomic_store(&p->references,1);release(p);atomic_fetch_sub(&active_workers,1);errno=error;return NULL;}
  pthread_detach(thread);return p;
}
LtPreviewLoader *lt_preview_create(const char *path,uint64_t generation) { return lt_preview_create_with_hooks(path,generation,NULL); }
int lt_preview_fd(const LtPreviewLoader *p) { return p?p->notify[0]:-1; }
int lt_preview_refresh(LtPreviewLoader *p,uint64_t generation) {
  if(!p || !generation || atomic_load(&p->stopped)){errno=EINVAL;return -1;}
  pthread_mutex_lock(&p->lock);
  if(generation<=p->requested){pthread_mutex_unlock(&p->lock);errno=EINVAL;return -1;}
  p->requested=generation;lt_preview_result_free(&p->result);p->has_result=0;p->changed=0;
  pthread_mutex_unlock(&p->lock);ping(p->control[1]);return 0;
}
int lt_preview_drain(LtPreviewLoader *p,LtPreviewResult *out) {
  if(!p || !out){errno=EINVAL;return -1;}empty_pipe(p->notify[0]);pthread_mutex_lock(&p->lock);memset(out,0,sizeof *out);int available=0;
  if(p->changed){out->changed=1;p->changed=0;available=1;}
  else if(p->has_result){*out=p->result;memset(&p->result,0,sizeof p->result);p->has_result=0;available=1;}
  pthread_mutex_unlock(&p->lock);return available;
}
void lt_preview_result_free(LtPreviewResult *result) { if(result){if(result->prepared && result->hooks.release)result->hooks.release(result->hooks.context,result->prepared);free_bytes(result->bytes,result->allocation);memset(result,0,sizeof *result);} }
void lt_preview_destroy(LtPreviewLoader *p) { if(p){atomic_store_explicit(&p->stopped,1,memory_order_release);pthread_mutex_lock(&load_lock);pthread_cond_broadcast(&load_ready);pthread_mutex_unlock(&load_lock);ping(p->control[1]);release(p);} }
static int hex(unsigned char ch) { return ch>='0'&&ch<='9'?ch-'0':ch>='a'&&ch<='f'?ch-'a'+10:ch>='A'&&ch<='F'?ch-'A'+10:-1; }
int lt_preview_read_resource(const char *document_path,const char *reference,LtPreviewResult *out) {
  if(!out)return -1;memset(out,0,sizeof *out);out->status=LT_PREVIEW_UNSUPPORTED_FORMAT;out->kind=LT_PREVIEW_UNSUPPORTED;
  size_t d=document_path?strnlen(document_path,LT_PREVIEW_MAX_PATH+1):0,n=reference?strnlen(reference,LT_PREVIEW_MAX_PATH+1):0;
  if(!d || d>LT_PREVIEW_MAX_PATH || document_path[0]!='/' || document_path[d-1]=='/' || !utf8((const unsigned char *)document_path,d) || !n || n>LT_PREVIEW_MAX_PATH || reference[0]=='/' || strchr(reference,':') || strchr(reference,'#') || strchr(reference,'?'))return 0;
  for(size_t i=0;i<d;i++)if((unsigned char)document_path[i]<32 || document_path[i]==127)return 0;
  char decoded[LT_PREVIEW_MAX_PATH+1];size_t used=0;
  for(size_t i=0;i<n;i++){unsigned char ch=(unsigned char)reference[i];if(ch=='%'){if(i+2>=n || hex(reference[i+1])<0 || hex(reference[i+2])<0)return 0;ch=(unsigned char)((hex(reference[i+1])<<4)|hex(reference[i+2]));i+=2;}if(ch<32 || ch==127 || ch=='\\')return 0;decoded[used++]=(char)ch;}decoded[used]=0;
  if(!utf8((unsigned char *)decoded,used) || decoded[0]=='/' || strchr(decoded,':'))return 0;
  char path[LT_PREVIEW_MAX_PATH+1];const char *slash=strrchr(document_path,'/');size_t base=(size_t)(slash-document_path)+1;
  if(base+used>LT_PREVIEW_MAX_PATH)return 0;memcpy(path,document_path,base);size_t pos=base;char *save=NULL;
  for(char *part=strtok_r(decoded,"/",&save);part;part=strtok_r(NULL,"/",&save)){if(!strcmp(part,".."))return 0;if(!strcmp(part,"."))continue;size_t len=strlen(part);if(pos>base)path[pos++]='/';memcpy(path+pos,part,len);pos+=len;}path[pos]=0;
  if(pos==base)return 0;
  LtPreviewLoader temporary={.parent=-1,.watch=-1,.file=-1,.resource=1};atomic_init(&temporary.stopped,0);strcpy(temporary.path,path);
  *out=load(&temporary,1);if(temporary.parent>=0)close(temporary.parent);
  if(out->status==LT_PREVIEW_READY && out->kind!=LT_PREVIEW_IMAGE){lt_preview_result_free(out);out->status=LT_PREVIEW_UNSUPPORTED_FORMAT;out->kind=LT_PREVIEW_UNSUPPORTED;}
  return 0;
}
