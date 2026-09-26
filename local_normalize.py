"""Deterministic frame normalizer: border flood-fill alpha extraction + cell fitting.

Turns raw generated frames into hatch-pet style cells:
aemeath-pet/work/aemeath-run/frames/<state>/NN.png  (192x208, transparent background)

Usage:
  python local_normalize.py --raw <dir> --frames-root <dir> --states idle,waving
  python local_normalize.py --selftest <image>
"""
import argparse
import json
import os
from collections import defaultdict

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

CELL_W, CELL_H = 192, 208
MARGIN_X, MARGIN_Y = 6, 8
TARGET_H = CELL_H - 2 * MARGIN_Y  # character height inside the cell


def background_mask(img, thresh=46):
    """Flood fill from the four corners over the near-uniform background colour."""
    w, h = img.size
    work = img.copy()
    marker = (255, 0, 255)
    for seed in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
        try:
            ImageDraw.floodfill(work, seed, marker, thresh=thresh)
        except Exception:
            pass
    arr = np.asarray(work)
    return np.all(arr == np.array(marker, dtype=np.uint8), axis=-1)


def background_color(img):
    arr = np.asarray(img)
    h, w, _ = arr.shape
    k = 6
    corners = np.concatenate([
        arr[:k, :k].reshape(-1, 3), arr[:k, -k:].reshape(-1, 3),
        arr[-k:, :k].reshape(-1, 3), arr[-k:, -k:].reshape(-1, 3),
    ])
    return np.median(corners, axis=0)


def largest_component(mask):
    """Keep only the biggest connected blob (drops watermarks and stray specks)."""
    h, w = mask.shape
    parent = {}

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)

    labels = np.zeros((h, w), np.int32)
    next_label = 1
    for y in range(h):
        row = mask[y]
        x = 0
        while x < w:
            if not row[x]:
                x += 1
                continue
            x0 = x
            while x < w and row[x]:
                x += 1
            x1 = x
            labs = set()
            if y > 0:
                above = labels[y - 1, x0:x1]
                labs = {int(v) for v in np.unique(above) if v > 0}
            if not labs:
                lab = next_label
                parent[lab] = lab
                next_label += 1
            else:
                lab = min(labs)
                for other in labs:
                    union(lab, other)
            labels[y, x0:x1] = lab
    if next_label == 1:
        return mask
    roots = {}
    for lab in range(1, next_label):
        r = find(lab)
        roots[r] = roots.get(r, 0) + int((labels == lab).sum())
    best = max(roots, key=roots.get)
    keep = np.isin(labels, [lab for lab in range(1, next_label) if find(lab) == best])
    return keep


def extract_alpha(img, thresh=46, keep_largest=True):
    bg = background_mask(img, thresh)

    # eat background-coloured shadows that are enclosed by the silhouette (e.g. the pool of
    # magenta under the feet): pixels whose hue matches the backdrop grow outward from the
    # already-detected background, so the sprite itself is never touched.
    bg_color = background_color(img)
    hsv = np.asarray(img.convert("HSV")).astype(np.int16)
    bg_hsv = np.asarray(Image.new("RGB", (1, 1), tuple(int(c) for c in bg_color)).convert("HSV")).astype(np.int16)[0, 0]
    hue_delta = np.abs(hsv[:, :, 0] - bg_hsv[0])
    hue_delta = np.minimum(hue_delta, 255 - hue_delta)
    hue_like = (hue_delta <= 26) & (hsv[:, :, 1] > 60)
    grow = Image.fromarray(np.where(bg, 255, 0).astype(np.uint8), "L")
    for _ in range(10):
        grown = np.asarray(grow.filter(ImageFilter.MaxFilter(5))) > 0
        new = grown & hue_like
        if not (new & ~bg).any():
            break
        bg = bg | new
        grow = Image.fromarray(np.where(bg, 255, 0).astype(np.uint8), "L")

    alpha = np.where(bg, 0, 255).astype(np.uint8)

    # anything that still matches the background colour (e.g. the gap between the legs,
    # enclosed by the silhouette so the border flood fill never reached it) is background too
    arr = np.asarray(img).astype(np.int16)
    bg_color = background_color(img).astype(np.int16)
    color_dist = np.abs(arr - bg_color).max(axis=-1)
    alpha[color_dist < max(24, thresh - 12)] = 0

    # close small gaps, then drop speckles
    a_img = Image.fromarray(alpha, "L")
    a_img = a_img.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.MinFilter(3))
    a_img = a_img.filter(ImageFilter.MedianFilter(3))

    # fill interior holes: any transparent region still connected to the border is real background
    inv = Image.fromarray(np.where(np.asarray(a_img) > 127, 0, 255).astype(np.uint8), "L")
    filled = inv.copy()
    w, h = filled.size
    for seed in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
        try:
            ImageDraw.floodfill(filled, seed, 128, thresh=8)
        except Exception:
            pass
    outside = np.asarray(filled) == 128
    alpha = np.where(outside, 0, 255).astype(np.uint8)
    alpha[color_dist < max(24, thresh - 12)] = 0

    # drop isolated specks (opening) while keeping the main silhouette intact
    a2 = Image.fromarray(alpha, "L").filter(ImageFilter.MinFilter(3)).filter(ImageFilter.MaxFilter(3))
    alpha = np.asarray(a2).astype(np.uint8)

    if keep_largest:
        alpha = np.where(largest_component(alpha > 8), 255, 0).astype(np.uint8)
    return alpha


def trim_and_place(img, alpha, scale, baseline_h=None):
    ys, xs = np.where(alpha > 8)
    if len(xs) == 0:
        return None
    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    sprite = img.crop((int(x0), int(y0), int(x1), int(y1)))
    a = Image.fromarray(alpha, "L").crop((int(x0), int(y0), int(x1), int(y1)))
    sprite.putalpha(a)

    nw = max(1, int(round(sprite.width * scale)))
    nh = max(1, int(round(sprite.height * scale)))
    sprite = sprite.resize((nw, nh), Image.LANCZOS)

    cell = Image.new("RGBA", (CELL_W, CELL_H), (0, 0, 0, 0))
    px = (CELL_W - nw) // 2
    py = CELL_H - MARGIN_Y - nh
    if px < 0:
        sprite = sprite.crop((-px, 0, nw + px, nh))
        nw = sprite.width
        px = 0
    if py < 0:
        sprite = sprite.crop((0, -py, nw, nh + py))
        py = 0
    cell.alpha_composite(sprite, (px, py))
    return cell


def group_files(raw_dir):
    groups = defaultdict(list)
    for name in sorted(os.listdir(raw_dir)):
        if not name.endswith(".png") or name.startswith("_"):
            continue
        stem = name[:-4]
        state, _, idx = stem.rpartition("-")
        if not state:
            state, idx = stem, "0"
        groups[state].append((idx, os.path.join(raw_dir, name)))
    return groups


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw")
    ap.add_argument("--frames-root")
    ap.add_argument("--states")
    ap.add_argument("--looks-root")
    ap.add_argument("--selftest")
    ap.add_argument("--thresh", type=int, default=46)
    args = ap.parse_args()

    if args.selftest:
        img = Image.open(args.selftest).convert("RGB")
        alpha = extract_alpha(img, args.thresh)
        cov = (alpha > 8).mean()
        print("selftest:", args.selftest, img.size, "opaque coverage %.3f" % cov)
        ys, xs = np.where(alpha > 8)
        print("bbox:", xs.min(), ys.min(), xs.max(), ys.max())
        out = os.path.join(os.path.dirname(args.selftest), "_selftest_cutout.png")
        cut = img.copy()
        cut.putalpha(Image.fromarray(alpha, "L"))
        cut.save(out)
        print("saved", out)
        return

    groups = group_files(args.raw)
    want = set(args.states.split(",")) if args.states else None
    stats = {}
    for state, items in sorted(groups.items()):
        if want and state not in want:
            continue
        is_look = state.startswith("look-")
        out_dir = os.path.join(args.looks_root if is_look else args.frames_root, state)
        os.makedirs(out_dir, exist_ok=True)

        prepared = []
        for idx, path in items:
            img = Image.open(path).convert("RGB")
            alpha = extract_alpha(img, args.thresh)
            ys, xs = np.where(alpha > 8)
            if len(xs) == 0:
                print("  skip empty:", path)
                continue
            prepared.append((idx, img, alpha, ys.max() - ys.min() + 1))

        if not prepared:
            continue
        heights = sorted(h for *_rest, h in prepared)
        median_h = heights[len(heights) // 2]
        scale = TARGET_H / float(median_h)
        for idx, img, alpha, h in prepared:
            cell = trim_and_place(img, alpha, scale)
            if cell is None:
                continue
            cell.save(os.path.join(out_dir, "%02d.png" % int(idx)))
        stats[state] = {"frames": len(prepared), "median_h": int(median_h), "scale": round(scale, 3)}
        print("%-14s frames=%d median_h=%d scale=%.3f -> %s" % (state, len(prepared), median_h, scale, out_dir))

    if args.frames_root:
        os.makedirs(args.frames_root, exist_ok=True)
        with open(os.path.join(args.frames_root, "normalize-stats.json"), "w", encoding="utf-8") as f:
            json.dump(stats, f, indent=2)
        print("wrote normalize-stats.json")


if __name__ == "__main__":
    main()
