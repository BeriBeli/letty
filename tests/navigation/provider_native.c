/* Isolated provider integration: temporary repos and test-owned TCP processes.
   No desktop, user config, user clipboard, global process scan or real hotkeys. */
#define LT_NAV_PROVIDER_TEST
#include "../../src/platform/navigation_provider.c"
#include <assert.h>
#include <sys/resource.h>
static unsigned checks;
static pid_t cleanup_pids[8];
static void cleanup_owned(void) {
  for(size_t i=0;i<sizeof cleanup_pids/sizeof cleanup_pids[0];++i) if(cleanup_pids[i]>0)kill(cleanup_pids[i],SIGKILL);
}

static void check(int ok,const char *label) {
  printf("%s NAV_PROVIDER %s\n",ok?"PASS":"FAIL",label);fflush(stdout);
  if(!ok)exit(1);++checks;
}
static void write_text(const char *path,const char *text,mode_t mode) {
  int fd=open(path,O_WRONLY|O_CREAT|O_TRUNC,mode);assert(fd>=0);
  size_t n=strlen(text);assert(write(fd,text,n)==(ssize_t)n);assert(!close(fd));
}
static int command(const char *cwd,const char *const *args) {
  pid_t pid=fork();assert(pid>=0);
  if(!pid) {
    int fd=open("/dev/null",O_RDWR);assert(fd>=0);dup2(fd,0);dup2(fd,1);dup2(fd,2);close(fd);
    if(cwd && chdir(cwd))_exit(125);
    char *const env[]={"PATH=/usr/bin:/bin","LC_ALL=C","HOME=/","GIT_CONFIG_NOSYSTEM=1","GIT_CONFIG_GLOBAL=/dev/null",NULL};
    execve(args[0],(char *const *)args,env);_exit(127);
  }
  int status;while(waitpid(pid,&status,0)<0)assert(errno==EINTR);
  return WIFEXITED(status)?WEXITSTATUS(status):128;
}
#define GIT(dir,...) command(dir,(const char *const[]){"/usr/bin/git",__VA_ARGS__,NULL})
static LtNavSnapshot await_result(LtNavProvider *p) {
  struct pollfd fd={lt_nav_provider_fd(p),POLLIN,0};
  assert(poll(&fd,1,3000)==1);
  LtNavSnapshot r;assert(lt_nav_provider_drain(p,&r)==1);
  return r;
}
static LtNavSnapshot start(LtNavProvider *p,uint64_t generation,const char *cwd,int git,int ports) {
  assert(lt_nav_provider_start(p,generation,cwd,git,ports,1200)==1);
  return await_result(p);
}
struct Owned {pid_t root,descendant;uint16_t port,descendant_port;};
static int listen_owned(uint16_t *port) {
  int fd=socket(AF_INET,SOCK_STREAM,0);assert(fd>=0);
  struct sockaddr_in addr={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
  assert(!bind(fd,(struct sockaddr*)&addr,sizeof addr));assert(!listen(fd,4));
  socklen_t size=sizeof addr;assert(!getsockname(fd,(struct sockaddr*)&addr,&size));*port=ntohs(addr.sin_port);return fd;
}
static struct Owned owned_server(int descendants) {
  int channel[2];assert(!pipe(channel));pid_t root=fork();assert(root>=0);
  if(!root) {
    close(channel[0]);struct Owned info={.root=getpid()};
    int socket=listen_owned(&info.port);
    if(descendants) {
      int child_channel[2];assert(!pipe(child_channel));pid_t child=fork();assert(child>=0);
      if(!child) {
        close(child_channel[0]);close(channel[1]);close(socket);
        uint16_t port;int inner=listen_owned(&port);(void)inner;
        assert(write(child_channel[1],&port,sizeof port)==sizeof port);close(child_channel[1]);
        for(;;)pause();
      }
      close(child_channel[1]);info.descendant=child;
      assert(read(child_channel[0],&info.descendant_port,sizeof info.descendant_port)==sizeof info.descendant_port);close(child_channel[0]);
    }
    assert(write(channel[1],&info,sizeof info)==sizeof info);close(channel[1]);for(;;)pause();
  }
  close(channel[1]);struct Owned info;assert(read(channel[0],&info,sizeof info)==sizeof info);close(channel[0]);return info;
}
static int has_port(LtNavSnapshot *r,pid_t pid,uint16_t port) {
  for(size_t i=0;i<r->port_count;++i)if(r->ports[i].pid==pid && r->ports[i].port==port && r->ports[i].family==4 && r->ports[i].birth>0)return 1;
  return 0;
}
static void stop_server(struct Owned server) {
  if(server.descendant>0)kill(server.descendant,SIGKILL);
  kill(server.root,SIGKILL);int status;while(waitpid(server.root,&status,0)<0)assert(errno==EINTR);
}
static unsigned fd_count(void) {
  unsigned n=0;for(int fd=0;fd<1024;++fd)if(fcntl(fd,F_GETFD)>=0)++n;return n;
}
static int exec_identity_child(int argc,char **argv) {
  assert(argc==4);int gate=atoi(argv[2]),report=atoi(argv[3]);
  struct Process self;assert(!process_info(getpid(),&self));
  assert(write(report,&self,sizeof self)==sizeof self);close(report);
  char byte;assert(read(gate,&byte,1)==1);close(gate);return 0;
}
static void exec_identity(const char *executable,const char *cwd) {
  int gate[2],report[2];assert(!pipe(gate));assert(!pipe(report));
  pid_t child=fork();assert(child>=0);
  if(!child) {
    close(gate[1]);close(report[0]);char byte;
    assert(read(gate[0],&byte,1)==1);
    char input[32],output[32];snprintf(input,sizeof input,"%d",gate[0]);snprintf(output,sizeof output,"%d",report[1]);
    char *const args[]={(char *)executable,"--exec-identity-child",input,output,NULL};
    execv(executable,args);_exit(127);
  }
  close(gate[0]);close(report[1]);cleanup_pids[3]=child;
  struct Process before,after;assert(!process_info(child,&before));
  LtNavProvider *provider=lt_nav_provider_create(500,child);assert(provider);
  assert(write(gate[1],"E",1)==1);
  assert(read(report[0],&after,sizeof after)==sizeof after);close(report[0]);
  struct Process observed;int read_error=process_info(child,&observed);
  printf("NAV_PROVIDER_EXEC_IDENTITY pid=%d before_birth=%llu after_birth=%llu observed_birth=%llu read_error=%d captured_birth=%llu\n",child,(unsigned long long)before.birth,(unsigned long long)after.birth,(unsigned long long)(read_error?0:observed.birth),read_error,(unsigned long long)provider->root_birth);fflush(stdout);
  check(!read_error && same_process(&before,&after) && same_process(&after,&observed),"owned root OS birth remains exact across a synchronized exec boundary");
  LtNavSnapshot result=start(provider,1,cwd,1,0);
  check(result.root_pid==child && result.root_birth==before.birth && result.git_state==LT_NAV_NON_REPOSITORY,"provider captured before exec accepts only the same live root after real child readiness");
  lt_nav_provider_destroy(provider);assert(write(gate[1],"X",1)==1);close(gate[1]);
  int status;while(waitpid(child,&status,0)<0)assert(errno==EINTR);
  assert(WIFEXITED(status) && WEXITSTATUS(status)==0);cleanup_pids[3]=0;
}
int main(int argc,char **argv) {
  if(argc>1 && !strcmp(argv[1],"--exec-identity-child"))return exec_identity_child(argc,argv);
  _Static_assert(sizeof(LtNavSnapshot)==872,"snapshot ABI");
  _Static_assert(sizeof(LtNavPort)==16,"port ABI");
  char root[]="/tmp/letty-navigation-provider-XXXXXX";assert(mkdtemp(root));
  char repo[4096],other[4096],worktree[4096],file[4096],slow[4096],bad[4096],large[4096];
  snprintf(repo,sizeof repo,"%s/repo",root);snprintf(other,sizeof other,"%s/plain",root);snprintf(worktree,sizeof worktree,"%s/worktree",root);
  snprintf(slow,sizeof slow,"%s/slow-git",root);snprintf(bad,sizeof bad,"%s/bad-git",root);snprintf(large,sizeof large,"%s/large-git",root);
  assert(!mkdir(repo,0700));assert(!mkdir(other,0700));
  assert(!GIT(repo,"init"));assert(!GIT(repo,"checkout","-b","provider-test"));
  snprintf(file,sizeof file,"%s/repo/tracked",root);write_text(file,"fixture\n",0600);
  assert(!GIT(repo,"add","tracked"));assert(!GIT(repo,"-c","user.name=Letty Fixture","-c","user.email=fixture@invalid","-c","commit.gpgsign=false","commit","--no-verify","-m","fixture"));
  assert(!atexit(cleanup_owned));
  exec_identity(argv[0],other);
  struct Owned owned=owned_server(1);
  cleanup_pids[0]=owned.descendant;cleanup_pids[1]=owned.root;
  struct Owned unrelated=owned_server(0);cleanup_pids[2]=unrelated.root;
  LtNavProvider *p=lt_nav_provider_create(101,owned.root);assert(p);
  check(lt_nav_provider_fd(p)>=0 && (fcntl(lt_nav_provider_fd(p),F_GETFL)&O_NONBLOCK),"owned context exposes a nonblocking close-on-exec notification fd");
  LtNavSnapshot r=start(p,1,repo,1,1);
  check(r.session_id==101 && r.generation==1 && r.root_birth>0 && r.root_pid==owned.root,"completion preserves exact session generation and OS root birth");
  check(r.git_state==LT_NAV_OK && !r.git_dirty && !r.git_detached && !strcmp(r.branch,"provider-test"),"real temporary Git repository reports clean branch");
  check(r.ports_state==LT_NAV_OK && has_port(&r,owned.root,owned.port) && has_port(&r,owned.descendant,owned.descendant_port),"real owned root and descendant TCP listeners are discovered");
  check(!has_port(&r,unrelated.root,unrelated.port) && r.scanned_pids==2,"sibling listener is excluded without scanning all machine processes");
  write_text(file,"modified fixture\n",0600);r=start(p,2,repo,1,0);
  check(r.git_state==LT_NAV_OK && r.git_dirty && !strcmp(r.branch,"provider-test") && r.ports_state==LT_NAV_DISABLED,"tracked modification reports dirty independently of disabled port collection");
  assert(!GIT(repo,"checkout","--","tracked"));assert(!GIT(repo,"checkout","--detach","HEAD"));r=start(p,3,repo,1,0);
  check(r.git_state==LT_NAV_OK && r.git_detached && !r.git_dirty && strlen(r.head)>=7 && !r.branch[0],"detached HEAD reports actual commit hash without inventing a branch");
  assert(!GIT(repo,"worktree","add","--detach",worktree,"HEAD"));r=start(p,4,worktree,1,0);
  check(r.git_state==LT_NAV_OK && r.git_detached && !r.git_dirty,"real linked worktree .git file is followed by Git");
  r=start(p,5,other,1,0);check(r.git_state==LT_NAV_NON_REPOSITORY && !r.branch[0] && !r.git_dirty,"non-repository is explicit and clears prior branch metadata");
  write_text(slow,"#!/bin/sh\n/bin/sleep 2\n",0700);p->test_git=slow;
  uint64_t begin=now_us();assert(lt_nav_provider_start(p,6,repo,1,0,40)==1);
  check(lt_nav_provider_start(p,7,repo,1,0,40)==0,"busy context refuses overlapping worker or borrowed replacement request");
  r=await_result(p);check(r.git_state==LT_NAV_TIMEOUT && now_us()-begin<400000 && !r.branch[0],"slow owned Git fixture times out and is killed and reaped within bounded time");
  assert(lt_nav_provider_start(p,8,repo,1,0,1200)==1);usleep(20000);begin=now_us();lt_nav_provider_cancel(p);
  check(now_us()-begin<10000,"disable cancellation is nonblocking");r=await_result(p);
  check(r.git_state==LT_NAV_CANCELLED && r.generation==8 && now_us()-begin<300000,"cancelled generation cannot publish metadata and its child is promptly reaped");
  p->test_git=bad;write_text(bad,"#!/bin/sh\nprintf 'fatal: Permission denied\\n' >&2\nexit 128\n",0700);r=start(p,9,repo,1,0);
  check(r.git_state==LT_NAV_PERMISSION && !r.branch[0],"permission failure is explicit rather than fabricated empty clean metadata");
  write_text(bad,"#!/bin/sh\nexit 3\n",0700);r=start(p,10,repo,1,0);
  check(r.git_state==LT_NAV_FAILED && !r.git_dirty,"command failure is independent from non-repository");
  p->test_git=large;write_text(large,"#!/bin/sh\n/usr/bin/head -c 80000 /dev/zero\n",0700);r=start(p,11,repo,1,0);
  check(r.git_state==LT_NAV_LIMIT && !r.branch[0],"unbounded child output is capped and never published as a valid branch");
  p->test_git=NULL;uint64_t birth=p->root_birth;p->root_birth^=1;r=start(p,12,repo,1,1);p->root_birth=birth;
  check(r.git_state==LT_NAV_STALE && r.ports_state==LT_NAV_STALE && r.port_count==0,"OS birth mismatch models PID reuse and rejects all collected metadata");
  r=start(p,13,repo,0,1);lt_nav_provider_cancel(p);
  check(r.ports_state==LT_NAV_OK,"ports can refresh independently from Git with a fresh generation");
  assert(lt_nav_provider_start(p,14,repo,0,1,1200)==1);
  struct pollfd notify={lt_nav_provider_fd(p),POLLIN,0};assert(poll(&notify,1,3000)==1);lt_nav_provider_cancel(p);assert(lt_nav_provider_drain(p,&r)==1);
  check(r.ports_state==LT_NAV_CANCELLED && r.port_count==0,"disable racing an already completed notification still revokes publication");
  lt_nav_provider_destroy(p);
  unsigned descriptors=fd_count();
  for(unsigned i=0;i<20;++i) {
    LtNavProvider *once=lt_nav_provider_create(200+i,owned.root);assert(once);once->test_git=slow;
    assert(lt_nav_provider_start(once,1,repo,1,0,1200)==1);lt_nav_provider_cancel(once);lt_nav_provider_destroy(once);
  }
  for(unsigned retry=0;retry<200 && fd_count()!=descriptors;++retry)usleep(5000);
  check(fd_count()==descriptors,"repeated disable and asynchronous destruction reclaim all provider pipe descriptors");
  p=lt_nav_provider_create(300,owned.root);assert(p);p->test_git=slow;assert(lt_nav_provider_start(p,1,repo,1,0,1200)==1);usleep(20000);begin=now_us();lt_nav_provider_destroy(p);
  check(now_us()-begin<10000,"forced teardown immediately retires worker without joining on the UI thread");
  for(unsigned retry=0;retry<200 && fd_count()!=descriptors;++retry)usleep(5000);
  check(fd_count()==descriptors,"retired worker reaps its slow Git child and closes pipes after host teardown");
  p=lt_nav_provider_create(301,owned.root);assert(p);stop_server(owned);r=start(p,1,repo,1,1);
  check(r.git_state==LT_NAV_STALE && r.ports_state==LT_NAV_STALE && r.port_count==0,"root exit invalidates cached process and Git ownership");lt_nav_provider_destroy(p);stop_server(unrelated);
  memset(cleanup_pids,0,sizeof cleanup_pids);
  check(lt_nav_provider_create(400,-1)==NULL,"invalid process identity cannot create a collector");
  assert(command(NULL,(const char *const[]){"/bin/rm","-rf",root,NULL})==0);
  printf("NAV_PROVIDER_NATIVE {\"checks\":%u,\"real_git\":true,\"real_owned_tcp\":true,\"global_process_enumeration\":false,\"target_linux_runtime\":\"pending\"}\n",checks);
  return 0;
}
