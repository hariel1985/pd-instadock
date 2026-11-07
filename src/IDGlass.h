/*
 * IDGlass.h - the dock's liquid glass, rendered on the CPU from the desktop picture.
 *
 * Copyright (c) 2026 The pd-instadock authors
 *
 * SPDX-License-Identifier: MPL-2.0 OR BSD-2-Clause
 */

#ifndef IDGLASS_H
#define IDGLASS_H

#include <stdint.h>

// premultiplied RGBA, 8 bits a sample, rows top to bottom
typedef struct {
    int w, h, stride;
    uint8_t *px;
} IDPixels;

typedef struct {
    float x, y, w, h, radius; // the glass shape, pixels in the target, y down
    float bezel;              // width of the curved rim in pixels
    float refraction;         // largest displacement in pixels at the rim
    float specular;           // 0..1, strength of the rim light
    float tint;               // 0..1, how much of the tint colour covers the backdrop
    float tintR, tintG, tintB;
    float saturation;         // 1 keeps the backdrop's colours
    float shadow;             // 0..1, darkness of the soft shadow under the glass
    float shadowSpread;       // how far the shadow reaches, pixels
    float shadowOffset;       // how far it falls downwards, pixels
} IDGlassShape;

// blurs a backdrop in place with three box passes of this radius, roughly a gaussian
void IDBlur(IDPixels *img, int radius);

// the glass's flat look over the whole of dst's area, computed once: the backdrop (what lies behind dst,
// backdrop pixel = dst pixel * backdropScale) saturated and tinted, with a sheen over the shape's upper half
void IDGlassBase(IDPixels *base, const IDPixels *backdrop, float backdropScale, const IDGlassShape *shape);

// draws the glass and its shadow into dst from a base of dst's size: the flat top copies it, the rim
// refracts it and catches the light
void IDGlassRender(IDPixels *dst, const IDPixels *base, const IDGlassShape *shape);

// halves an image with a 2x2 box filter, into a new buffer
IDPixels IDHalve(const IDPixels *src);

// composites an icon into dst at (x, y) top left, size pixels square, scaled from the smallest of its
// levels (largest first) that is still at least that big; alpha fades it
void IDBlitIcon(IDPixels *dst, const IDPixels *levels, int count, float x, float y, float size, float alpha);

// composites src into dst unscaled, its top left at (x, y)
void IDBlitPixels(IDPixels *dst, const IDPixels *src, int x, int y);

#endif
