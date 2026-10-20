/* Real owned files and native watch events only; no UI or arbitrary user file. */
#include "../../src/platform/file_preview.c"
#include <assert.h>
static unsigned checks;
static uint64_t millis(void){struct timespec t;assert(!clock_gettime(CLOCK_MONOTONIC,&t));return (uint64_t)t.tv_sec*1000+(uint64_t)t.tv_nsec/1000000;}
static void check(int ok,const char *label){printf("%s PREVIEW_LOADER %s\n",ok?"PASS":"FAIL",label);fflush(stdout);if(!ok)exit(1);checks++;}
static void put(const char *path,const void *bytes,size_t n){int fd=open(path,O_WRONLY|O_CREAT|O_TRUNC,0600);assert(fd>=0);assert(write(fd,bytes,n)==(ssize_t)n);assert(!close(fd));}
static LtPreviewResult await_result(LtPreviewLoader *p,uint64_t *generation) {
  uint64_t deadline=millis()+4000;LtPreviewResult result;
  while(millis()<deadline){
    while(lt_preview_drain(p,&result)>0){
      if(result.changed){lt_preview_result_free(&result);assert(!lt_preview_refresh(p,++*generation));continue;}
      if(result.generation==*generation)return result;
      lt_preview_result_free(&result);
    }
    struct pollfd event={lt_preview_fd(p),POLLIN,0};assert(poll(&event,1,50)>=0);
  }
  fprintf(stderr,"PREVIEW_LOADER_TIMEOUT generation=%llu\n",(unsigned long long)*generation);abort();
}
static int is_text(const LtPreviewResult *r,const char *text){return r->status==LT_PREVIEW_READY && r->length==strlen(text) && !memcmp(r->bytes,text,r->length);}
static LtPreviewResult one(const char *path){uint64_t generation=1;LtPreviewLoader *p=lt_preview_create(path,generation);assert(p);LtPreviewResult result=await_result(p,&generation);lt_preview_destroy(p);return result;}
static void quiesce(void){uint64_t deadline=millis()+3000;while(atomic_load(&active_workers) && millis()<deadline)usleep(1000);assert(!atomic_load(&active_workers));}
static unsigned descriptors(void){unsigned count=0;for(int fd=0;fd<2048;fd++)if(fcntl(fd,F_GETFD)>=0)count++;return count;}
static atomic_int prepare_entered,prepare_gate,prepared_freed;
static int32_t prepare(void *context,const char *path,const unsigned char *bytes,size_t length,int32_t kind,void **out){
  (void)context;assert(path[0]=='/' && kind==LT_PREVIEW_MARKDOWN && bytes && length);atomic_fetch_add(&prepare_entered,1);
  while(!atomic_load(&prepare_gate))usleep(1000);
  *out=malloc(1);assert(*out);return LT_PREVIEW_READY;
}
static void prepared_free(void *context,void *value){(void)context;atomic_fetch_add(&prepared_freed,1);free(value);}
static int32_t prepare_failure(void *context,const char *path,const unsigned char *bytes,size_t length,int32_t kind,void **out){(void)context;(void)path;(void)bytes;(void)length;(void)kind;*out=malloc(1);assert(*out);return LT_PREVIEW_TOO_LARGE;}
int main(void){
  unsigned original_fds=descriptors();char temporary[]="/tmp/letty-preview-loader-XXXXXX";assert(mkdtemp(temporary));
  char root[4096];assert(realpath(temporary,root));char path[4096],replacement[4096],other[4096],link[4096],fifo[4096],subdir[4096],document[4096],image[4096];
  assert(snprintf(path,sizeof path,"%s/文档 space:12.md",root)<(int)sizeof path);
  snprintf(replacement,sizeof replacement,"%s/replacement",root);snprintf(other,sizeof other,"%s/other.txt",root);snprintf(link,sizeof link,"%s/link",root);snprintf(fifo,sizeof fifo,"%s/fifo",root);snprintf(subdir,sizeof subdir,"%s/subdir",root);snprintf(document,sizeof document,"%s/doc.md",root);snprintf(image,sizeof image,"%s/image space.png",root);
  /* Avoid source character byte-count assumptions in the first owned fixture. */
  const char *initial="\xef\xbb\xbf# 中文\r\nline\rnext\n";put(path,initial,strlen(initial));
  uint64_t generation=1;LtPreviewLoader *p=lt_preview_create(path,generation);assert(p);
  LtPreviewResult r=await_result(p,&generation);
  check(is_text(&r,"# 中文\nline\nnext\n") && r.kind==LT_PREVIEW_MARKDOWN && r.watch_available,"UTF8 BOM CRLF Chinese and colon-space path load as owned normalized Markdown with native watch");
  lt_preview_result_free(&r);
  put(path,"in-place",8);r=await_result(p,&generation);check(is_text(&r,"in-place"),"ordinary file write triggers event-driven latest reload");lt_preview_result_free(&r);
  put(replacement,"atomic replacement",18);assert(!rename(replacement,path));r=await_result(p,&generation);check(is_text(&r,"atomic replacement"),"atomic rename replaces watched inode and publishes replacement bytes");lt_preview_result_free(&r);
  assert(!unlink(path));r=await_result(p,&generation);check(r.status==LT_PREVIEW_MISSING && !r.bytes,"delete reports explicit missing state without inventing empty successful content");lt_preview_result_free(&r);
  put(path,"recreated",9);r=await_result(p,&generation);check(is_text(&r,"recreated"),"directory watch survives deletion and detects file recreation");lt_preview_result_free(&r);
  for(unsigned i=0;i<40;i++)assert(!lt_preview_refresh(p,++generation));r=await_result(p,&generation);check(r.generation==generation && is_text(&r,"recreated"),"rapid explicit refreshes coalesce and stale generations cannot publish");lt_preview_result_free(&r);
  put(other,"unrelated",9);struct pollfd event={lt_preview_fd(p),POLLIN,0};int quiet=1;uint64_t deadline=millis()+200;
  while(millis()<deadline){if(poll(&event,1,20)>0){LtPreviewResult idle;while(lt_preview_drain(p,&idle)>0){quiet=0;lt_preview_result_free(&idle);}}}
  check(quiet,"idle and unrelated directory events do not reload an unchanged document");lt_preview_destroy(p);quiesce();
  assert(!mkfifo(fifo,0600));uint64_t before=millis();r=one(fifo);check(r.status==LT_PREVIEW_NOT_REGULAR && millis()-before<500,"FIFO is opened nonblocking and rejected as nonregular without waiting for writer");lt_preview_result_free(&r);
  assert(!mkdir(subdir,0700));r=one(subdir);check(r.status==LT_PREVIEW_NOT_REGULAR,"directory is never consumed as file content");lt_preview_result_free(&r);
  r=one("/dev/null");check(r.status==LT_PREVIEW_NOT_REGULAR,"device is never consumed as file content");lt_preview_result_free(&r);
  assert(!symlink(path,link));r=one(link);check(r.status==LT_PREVIEW_SYMLINK,"final symlink is explicitly rejected");lt_preview_result_free(&r);assert(!unlink(link));
  assert(!symlink(root,link));char nested[4096];snprintf(nested,sizeof nested,"%s/doc.md",link);r=one(nested);check(r.status==LT_PREVIEW_SYMLINK,"intermediate directory symlink cannot bypass path policy");lt_preview_result_free(&r);assert(!unlink(link));
  put(document,"a\0b",3);r=one(document);check(r.status==LT_PREVIEW_UNSUPPORTED_FORMAT,"binary with a text extension is explicitly unsupported");lt_preview_result_free(&r);
  put(document,"\xf0\x80\x80\x80",4);r=one(document);check(r.status==LT_PREVIEW_INVALID_UTF8,"invalid overlong UTF8 is rejected without replacement text");lt_preview_result_free(&r);
  put(document,"",0);r=one(document);check(r.status==LT_PREVIEW_READY && !r.length && !r.lines,"empty regular text is a successful owned snapshot");lt_preview_result_free(&r);
  int fd=open(document,O_WRONLY|O_TRUNC);assert(fd>=0);assert(!ftruncate(fd,LT_PREVIEW_MAX_IMAGE+1));close(fd);r=one(document);check(r.status==LT_PREVIEW_TOO_LARGE,"oversize sparse input refuses before allocation");lt_preview_result_free(&r);
  fd=open(document,O_WRONLY|O_TRUNC);assert(fd>=0);assert(!ftruncate(fd,LT_PREVIEW_MAX_TEXT+1));assert(write(fd,"text",4)==4);close(fd);r=one(document);check(r.status==LT_PREVIEW_TOO_LARGE,"text obeys tighter two-MiB input budget");lt_preview_result_free(&r);
  char *lines=malloc(LT_PREVIEW_MAX_LINES+1);assert(lines);memset(lines,'\n',LT_PREVIEW_MAX_LINES+1);put(document,lines,LT_PREVIEW_MAX_LINES+1);free(lines);r=one(document);check(r.status==LT_PREVIEW_TOO_LARGE,"line count budget refuses excessive document work");lt_preview_result_free(&r);
  put(document,"private",7);assert(!chmod(document,0000));r=one(document);check(geteuid()==0?r.status==LT_PREVIEW_READY:r.status==LT_PREVIEW_PERMISSION,"permission failure stays explicit");lt_preview_result_free(&r);assert(!chmod(document,0600));
  unsigned char png_bytes[33]={137,80,78,71,13,10,26,10,0,0,0,13,'I','H','D','R',0,0,0,1,0,0,0,1,8,6};put(image,png_bytes,sizeof png_bytes);r=one(image);check(r.status==LT_PREVIEW_READY && r.kind==LT_PREVIEW_IMAGE && r.width==1 && r.height==1,"PNG signature and bounded IHDR dimensions classify portable image input");lt_preview_result_free(&r);
  png_bytes[16]=1;put(image,png_bytes,sizeof png_bytes);r=one(image);check(r.status==LT_PREVIEW_TOO_LARGE,"decompression dimensions refuse oversized PNG before UI decode");lt_preview_result_free(&r);png_bytes[16]=0;put(image,png_bytes,sizeof png_bytes);
  assert(!lt_preview_read_resource(document,"./image%20space.png",&r));check(r.status==LT_PREVIEW_READY && r.kind==LT_PREVIEW_IMAGE,"worker resource helper resolves encoded local PNG within document directory");lt_preview_result_free(&r);
  for(const char **ref=(const char *[]) {"../outside.png","https://invalid/a.png","/tmp/else.png","%2e%2e/out.png","image%00space.png",NULL};*ref;ref++){assert(!lt_preview_read_resource(document,*ref,&r));assert(r.status==LT_PREVIEW_UNSUPPORTED_FORMAT && !r.bytes);lt_preview_result_free(&r);}
  check(1,"resource traversal remote absolute and encoded-NUL paths are rejected");
  assert(!symlink(image,link));assert(!lt_preview_read_resource(document,"link",&r));check(r.status==LT_PREVIEW_SYMLINK && !r.bytes,"local resource symlink cannot escape document directory policy");lt_preview_result_free(&r);assert(!unlink(link));
  char nested_file[4096],moved[4096],old_file[4096];snprintf(nested_file,sizeof nested_file,"%s/subdir/child.md",root);snprintf(moved,sizeof moved,"%s/moved",root);snprintf(old_file,sizeof old_file,"%s/moved/child.md",root);put(nested_file,"old",3);generation=1;p=lt_preview_create(nested_file,generation);assert(p);r=await_result(p,&generation);assert(is_text(&r,"old"));lt_preview_result_free(&r);
  assert(!rename(subdir,moved));assert(!mkdir(subdir,0700));put(nested_file,"different parent",16);r=await_result(p,&generation);check(r.status==LT_PREVIEW_IO_ERROR && !r.bytes,"replaced directory component cannot redirect an established document identity");lt_preview_result_free(&r);lt_preview_destroy(p);quiesce();assert(!unlink(nested_file));assert(!unlink(old_file));assert(!rmdir(moved));
  check(lt_preview_create("file:///tmp/x",1)==NULL && lt_preview_create("/tmp/a\nb",1)==NULL,"invalid path constructor rejects remote URI and controls");
  put(document,"hook content",12);LtPreviewHooks hooks={NULL,prepare,prepared_free};atomic_store(&prepare_gate,0);atomic_store(&prepare_entered,0);atomic_store(&prepared_freed,0);
  generation=1;p=lt_preview_create_with_hooks(document,generation,&hooks);assert(p);deadline=millis()+2000;while(!atomic_load(&prepare_entered) && millis()<deadline)usleep(1000);assert(atomic_load(&prepare_entered));assert(!lt_preview_refresh(p,++generation));atomic_store(&prepare_gate,1);r=await_result(p,&generation);
  check(r.generation==2 && r.prepared && atomic_load(&prepared_freed)>=1,"stale background transform is released while latest generation transfers owned prepared result");lt_preview_result_free(&r);lt_preview_destroy(p);quiesce();check(atomic_load(&prepared_freed)==2,"adopted and stale prepared payloads are both released exactly once");
  atomic_store(&prepare_gate,0);atomic_store(&prepare_entered,0);p=lt_preview_create_with_hooks(document,1,&hooks);assert(p);deadline=millis()+2000;while(!atomic_load(&prepare_entered) && millis()<deadline)usleep(1000);assert(atomic_load(&prepare_entered));before=millis();lt_preview_destroy(p);check(millis()-before<50,"close retires active transform without blocking UI on worker completion");atomic_store(&prepare_gate,1);quiesce();
  atomic_store(&prepare_gate,0);atomic_store(&prepare_entered,0);int freed_before=atomic_load(&prepared_freed);p=lt_preview_create_with_hooks(document,1,&hooks);assert(p);deadline=millis()+2000;while(!atomic_load(&prepare_entered) && millis()<deadline)usleep(1000);assert(atomic_load(&prepare_entered));put(document,"changed during transform",24);atomic_store(&prepare_gate,1);int obtained=0;deadline=millis()+2000;
  while(millis()<deadline && !obtained){if(lt_preview_drain(p,&r)>0){if(!r.changed)obtained=1;else lt_preview_result_free(&r);}else usleep(1000);}
  check(obtained && r.status==LT_PREVIEW_IO_ERROR && !r.bytes && !r.prepared && atomic_load(&prepared_freed)==freed_before+1,"file mutation during transform invalidates prepared snapshot and releases it before publication");lt_preview_result_free(&r);lt_preview_destroy(p);quiesce();
  int freed=atomic_load(&prepared_freed);LtPreviewHooks failure_hooks={NULL,prepare_failure,prepared_free};generation=1;p=lt_preview_create_with_hooks(document,generation,&failure_hooks);assert(p);r=await_result(p,&generation);check(r.status==LT_PREVIEW_TOO_LARGE && !r.prepared && r.watch_available && atomic_load(&prepared_freed)==freed+1,"failed transform reports its real budget status and releases partially prepared payload");lt_preview_result_free(&r);lt_preview_destroy(p);quiesce();
  LtPreviewLoader *parallel[36];atomic_store(&prepare_gate,0);atomic_store(&prepare_entered,0);
  for(unsigned i=0;i<36;i++){parallel[i]=lt_preview_create_with_hooks(document,1,&hooks);assert(parallel[i]);}
  deadline=millis()+2000;while(atomic_load(&prepare_entered)<4 && millis()<deadline)usleep(1000);usleep(20000);check(atomic_load(&prepare_entered)==4,"36 open document loaders retain a four-worker read and transform concurrency bound");
  for(unsigned i=0;i<36;i++)lt_preview_destroy(parallel[i]);atomic_store(&prepare_gate,1);quiesce();
  fd=open(image,O_WRONLY|O_TRUNC);assert(fd>=0);assert(write(fd,png_bytes,sizeof png_bytes)==sizeof png_bytes);assert(!ftruncate(fd,LT_PREVIEW_MAX_IMAGE-1));close(fd);
  LtPreviewResult held[4];for(unsigned i=0;i<4;i++){held[i]=one(image);assert(held[i].status==LT_PREVIEW_READY);}r=one(image);check(r.status==LT_PREVIEW_TOO_LARGE && atomic_load(&encoded_bytes)==LT_PREVIEW_GLOBAL_BYTES,"global encoded budget includes caller-retained published snapshots and refuses a fifth eight-MiB result");lt_preview_result_free(&r);
  lt_preview_result_free(&held[0]);r=one(image);check(r.status==LT_PREVIEW_READY,"releasing an owned snapshot restores global load budget without restarting other documents");lt_preview_result_free(&r);for(unsigned i=1;i<4;i++)lt_preview_result_free(&held[i]);quiesce();
  check(!atomic_load(&encoded_bytes) && descriptors()==original_fds,"cancel close and retained results reclaim every owned content byte watch and pipe fd");
  assert(!unlink(path));assert(!unlink(other));assert(!unlink(fifo));assert(!rmdir(subdir));assert(!unlink(document));assert(!unlink(image));assert(!rmdir(root));
  printf("PREVIEW_LOADER_NATIVE {\"checks\":%u,\"native_file_events\":true,\"idle_polling\":false}\n",checks);return 0;
}
