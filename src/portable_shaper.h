#ifndef LETTY_PORTABLE_SHAPER_H
#define LETTY_PORTABLE_SHAPER_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define LT_SHAPE_MAX_FONT_BYTES (64u * 1024u * 1024u)
#define LT_SHAPE_MAX_BYTES 16384u
#define LT_SHAPE_MAX_CODEPOINTS 4096u
#define LT_SHAPE_MAX_GLYPHS 4096u
#define LT_SHAPE_MAX_FEATURES 32u
typedef struct LtShapeFont LtShapeFont;
typedef struct { uint8_t tag[4]; uint32_t value; } LtShapeFeature;
typedef struct {
    uint32_t glyph, cluster;
    int32_t x_advance, y_advance, x_offset, y_offset;
} LtShapeGlyph;
enum { LT_SHAPE_OK, LT_SHAPE_INVALID, LT_SHAPE_LIMIT, LT_SHAPE_ALLOC, LT_SHAPE_FAILED };
/* Copies font bytes. index selects a TTC face; the caller may free its bytes
   immediately. Each returned handle must be freed exactly once. */
LtShapeFont *lt_shape_font_new(const uint8_t *, size_t, uint32_t index);
/* Status-returning constructor: *out is NULL on every failure. INVALID means
   malformed input/face, LIMIT means font budget, ALLOC means a detected
   allocation failure. HarfBuzz validation can reject malformed tables before
   construction. The legacy pointer constructor preserves its old ABI. */
int lt_shape_font_create(const uint8_t *, size_t, uint32_t index, LtShapeFont **out);
void lt_shape_font_free(LtShapeFont *);
uint32_t lt_shape_font_upem(const LtShapeFont *);
int lt_shape_font_has_glyph(const LtShapeFont *, uint32_t codepoint);
/* Output is caller-owned. Coordinates are signed 26.6 pixel units; clusters
   are UTF-8 byte offsets. Direction is deliberately LTR: no paragraph bidi
   or VT width inference. The host splits font/script runs and maps cells.
   On any failure *length=0, and output must be ignored. No borrowed HB data
   survives this function. Zero glyph IDs report missing glyphs to the host. */
int lt_shape_run(const LtShapeFont *, const uint8_t *, size_t,
                 int32_t scale_26_6, const LtShapeFeature *, size_t,
                 LtShapeGlyph *, size_t capacity, size_t *length);
const char *lt_shape_version(void);
#ifdef __cplusplus
}
#endif
#endif
