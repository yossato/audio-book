#!/usr/bin/env python3
"""
注釈検出の可視化スクリプト

距離ベースアルゴリズムの結果をページ画像上に表示。
- 緑: 本文（読み上げる）
- 赤: 注釈/スキップ（読み上げない）
- ブロック番号を表示

使い方:
    python scripts/visualize_footnotes.py --book ~/Documents/AudioBookLibrary/料理の科学/book.json --page 27
"""

import argparse
import json
import math
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def euclidean_distance(bbox_a, bbox_b):
    x1, y1 = bbox_a[0], bbox_a[1]
    x2, y2 = bbox_b[0], bbox_b[1]
    return math.sqrt((x2 - x1)**2 + (y2 - y1)**2)


def detect_footnotes_by_distance(blocks):
    if len(blocks) < 3:
        return set()

    footnote_ids = set()

    for i in range(len(blocks) - 2):
        b_n = blocks[i]
        b_n1 = blocks[i + 1]
        b_n2 = blocks[i + 2]

        bbox_n = b_n.get("bbox", [0, 0, 0, 0])
        bbox_n1 = b_n1.get("bbox", [0, 0, 0, 0])
        bbox_n2 = b_n2.get("bbox", [0, 0, 0, 0])

        dist_n_to_n1 = euclidean_distance(bbox_n, bbox_n1)
        dist_n_to_n2 = euclidean_distance(bbox_n, bbox_n2)

        if dist_n_to_n2 < dist_n_to_n1:
            footnote_ids.add(i + 1)

    return footnote_ids


def draw_page(image_path: str, blocks: list, footnote_ids: set, output_path: str):
    img = Image.open(image_path).convert("RGBA")
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay, "RGBA")

    # フォント（macOS 標準）
    try:
        font = ImageFont.truetype("/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc", 20)
        font_small = ImageFont.truetype("/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc", 14)
    except (IOError, OSError):
        font = ImageFont.load_default()
        font_small = font

    for block in blocks:
        bid = block["id"]
        bbox = block.get("bbox", [])
        if len(bbox) != 4:
            continue

        x1, y1, x2, y2 = [int(v) for v in bbox]

        if bid in footnote_ids:
            # 赤: スキップ（注釈）
            outline_color = (255, 0, 0, 220)
            label_color = (255, 0, 0)
        else:
            # 緑: 本文（読み上げる）
            outline_color = (0, 150, 0, 220)
            label_color = (0, 100, 0)

        # 枠線のみ描画（重なっても見えるように塗りつぶしなし）
        draw.rectangle([x1, y1, x2, y2], fill=None, outline=outline_color, width=3)

        # ブロック番号（細いボックスはラベルを左に表示）
        label = str(bid)
        box_width = x2 - x1
        if box_width < 40:
            # 細いボックス: ラベルを左側に表示
            draw.text((x1 - 25, y1), label, fill=label_color, font=font)
        else:
            draw.text((x1 + 3, y1 + 3), label, fill=label_color, font=font)
            # テキスト（短縮）
            text = block.get("text", "")[:15]
            draw.text((x1 + 3, y1 + 28), text, fill=label_color, font=font_small)

    img = Image.alpha_composite(img, overlay)
    img = img.convert("RGB")
    img.save(output_path)
    return output_path


def main():
    parser = argparse.ArgumentParser(description="注釈検出可視化")
    parser.add_argument("--book", type=str, required=True, help="book.json のパス")
    parser.add_argument("--page", type=int, nargs="+", default=[27], help="表示するページ番号")
    args = parser.parse_args()

    book_path = Path(args.book)
    with open(book_path, encoding="utf-8") as f:
        book = json.load(f)

    for page_num in args.page:
        page = book["pages"][page_num - 1]
        blocks = page.get("blocks", [])
        image_path = page.get("image_path", "")

        if not Path(image_path).exists():
            print(f"[ERROR] 画像が見つかりません: {image_path}")
            continue

        footnote_ids = detect_footnotes_by_distance(blocks)

        # 出力パス
        output_path = f"/tmp/footnote_viz_p{page_num}.png"
        draw_page(image_path, blocks, footnote_ids, output_path)

        print(f"ページ {page_num}: {output_path}")
        print(f"  総ブロック: {len(blocks)}")
        print(f"  本文（緑）: {len(blocks) - len(footnote_ids)} 個")
        print(f"  スキップ（赤）: {len(footnote_ids)} 個")

        # macOS で開く
        subprocess.run(["open", output_path])


if __name__ == "__main__":
    main()
