// Smoke test for the packed lilliput-rs keep-set. Links only the archives in
// the release prefix and checks the encoders, sharp YUV, 10-bit PQ and decode.
// CI runs it after every build (see .github/workflows/lilliput-rs-deps.yml).
#include <avif/avif.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails = 0;
#define CHECK(cond, ...) do { if (!(cond)) { printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); fails++; } else { printf("ok:   "); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void fill(avifRGBImage *rgb) {
    // Saturated thin strokes on a gradient: the case sharp YUV exists for.
    for (uint32_t y = 0; y < rgb->height; y++) {
        for (uint32_t x = 0; x < rgb->width; x++) {
            uint32_t v[4];
            uint32_t max = (1u << rgb->depth) - 1;
            v[0] = (x * max) / rgb->width;
            v[1] = (y * max) / rgb->height;
            v[2] = max / 3;
            v[3] = max;
            if ((x / 2) % 4 == 0) { v[0] = max; v[1] = 0; v[2] = 0; }
            if ((y / 2) % 5 == 0) { v[0] = 0; v[1] = max / 2; v[2] = max / 2; }
            for (int c = 0; c < 4; c++) {
                if (rgb->depth > 8)
                    ((uint16_t *)(rgb->pixels + y * rgb->rowBytes))[x * 4 + c] = (uint16_t)v[c];
                else
                    rgb->pixels[y * rgb->rowBytes + x * 4 + c] = (uint8_t)v[c];
            }
        }
    }
}

static avifImage *make_image(uint32_t w, uint32_t h, uint32_t depth, avifPixelFormat fmt,
                             avifChromaDownsampling ds, avifResult *conv) {
    avifImage *img = avifImageCreate(w, h, depth, fmt);
    avifRGBImage rgb;
    avifRGBImageSetDefaults(&rgb, img);
    rgb.format = AVIF_RGB_FORMAT_RGBA;
    rgb.chromaDownsampling = ds;
    avifRGBImageAllocatePixels(&rgb);
    fill(&rgb);
    *conv = avifImageRGBToYUV(img, &rgb);
    avifRGBImageFreePixels(&rgb);
    return img;
}

static avifResult encode(avifImage *img, avifCodecChoice choice, int speed, int quality, avifRWData *out) {
    avifEncoder *enc = avifEncoderCreate();
    enc->codecChoice = choice;
    enc->speed = speed;
    enc->quality = quality;
    enc->qualityAlpha = quality;
    enc->maxThreads = 1;
    avifResult r = avifEncoderWrite(enc, img, out);
    if (r != AVIF_RESULT_OK)
        printf("      encoder diag: %s\n", enc->diag.error);
    avifEncoderDestroy(enc);
    return r;
}

static int decode_check(const avifRWData *d, uint32_t w, uint32_t h, uint32_t depth) {
    avifDecoder *dec = avifDecoderCreate();
    dec->codecChoice = AVIF_CODEC_CHOICE_AUTO;
    avifImage *img = avifImageCreateEmpty();
    avifResult r = avifDecoderReadMemory(dec, img, d->data, d->size);
    int ok = r == AVIF_RESULT_OK && img->width == w && img->height == h && img->depth == depth;
    avifImageDestroy(img);
    avifDecoderDestroy(dec);
    return ok;
}

int main(void) {
    char versions[256];
    avifCodecVersions(versions);
    printf("libavif %s; codecs: %s\n", avifVersion(), versions);
    CHECK(strcmp(avifVersion(), "1.4.2") == 0, "avifVersion() == 1.4.2");

    const char *svt = avifCodecName(AVIF_CODEC_CHOICE_SVT, AVIF_CODEC_FLAG_CAN_ENCODE);
    const char *aom = avifCodecName(AVIF_CODEC_CHOICE_AOM, AVIF_CODEC_FLAG_CAN_ENCODE);
    const char *autoenc = avifCodecName(AVIF_CODEC_CHOICE_AUTO, AVIF_CODEC_FLAG_CAN_ENCODE);
    const char *autodec = avifCodecName(AVIF_CODEC_CHOICE_AUTO, AVIF_CODEC_FLAG_CAN_DECODE);
    CHECK(svt && strcmp(svt, "svt") == 0, "SVT encoder available (%s)", svt ? svt : "null");
    CHECK(aom && strcmp(aom, "aom") == 0, "aom encoder available (%s)", aom ? aom : "null");
    CHECK(autoenc && strcmp(autoenc, "aom") == 0, "AUTO encoder is still aom (%s)", autoenc ? autoenc : "null");
    CHECK(autodec && strcmp(autodec, "dav1d") == 0, "AUTO decoder is still dav1d (%s)", autodec ? autodec : "null");

    const uint32_t W = 256, H = 192;
    avifResult conv;

    // Sharp YUV: 1.6.0 returns NOT_IMPLEMENTED here.
    avifImage *sharp = make_image(W, H, 8, AVIF_PIXEL_FORMAT_YUV420, AVIF_CHROMA_DOWNSAMPLING_SHARP_YUV, &conv);
    CHECK(conv == AVIF_RESULT_OK, "RGB->YUV with SHARP_YUV: %s", avifResultToString(conv));
    avifImage *plain = make_image(W, H, 8, AVIF_PIXEL_FORMAT_YUV420, AVIF_CHROMA_DOWNSAMPLING_AUTOMATIC, &conv);
    CHECK(conv == AVIF_RESULT_OK, "RGB->YUV default: %s", avifResultToString(conv));
    int differ = memcmp(sharp->yuvPlanes[0], plain->yuvPlanes[0], (size_t)sharp->yuvRowBytes[0] * H) != 0;
    CHECK(differ, "sharp YUV changes the Y plane (it is not a silent fallback)");

    avifRWData o = AVIF_DATA_EMPTY;
    avifResult r = encode(sharp, AVIF_CODEC_CHOICE_SVT, 6, 60, &o);
    CHECK(r == AVIF_RESULT_OK, "SVT p6 q60 8-bit 4:2:0 sharp: %s, %zu bytes", avifResultToString(r), o.size);
    CHECK(r == AVIF_RESULT_OK && decode_check(&o, W, H, 8), "SVT output decodes with dav1d");
    avifRWDataFree(&o);

    avifRWData a1 = AVIF_DATA_EMPTY, a2 = AVIF_DATA_EMPTY;
    r = encode(plain, AVIF_CODEC_CHOICE_AOM, 6, 60, &a1);
    CHECK(r == AVIF_RESULT_OK, "aom s6 q60 8-bit 4:2:0: %s, %zu bytes", avifResultToString(r), a1.size);
    r = encode(plain, AVIF_CODEC_CHOICE_AUTO, 6, 60, &a2);
    CHECK(r == AVIF_RESULT_OK && a1.size == a2.size && memcmp(a1.data, a2.data, a1.size) == 0,
          "AUTO encode is byte-identical to explicit aom");
    CHECK(decode_check(&a1, W, H, 8), "aom output decodes with dav1d");
    avifRWDataFree(&a1);
    avifRWDataFree(&a2);

    // 10-bit BT.2020 PQ through SVT (the WS1 HDR lossy tier).
    avifImage *pq = make_image(W, H, 10, AVIF_PIXEL_FORMAT_YUV420, AVIF_CHROMA_DOWNSAMPLING_AUTOMATIC, &conv);
    pq->colorPrimaries = AVIF_COLOR_PRIMARIES_BT2020;
    pq->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_PQ;
    pq->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT2020_NCL;
    pq->yuvRange = AVIF_RANGE_FULL;
    pq->clli.maxCLL = 1000;
    pq->clli.maxPALL = 400;
    o = (avifRWData)AVIF_DATA_EMPTY;
    r = encode(pq, AVIF_CODEC_CHOICE_SVT, 6, 60, &o);
    CHECK(r == AVIF_RESULT_OK, "SVT p6 10-bit PQ 4:2:0: %s, %zu bytes", avifResultToString(r), o.size);
    CHECK(r == AVIF_RESULT_OK && decode_check(&o, W, H, 10), "10-bit SVT output decodes as 10-bit");
    avifRWDataFree(&o);

    // Lossless 4:4:4 stays on aom; SVT 4.3 is 4:2:0 only.
    avifImage *ll = make_image(W, H, 8, AVIF_PIXEL_FORMAT_YUV444, AVIF_CHROMA_DOWNSAMPLING_AUTOMATIC, &conv);
    ll->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_IDENTITY;
    o = (avifRWData)AVIF_DATA_EMPTY;
    r = encode(ll, AVIF_CODEC_CHOICE_AOM, 6, AVIF_QUALITY_LOSSLESS, &o);
    CHECK(r == AVIF_RESULT_OK, "aom s6 lossless 4:4:4: %s, %zu bytes", avifResultToString(r), o.size);
    avifRWDataFree(&o);
    o = (avifRWData)AVIF_DATA_EMPTY;
    r = encode(ll, AVIF_CODEC_CHOICE_SVT, 6, AVIF_QUALITY_LOSSLESS, &o);
    printf("info: SVT 4:4:4 lossless -> %s (expected to fail: SVT 4.3 is 4:2:0 only)\n", avifResultToString(r));
    avifRWDataFree(&o);

    // Gain-map API is compiled in (WS1-P2).
#if AVIF_VERSION >= 1020000
    avifGainMap *gm = avifGainMapCreate();
    CHECK(gm != NULL, "avifGainMapCreate() available");
    avifGainMapDestroy(gm);
#else
    CHECK(0, "avifGainMapCreate() available (headers are libavif < 1.2)");
#endif

    avifImageDestroy(sharp);
    avifImageDestroy(plain);
    avifImageDestroy(pq);
    avifImageDestroy(ll);
    printf("%s (%d failures)\n", fails ? "FAILED" : "PASSED", fails);
    return fails ? 1 : 0;
}
