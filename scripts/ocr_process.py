"""
OCR処理スクリプト

ndlocr-lite を使って画像から OCR を実行し、book.json 形式に変換する。

使い方:
    python scripts/ocr_process.py --input pages/ --output book.json [--viz]
"""

import argparse
import json
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
NDLOCR_SRC = PROJECT_ROOT / "ndlocr-lite" / "src"


def run_ocr(input_dir: Path, viz: bool = False) -> Path:
    """ndlocr-lite を実行して OCR 結果を一時ディレクトリに保存する"""
    tmp_dir = Path(tempfile.mkdtemp(prefix="ocr_output_"))

    cmd = [
        sys.executable,
        str(NDLOCR_SRC / "ocr.py"),
        "--sourcedir", str(input_dir),
        "--output", str(tmp_dir),
    ]
    if viz:
        cmd += ["--viz", "True"]

    env_path = str(NDLOCR_SRC)
    subprocess.run(cmd, check=True, env={
        **__import__("os").environ,
        "PYTHONPATH": env_path,
    })
    return tmp_dir


def parse_xml_types(xml_file: Path) -> dict[str, str]:
    """XML ファイルからテキスト → TYPE のマッピングを取得する。

    JSON の id と XML の ORDER は必ずしも一致しないため、
    テキスト内容（STRING 属性の先頭部分）で照合する。
    """
    type_map = {}
    try:
        tree = ET.parse(xml_file)
        root = tree.getroot()
        for line in root.iter("LINE"):
            line_type = line.get("TYPE")
            string = line.get("STRING")
            if line_type is not None and string is not None:
                # テキストの先頭30文字をキーとして使う
                key = string[:30]
                type_map[key] = line_type
    except (ET.ParseError, FileNotFoundError):
        pass
    return type_map


def convert_to_book_json(ocr_output_dir: Path, input_dir: Path, title: str = "",
                         book_dir: Path | None = None) -> dict:
    """ndlocr-lite の JSON + XML 出力を book.json 形式に変換する"""
    pages = []

    json_files = sorted(ocr_output_dir.glob("*.json"))
    for page_num, json_file in enumerate(json_files, start=1):
        with open(json_file, encoding="utf-8") as f:
            ocr_data = json.load(f)

        # 対応する XML ファイルから TYPE 情報を取得
        xml_file = json_file.with_suffix(".xml")
        type_map = parse_xml_types(xml_file)

        image_name = ocr_data["imginfo"]["img_name"]
        # book.json からの相対パスで保存（例: pages/image.jpg）
        if book_dir is not None:
            image_path = str((input_dir / image_name).relative_to(book_dir))
        else:
            # フォールバック: input_dir の最後のディレクトリ名 + ファイル名
            image_path = f"{input_dir.name}/{image_name}"

        blocks = []
        for item in ocr_data["contents"][0]:
            bb = item["boundingBox"]
            # boundingBox: [[x1,y1], [x1,y2], [x2,y1], [x2,y2]]
            # → bbox: [x1, y1, x2, y2] (左上, 右下)
            x1 = bb[0][0]
            y1 = bb[0][1]
            x2 = bb[3][0]
            y2 = bb[3][1]

            block_id = item["id"]
            # テキスト先頭30文字で XML の TYPE を照合
            text_key = item["text"][:30]
            block_type = type_map.get(text_key, "本文")

            blocks.append({
                "id": block_id,
                "text": item["text"],
                "bbox": [x1, y1, x2, y2],
                "confidence": item.get("confidence", 0),
                "is_vertical": item.get("isVertical", "false") == "true",
                "type": block_type,
                "audio_start": None,  # TTS処理後に設定
                "audio_end": None,
            })

        pages.append({
            "page_number": page_num,
            "image_path": image_path,
            "audio_path": None,  # TTS処理後に設定
            "blocks": blocks,
        })

    return {
        "title": title,
        "pages": pages,
    }


def main():
    parser = argparse.ArgumentParser(description="OCR処理 → book.json 生成")
    parser.add_argument("--input", type=str, required=True, help="画像ディレクトリのパス")
    parser.add_argument("--output", type=str, default="book.json", help="出力する book.json のパス")
    parser.add_argument("--title", type=str, default="", help="ブックタイトル")
    parser.add_argument("--viz", action="store_true", help="バウンディングボックスの可視化画像を保存")
    parser.add_argument("--ocr-output", type=str, default=None, help="既存のOCR出力ディレクトリ（OCR実行をスキップ）")
    args = parser.parse_args()

    input_dir = Path(args.input).resolve()

    if args.ocr_output:
        ocr_output_dir = Path(args.ocr_output).resolve()
        print(f"[INFO] 既存のOCR出力を使用: {ocr_output_dir}")
    else:
        print(f"[INFO] OCR実行中: {input_dir}")
        ocr_output_dir = run_ocr(input_dir, viz=args.viz)
        print(f"[INFO] OCR出力: {ocr_output_dir}")

    output_path = Path(args.output).resolve()
    book_dir = output_path.parent

    book = convert_to_book_json(ocr_output_dir, input_dir, title=args.title,
                                book_dir=book_dir)
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(book, f, ensure_ascii=False, indent=2)

    total_blocks = sum(len(p["blocks"]) for p in book["pages"])
    print(f"[INFO] book.json 生成完了: {output_path}")
    print(f"[INFO] ページ数: {len(book['pages'])}, テキストブロック数: {total_blocks}")


if __name__ == "__main__":
    main()
