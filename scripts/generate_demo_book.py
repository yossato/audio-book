#!/usr/bin/env python3
"""
デモ用縦書きページ画像・book.json 生成スクリプト

テキスト: 夏目漱石「吾輩は猫である」(1905年発表)
著作権: 1916年没 → パブリックドメイン。SNS 等へのアップロード可。
底本: 青空文庫 https://www.aozora.gr.jp/cards/000148/card789.html

使い方:
    cd /Users/yoshiaki/Projects/audio-book
    python3 scripts/generate_demo_book.py
    # → demo_book/book.json と demo_book/pages/*.png が生成される
"""

import json
import os
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("pip install Pillow が必要です")
    sys.exit(1)

# ---------------------------------------------------------------------------
# ページ設定
# ---------------------------------------------------------------------------
PAGE_W, PAGE_H = 840, 1188      # B5 縦比
BG_COLOR       = (252, 248, 238) # 和紙風
TEXT_COLOR     = (28, 22, 15)
RULE_COLOR     = (200, 190, 175)
CHAR_SIZE      = 26
LINE_GAP       = 18              # 列間余白（行間1.5倍）
MARGIN_T       = 80
MARGIN_B       = 72
MARGIN_R       = 70
MARGIN_L       = 55

COL_W = CHAR_SIZE + LINE_GAP    # 1 列の幅

# ---------------------------------------------------------------------------
# フォント
# ---------------------------------------------------------------------------
_FONT_CANDIDATES = [
    "/System/Library/Fonts/ヒラギノ明朝 ProN W3.ttc",
    "/System/Library/Fonts/Hiragino Mincho ProN W3.ttc",
    "/Library/Fonts/ヒラギノ明朝 ProN W3.ttc",
    "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc",
    "/System/Library/Fonts/Hiragino Sans W3.ttc",
]

def _load_font(size: int):
    for path in _FONT_CANDIDATES:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                pass
    # Pillow 10+ では default でサイズ指定可
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()

FONT       = _load_font(CHAR_SIZE)
FONT_TITLE = _load_font(CHAR_SIZE + 8)
FONT_SMALL = _load_font(CHAR_SIZE - 5)
FONT_KANA  = _load_font(CHAR_SIZE - 2)  # ルビ・注記

# ---------------------------------------------------------------------------
# テキスト
# 夏目漱石「吾輩は猫である」(1905) — パブリックドメイン
# ---------------------------------------------------------------------------
#  各ページのブロック定義。type は ndlocr-lite と同じ種別名を使用。
PAGE_TEXTS = [
    # ─── ページ 0: タイトルページ ───────────────────────────────────────────
    [
        {
            "type": "タイトル本文",
            "text": "吾輩は猫である",
        },
        {
            "type": "本文",
            "text": "夏目漱石",
        },
        {
            "type": "キャプション",
            "text": "（一九〇五年発表・パブリックドメイン）",
        },
    ],

    # ─── ページ 1 ──────────────────────────────────────────────────────────
    [
        {
            "type": "本文",
            "text": "吾輩は猫である。名前はまだ無い。",
        },
        {
            "type": "本文",
            "text": "どこで生れたかとんと見当がつかぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。吾輩はここで始めて人間というものを見た。しかもあとで聞くとそれは書生という人間中で一番獰悪な種族であったそうだ。この書生というのは時々我々を捕えて煮て食うという話である。しかし当時は何という考もなかったから別段恐しいとも思わなかった。ただ彼の掌に載せられてスーと持ち上げられた時何だかフワフワした感じがあったばかりである。",
        },
        {
            "type": "本文",
            "text": "掌の上で少し落ちついて書生の顔を見たのがいわゆる人間というものの見始であろう。この時妙なものだと思った感じが今でも残っている。",
        },
    ],

    # ─── ページ 2 ──────────────────────────────────────────────────────────
    [
        {
            "type": "本文",
            "text": "第一毛をもって装飾されべきはずの顔がつるつるしていてまるで薬缶だ。その後猫にも大分逢ったがこんな片輪には一度も出会わした事がない。のみならず顔の真中があまりに突起している。そうしてその穴の中から時々ぷうぷうと煙を吹く。どうも咽せぽくて実に弱った。これが人間の飲む煙草というものである事はようやくこの頃知った。",
        },
        {
            "type": "割注",
            "text": "（書生＝当時の学生のこと）",
        },
        {
            "type": "本文",
            "text": "この書生の掌の裡に載せられた時から吾輩の旅は始まった。しかし胡魂たる吾輩は今日でもどこへどうして連れて来られたか知れない。かてて加えて吾輩は生れながらにして不敏なる種族であった。すなわち人家に飼われていた。",
        },
    ],

    # ─── ページ 3 ──────────────────────────────────────────────────────────
    [
        {
            "type": "本文",
            "text": "吾輩はこの家の主人が誰であるかを知らなかった。ただ時々台所に置いてある飯を食うという事だけを知っていた。",
        },
        {
            "type": "本文",
            "text": "主人は中学校の英語の先生である。毎日書斎に閉じこもって本を読んでいる。吾輩は時々その書斎に忍び込んで、膝の上に乗ろうとするが、その度に「こら」と言って払い落とされる。それでも吾輩は懲りずにまた入って行く。",
        },
        {
            "type": "キャプション",
            "text": "（第一章より）",
        },
    ],
]

# ---------------------------------------------------------------------------
# 縦書き描画エンジン
# ---------------------------------------------------------------------------

class VerticalRenderer:
    """右→左へ列を積む縦書きページ描画クラス。"""

    def render_page(self, blocks: list[dict], page_number: int) -> tuple[Image.Image, list[dict]]:
        """
        1 ページを描画し (image, rendered_blocks) を返す。
        rendered_blocks の各要素に bbox を追加済み。
        """
        img  = Image.new("RGB", (PAGE_W, PAGE_H), BG_COLOR)
        draw = ImageDraw.Draw(img)

        # 外枠
        draw.rectangle([(20, 20), (PAGE_W - 20, PAGE_H - 20)],
                       outline=RULE_COLOR, width=1)

        # ノンブル（ページ番号）
        num_text = str(page_number)
        draw.text((PAGE_W // 2, PAGE_H - 36), num_text,
                  font=FONT_SMALL, fill=RULE_COLOR, anchor="mm")

        # 描画カーソル（右端の列から開始）
        col_x = PAGE_W - MARGIN_R - CHAR_SIZE
        row_y = MARGIN_T

        area_bottom = PAGE_H - MARGIN_B
        area_left   = MARGIN_L

        rendered = []
        block_id = 0

        for raw in blocks:
            text  = raw["text"]
            btype = raw.get("type", "本文")

            if btype == "タイトル本文":
                font  = FONT_TITLE
                color = (40, 20, 10)
            elif btype == "キャプション":
                font  = FONT_SMALL
                color = (100, 90, 80)
            elif btype == "割注":
                font  = FONT_KANA
                color = (90, 80, 70)
            else:
                font  = FONT
                color = TEXT_COLOR

            if col_x < area_left:
                break  # ページ溢れ

            # この列の開始位置を記録
            block_col_start_x = col_x

            min_x =  10000.0
            max_x = -10000.0
            min_y =  10000.0
            max_y = -10000.0
            chars_drawn = 0

            for ch in text:
                if col_x < area_left:
                    break

                draw.text((col_x, row_y), ch, font=font, fill=color)

                min_x = min(min_x, float(col_x))
                max_x = max(max_x, float(col_x + CHAR_SIZE))
                min_y = min(min_y, float(row_y))
                max_y = max(max_y, float(row_y + CHAR_SIZE))
                chars_drawn += 1

                row_y += CHAR_SIZE
                if row_y + CHAR_SIZE > area_bottom:
                    col_x -= COL_W
                    row_y  = MARGIN_T

            # ブロック終端: 次の列へ
            if row_y > MARGIN_T:
                col_x -= COL_W
                row_y  = MARGIN_T

            if chars_drawn > 0:
                rendered.append({
                    "id":          block_id,
                    "text":        text,
                    "bbox":        [min_x, min_y, max_x, max_y],
                    "confidence":  1.0,
                    "is_vertical": True,
                    "type":        btype,
                })
                block_id += 1

        return img, rendered


# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------

def main():
    out_dir   = Path(__file__).parent.parent / "demo_book"
    pages_dir = out_dir / "pages"
    pages_dir.mkdir(parents=True, exist_ok=True)

    renderer   = VerticalRenderer()
    pages_json = []

    print("縦書きページを生成中...")
    for page_num, blocks in enumerate(PAGE_TEXTS):
        img, rendered_blocks = renderer.render_page(blocks, page_number=page_num)
        img_file = pages_dir / f"page_{page_num:03d}.png"
        img.save(img_file, "PNG")
        print(f"  page_{page_num:03d}.png — {len(rendered_blocks)} ブロック")

        pages_json.append({
            "page_number": page_num,
            "image_path":  f"pages/page_{page_num:03d}.png",
            "audio_path":  None,
            "blocks":      rendered_blocks,
        })

    book = {
        "title": "吾輩は猫である",
        "pages": pages_json,
    }

    book_json = out_dir / "book.json"
    with open(book_json, "w", encoding="utf-8") as f:
        json.dump(book, f, ensure_ascii=False, indent=2)

    print(f"\n完成: {book_json}")
    print("\nアプリで開くには:")
    print(f"  open ~/Library/Developer/Xcode/DerivedData/AudioBookApp-*/Build/Products/Debug/AudioBookApp.app --args --book '{book_json}'")
    print("\nページ画像を確認するには:")
    print(f"  open '{pages_dir}'")


if __name__ == "__main__":
    main()
