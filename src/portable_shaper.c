#include "portable_shaper.h"
#include "hb.h"
#include "hb-ot.h"
#include <stdlib.h>

struct LtShapeFont { hb_font_t *font; unsigned upem; };

/* HB_CUSTOM_MALLOC routes HB's allocations through these four functions.
   The per-thread failure epoch distinguishes real heap exhaustion (including
   a failed lazy table allocation HB converts to an empty result) from its
   operation/output limits. This is diagnostics, not a total-memory quota. */
static _Thread_local uint64_t allocation_failures;
void *hb_malloc_impl(size_t size) {
    void *p = malloc(size);
    if (!p && size) allocation_failures++;
    return p;
}
void *hb_calloc_impl(size_t count, size_t size) {
    void *p = calloc(count, size);
    if (!p && count && size) allocation_failures++;
    return p;
}
void *hb_realloc_impl(void *old, size_t size) {
    void *p = realloc(old, size);
    if (!p && size) allocation_failures++;
    return p;
}
void hb_free_impl(void *p) { free(p); }
static int allocation_status(uint64_t before, int status) {
    return allocation_failures != before ? LT_SHAPE_ALLOC : status;
}

static int valid_utf8(const uint8_t *p, size_t len) {
    size_t i = 0, count = 0;
    while (i < len) {
        uint32_t cp = p[i++];
        unsigned n = 0;
        uint32_t minimum = 0;
        if (cp < 0x80) {}
        else if (cp >= 0xc2 && cp <= 0xdf) { cp &= 0x1f; n = 1; minimum = 0x80; }
        else if (cp >= 0xe0 && cp <= 0xef) { cp &= 0x0f; n = 2; minimum = 0x800; }
        else if (cp >= 0xf0 && cp <= 0xf4) { cp &= 7; n = 3; minimum = 0x10000; }
        else return LT_SHAPE_INVALID;
        if (n > len - i) return LT_SHAPE_INVALID;
        while (n--) {
            if ((p[i] & 0xc0) != 0x80) return LT_SHAPE_INVALID;
            cp = (cp << 6) | (p[i++] & 0x3f);
        }
        if (cp < minimum || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return LT_SHAPE_INVALID;
        if (++count > LT_SHAPE_MAX_CODEPOINTS) return LT_SHAPE_LIMIT;
    }
    return LT_SHAPE_OK;
}

int lt_shape_font_create(const uint8_t *data, size_t len, uint32_t index, LtShapeFont **result) {
    if (!result) return LT_SHAPE_INVALID;
    *result = NULL;
    if (!data || !len) return LT_SHAPE_INVALID;
    if (len > LT_SHAPE_MAX_FONT_BYTES) return LT_SHAPE_LIMIT;
    const uint64_t before = allocation_failures;
    hb_blob_t *blob = hb_blob_create_or_fail((const char *)data, (unsigned)len, HB_MEMORY_MODE_DUPLICATE, NULL, NULL);
    if (!blob) return LT_SHAPE_ALLOC;
    if (index >= hb_face_count(blob)) { hb_blob_destroy(blob); return allocation_status(before, LT_SHAPE_INVALID); }
    hb_face_t *face = hb_face_create(blob, index);
    hb_blob_destroy(blob);
    if (face == hb_face_get_empty()) { hb_face_destroy(face); return LT_SHAPE_ALLOC; }
    unsigned upem = hb_face_get_upem(face);
    if (!hb_face_get_glyph_count(face) || !upem) { hb_face_destroy(face); return allocation_status(before, LT_SHAPE_INVALID); }
    hb_font_t *font = hb_font_create(face);
    hb_face_destroy(face);
    if (font == hb_font_get_empty()) { hb_font_destroy(font); return LT_SHAPE_ALLOC; }
    hb_ot_font_set_funcs(font);
    hb_font_make_immutable(font);
    LtShapeFont *out = malloc(sizeof(*out));
    if (!out) { hb_font_destroy(font); return LT_SHAPE_ALLOC; }
    if (allocation_failures != before) { hb_font_destroy(font); free(out); return LT_SHAPE_ALLOC; }
    out->font = font; out->upem = upem;
    *result = out;
    return LT_SHAPE_OK;
}

LtShapeFont *lt_shape_font_new(const uint8_t *data, size_t len, uint32_t index) {
    LtShapeFont *out = NULL;
    (void)lt_shape_font_create(data, len, index, &out);
    return out;
}

void lt_shape_font_free(LtShapeFont *font) {
    if (font) { hb_font_destroy(font->font); free(font); }
}
uint32_t lt_shape_font_upem(const LtShapeFont *font) { return font ? font->upem : 0; }
int lt_shape_font_has_glyph(const LtShapeFont *font, uint32_t cp) {
    hb_codepoint_t glyph = 0;
    return font && cp <= 0x10ffff && hb_font_get_nominal_glyph(font->font, cp, &glyph) && glyph != 0;
}

int lt_shape_run(const LtShapeFont *font, const uint8_t *text, size_t len,
                 int32_t scale, const LtShapeFeature *features, size_t feature_count,
                 LtShapeGlyph *out, size_t capacity, size_t *length) {
    if (!length) return LT_SHAPE_INVALID;
    *length = 0;
    if (!font || (!text && len) || (!features && feature_count) || (!out && capacity) || scale <= 0 || scale > 512 * 64) return LT_SHAPE_INVALID;
    if (len > LT_SHAPE_MAX_BYTES || capacity > LT_SHAPE_MAX_GLYPHS || feature_count > LT_SHAPE_MAX_FEATURES) return LT_SHAPE_LIMIT;
    int valid = valid_utf8(text, len);
    if (valid) return valid;
    if (!len) return LT_SHAPE_OK;
    hb_feature_t settings[LT_SHAPE_MAX_FEATURES];
    for (size_t i = 0; i < feature_count; i++) {
        for (unsigned b = 0; b < 4; b++) if (features[i].tag[b] < 0x20 || features[i].tag[b] > 0x7e) return LT_SHAPE_INVALID;
        settings[i].tag = HB_TAG(features[i].tag[0], features[i].tag[1], features[i].tag[2], features[i].tag[3]);
        settings[i].value = features[i].value;
        settings[i].start = HB_FEATURE_GLOBAL_START;
        settings[i].end = HB_FEATURE_GLOBAL_END;
    }
    const uint64_t before = allocation_failures;
    hb_buffer_t *buffer = hb_buffer_create();
    hb_font_t *scaled = hb_font_create_sub_font(font->font);
    int result = LT_SHAPE_FAILED;
    if (buffer == hb_buffer_get_empty() || scaled == hb_font_get_empty()) goto done;
    hb_font_set_scale(scaled, scale, scale);
    hb_buffer_set_cluster_level(buffer, HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES);
    hb_buffer_set_direction(buffer, HB_DIRECTION_LTR);
    hb_buffer_set_language(buffer, hb_language_from_string("und", -1));
    hb_buffer_set_flags(buffer, HB_BUFFER_FLAG_BOT | HB_BUFFER_FLAG_EOT);
    hb_buffer_add_utf8(buffer, (const char *)text, (int)len, 0, (int)len);
    hb_buffer_guess_segment_properties(buffer);
    if (!hb_buffer_allocation_successful(buffer)) { result = LT_SHAPE_LIMIT; goto done; }
    const char *shapers[] = {"ot", NULL};
    result = LT_SHAPE_FAILED;
    hb_bool_t shaped = hb_shape_full(scaled, buffer, settings, (unsigned)feature_count, shapers);
    if (!hb_buffer_allocation_successful(buffer)) { result = LT_SHAPE_LIMIT; goto done; }
    if (!shaped) goto done;
    unsigned count = 0, positions = 0;
    hb_glyph_info_t *info = hb_buffer_get_glyph_infos(buffer, &count);
    hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(buffer, &positions);
    result = LT_SHAPE_LIMIT;
    if (count > capacity || count > LT_SHAPE_MAX_GLYPHS) goto done;
    result = LT_SHAPE_FAILED;
    if (count != positions) goto done;
    for (unsigned i = 0; i < count; i++) {
        if (info[i].cluster >= len || (text[info[i].cluster] & 0xc0) == 0x80) goto done;
    }
    for (unsigned i = 0; i < count; i++) out[i] = (LtShapeGlyph){
        info[i].codepoint, info[i].cluster,
        pos[i].x_advance, pos[i].y_advance, pos[i].x_offset, pos[i].y_offset
    };
    *length = count;
    result = LT_SHAPE_OK;
done:
    hb_buffer_destroy(buffer);
    hb_font_destroy(scaled);
    if (allocation_failures != before) { *length = 0; result = LT_SHAPE_ALLOC; }
    return result;
}
const char *lt_shape_version(void) { return hb_version_string(); }
