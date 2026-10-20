#define _GNU_SOURCE
#define _DARWIN_C_SOURCE
#include "navigation_provider.h"
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <ctype.h>
#include <arpa/inet.h>
#ifdef __APPLE__
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#endif
/* No statx, pidfd, epoll extensions, getentropy, or recent libc entrypoints. */
#define GIT_BYTES (64u * 1024u)
#define ERROR_BYTES 8192u
#define TABLE_BYTES (256u * 1024u)
#define CHILD_BYTES 16384u
#define THREAD_LIMIT 256u
#define TASK_FD_LIMIT 8192u
struct Process { pid_t pid, ppid; uint64_t birth, tty; };
struct Node { struct Process info; size_t parent; };
struct LtNavProvider {
  uint64_t session_id, root_birth;
  pid_t root_pid;
  int notify[2], joinable;
  pthread_t thread;
  atomic_int cancelled, done;
  atomic_uint references;
  uint64_t generation, deadline_us;
  int git_enabled, ports_enabled;
  char cwd[LT_NAV_MAX_PATH + 1];
  LtNavSnapshot result;
#ifdef LT_NAV_PROVIDER_TEST
  const char *test_git;
#endif
};
static void release_provider(LtNavProvider *p) {
  if(atomic_fetch_sub_explicit(&p->references,1,memory_order_acq_rel)==1) {
    close(p->notify[0]);close(p->notify[1]);memset(p,0,sizeof *p);free(p);
  }
}
static uint64_t now_us(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t)) return 0;
  return (uint64_t)t.tv_sec * 1000000u + (uint64_t)t.tv_nsec / 1000u;
}
static int stopped(LtNavProvider *p) {
  if (atomic_load_explicit(&p->cancelled, memory_order_acquire)) return LT_NAV_CANCELLED;
  return now_us() >= p->deadline_us ? LT_NAV_TIMEOUT : LT_NAV_OK;
}
static int set_fd(int fd) {
  return fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 || fcntl(fd, F_SETFL, O_NONBLOCK) < 0 ? -1 : 0;
}
/* Every read, directory visit and socket table is capped, including fixtures. */

#ifdef __linux__
static int read_file(const char *path, char *out, size_t cap, size_t *length) {
  int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
  if (fd < 0) return -1;
  size_t at = 0;
  int result = 0, saved = 0;
  while (at < cap) {
    ssize_t n = read(fd, out + at, cap - at);
    if (n > 0) at += (size_t)n;
    else if (!n) break;
    else if (errno != EINTR) { result = -1; saved = errno; break; }
  }
  if (!result && at == cap) {
    char extra; ssize_t n = read(fd, &extra, 1);
    if (n != 0) { result = -1; saved = E2BIG; }
  }
  close(fd); *length = at;
  if (result) errno = saved;
  return result;
}

#endif
static int process_info(pid_t pid, struct Process *out) {
  if (pid <= 0) { errno = EINVAL; return -1; }
#ifdef __APPLE__
  struct proc_bsdinfo b;
  errno = 0;
  if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, sizeof b) != sizeof b) {
    if (errno != EPERM && errno != EACCES) return -1;
    /* The real Session root may remain Apple's set-id login process. libproc
       denies BSDINFO after login's exec, while this exact-PID sysctl exposes
       the same kernel birth timestamp. Never enumerate or accept PID alone. */
    struct kinfo_proc k;
    size_t size = sizeof k;
    int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    if (sysctl(mib, 4, &k, &size, NULL, 0)) return -1;
    if (size != sizeof k || k.kp_proc.p_pid != pid ||
        k.kp_proc.p_starttime.tv_sec <= 0 ||
        k.kp_proc.p_starttime.tv_usec < 0 || k.kp_proc.p_starttime.tv_usec >= 1000000 ||
        (uint64_t)k.kp_proc.p_starttime.tv_sec > (UINT64_MAX - (uint64_t)k.kp_proc.p_starttime.tv_usec) / 1000000u) {
      errno = ESRCH; return -1;
    }
    *out = (struct Process){ pid, k.kp_eproc.e_ppid,
      (uint64_t)k.kp_proc.p_starttime.tv_sec * 1000000u + (uint64_t)k.kp_proc.p_starttime.tv_usec,
      (uint32_t)k.kp_eproc.e_tdev };
    return 0;
  }
  if (b.pbi_pid != (uint32_t)pid || b.pbi_start_tvsec > UINT64_MAX / 1000000u) { errno = ESRCH; return -1; }
  *out = (struct Process){ pid, (pid_t)b.pbi_ppid, b.pbi_start_tvsec * 1000000u + b.pbi_start_tvusec, b.e_tdev };
  return 0;
#elif defined(__linux__)
  char path[96], data[8192]; size_t length;
  snprintf(path, sizeof path, "/proc/%d/stat", pid);
  if (read_file(path, data, sizeof data - 1, &length)) return -1;
  data[length] = 0;
  /* comm may contain spaces and ')' characters. The final ')' is its boundary. */
  char *end = strrchr(data, ')');
  if (!end || end[1] != ' ') { errno = EIO; return -1; }
  unsigned field = 3; char *save = NULL; uint64_t birth = 0, tty = 0; pid_t parent = 0;
  for (char *v = strtok_r(end + 2, " ", &save); v; v = strtok_r(NULL, " ", &save), ++field) {
    char *tail;
    if (field == 4) { long x = strtol(v, &tail, 10); if (*tail || x < 0 || x > INT32_MAX) { errno=EIO; return -1; } parent=(pid_t)x; }
    if (field == 7) { long long x = strtoll(v, &tail, 10); if (*tail) { errno=EIO; return -1; } tty=(uint64_t)x; }
    if (field == 22) { birth=strtoull(v, &tail, 10); if (*tail && *tail != '\n') { errno=EIO; return -1; } break; }
  }
  if (!birth || field != 22) { errno=EIO; return -1; }
  *out=(struct Process){pid,parent,birth,tty}; return 0;
#else
  (void)out; errno = ENOTSUP; return -1;
#endif
}
static int same_process(const struct Process *a, const struct Process *b) {
  return a->pid == b->pid && a->birth == b->birth;
}
static int root_current(LtNavProvider *p, struct Process *root) {
  if (process_info(p->root_pid, root) || root->birth != p->root_birth) return 0;
  return 1;
}
static int errno_state(void) {
  return errno == EPERM || errno == EACCES ? LT_NAV_PERMISSION :
    errno == E2BIG ? LT_NAV_LIMIT : LT_NAV_UNAVAILABLE;
}
/* Build only from a known Session root. Never list all machine processes. */
static int add_child(LtNavProvider *p, struct Node *nodes, size_t *count, size_t parent, pid_t pid) {
  for (size_t i=0;i<*count;++i) if (nodes[i].info.pid == pid) return LT_NAV_OK;
  if (*count == LT_NAV_MAX_PIDS) return LT_NAV_LIMIT;
  struct Process child;
  if (process_info(pid, &child)) return errno == ESRCH || errno == ENOENT ? LT_NAV_OK : errno_state();
  if (child.ppid != nodes[parent].info.pid || child.tty != nodes[0].info.tty) return LT_NAV_OK;
  if (child.birth < nodes[parent].info.birth) return LT_NAV_STALE;
  nodes[*count] = (struct Node){child,parent}; ++*count;
  return stopped(p);
}
static int children(LtNavProvider *p, struct Node *nodes, size_t *count, size_t parent) {
#ifdef __APPLE__
  pid_t ids[LT_NAV_MAX_PIDS + 1];
  errno=0;
  int size = proc_listchildpids(nodes[parent].info.pid, ids, sizeof ids);
  // Unlike proc_listpids(), this wrapper returns PID count, not byte count.
  if (size < 0 || (!size && errno && errno!=ESRCH)) return errno_state();
  if (size >= (int)(sizeof ids/sizeof ids[0])) return LT_NAV_LIMIT;
  for (int i=0;i<size;++i) {
    int state = add_child(p,nodes,count,parent,ids[i]);
    if (state != LT_NAV_OK) return state;
  }
  return LT_NAV_OK;
#elif defined(__linux__)
  char dirpath[96]; snprintf(dirpath,sizeof dirpath,"/proc/%d/task",nodes[parent].info.pid);
  DIR *dir = opendir(dirpath); if (!dir) return errno_state();
  size_t visits=0; int state=LT_NAV_OK; struct dirent *entry;
  while ((entry=readdir(dir))) {
    if (entry->d_name[0]=='.') continue;
    if (++visits > THREAD_LIMIT) { state=LT_NAV_LIMIT; break; }
    state=stopped(p); if (state != LT_NAV_OK) break;
    char *tail; long tid=strtol(entry->d_name,&tail,10); if (*tail || tid<=0 || tid>INT32_MAX) continue;
    char path[128], data[CHILD_BYTES]; size_t length;
    snprintf(path,sizeof path,"/proc/%d/task/%ld/children",nodes[parent].info.pid,tid);
    if (read_file(path,data,sizeof data-1,&length)) {
      if (errno==ENOENT || errno==ESRCH) continue;
      state=errno_state(); break;
    }
    data[length]=0; char *save=NULL;
    for (char *v=strtok_r(data," \n",&save); v; v=strtok_r(NULL," \n",&save)) {
      long pid=strtol(v,&tail,10); if (*tail || pid<=0 || pid>INT32_MAX) { state=LT_NAV_FAILED; break; }
      state=add_child(p,nodes,count,parent,(pid_t)pid); if (state!=LT_NAV_OK) break;
    }
    if (state!=LT_NAV_OK) break;
  }
  closedir(dir); return state;
#else
  (void)p;(void)nodes;(void)count;(void)parent; return LT_NAV_UNAVAILABLE;
#endif
}
static int chain_current(LtNavProvider *p, struct Node *nodes, size_t index) {
  for (size_t steps=0; steps<LT_NAV_MAX_PIDS; ++steps) {
    struct Process now;
    if (process_info(nodes[index].info.pid,&now) || !same_process(&now,&nodes[index].info) || now.tty != nodes[0].info.tty) return 0;
    if (!index) return now.birth == p->root_birth;
    size_t parent=nodes[index].parent;
    if (parent>=index || now.ppid != nodes[parent].info.pid) return 0;
    index=parent;
  }
  return 0;
}
static void add_port(LtNavSnapshot *r, const struct Process *owner, unsigned port, unsigned family) {
  if (!port || port > 65535 || (family!=4 && family!=6)) return;
  for (size_t i=0;i<r->port_count;++i) if (r->ports[i].pid==owner->pid && r->ports[i].port==port && r->ports[i].family==family) return;
  if (r->port_count==LT_NAV_MAX_PORTS) { r->partial=1; return; }
  r->ports[r->port_count++]=(LtNavPort){owner->pid,(uint16_t)port,(uint8_t)family,0,owner->birth};
}
#ifdef __linux__
static int table_ports(LtNavProvider *p, const struct Process *owner, const uint64_t *inodes, size_t count, unsigned family) {
  char path[96]; snprintf(path,sizeof path,"/proc/%d/net/tcp%s",owner->pid,family==6?"6":"");
  char *data=malloc(TABLE_BYTES); if (!data) return LT_NAV_FAILED;
  size_t length;
  if (read_file(path,data,TABLE_BYTES-1,&length)) {
    // An IPv4-only kernel has no tcp6 table. Root/owner identity is still
    // rechecked by the caller, so a vanished process cannot look like success.
    int state=family==6 && errno==ENOENT ? LT_NAV_OK : errno_state();free(data);return state;
  }
  data[length]=0; char *lines=NULL;
  for (char *line=strtok_r(data,"\n",&lines);line;line=strtok_r(NULL,"\n",&lines)) {
    int state=stopped(p); if (state!=LT_NAV_OK) { free(data); return state; }
    char *columns[10], *fields=NULL; size_t n=0;
    for (char *v=strtok_r(line," \t",&fields);v && n<10;v=strtok_r(NULL," \t",&fields)) columns[n++]=v;
    if (n<10 || strcmp(columns[3],"0A")) continue; /* TCP_LISTEN */
    char *tail, *colon=strrchr(columns[1],':'); if (!colon) continue;
    unsigned long port=strtoul(colon+1,&tail,16); if (*tail || port>65535) continue;
    uint64_t inode=strtoull(columns[9],&tail,10); if (*tail || !inode) continue;
    for (size_t i=0;i<count;++i) if (inode==inodes[i]) { add_port(&p->result,owner,(unsigned)port,family); break; }
  }
  free(data); return LT_NAV_OK;
}
#endif
static int process_ports(LtNavProvider *p, const struct Process *owner) {
#ifdef __APPLE__
  struct proc_fdinfo *fds=malloc(sizeof(*fds)*(LT_NAV_MAX_FDS+1));
  if (!fds) return LT_NAV_FAILED;
  errno=0;
  int bytes=proc_pidinfo(owner->pid,PROC_PIDLISTFDS,0,fds,(int)(sizeof(*fds)*(LT_NAV_MAX_FDS+1)));
  if (bytes<=0 && errno) { int state=errno_state(); free(fds); return state; }
  if (bytes>=(int)(sizeof(*fds)*(LT_NAV_MAX_FDS+1))) { free(fds); return LT_NAV_LIMIT; }
  for (size_t i=0;i<(size_t)bytes/sizeof(*fds);++i) {
    int state=stopped(p); if (state!=LT_NAV_OK) { free(fds); return state; }
    if (++p->result.scanned_fds>TASK_FD_LIMIT) { free(fds); return LT_NAV_LIMIT; }
    if (fds[i].proc_fdtype!=PROX_FDTYPE_SOCKET) continue;
    struct socket_fdinfo socket;
    int got=proc_pidfdinfo(owner->pid,(int)fds[i].proc_fd,PROC_PIDFDSOCKETINFO,&socket,sizeof socket);
    if (got!=sizeof socket) {
      if (errno==EBADF || errno==ENOENT || errno==ESRCH) continue;
      int state=errno_state(); free(fds); return state;
    }
    if (socket.psi.soi_kind!=SOCKINFO_TCP || socket.psi.soi_type!=SOCK_STREAM || socket.psi.soi_protocol!=IPPROTO_TCP || socket.psi.soi_proto.pri_tcp.tcpsi_state!=TSI_S_LISTEN) continue;
    unsigned family=socket.psi.soi_family==AF_INET?4:socket.psi.soi_family==AF_INET6?6:0;
    unsigned port=ntohs((uint16_t)socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport);
    add_port(&p->result,owner,port,family);
  }
  free(fds); return LT_NAV_OK;
#elif defined(__linux__)
  char path[96]; snprintf(path,sizeof path,"/proc/%d/fd",owner->pid);
  DIR *dir=opendir(path); if (!dir) return errno_state();
  uint64_t inodes[LT_NAV_MAX_FDS]; size_t count=0, visits=0; struct dirent *entry; int state=LT_NAV_OK;
  while ((entry=readdir(dir))) {
    if (entry->d_name[0]=='.') continue;
    if (++visits>LT_NAV_MAX_FDS || ++p->result.scanned_fds>TASK_FD_LIMIT) { state=LT_NAV_LIMIT; break; }
    state=stopped(p); if (state!=LT_NAV_OK) break;
    char linkpath[192], target[128];
    if (snprintf(linkpath,sizeof linkpath,"%s/%s",path,entry->d_name)>=(int)sizeof linkpath) { state=LT_NAV_LIMIT; break; }
    ssize_t n=readlink(linkpath,target,sizeof target-1);
    if (n<0) { if (errno==ENOENT) continue; state=errno_state(); break; }
    target[n]=0; unsigned long long inode; int consumed=0;
    if (sscanf(target,"socket:[%llu]%n",&inode,&consumed)==1 && consumed==n && count<LT_NAV_MAX_FDS) inodes[count++]=(uint64_t)inode;
  }
  closedir(dir);
  if (state!=LT_NAV_OK || !count) return state;
  state=table_ports(p,owner,inodes,count,4);
  if (state==LT_NAV_OK) state=table_ports(p,owner,inodes,count,6);
  return state;
#else
  (void)p;(void)owner; return LT_NAV_UNAVAILABLE;
#endif
}
static int port_order(const void *a,const void *b) {
  const LtNavPort *x=a,*y=b;
  if (x->port!=y->port) return x->port<y->port?-1:1;
  if (x->pid!=y->pid) return x->pid<y->pid?-1:1;
  return (int)x->family-(int)y->family;
}
static int scan_ports(LtNavProvider *p) {
  struct Node nodes[LT_NAV_MAX_PIDS]; size_t count=1;
  if (!root_current(p,&nodes[0].info)) return LT_NAV_STALE;
  nodes[0].parent=0;
  for (size_t i=0;i<count;++i) {
    int state=stopped(p); if (state!=LT_NAV_OK) return state;
    state=children(p,nodes,&count,i); if (state!=LT_NAV_OK) return state;
  }
  p->result.scanned_pids=(uint32_t)count;
  for (size_t i=0;i<count;++i) {
    if (!chain_current(p,nodes,i)) return LT_NAV_STALE;
    size_t before=p->result.port_count;
    int state=process_ports(p,&nodes[i].info);
    if (!chain_current(p,nodes,i)) return LT_NAV_STALE;
    if (state!=LT_NAV_OK) {
      p->result.port_count=(uint32_t)before;
#ifdef __APPLE__
      /* A set-id login root can deny FD inspection while its verified child
         shell is readable. Keep that child scope useful but explicitly partial.
         Both ancestry checks above remain mandatory for the skipped node. */
      if (state==LT_NAV_PERMISSION) { p->result.partial=1; continue; }
#endif
      return state;
    }
  }
  for (size_t i=0;i<count;++i) if (!chain_current(p,nodes,i)) return LT_NAV_STALE;
  qsort(p->result.ports,p->result.port_count,sizeof(p->result.ports[0]),port_order);
  return LT_NAV_OK;
}
struct GitOutput { char out[GIT_BYTES+1], err[ERROR_BYTES+1]; size_t out_len, err_len; int exit_code; };
/* A child is killed/reaped only by its worker, while its PID is still reserved.
   cancel never races a reused child PID with an asynchronous kill(). */
static int run_git(LtNavProvider *p, const char *const *args, struct GitOutput *result) {
  int admission=stopped(p);if(admission!=LT_NAV_OK)return admission;
  int output[2], errors[2];
  if (pipe(output)) return LT_NAV_FAILED;
  if (pipe(errors)) { int e=errno; close(output[0]); close(output[1]); errno=e; return LT_NAV_FAILED; }
  if (set_fd(output[0]) || set_fd(errors[0]) || fcntl(output[1],F_SETFD,FD_CLOEXEC)<0 || fcntl(errors[1],F_SETFD,FD_CLOEXEC)<0) goto pipe_fail;
  int nullfd=open("/dev/null",O_RDONLY|O_CLOEXEC); if (nullfd<0) goto pipe_fail;
  const char *executable="/usr/bin/git";
#ifdef LT_NAV_PROVIDER_TEST
  if (p->test_git) executable=p->test_git;
#endif
  char *const env[]={"PATH=/usr/bin:/bin","LC_ALL=C","HOME=/","GIT_OPTIONAL_LOCKS=0","GIT_CONFIG_NOSYSTEM=1","GIT_CONFIG_GLOBAL=/dev/null",NULL};
  pid_t pid=fork();
  if (pid==0) {
    setpgid(0,0);
    if (dup2(nullfd,STDIN_FILENO)<0 || dup2(output[1],STDOUT_FILENO)<0 || dup2(errors[1],STDERR_FILENO)<0) _exit(126);
    close(nullfd); close(output[0]); close(output[1]); close(errors[0]); close(errors[1]);
    if (chdir(p->cwd)) _exit(errno==EACCES?125:126);
    execve(executable,(char *const *)args,env); _exit(127);
  }
  close(nullfd);
  if (pid<0) goto pipe_fail;
  (void)setpgid(pid,pid);
  close(output[1]); close(errors[1]);
  result->out_len=result->err_len=0; result->exit_code=-1;
  int state=LT_NAV_OK, status=0, reaped=0, open_out=1, open_err=1;
  while (!reaped || open_out || open_err) {
    state=stopped(p); if (state!=LT_NAV_OK) break;
    struct pollfd fds[2]={{output[0],POLLIN|POLLHUP,0},{errors[0],POLLIN|POLLHUP,0}};
    if (!open_out) fds[0].fd=-1;
    if (!open_err) fds[1].fd=-1;
    int ready=poll(fds,2,10);
    if (ready<0 && errno!=EINTR) { state=LT_NAV_FAILED; break; }
    for (int i=0;i<2;++i) if (fds[i].revents&(POLLIN|POLLHUP|POLLERR)) {
      char *data=i?result->err:result->out;
      size_t *length=i?&result->err_len:&result->out_len, cap=i?ERROR_BYTES:GIT_BYTES;
      ssize_t n=read(fds[i].fd,data+*length,cap-*length);
      if (n>0) *length+=(size_t)n;
      else if (!n) { if (i) open_err=0; else open_out=0; }
      else if (errno!=EINTR && errno!=EAGAIN) { state=LT_NAV_FAILED; break; }
      if (*length==cap) { state=LT_NAV_LIMIT; break; }
    }
    if (state!=LT_NAV_OK) break;
    if (!reaped) {
      pid_t waited=waitpid(pid,&status,WNOHANG);
      if (waited==pid) reaped=1;
      else if (waited<0 && errno!=EINTR) { state=LT_NAV_FAILED; break; }
    }
  }
  if (state!=LT_NAV_OK) {
    if (!reaped) { (void)kill(-pid,SIGKILL); (void)kill(pid,SIGKILL); }
    while (!reaped) { pid_t waited=waitpid(pid,&status,0); if (waited==pid || (waited<0 && errno!=EINTR)) reaped=1; }
  }
  close(output[0]); close(errors[0]);
  result->out[result->out_len]=0; result->err[result->err_len]=0;
  if (WIFEXITED(status)) result->exit_code=WEXITSTATUS(status);
  if (state!=LT_NAV_OK) return state;
  if (result->exit_code==0) return LT_NAV_OK;
  if (strstr(result->err,"not a git repository")) return LT_NAV_NON_REPOSITORY;
  if (result->exit_code==125 || strstr(result->err,"Permission denied")) return LT_NAV_PERMISSION;
  return result->exit_code==127 ? LT_NAV_UNAVAILABLE : LT_NAV_FAILED;
pipe_fail: {
    int e=errno; close(output[0]);close(output[1]);close(errors[0]);close(errors[1]);errno=e;return LT_NAV_FAILED;
  }
}
static int scan_git(LtNavProvider *p) {
  struct GitOutput *output=malloc(sizeof *output); if (!output) return LT_NAV_FAILED;
  const char *const args[]={"git","-c","core.fsmonitor=false","-c","core.untrackedCache=false","-c","core.pager=cat","status","--porcelain","-z","--branch","--untracked-files=normal","--ignore-submodules=all",NULL};
  int state=run_git(p,args,output);
  if (state!=LT_NAV_OK) { free(output); return state; }
  size_t header=strnlen(output->out,output->out_len);
  if (header==output->out_len || header<4 || strncmp(output->out,"## ",3)) { free(output); return LT_NAV_FAILED; }
  char *branch=output->out+3;
  p->result.git_dirty=header+1<output->out_len;
  if (!strcmp(branch,"HEAD (no branch)") || !strcmp(branch,"HEAD (detached at ") || !strncmp(branch,"HEAD (",6)) {
    p->result.git_detached=1;
    const char *const head[]={"git","rev-parse","--short=12","HEAD",NULL};
    state=run_git(p,head,output);
    if (state==LT_NAV_OK) {
      size_t n=strcspn(output->out,"\r\n");
      if (n==0 || n>=sizeof p->result.head || n!=strspn(output->out,"0123456789abcdefABCDEF")) state=LT_NAV_FAILED;
      else { memcpy(p->result.head,output->out,n); p->result.head[n]=0; }
    }
  } else {
    if (!strncmp(branch,"No commits yet on ",18)) branch+=18;
    else if (!strncmp(branch,"Initial commit on ",18)) branch+=18;
    char *upstream=strstr(branch,"..."); if (upstream) *upstream=0;
    size_t n=strlen(branch);
    if (n==0 || n>=sizeof p->result.branch) state=LT_NAV_LIMIT;
    else { memcpy(p->result.branch,branch,n); p->result.branch[n]=0; }
  }
  free(output); return state;
}
static void invalidate(LtNavSnapshot *r, int state) {
  if (r->git_state!=LT_NAV_DISABLED) r->git_state=state;
  if (r->ports_state!=LT_NAV_DISABLED) r->ports_state=state;
  r->git_dirty=r->git_detached=r->port_count=0; r->branch[0]=r->head[0]=0;
}
static void *worker(void *raw) {
  LtNavProvider *p=raw; uint64_t start=now_us();
  LtNavSnapshot *r=&p->result;
  *r=(LtNavSnapshot){.session_id=p->session_id,.generation=p->generation,.root_birth=p->root_birth,.root_pid=p->root_pid,
    .git_state=p->git_enabled?LT_NAV_UNAVAILABLE:LT_NAV_DISABLED,.ports_state=p->ports_enabled?LT_NAV_UNAVAILABLE:LT_NAV_DISABLED};
  struct Process root;
  if (!root_current(p,&root)) invalidate(r,LT_NAV_STALE);
  else {
    if (p->git_enabled) r->git_state=scan_git(p);
    if (p->ports_enabled) r->ports_state=scan_ports(p);
    int state=stopped(p);
    if (state==LT_NAV_CANCELLED || !root_current(p,&root)) invalidate(r,state==LT_NAV_CANCELLED?state:LT_NAV_STALE);
    else if (state==LT_NAV_TIMEOUT && r->ports_state!=LT_NAV_OK && r->ports_state!=LT_NAV_DISABLED) r->ports_state=state;
    if (r->git_state!=LT_NAV_OK) { r->branch[0]=r->head[0]=0; r->git_dirty=r->git_detached=0; }
    if (r->ports_state!=LT_NAV_OK) r->port_count=0;
  }
  r->elapsed_us=now_us()-start;
  atomic_store_explicit(&p->done,1,memory_order_release);
  const char byte=1; (void)write(p->notify[1],&byte,1);
  release_provider(p); // Retired contexts have no host callbacks or UI borrows.
  return NULL;
}
LtNavProvider *lt_nav_provider_create(uint64_t session_id,int32_t root_pid) {
  struct Process root;
  if (!session_id || process_info(root_pid,&root)) return NULL;
  LtNavProvider *p=calloc(1,sizeof *p); if (!p) return NULL;
  p->session_id=session_id;p->root_pid=root_pid;p->root_birth=root.birth;
  if (pipe(p->notify)) { free(p); return NULL; }
  if (set_fd(p->notify[0]) || set_fd(p->notify[1])) { int e=errno;close(p->notify[0]);close(p->notify[1]);free(p);errno=e;return NULL; }
  atomic_init(&p->cancelled,0);atomic_init(&p->done,0);atomic_init(&p->references,1);return p;
}
int lt_nav_provider_fd(const LtNavProvider *p) { return p?p->notify[0]:-1; }
int lt_nav_provider_start(LtNavProvider *p,uint64_t generation,const char *cwd,int git_enabled,int ports_enabled,uint32_t timeout_ms) {
  if (!p || !generation || (!git_enabled && !ports_enabled) || !timeout_ms || timeout_ms>LT_NAV_MAX_TIMEOUT_MS) { errno=EINVAL;return -1; }
  if (p->joinable) return 0;
  size_t n=cwd?strnlen(cwd,LT_NAV_MAX_PATH+1):0;
  if (git_enabled && (!cwd || !n || n>LT_NAV_MAX_PATH || cwd[0]!='/')) { errno=EINVAL;return -1; }
  if (n>LT_NAV_MAX_PATH) { errno=EINVAL;return -1; }
  p->cwd[0]=0;if (n) memcpy(p->cwd,cwd,n+1);
  p->generation=generation;p->git_enabled=git_enabled!=0;p->ports_enabled=ports_enabled!=0;
  p->deadline_us=now_us()+(uint64_t)timeout_ms*1000u;
  atomic_store_explicit(&p->cancelled,0,memory_order_release);atomic_store_explicit(&p->done,0,memory_order_release);
  atomic_fetch_add_explicit(&p->references,1,memory_order_relaxed);
  int e=pthread_create(&p->thread,NULL,worker,p);if (e) { release_provider(p);errno=e;return -1; }
  p->joinable=1;return 1;
}
void lt_nav_provider_cancel(LtNavProvider *p) { if(p) atomic_store_explicit(&p->cancelled,1,memory_order_release); }
int lt_nav_provider_drain(LtNavProvider *p,LtNavSnapshot *out) {
  if (!p || !out) { errno=EINVAL;return -1; }
  if (!p->joinable || !atomic_load_explicit(&p->done,memory_order_acquire)) return 0;
  int e=pthread_join(p->thread,NULL);if(e){errno=e;return -1;}p->joinable=0;
  char bytes[64];while(read(p->notify[0],bytes,sizeof bytes)>0) {}
  *out=p->result;
  if(atomic_load_explicit(&p->cancelled,memory_order_acquire)) invalidate(out,LT_NAV_CANCELLED);
  struct Process root;if(!root_current(p,&root)) invalidate(out,LT_NAV_STALE);
  return 1;
}
void lt_nav_provider_destroy(LtNavProvider *p) {
  if(!p)return;
  lt_nav_provider_cancel(p);
  // Host first unregisters fdwatch. Never block its UI on a subprocess or a
  // kernel process-info read. The worker owns its copy until it has reaped Git.
  if(p->joinable)(void)pthread_detach(p->thread);
  release_provider(p);
}
