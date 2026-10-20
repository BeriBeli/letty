/* Real Session launch boundary: private login PTY, temporary non-repository,
   and one listener owned by that PTY. No machine-wide process enumeration. */
#define LT_NAV_PROVIDER_TEST
#include "../../src/platform/navigation_provider.c"
#include "../../src/platform/compat.h"
#include <assert.h>
#include <stdbool.h>
extern int lt_spawn_integrated(const char *,const char *,const char *,unsigned,unsigned,int *,bool,bool *);
static unsigned checks;
static int owned_pid=-1,owned_fd=-1;
static char directory[4096];
static void cleanup(void) {
  if(owned_fd>=0) {
    if(owned_pid>0)lt_terminate_session(owned_fd,owned_pid);
    close(owned_fd);
    if(owned_pid>0){int status;while(waitpid(owned_pid,&status,0)<0 && errno==EINTR){}}
  }
  if(directory[0])rmdir(directory);
}
static void check(int ok,const char *label) {
  printf("%s NAV_PROVIDER_LOGIN %s\n",ok?"PASS":"FAIL",label);fflush(stdout);
  if(!ok)exit(1);++checks;
}
static int listener(void) {
  int fd=socket(AF_INET,SOCK_STREAM,0);assert(fd>=0);
  struct sockaddr_in address={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
  assert(!bind(fd,(struct sockaddr *)&address,sizeof address));assert(!listen(fd,1));
  socklen_t length=sizeof address;assert(!getsockname(fd,(struct sockaddr *)&address,&length));
  printf("__LOGIN_PROVIDER_READY__ %d %u\n",getpid(),ntohs(address.sin_port));fflush(stdout);
  char byte;ssize_t got;do{got=read(STDIN_FILENO,&byte,1);}while(got<0 && errno==EINTR);
  printf("__LOGIN_PROVIDER_READ__ %ld %d %d %d\n",(long)got,errno,getpgrp(),tcgetpgrp(STDIN_FILENO));fflush(stdout);close(fd);return 0;
}
static int quoted(char *out,size_t cap,const char *text) {
  size_t used=0;if(cap<3)return -1;out[used++]='\'';
  for(;*text;++text) {
    const char *bytes=*text=='\''?"'\\''":text;size_t count=*text=='\''?4:1;
    if(used+count+2>cap)return -1;memcpy(out+used,bytes,count);used+=count;
  }
  out[used++]='\'';out[used]=0;return 0;
}
static LtNavSnapshot result(LtNavProvider *provider,uint64_t generation,int ports) {
  assert(lt_nav_provider_start(provider,generation,directory,1,ports,750)==1);
  struct pollfd event={lt_nav_provider_fd(provider),POLLIN,0};assert(poll(&event,1,3000)==1);
  LtNavSnapshot snapshot;assert(lt_nav_provider_drain(provider,&snapshot)==1);return snapshot;
}
int main(int argc,char **argv) {
  if(argc==2 && !strcmp(argv[1],"--login-listener"))return listener();
  assert(!atexit(cleanup));
  strcpy(directory,"/tmp/letty-provider-login-XXXXXX");assert(mkdtemp(directory));
  char executable[4096],escaped[16384],command[16432];assert(realpath(argv[0],executable));
  assert(!quoted(escaped,sizeof escaped,executable));assert(snprintf(command,sizeof command,"exec %s --login-listener",escaped)<(int)sizeof command);
  bool integrated=false;owned_fd=lt_spawn_integrated("/bin/sh",command,directory,80,24,&owned_pid,false,&integrated);
  check(owned_fd>=0 && owned_pid>0 && !integrated,"actual Session launcher creates only its private command PTY");
  char output[8192]={0};size_t used=0;uint64_t deadline=now_us()+5000000;
  while(now_us()<deadline && !strstr(output,"__LOGIN_PROVIDER_READY__")) {
    struct pollfd event={owned_fd,POLLIN,0};
    if(poll(&event,1,10)>0) {ssize_t n=read(owned_fd,output+used,sizeof output-used-1);if(n>0){used+=(size_t)n;output[used]=0;}}
  }
  char *ready=strstr(output,"__LOGIN_PROVIDER_READY__");int child=0;unsigned port=0;
  check(ready && sscanf(ready,"__LOGIN_PROVIDER_READY__ %d %u",&child,&port)==2 && child>0 && port>0 && port<=65535,"real child signals readiness only after login exec and owned loopback listen");
  struct Process process;errno=0;int status=process_info(owned_pid,&process),saved=errno;
#ifdef __APPLE__
  struct proc_bsdinfo raw={0};errno=0;int bytes=proc_pidinfo(owned_pid,PROC_PIDTBSDINFO,0,&raw,sizeof raw),raw_errno=errno;
  printf("NAV_PROVIDER_LOGIN_IDENTITY pid=%d process_info=%d errno=%d birth=%llu libproc_bytes=%d libproc_errno=%d\n",owned_pid,status,saved,(unsigned long long)(status?0:process.birth),bytes,raw_errno);
#else
  printf("NAV_PROVIDER_LOGIN_IDENTITY pid=%d process_info=%d errno=%d birth=%llu\n",owned_pid,status,saved,(unsigned long long)(status?0:process.birth));
#endif
  check(!status && process.pid==owned_pid && process.birth>0,"post-READY login root retains exact readable PID and kernel birth identity");
  LtNavProvider *provider=lt_nav_provider_create(601,owned_pid);
  check(provider && provider->root_birth==process.birth,"provider captures settled real Session root despite restricted login libproc access");
  LtNavSnapshot snapshot=result(provider,1,0);
  check(snapshot.session_id==601 && snapshot.generation==1 && snapshot.root_pid==owned_pid && snapshot.root_birth==process.birth && snapshot.git_state==LT_NAV_NON_REPOSITORY && snapshot.ports_state==LT_NAV_DISABLED,"real notification publishes nonrepository Git result for exact login Session identity");
  snapshot=result(provider,2,1);int found=0,foreign=0;
  for(unsigned i=0;i<snapshot.port_count;++i){LtNavPort p=snapshot.ports[i];if(p.pid==child && p.port==port)found=1;else foreign=1;}
  check(snapshot.git_state==LT_NAV_NON_REPOSITORY && snapshot.ports_state==LT_NAV_OK && found && !foreign,"owned login port scope discovers exact child listener without stale identity or foreign ports");
#ifdef __APPLE__
  check(bytes==(int)sizeof raw || snapshot.partial,"restricted login root FD visibility is explicitly partial rather than complete empty metadata");
#else
  check(!snapshot.partial,"fully readable private process scope is complete");
#endif
  printf("NAV_PROVIDER_LOGIN_PORTS state=%d scanned_pids=%u count=%u owned_listener=%d:%u\n",snapshot.ports_state,snapshot.scanned_pids,snapshot.port_count,child,port);
  uint64_t birth=provider->root_birth;provider->root_birth^=1;snapshot=result(provider,3,1);provider->root_birth=birth;
  check(snapshot.git_state==LT_NAV_STALE && snapshot.ports_state==LT_NAV_STALE && !snapshot.port_count,"real login fallback still rejects a mismatched root birth as PID reuse");
  lt_nav_provider_destroy(provider);assert(lt_write(owned_fd,"exit\n",5)==5);
  int exited=0;deadline=now_us()+3000000;
  while(now_us()<deadline){int rc=lt_wait(owned_pid,&status);if(rc==owned_pid){exited=1;break;}assert(rc>=0);char bytes[512];ssize_t n=lt_read(owned_fd,bytes,sizeof bytes-1);if(n>0){bytes[n]=0;printf("NAV_PROVIDER_LOGIN_EXIT_OUTPUT %s",bytes);}usleep(10000);}
  printf("NAV_PROVIDER_LOGIN_EXIT exited=%d status=%d errno=%d\n",exited,status,errno);
  check(exited && WIFEXITED(status) && WEXITSTATUS(status)==0,"private listener and login child exit and are reaped after owned PTY input");
  close(owned_fd);owned_fd=-1;owned_pid=-1;
  printf("NAV_PROVIDER_LOGIN_NATIVE {\"checks\":%u,\"actual_session_launcher\":true,\"global_process_enumeration\":false}\n",checks);
  return 0;
}
