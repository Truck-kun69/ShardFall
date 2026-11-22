#!/usr/bin/env python3
"""Generate the procedural (CC0, $0) tileable terrain texture set.

Writes 1024x1024 seamless albedo + normal maps into godot/textures/terrain/.
Deterministic: same seed -> byte-identical PNGs. Re-run only to regenerate.
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "godot", "textures", "terrain")
SIZE = 1024


def tile_noise(rng, size, beta, lo_cut=0.0):
    """Seamless fractal noise by spectral synthesis (periodic by construction)."""
    white = rng.standard_normal((size, size))
    f = np.fft.fft2(white)
    fx = np.fft.fftfreq(size)[:, None]
    fy = np.fft.fftfreq(size)[None, :]
    r = np.sqrt(fx * fx + fy * fy)
    r[0, 0] = 1.0
    amp = 1.0 / np.power(r, beta)
    if lo_cut > 0:
        amp *= 1.0 - np.exp(-(r / lo_cut) ** 2)
    amp[0, 0] = 0.0
    n = np.real(np.fft.ifft2(f * amp))
    n -= n.min()
    n /= max(n.max(), 1e-9)
    return n


def cells(rng, size, count):
    """Seamless Worley-ish cell pattern (pebbles/cracks)."""
    pts = rng.random((count, 2)) * size
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    best = np.full((size, size), 1e9, dtype=np.float32)
    second = np.full((size, size), 1e9, dtype=np.float32)
    for px, py in pts:
        dx = np.abs(xx - px)
        dx = np.minimum(dx, size - dx)
        dy = np.abs(yy - py)
        dy = np.minimum(dy, size - dy)
        d = np.sqrt(dx * dx + dy * dy)
        m = d < best
        second = np.where(m, best, np.minimum(second, d))
        best = np.where(m, d, best)
    return best, second


def colorize(h, stops):
    """Map 0..1 height through colour stops [(t, (r,g,b)), ...]."""
    out = np.zeros(h.shape + (3,), dtype=np.float32)
    ts = [s[0] for s in stops]
    for c in range(3):
        out[..., c] = np.interp(h, ts, [s[1][c] for s in stops])
    return out


def normal_from_height(h, strength):
    gx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * 0.5
    gy = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * 0.5
    nx = -gx * strength
    ny = -gy * strength
    nz = np.ones_like(h)
    ln = np.sqrt(nx * nx + ny * ny + nz * nz)
    n = np.stack([nx / ln, ny / ln, nz / ln], axis=-1)
    return (n * 0.5 + 0.5)


def save(arr, name):
    img = Image.fromarray(np.clip(arr * 255.0 + 0.5, 0, 255).astype(np.uint8), "RGB")
    img.save(os.path.join(OUT, name), optimize=True)
    print(f"  wrote textures/terrain/{name} {img.size[0]}x{img.size[1]}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seed", type=int, default=1337)
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    rng = np.random.default_rng(args.seed)
    # Moss / grass ground.
    base = tile_noise(rng, SIZE, 1.6)
    fine = tile_noise(rng, SIZE, 0.9, lo_cut=0.02)
    blades = tile_noise(rng, SIZE, 0.4, lo_cut=0.15)
    h = 0.55 * base + 0.3 * fine + 0.15 * blades
    moss = colorize(h, [(0.0, (0.16, 0.19, 0.10)), (0.45, (0.30, 0.36, 0.18)), (0.7, (0.40, 0.44, 0.24)), (1.0, (0.52, 0.50, 0.32))])
    moss *= (0.85 + 0.3 * blades)[..., None]
    save(np.clip(moss, 0, 1), "ground_moss_albedo.png")
    save(normal_from_height(h, 6.0), "ground_moss_normal.png")
    # Dirt / ash ground.
    d0 = tile_noise(rng, SIZE, 1.8)
    d1 = tile_noise(rng, SIZE, 1.0, lo_cut=0.03)
    best, second = cells(rng, 256, 70)
    peb = np.kron(np.clip((second - best) / 8.0, 0, 1), np.ones((4, 4)))
    hd = 0.5 * d0 + 0.3 * d1 + 0.2 * peb
    dirt = colorize(hd, [(0.0, (0.18, 0.14, 0.11)), (0.5, (0.34, 0.27, 0.20)), (1.0, (0.50, 0.42, 0.33))])
    save(np.clip(dirt, 0, 1), "ground_dirt_albedo.png")
    # Rock.
    r0 = tile_noise(rng, SIZE, 2.0)
    r1 = tile_noise(rng, SIZE, 1.1, lo_cut=0.02)
    best2, second2 = cells(rng, 256, 40)
    cracks = np.kron(np.clip((second2 - best2) / 5.0, 0, 1), np.ones((4, 4)))
    hr = 0.45 * r0 + 0.3 * r1 + 0.25 * cracks
    rock = colorize(hr, [(0.0, (0.20, 0.19, 0.18)), (0.5, (0.42, 0.40, 0.37)), (1.0, (0.62, 0.60, 0.56))])
    save(np.clip(rock, 0, 1), "ground_rock_albedo.png")
    save(normal_from_height(hr, 10.0), "ground_rock_normal.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
