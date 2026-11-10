# Copyright (C) 2025-2026 Ari Jaaksi. All rights reserved.
# Licensed under GPLv3 or a commercial license.
# See LICENSE.txt for details or contact [ari@slowlight.art] for commercial licensing.

import numpy as np, sys, os
from PIL import Image
from scipy import ndimage
import skimage.data as skd

rng = np.random.default_rng(1)
OUT = sys.argv[1]

def srgb2lin(v):
    v = v.astype(np.float64) / 255.0
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)

def resize(img, w, h):
    return np.asarray(Image.fromarray(img).resize((w, h), Image.LANCZOS))

GAMMA = np.array([0.50, 0.60, 0.68])
BASE = np.array([0.25, 0.60, 0.95])
F = np.array([[0.80, 0.15, 0.05], [0.10, 0.80, 0.10], [0.03, 0.17, 0.80]])
A = np.array([[1.0, 0.08, 0.03], [0.10, 1.0, 0.08], [0.04, 0.15, 1.0]])
ETOE = 0.004
LIGHT = 0.85

def film_color(lin, exposure=1.0):
    e = np.clip(lin @ F.T, 0, None) * exposure
    d = GAMMA * np.log10(1 + e / ETOE)
    dens = BASE + d @ A.T
    return LIGHT * 10 ** (-dens)

def film_bw(lin, exposure=1.0):
    y = (lin @ np.array([0.25, 0.60, 0.15])) * exposure
    d = 0.62 * np.log10(1 + y / ETOE) + 0.28
    t = LIGHT * 10 ** (-d)
    return t[..., None] * np.array([1.0, 0.97, 0.93])

def base_t(kind):
    if kind == 'bw':
        return LIGHT * 10 ** (-0.28) * np.array([1.0, 0.97, 0.93])
    return LIGHT * 10 ** (-BASE)

def holder(h, w):
    # near-black with a little flare
    return np.full((h, w, 3), 0.0012)

def compose(neg, kind, layout):
    fh, fw = neg.shape[:2]
    b = base_t(kind)
    light = np.full(3, LIGHT)
    if layout == 'tight':
        canvas = neg.copy()
    elif layout == 'holder':
        rb = int(0.02 * fw)
        H, W = int(fh * 1.22), int(fw * 1.16)
        canvas = holder(H, W)
        y0, x0 = (H - fh) // 2, (W - fw) // 2 + 10
        canvas[y0 - rb:y0 + fh + rb, x0 - rb:x0 + fw + rb] = b
        canvas[y0:y0 + fh, x0:x0 + fw] = neg
    elif layout == 'sides':
        H, W = fh, int(fw * 1.5)
        canvas = holder(H, W)
        x0 = (W - fw) // 2
        canvas[:, x0:x0 + fw] = neg
    elif layout == 'sprocket':
        strip = int(fh * 0.23)
        gap = int(fw * 0.04)
        H, W = fh + 2 * strip + int(0.08 * fh), fw + 2 * gap
        canvas = holder(H, W)
        ys = (H - fh - 2 * strip) // 2
        canvas[ys:ys + fh + 2 * strip, :] = b
        canvas[ys + strip:ys + strip + fh, gap:gap + fw] = neg
        hole_w, hole_h, pitch = int(fw * 0.055), int(strip * 0.55), fw / 8.0
        for k in range(-1, 10):
            cx = int(gap + k * pitch + pitch * 0.3)
            for yy in (ys + int(strip * 0.2), ys + fh + strip + int(strip * 0.25)):
                canvas[yy:yy + hole_h, max(cx, 0):max(cx + hole_w, 0)] = light
    else:
        raise ValueError(layout)
    # optics: slight blur, vignetting, veiling flare, noise
    canvas = ndimage.gaussian_filter(canvas, sigma=(1.0, 1.0, 0))
    H, W = canvas.shape[:2]
    yy, xx = np.mgrid[0:H, 0:W]
    r2 = ((xx - W / 2) / (W / 2)) ** 2 + ((yy - H / 2) / (H / 2)) ** 2
    canvas = canvas * (1 - 0.06 * r2)[..., None]
    canvas = canvas + 0.0015 * canvas.mean(axis=(0, 1))
    noise = rng.normal(size=canvas.shape) * np.sqrt(np.abs(canvas) * 4e-6 + 4e-9)
    return canvas + noise

def save(name, arr):
    H, W = arr.shape[:2]
    rgba = np.concatenate([arr, np.ones((H, W, 1))], axis=2).astype(np.float16)
    with open(os.path.join(OUT, name + '.half'), 'wb') as f:
        f.write(np.array([W, H], dtype=np.int32).tobytes())
        f.write(rgba.tobytes())

def ref(name, img):
    Image.fromarray(img).save(os.path.join(OUT, name + '.ref.png'))


photos = {
    'astronaut': resize(skd.astronaut(), 900, 900),
    'coffee': resize(skd.coffee(), 1080, 720),
    'cat': resize(skd.chelsea(), 1080, 720),
    'rocket': resize(skd.rocket(), 1080, 720),
}
EXP = 0.30   # mid-grey lands about 0.7 density units above clear film, as at box speed
def enc(v): return (255*np.clip(np.where(v<=0.0031308,v*12.92,1.055*np.clip(v,0,None)**(1/2.4)-0.055),0,1)).astype(np.uint8)
def backlit(img):
    """Correctly exposed subject in front of a background four to five stops brighter."""
    lin = srgb2lin(img)
    h, w = lin.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w]
    lum = lin.mean(axis=2)
    # the light studio backdrop of the astronaut photo becomes a blazing window
    mask = ndimage.gaussian_filter(((lum > 0.45) & (yy < h*0.55)).astype(float), 3)
    window = (4.0 + 3.0 * np.sin(xx/37.0)*np.sin(yy/29.0))[..., None] * np.array([1.0, 1.0, 1.05])
    return lin*(1-mask[...,None]) + window*mask[...,None]
frames = [
    ('r1_backlit_holder', backlit(photos['astronaut']), 'color', 'holder'),
    ('r2_backlit_tight', backlit(photos['astronaut']), 'color', 'tight'),
    ('r3_coffee_tight', srgb2lin(photos['coffee']), 'color', 'tight'),
    ('r4_cat_holder', srgb2lin(photos['cat']), 'color', 'holder'),
    ('r5_rocket_tight', srgb2lin(photos['rocket']), 'color', 'tight'),
    ('b1_backlit_tight', backlit(photos['astronaut']), 'bw', 'tight'),
    ('b2_cat_holder', srgb2lin(photos['cat']), 'bw', 'holder'),
    ('b3_rocket_tight', srgb2lin(photos['rocket']), 'bw', 'tight'),
]
for name, lin, kind, layout in frames:
    neg = film_color(lin, EXP) if kind == 'color' else film_bw(lin, EXP)
    save(name, compose(neg, kind, layout))
    ref(name, enc(lin))
print('roll done')
