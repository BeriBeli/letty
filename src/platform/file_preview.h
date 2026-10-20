#ifndef LETTY_FILE_PREVIEW_H
#define LETTY_FILE_PREVIEW_H
#include <stddef.h>
#include <stdint.h>
#define LT_PREVIEW_MAX_PATH 4095u
#define LT_PREVIEW_MAX_TEXT (2u * 1024u * 1024u)
#define LT_PREVIEW_MAX_IMAGE (8u * 1024u * 1024u)
#define LT_PREVIEW_MAX_LINES 50000u
#define LT_PREVIEW_MAX_SIDE 8192u
#define LT_PREVIEW_MAX_PIXELS (16u * 1024u * 1024u)
#define LT_PREVIEW_GLOBAL_BYTES (32u * 1024u * 1024u)
enum LtPreviewKind { LT_PREVIEW_TEXT=0,LT_PREVIEW_MARKDOWN,LT_PREVIEW_IMAGE,LT_PREVIEW_UNSUPPORTED };
enum LtPreviewStatus { LT_PREVIEW_CLOSED=0,LT_PREVIEW_LOADING,LT_PREVIEW_READY,LT_PREVIEW_MISSING,
 LT_PREVIEW_PERMISSION,LT_PREVIEW_TOO_LARGE,LT_PREVIEW_UNSUPPORTED_FORMAT,LT_PREVIEW_INVALID_UTF8,
 LT_PREVIEW_NOT_REGULAR,LT_PREVIEW_SYMLINK,LT_PREVIEW_WATCH_ERROR,LT_PREVIEW_IO_ERROR,LT_PREVIEW_CANCELLED,LT_PREVIEW_INVALID_IMAGE };
typedef struct LtPreviewLoader LtPreviewLoader;
/* Immutable worker-only transform context; no UI/config/Window borrows.
   prepare owns its output independently of bytes and returns LtPreviewStatus.
   release may run on either the worker or the receiving main thread. */
typedef struct {
  void *context;
  int32_t (*prepare)(void *context,const char *path,const unsigned char *bytes,size_t length,int32_t kind,void **out);
  void (*release)(void *context,void *value);
} LtPreviewHooks;
typedef struct {
  uint64_t generation;
  int32_t status,kind;
  uint32_t changed,watch_available,width,height;
  size_t length,lines,allocation;
  unsigned char *bytes;
  void *prepared;
  LtPreviewHooks hooks;
} LtPreviewResult;
/* Absolute local UTF-8 path only. Every symlink component is rejected in the
   worker. No file open/stat/read occurs on the calling/UI thread. */
LtPreviewLoader *lt_preview_create(const char *path,uint64_t generation);
LtPreviewLoader *lt_preview_create_with_hooks(const char *path,uint64_t generation,const LtPreviewHooks *);
int lt_preview_fd(const LtPreviewLoader *);
/* Main thread only, generations strictly increase. No blocking I/O. */
int lt_preview_refresh(LtPreviewLoader *,uint64_t generation);
/* 1=owned result/event; 0=none. changed requires a new refresh generation.
   Changes win over an already queued older result. Every result must be freed. */
int lt_preview_drain(LtPreviewLoader *,LtPreviewResult *);
void lt_preview_result_free(LtPreviewResult *);
/* Worker-only synchronous local PNG resource load, confined to document's
   directory. No watch or transform is installed. Returns one owned result. */
int lt_preview_read_resource(const char *document_path,const char *relative_ref,LtPreviewResult *);
/* Unregister the UI fdwatch first. Nonblocking retire wakes the independent
   worker; it closes its watch/fds and frees its own owned data on exit. */
void lt_preview_destroy(LtPreviewLoader *);
#endif
