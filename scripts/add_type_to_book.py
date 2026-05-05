"""
既存の book.json に OCR XML の TYPE 情報を追加するスクリプト。

book.json の各ブロックに "type" フィールドを追加する。
XML がない場合はデフォルトで "本文" とする。

使い方:
    python scripts/add_type_to_book.py \
        --book /path/to/book.json \
        --ocr-output /path/to/ocr_output_dir
"""

import argparse
import json
import xml.etree.ElementTree as ET
from pathlib import Path


def parse_xml_types(xml_file: Path) -> dict[str, str]:
    """XML ファイルからテキスト先頭 → TYPE のマッピングを取得する"""
    type_map = {}
    try:
        tree = ET.parse(xml_file)
        root = tree.getroot()
        for line in root.iter("LINE"):
            line_type = line.get("TYPE")
            string = line.get("STRING")
            if line_type is not None and string is not None:
                key = string[:30]
                type_map[key] = line_type
    except (ET.ParseError, FileNotFoundError):
        pass
    return type_map


def main():
    parser = argparse.ArgumentParser(description="book.json に type フィールドを追加")
    parser.add_argument("--book", type=str, required=True, help="book.json のパス")
    parser.add_argument("--ocr-output", type=str, required=True, help="OCR XML 出力ディレクトリ")
    args = parser.parse_args()

    book_path = Path(args.book)
    ocr_dir = Path(args.ocr_output)

    with open(book_path, encoding="utf-8") as f:
        book = json.load(f)

    # XML ファイルをソート（book.json のページ順と対応）
    xml_files = sorted(ocr_dir.glob("*.xml"))

    # 画像名 → XML ファイルのマッピングを作成
    xml_by_image = {}
    for xml_file in xml_files:
        try:
            tree = ET.parse(xml_file)
            root = tree.getroot()
            page_elem = root.find("PAGE")
            if page_elem is not None:
                img_name = page_elem.get("IMAGENAME", "")
                xml_by_image[img_name] = xml_file
        except ET.ParseError:
            pass

    updated_count = 0
    for page in book["pages"]:
        # ページの画像名を取得
        img_name = Path(page["image_path"]).name
        xml_file = xml_by_image.get(img_name)

        if xml_file:
            type_map = parse_xml_types(xml_file)
        else:
            type_map = {}

        for block in page["blocks"]:
            if "type" not in block:
                text_key = block["text"][:30]
                block["type"] = type_map.get(text_key, "本文")
                updated_count += 1

    with open(book_path, "w", encoding="utf-8") as f:
        json.dump(book, f, ensure_ascii=False, indent=2)

    total_blocks = sum(len(p["blocks"]) for p in book["pages"])
    type_counts = {}
    for page in book["pages"]:
        for block in page["blocks"]:
            t = block.get("type", "本文")
            type_counts[t] = type_counts.get(t, 0) + 1

    print(f"[INFO] 更新完了: {book_path}")
    print(f"[INFO] 更新ブロック数: {updated_count}/{total_blocks}")
    print(f"[INFO] TYPE 分布:")
    for t, cnt in sorted(type_counts.items(), key=lambda x: -x[1]):
        print(f"  {t}: {cnt}")


if __name__ == "__main__":
    main()
