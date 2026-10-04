"""Cắt sprite sheet 4x8 thành từng PNG nền trong suốt.
Dùng: python3 tools/slice_sheet.py <sheet.png> <out_dir>"""
import sys, os
from collections import deque
from PIL import Image, ImageFilter

CHARS = ["be_non", "dom", "lac_lac", "nghe_o"]
POSES = ["cam_do", "chi_tay", "cuoi", "di_chuyen", "ngoi", "noi", "sai_roi", "soi_kinh"]
ROW_H, LABEL_H, COL_W = 394, 36, 640
TARGET = 320

def is_bg(p):
    r, g, b = p[:3]
    return min(r, g, b) > 165 and max(r, g, b) - min(r, g, b) < 75

def cut(cell):
    cell = cell.convert("RGBA")
    w, h = cell.size
    px = cell.load()
    seen = bytearray(w * h)
    q = deque()
    for x in range(w):
        q.append((x, 0)); q.append((x, h - 1))
    for y in range(h):
        q.append((0, y)); q.append((w - 1, y))
    while q:
        x, y = q.popleft()
        i = y * w + x
        if seen[i] or not is_bg(px[x, y]):
            continue
        seen[i] = 1
        for nx, ny in ((x+1, y), (x-1, y), (x, y+1), (x, y-1)):
            if 0 <= nx < w and 0 <= ny < h and not seen[ny * w + nx]:
                q.append((nx, ny))
    mask = Image.new("L", (w, h), 255)
    mp = mask.load()
    for y in range(h):
        for x in range(w):
            if seen[y * w + x]:
                mp[x, y] = 0
    # làm mềm mép để không lộ viền màu nền
    mask = mask.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.8))
    cell.putalpha(mask)
    bbox = mask.point(lambda v: 255 if v > 20 else 0).getbbox()
    cell = cell.crop(bbox)
    s = TARGET / max(cell.size)
    return cell.resize((round(cell.width * s), round(cell.height * s)), Image.LANCZOS)

def main(sheet, out):
    im = Image.open(sheet)
    for idx in range(32):
        row, col = divmod(idx, 4)
        name = CHARS[idx // 8]; pose = POSES[idx % 8]
        box = (col * COL_W + 4, row * ROW_H + LABEL_H, col * COL_W + COL_W - 4, row * ROW_H + ROW_H - 4)
        d = os.path.join(out, name); os.makedirs(d, exist_ok=True)
        cut(im.crop(box)).save(os.path.join(d, pose + ".png"))
        print(name, pose)

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
