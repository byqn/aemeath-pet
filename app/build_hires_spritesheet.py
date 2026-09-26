"""从原始条带重建高分辨率图集，供桌面应用使用。

背景：交付用的 Codex 图集受格式限制，每格只有 192x208；而原始条带里每个姿势
高约 460px。所以把图集放大显示必然发虚——细节在组装阶段就丢了。

做法：以现有图集为“构图基准”，回到原始条带裁出同序号的姿势，按一个统一的
全局倍率放大后放进放大的格子里。统一倍率保证各姿势之间的相对大小完全不变；
每格再按内容包围盒对齐到基准位置，保证基线和注册关系与原图集一致。

输出：app/spritesheet-hires.png
"""
import json
from pathlib import Path

from PIL import Image

PROJ = Path(r"C:\Users\32022\Desktop\000\aemeath-pet")
RUN = PROJ / "work" / "aemeath-run"
APP = PROJ / "app"

CELL_W, CELL_H = 192, 208
BG_TOLERANCE = 96
# 目标倍率：与程序默认 Scale=2 的显示尺寸一致，做到 1:1 像素映射
TARGET_FACTOR = 2.0

# 行 -> (原始条带文件, 帧数)
ROWS = [
    ("idle", RUN / "decoded" / "idle.png", 6),
    ("running-right", RUN / "decoded" / "running-right.png", 8),
    ("running-left", RUN / "decoded" / "running-left.png", 8),
    ("waving", RUN / "decoded" / "waving.png", 4),
    ("jumping", RUN / "decoded" / "jumping.png", 5),
    ("failed", RUN / "decoded" / "failed.png", 8),
    ("waiting", RUN / "decoded" / "waiting.png", 6),
    ("running", RUN / "decoded" / "running.png", 6),
    ("review", RUN / "decoded" / "review.png", 6),
    ("look-row-9", RUN / "decoded" / "look-row-9.png", 8),
    ("look-row-10", RUN / "decoded" / "look-row-10.png", 8),
]

CHROMA = (255, 0, 255)


def is_background(pixel) -> bool:
    r, g, b = pixel[0], pixel[1], pixel[2]
    distance = ((r - CHROMA[0]) ** 2 + (g - CHROMA[1]) ** 2 + (b - CHROMA[2]) ** 2) ** 0.5
    return distance <= BG_TOLERANCE


def column_occupied(image: Image.Image) -> list[bool]:
    """按列判断是否含前景（用透明度/去背后更稳，这里对原始条带用色距判断）。"""
    rgba = image.convert("RGBA")
    px = rgba.load()
    width, height = rgba.size
    occupied = []
    for x in range(width):
        found = False
        for y in range(0, height, 2):
            if not is_background(px[x, y]):
                found = True
                break
        occupied.append(found)
    return occupied


def group_boxes(image: Image.Image, expected: int) -> list[tuple[int, int, int, int]]:
    """用贯穿全高的背景列把姿势分开。"""
    occupied = column_occupied(image)
    width = len(occupied)
    runs = []
    start = None
    for x in range(width):
        if occupied[x]:
            if start is None:
                start = x
        else:
            if start is not None:
                runs.append((start, x - 1))
                start = None
    if start is not None:
        runs.append((start, width - 1))
    if len(runs) != expected:
        raise SystemExit(
            f"姿势分组数不符：检测到 {len(runs)} 组，期望 {expected} 组；"
            "请检查原始条带的间距。"
        )
    height = image.size[1]
    return [(x0, 0, x1 + 1, height) for x0, x1 in runs]


def key_background(image: Image.Image) -> Image.Image:
    """把纯色背景抠成透明。

    原始条带是未抠图的全不透明 PNG，必须先抠图，否则 getbbox() 会返回整张图，
    导致缩放比例和定位全错，而且会把洋红背景一起带进结果。
    """
    rgba = image.convert("RGBA")
    px = rgba.load()
    width, height = rgba.size
    for y in range(height):
        for x in range(width):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            distance = ((r - CHROMA[0]) ** 2 + (g - CHROMA[1]) ** 2 + (b - CHROMA[2]) ** 2) ** 0.5
            if distance <= BG_TOLERANCE:
                px[x, y] = (r, g, b, 0)
    return rgba


def content_bbox(image: Image.Image) -> tuple[int, int, int, int]:
    """返回内容（非透明）包围盒，相对图像左上角。"""
    alpha = image.convert("RGBA").getchannel("A")
    box = alpha.getbbox()
    if box is None:
        raise SystemExit("裁出的姿势是空的")
    return box


def main() -> None:
    atlas = Image.open(RUN / "final" / "spritesheet-extended.png").convert("RGBA")
    if atlas.size != (CELL_W * 8, CELL_H * 11):
        raise SystemExit(f"基准图集尺寸异常：{atlas.size}")

    # 第一遍：算出全局统一倍率 = 各格“原始分辨率 / 图集分辨率”的最小值
    plans = []          # (row, col, 原始裁剪图, 图集内容框, 倍率)
    native_ratios = {}
    for row_index, (state, strip_path, frames) in enumerate(ROWS):
        strip = Image.open(strip_path).convert("RGBA")
        boxes = group_boxes(strip, frames)
        ratios_here = []
        for col in range(frames):
            raw = key_background(strip.crop(boxes[col]))
            raw_box = content_bbox(raw)
            cell = atlas.crop((col * CELL_W, row_index * CELL_H, (col + 1) * CELL_W, (row_index + 1) * CELL_H))
            cell_box = content_bbox(cell)
            plans.append((row_index, col, raw, raw_box, cell_box))
            ratios_here.append((raw_box[3] - raw_box[1]) / (cell_box[3] - cell_box[1]))
        native_ratios[state] = ratios_here

    # 目标倍率：与程序默认显示比例（Scale=2）对齐，做到 1:1 像素映射。
    # 不用“全局最小原生倍率”，因为各行原生分辨率差异很大
    # （idle 约 1.84 倍，running 系列只有约 1.04 倍）：取最小等于白做。
    factor = TARGET_FACTOR
    print(f"  目标倍率 = {factor:.2f}（与显示比例 1:1 对齐）")
    print("  各行原生倍率（>= 目标倍率表示该行是真正的高清来源）：")
    for state, values in native_ratios.items():
        low = min(values)
        tag = "高清" if low >= factor - 0.01 else ("接近" if low >= factor * 0.75 else "原生偏小，靠插值")
        print(f"    {state:14s} {low:.2f} ~ {max(values):.2f}   {tag}")

    out_w = int(round(CELL_W * factor))
    out_h = int(round(CELL_H * factor))
    hires = Image.new("RGBA", (out_w * 8, out_h * 11), (0, 0, 0, 0))

    for row_index, col, raw, raw_box, cell_box in plans:
        crop = raw.crop(raw_box)
        target_w = max(1, int(round((cell_box[2] - cell_box[0]) * factor)))
        target_h = max(1, int(round((cell_box[3] - cell_box[1]) * factor)))
        scaled = crop.resize((target_w, target_h), Image.LANCZOS)
        # 按基准内容框的左上角位置放回去，保证基线/注册关系与图集一致
        x = col * out_w + int(round(cell_box[0] * factor))
        y = row_index * out_h + int(round(cell_box[1] * factor))
        hires.alpha_composite(scaled, (x, y))

    target = APP / "spritesheet-hires.png"
    hires.save(target)
    meta = {
        "source_atlas": str(RUN / "final" / "spritesheet-extended.png"),
        "cell_width": out_w,
        "cell_height": out_h,
        "columns": 8,
        "rows": 11,
        "global_factor": round(factor, 4),
        "note": "以交付图集为构图基准、从原始条带重采样得到的应用用高分辨率图集。",
    }
    (APP / "spritesheet-hires.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    size_mb = target.stat().st_size / 1024 / 1024
    print(f"  写出 {target.name}  {hires.size[0]}x{hires.size[1]}  每格 {out_w}x{out_h}  {size_mb:.1f} MB")


if __name__ == "__main__":
    main()
