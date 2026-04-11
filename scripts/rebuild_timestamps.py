"""
既存の音声ファイルから book.json のタイムスタンプを再構築する。

tts_process.py が --start-page で部分実行された後、スキップされたページの
audio_path / audio_start / audio_end が null のままになる問題を修正するための補助スクリプト。

各ブロック単位の音声長は再計算できないため、ページ全体の音声長をブロック数で
均等割りする近似で埋める（再生はできるがハイライト同期は粗くなる）。

より正確にやる場合は --voice / --rate を指定して該当ページのみ再生成すべき。

使い方:
    python scripts/rebuild_timestamps.py --book book.json --audio-dir audio
"""

import argparse
import json
import wave
from pathlib import Path


def get_wav_duration(path: Path) -> float:
    with wave.open(str(path), "r") as w:
        return w.getnframes() / w.getframerate()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--book", type=str, required=True)
    parser.add_argument("--audio-dir", type=str, required=True)
    args = parser.parse_args()

    book_path = Path(args.book).resolve()
    audio_dir = Path(args.audio_dir).resolve()

    with open(book_path, encoding="utf-8") as f:
        book = json.load(f)

    fixed = 0
    for page in book["pages"]:
        if page.get("audio_path") and page["blocks"] and page["blocks"][0].get("audio_start") is not None:
            continue  # 既に正常

        page_num = page["page_number"]
        wav_path = audio_dir / f"page_{page_num:03d}.wav"
        if not wav_path.exists():
            print(f"  Page {page_num}: WAV not found, skip")
            continue

        total_duration = get_wav_duration(wav_path)
        non_empty_blocks = [b for b in page["blocks"] if b["text"].strip()]
        n = len(non_empty_blocks)
        if n == 0:
            continue

        # ブロックのテキスト長で重み付けして時間を割り振る
        total_chars = sum(len(b["text"]) for b in non_empty_blocks)
        current = 0.0
        for block in page["blocks"]:
            text = block["text"].strip()
            if not text:
                block["audio_start"] = round(current, 3)
                block["audio_end"] = round(current, 3)
                continue
            ratio = len(text) / total_chars if total_chars > 0 else 1.0 / n
            duration = total_duration * ratio
            block["audio_start"] = round(current, 3)
            block["audio_end"] = round(current + duration, 3)
            current += duration

        page["audio_path"] = str(wav_path)
        fixed += 1
        print(f"  Page {page_num}: rebuilt timestamps from {total_duration:.1f}s WAV ({n} blocks)")

    with open(book_path, "w", encoding="utf-8") as f:
        json.dump(book, f, ensure_ascii=False, indent=2)

    print(f"[INFO] {fixed} pages updated")


if __name__ == "__main__":
    main()
