/*
 * IDGlass.c - the dock's liquid glass, rendered on the CPU from the desktop picture.
 *
 * The rim of the glass is a convex squircle; vertical rays through it bend by Snell's law
 * (air to glass, n = 1.5), so the backdrop under the rim is pulled in from further inside.
 * A rim light from the upper left and a faint opposite reflection follow the surface normal.
 * The idea and the surface profile follow kube.io's "Liquid Glass in the Browser".
 *
 * Copyright (c) 2026 The pd-instadock authors
 *
 * SPDX-License-Identifier: MPL-2.0 OR BSD-2-Clause
 */

#include "IDGlass.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define LUT_SIZE 256

// displacement across the rim, 0 at the outer edge to 1 where the flat top begins, peak 1
static float displacement[LUT_SIZE];
static int displacementReady;

static double squircle(double x)
{
    if (x <= 0)
        return 0;
    if (x >= 1)
        return 1;
    return pow(1 - pow(1 - x, 4), 0.25);
}

static void buildDisplacement(void)
{
    const double n = 1.5, e = 1e-3;
    float peak = 0;

    for (int i = 0; i < LUT_SIZE; i++) {
        double x = (i + 0.5) / LUT_SIZE;
        double slope = (squircle(x + e) - squircle(x - e)) / (2 * e);
        double incident = atan(slope);
        double refracted = asin(sin(incident) / n);

        displacement[i] = (float)tan(incident - refracted);
        if (displacement[i] > peak)
            peak = displacement[i];
    }
    for (int i = 0; i < LUT_SIZE; i++)
        displacement[i] /= peak;
    displacementReady = 1;
}

static void boxPass(uint8_t *line, int count, int step, int radius, uint8_t *tmp)
{
    int sum[4] = { 0 }, window = 2 * radius + 1;

    for (int i = 0; i < count; i++)
        memcpy(tmp + 4 * i, line + (size_t)i * step, 4);
    for (int k = -radius; k <= radius; k++) {
        int j = k < 0 ? 0 : (k >= count ? count - 1 : k);

        for (int c = 0; c < 4; c++)
            sum[c] += tmp[4 * j + c];
    }
    for (int i = 0; i < count; i++) {
        int out = i - radius < 0 ? 0 : i - radius, in = i + radius + 1 >= count ? count - 1 : i + radius + 1;

        for (int c = 0; c < 4; c++) {
            line[(size_t)i * step + c] = (uint8_t)(sum[c] / window);
            sum[c] += tmp[4 * in + c] - tmp[4 * out + c];
        }
    }
}

void IDBlur(IDPixels *img, int radius)
{
    int longest = img->w > img->h ? img->w : img->h;
    uint8_t *tmp;

    if (radius < 1 || img->w < 2 || img->h < 2)
        return;
    tmp = malloc((size_t)longest * 4);
    for (int pass = 0; pass < 3; pass++) {
        for (int y = 0; y < img->h; y++)
            boxPass(img->px + (size_t)y * img->stride, img->w, 4, radius, tmp);
        for (int x = 0; x < img->w; x++)
            boxPass(img->px + (size_t)x * 4, img->h, img->stride, radius, tmp);
    }
    free(tmp);
}

// one premultiplied sample of the backdrop, bilinear, clamped to its edges
static void sample(const IDPixels *b, float x, float y, float out[4])
{
    int x0, y0, x1, y1;
    float fx, fy;
    const uint8_t *p00, *p10, *p01, *p11;

    if (x < 0)
        x = 0;
    if (y < 0)
        y = 0;
    if (x > b->w - 1)
        x = (float)(b->w - 1);
    if (y > b->h - 1)
        y = (float)(b->h - 1);
    x0 = (int)x;
    y0 = (int)y;
    x1 = x0 + 1 < b->w ? x0 + 1 : x0;
    y1 = y0 + 1 < b->h ? y0 + 1 : y0;
    fx = x - x0;
    fy = y - y0;
    p00 = b->px + (size_t)y0 * b->stride + 4 * x0;
    p10 = b->px + (size_t)y0 * b->stride + 4 * x1;
    p01 = b->px + (size_t)y1 * b->stride + 4 * x0;
    p11 = b->px + (size_t)y1 * b->stride + 4 * x1;
    for (int c = 0; c < 4; c++) {
        float top = p00[c] + (p10[c] - p00[c]) * fx;
        float bottom = p01[c] + (p11[c] - p01[c]) * fx;

        out[c] = top + (bottom - top) * fy;
    }
}

static inline float clampf(float v, float lo, float hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

// one pixel of the base, the nearest one, clamped to its edges
static inline const uint8_t *texelAt(const IDPixels *b, float x, float y)
{
    int ix = (int)x, iy = (int)y;

    ix = ix < 0 ? 0 : (ix >= b->w ? b->w - 1 : ix);
    iy = iy < 0 ? 0 : (iy >= b->h ? b->h - 1 : iy);
    return b->px + (size_t)iy * b->stride + 4 * ix;
}

void IDGlassBase(IDPixels *base, const IDPixels *backdrop, float scale, const IDGlassShape *s)
{
    const float tint[3] = { s->tintR * 255, s->tintG * 255, s->tintB * 255 };
    float cy = s->y + s->h / 2, by = s->h / 2;

    for (int y = 0; y < base->h; y++) {
        uint8_t *row = base->px + (size_t)y * base->stride;
        float py = y + 0.5f;
        float sheen = 0.05f * clampf((cy - py) / by, 0, 1) * s->specular;

        for (int x = 0; x < base->w; x++) {
            float c[4], luma;

            sample(backdrop, (x + 0.5f) * scale - 0.5f, py * scale - 0.5f, c);
            luma = 0.299f * c[0] + 0.587f * c[1] + 0.114f * c[2];
            for (int k = 0; k < 3; k++) {
                float v = luma + (c[k] - luma) * s->saturation;

                v += (tint[k] - v) * s->tint;
                v += (255 - v) * sheen;
                row[4 * x + k] = (uint8_t)clampf(v, 0, 255);
            }
            row[4 * x + 3] = 255;
        }
    }
}

// signed distance to a rounded rectangle, negative inside
static inline float roundedDistance(float px, float py, float cx, float cy, float bx, float by, float r)
{
    float qx = fabsf(px - cx) - (bx - r), qy = fabsf(py - cy) - (by - r);
    float ox = fmaxf(qx, 0), oy = fmaxf(qy, 0);

    return sqrtf(ox * ox + oy * oy) + fminf(fmaxf(qx, qy), 0) - r;
}

// the bright line just inside the edge, a quick stand-in for 0.35 * exp(-depth / 0.9)
static inline float hairline(float depth)
{
    float k = 1 - depth * (1.0f / 3.2f);

    return k > 0 ? 0.35f * k * k * k * k : 0;
}

// half the width of a rounded rectangle at a vertical distance dy from its centre, -1 above or below it
static inline float halfWidthAt(float dy, float bx, float by, float r)
{
    if (dy > by)
        return -1;
    if (dy <= by - r)
        return bx;
    dy -= by - r;
    return bx - r + sqrtf(fmaxf(r * r - dy * dy, 0));
}

void IDGlassRender(IDPixels *dst, const IDPixels *base, const IDGlassShape *s)
{
    float cx = s->x + s->w / 2, cy = s->y + s->h / 2;
    float bx = s->w / 2, by = s->h / 2;
    float r = fminf(s->radius, fminf(bx, by));
    float bezel = fmaxf(s->bezel, 1);
    // the normal is taken from a rounder shape, so it turns smoothly through the corners
    float rn = fmaxf(r, fminf(bezel + 2, fminf(bx, by)));
    // the flat top, where the glass only shows the base
    float inset = bezel + 1.5f, ibx = bx - inset, iby = by - inset, ir = fmaxf(r - inset, 0);
    // light from the upper left, y grows downwards
    const float lx = -0.5f, ly = -0.866f;
    float reach = s->shadow > 0 ? s->shadowSpread : 0;
    int x0 = (int)floorf(s->x - reach) - 1, x1 = (int)ceilf(s->x + s->w + reach) + 1;
    int y0 = (int)floorf(s->y - reach + s->shadowOffset) - 1, y1 = (int)ceilf(s->y + s->h + reach + s->shadowOffset) + 1;
    float shadowY0 = s->y + s->shadowOffset - reach, shadowY1 = s->y + s->h + s->shadowOffset + reach;

    if (!displacementReady)
        buildDisplacement();
    if (x0 < 0)
        x0 = 0;
    if (y0 < 0)
        y0 = 0;
    if (x1 > dst->w)
        x1 = dst->w;
    if (y1 > dst->h)
        y1 = dst->h;

    for (int y = y0; y < y1; y++) {
        uint8_t *row = dst->px + (size_t)y * dst->stride;
        float py = y + 0.5f, ay = fabsf(py - cy), sy = py < cy ? -1.f : 1.f;
        float qy = ay - (by - r), qny = ay - (by - rn);
        float inner = ibx > 0 && iby > 0 ? halfWidthAt(ay, ibx, iby, ir) : -1;
        int fa = inner >= 0 ? (int)ceilf(cx - inner - 0.5f) : x1, fb = inner >= 0 ? (int)floorf(cx + inner - 0.5f) : x1 - 1;
        // rows the shadow cannot reach outside the glass skip it, the base fills the flat top
        int shadowRow = s->shadow > 0 && py >= shadowY0 && py <= shadowY1;

        // the straight part of the top and bottom rim: refraction and light are the same along the row
        int band = 0;
        const uint8_t *bandRows[3] = { NULL, NULL, NULL };
        float bandLight = 0;

        if (inner < 0 && ay <= by - 0.5f && by - ay < bezel) {
            float half = fminf(bx - rn, bx - by + ay);
            float depth = by - ay, rim = clampf(depth / bezel, 0, 1);
            float shift = displacement[(int)(rim * (LUT_SIZE - 1))] * s->refraction;
            float facing = sy * ly, falloff = (1 - rim) * (1 - rim);

            if (half > 1) {
                band = 1;
                fa = (int)ceilf(cx - half - 0.5f);
                fb = (int)floorf(cx + half - 0.5f);
                bandRows[0] = texelAt(base, 0, py - sy * shift * 0.94f);
                bandRows[1] = texelAt(base, 0, py - sy * shift);
                bandRows[2] = texelAt(base, 0, py - sy * shift * 1.06f);
                bandLight = (facing > 0 ? facing * facing : 0.45f * facing * facing) * falloff * 0.9f;
                bandLight = clampf((bandLight + hairline(depth)) * s->specular, 0, 1);
            }
        }
        fa = fa < x0 ? x0 : fa;
        fb = fb >= x1 ? x1 - 1 : fb;
        for (int x = x0; x < x1; x++) {
            float px, ax, sx, qx, qnx, ox, oy, d, coverage, nx, ny, depth, rim, shift, c[3], light, shade = 0;
            uint8_t *p = row + 4 * x;

            if (x == fa && fa <= fb) {
                if (band) {
                    for (int k = fa; k <= fb; k++) {
                        uint8_t *q = row + 4 * k;

                        for (int c = 0; c < 3; c++) {
                            float v = bandRows[c][4 * k + c];

                            q[c] = (uint8_t)(v + (255 - v) * bandLight);
                        }
                        q[3] = 255;
                    }
                } else {
                    memcpy(p, texelAt(base, (float)fa, (float)y), (size_t)(fb - fa + 1) * 4);
                }
                x = fb;
                continue;
            }
            px = x + 0.5f, ax = fabsf(px - cx), sx = px < cx ? -1.f : 1.f;
            qx = ax - (bx - r), qnx = ax - (bx - rn);
            ox = fmaxf(qx, 0), oy = fmaxf(qy, 0);
            d = sqrtf(ox * ox + oy * oy) + fminf(fmaxf(qx, qy), 0) - r;
            coverage = clampf(0.5f - d, 0, 1);

            // the shadow, a soft falloff around the shape moved down, under the glass's edge
            if (shadowRow && coverage < 1) {
                float ds = roundedDistance(px, py - s->shadowOffset, cx, cy, bx, by, r);
                float k = 1 - clampf(ds / s->shadowSpread, 0, 1);

                shade = s->shadow * k * k;
            }
            if (coverage <= 0) {
                p[0] = p[1] = p[2] = 0;
                p[3] = (uint8_t)(255 * shade);
                continue;
            }
            depth = -d;
            // outward normal of the shape
            if (qnx > 0 && qny > 0) {
                float len = sqrtf(qnx * qnx + qny * qny);

                nx = sx * qnx / len;
                ny = sy * qny / len;
            } else if (qnx > qny) {
                nx = sx;
                ny = 0;
            } else {
                nx = 0;
                ny = sy;
            }
            rim = depth < bezel ? clampf(depth / bezel, 0, 1) : 1;
            shift = rim < 1 ? displacement[(int)(rim * (LUT_SIZE - 1))] * s->refraction : 0;
            // a touch of dispersion: red bends least, blue most
            c[0] = texelAt(base, px - nx * shift * 0.94f, py - ny * shift * 0.94f)[0];
            c[1] = texelAt(base, px - nx * shift, py - ny * shift)[1];
            c[2] = texelAt(base, px - nx * shift * 1.06f, py - ny * shift * 1.06f)[2];

            // the rim light, strongest where the surface faces the light, and a hairline at the edge
            {
                float facing = nx * lx + ny * ly;
                float falloff = (1 - rim) * (1 - rim);

                light = (facing > 0 ? facing * facing : 0.45f * facing * facing) * falloff * 0.9f;
                light += hairline(depth);
                light *= s->specular;
            }
            {
                float a = 255 * coverage;

                for (int k = 0; k < 3; k++) {
                    float v = c[k] + (255 - c[k]) * clampf(light, 0, 1);

                    p[k] = (uint8_t)clampf(v * coverage, 0, a);
                }
                p[3] = (uint8_t)clampf(a + 255 * shade * (1 - coverage), 0, 255);
            }
        }
    }
}

IDPixels IDHalve(const IDPixels *src)
{
    IDPixels half = { src->w / 2, src->h / 2, (src->w / 2) * 4, NULL };

    half.px = malloc((size_t)half.stride * (half.h > 0 ? half.h : 1));
    for (int y = 0; y < half.h; y++) {
        const uint8_t *a = src->px + (size_t)(2 * y) * src->stride, *b = a + src->stride;
        uint8_t *out = half.px + (size_t)y * half.stride;

        for (int x = 0; x < half.w; x++) {
            for (int c = 0; c < 4; c++)
                out[4 * x + c] = (uint8_t)((a[8 * x + c] + a[8 * x + 4 + c] + b[8 * x + c] + b[8 * x + 4 + c] + 2) / 4);
        }
    }
    return half;
}

// a premultiplied texel, transparent outside the image
static inline void texel(const IDPixels *img, int x, int y, float w, float out[4])
{
    const uint8_t *p;

    if (x < 0 || y < 0 || x >= img->w || y >= img->h)
        return;
    p = img->px + (size_t)y * img->stride + 4 * x;
    out[0] += p[0] * w;
    out[1] += p[1] * w;
    out[2] += p[2] * w;
    out[3] += p[3] * w;
}

void IDBlitIcon(IDPixels *dst, const IDPixels *levels, int count, float x, float y, float size, float alpha)
{
    const IDPixels *img = &levels[0];
    int x0, x1, y0, y1;
    float step;

    if (size < 1 || count < 1)
        return;
    for (int i = count - 1; i >= 0; i--) {
        if (levels[i].w >= size) {
            img = &levels[i];
            break;
        }
    }
    step = img->w / size;
    x0 = (int)floorf(x), x1 = (int)ceilf(x + size);
    y0 = (int)floorf(y), y1 = (int)ceilf(y + size);
    if (x0 < 0)
        x0 = 0;
    if (y0 < 0)
        y0 = 0;
    if (x1 > dst->w)
        x1 = dst->w;
    if (y1 > dst->h)
        y1 = dst->h;
    for (int py = y0; py < y1; py++) {
        uint8_t *row = dst->px + (size_t)py * dst->stride;
        float v = (py + 0.5f - y) * step - 0.5f;
        int ty = (int)floorf(v);
        float fy = v - ty;

        for (int px = x0; px < x1; px++) {
            float u = (px + 0.5f - x) * step - 0.5f;
            int tx = (int)floorf(u);
            float fx = u - tx, c[4] = { 0, 0, 0, 0 }, a;
            uint8_t *p = row + 4 * px;

            texel(img, tx, ty, (1 - fx) * (1 - fy), c);
            texel(img, tx + 1, ty, fx * (1 - fy), c);
            texel(img, tx, ty + 1, (1 - fx) * fy, c);
            texel(img, tx + 1, ty + 1, fx * fy, c);
            if (c[3] <= 0.5f)
                continue;
            a = c[3] * alpha / 255;
            for (int k = 0; k < 4; k++)
                p[k] = (uint8_t)clampf(c[k] * alpha + p[k] * (1 - a), 0, 255);
        }
    }
}

void IDBlitPixels(IDPixels *dst, const IDPixels *src, int x, int y)
{
    for (int sy = 0; sy < src->h; sy++) {
        const uint8_t *in;
        uint8_t *out;
        int dy = y + sy;

        if (dy < 0 || dy >= dst->h)
            continue;
        in = src->px + (size_t)sy * src->stride;
        out = dst->px + (size_t)dy * dst->stride;
        for (int sx = 0; sx < src->w; sx++) {
            int dx = x + sx, a = in[4 * sx + 3];

            if (dx < 0 || dx >= dst->w || a == 0)
                continue;
            for (int k = 0; k < 4; k++)
                out[4 * dx + k] = (uint8_t)(in[4 * sx + k] + out[4 * dx + k] * (255 - a) / 255);
        }
    }
}

void IDPutUnder(IDPixels *dst, const IDPixels *under, int x0, int y0, int x1, int y1)
{
    for (int y = y0; y < y1; y++) {
        uint8_t *out = dst->px + (size_t)y * dst->stride;
        const uint8_t *in = under->px + (size_t)y * under->stride;

        for (int x = x0; x < x1; x++) {
            int a = out[4 * x + 3];

            if (a == 0) {
                memcpy(out + 4 * x, in + 4 * x, 4);
            } else if (a < 255) {
                for (int k = 0; k < 3; k++)
                    out[4 * x + k] = (uint8_t)(out[4 * x + k] + in[4 * x + k] * (255 - a) / 255);
                out[4 * x + 3] = 255;
            }
        }
    }
}
