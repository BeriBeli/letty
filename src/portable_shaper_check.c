#include "portable_shaper.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks;
#define CHECK(x, name) do { if (!(x)) { fprintf(stderr, "FAIL: %s\n", name); exit(1); } checks++; printf("PASS: %s\n", name); } while (0)
static LtShapeFont *load(const char *path) {
    FILE *file = fopen(path, "rb");
    if (!file || fseek(file, 0, SEEK_END)) return NULL;
    long len = ftell(file);
    if (len <= 0 || len > LT_SHAPE_MAX_FONT_BYTES || fseek(file, 0, SEEK_SET)) { fclose(file); return NULL; }
    uint8_t *bytes = malloc((size_t)len);
    if (!bytes || fread(bytes, 1, (size_t)len, file) != (size_t)len) { free(bytes); fclose(file); return NULL; }
    fclose(file);
    LtShapeFont *font = lt_shape_font_new(bytes, (size_t)len, 0);
    free(bytes); /* Shape only after original bytes have been released. */
    return font;
}

int main(void) {
    LtShapeGlyph glyphs[LT_SHAPE_MAX_GLYPHS];
    size_t len = 0;
    LtShapeFont *latin = load("vendor/harfbuzz/test/api/fonts/OpenSans-Regular.ttf");
    CHECK(latin && lt_shape_font_upem(latin) > 0, "owned font bytes survive caller release");
    int rc = lt_shape_run(latin, (const uint8_t *)"e\xcc\x81", 3, 16 * 64, NULL, 0, glyphs, LT_SHAPE_MAX_GLYPHS, &len);
    CHECK(rc == 0 && len == 1 && glyphs[0].glyph && glyphs[0].cluster == 0, "combining accent forms one real glyph cluster");
    CHECK(!lt_shape_font_has_glyph(latin, 0x4e2d), "missing CJK glyph is reported for fallback");
    rc = lt_shape_run(latin, (const uint8_t *)"\xe4\xb8\xad", 3, 16 * 64, NULL, 0, glyphs, LT_SHAPE_MAX_GLYPHS, &len);
    CHECK(rc == 0 && len == 1 && glyphs[0].glyph == 0, "missing glyph remains explicit notdef");
    rc = lt_shape_run(latin, (const uint8_t *)"\xc0\x80", 2, 16 * 64, NULL, 0, glyphs, LT_SHAPE_MAX_GLYPHS, &len);
    CHECK(rc == LT_SHAPE_INVALID && len == 0, "overlong UTF8 rejected without partial output");
    uint8_t excessive[LT_SHAPE_MAX_CODEPOINTS + 1]; memset(excessive, 'a', sizeof(excessive));
    rc = lt_shape_run(latin, excessive, sizeof(excessive), 16 * 64, NULL, 0, glyphs, LT_SHAPE_MAX_GLYPHS, &len);
    CHECK(rc == LT_SHAPE_LIMIT && len == 0, "codepoint budget rejected before shaping");
    rc = lt_shape_run(latin, (const uint8_t *)"a", 1, 16 * 64, NULL, 0, glyphs, 0, &len);
    CHECK(rc == LT_SHAPE_LIMIT && len == 0, "insufficient output has no partial result");
    lt_shape_font_free(latin);

    LtShapeFont *fi = load("vendor/harfbuzz/test/api/fonts/Roboto-Regular.gsub.fi.ttf");
    CHECK(fi != NULL, "GSUB fixture font loads");
    LtShapeFeature setting = {{'l','i','g','a'}, 1};
    rc = lt_shape_run(fi, (const uint8_t *)"fi", 2, 16 * 64, &setting, 1, glyphs, LT_SHAPE_MAX_GLYPHS, &len);
    CHECK(rc == 0 && len == 1 && glyphs[0].glyph && glyphs[0].cluster == 0, "OpenType liga on produces actual fi ligature");
    setting.value = 0;
    rc = lt_shape_run(fi, (const uint8_t *)"fi", 2, 16 * 64, &setting, 1, glyphs, LT_SHAPE_MAX_GLYPHS, &len);
    CHECK(rc == 0 && len == 2 && glyphs[0].glyph && glyphs[1].glyph && glyphs[1].cluster == 1, "OpenType liga off restores two byte clusters");
    lt_shape_font_free(fi);

    LtShapeFont *cjk = load("vendor/harfbuzz/test/api/fonts/Mplus1p-Regular.660E,6975,73E0,5EA6,8F38,6E05.ttf");
    rc = lt_shape_run(cjk, (const uint8_t *)"\xe6\x98\x8e", 3, 16 * 64, NULL, 0, glyphs, LT_SHAPE_MAX_GLYPHS, &len);
    CHECK(cjk && rc == 0 && len == 1 && glyphs[0].glyph && glyphs[0].cluster == 0, "CJK fixture supplies real Ming ideograph glyph");
    lt_shape_font_free(cjk);

    LtShapeFont *emoji = load("vendor/harfbuzz/test/shape/data/in-house/fonts/3cf6f8ac6d647473a43a3100e7494b202b2cfafe.ttf");
    const uint8_t sequence[] = "\xf0\x9f\x92\x81\xf0\x9f\x8f\xbb\xe2\x80\x8d\xe2\x99\x82\xef\xb8\x8f";
    rc = lt_shape_run(emoji, sequence, sizeof(sequence) - 1, 16 * 64, NULL, 0, glyphs, LT_SHAPE_MAX_GLYPHS, &len);
    CHECK(emoji && rc == 0 && len == 1 && glyphs[0].glyph == 7 && glyphs[0].cluster == 0, "ZWJ skin tone variation sequence forms real emoji glyph");
    lt_shape_font_free(emoji);
    const uint8_t bad[] = {0, 1, 2, 3};
    CHECK(!lt_shape_font_new(bad, sizeof(bad), 0), "invalid font data rejected");
    LtShapeFont *invalid = (LtShapeFont *)(uintptr_t)1;
    CHECK(lt_shape_font_create(bad, sizeof(bad), 0, &invalid) == LT_SHAPE_INVALID && invalid == NULL,
          "status constructor clears output and identifies invalid font");
    invalid = (LtShapeFont *)(uintptr_t)1;
    CHECK(lt_shape_font_create(bad, LT_SHAPE_MAX_FONT_BYTES + (size_t)1, 0, &invalid) == LT_SHAPE_LIMIT && invalid == NULL,
          "status constructor rejects font payload budget before reading bytes");
    CHECK(lt_shape_font_create(bad, sizeof(bad), 0, NULL) == LT_SHAPE_INVALID,
          "status constructor rejects missing result storage");
    printf("{\"suite\":\"portable-shaper\",\"version\":\"%s\",\"checks\":%u,\"status\":\"pass\",\"scope\":\"glyph shaping only; color rasterization not asserted\"}\n", lt_shape_version(), checks);
    return 0;
}
