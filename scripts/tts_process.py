"""
TTS処理スクリプト

macOS の say コマンドを使って book.json のテキストを音声化する。
各テキストブロックごとに音声を生成し、ページ単位で結合。
タイムスタンプを book.json に書き戻す。

使い方:
    python scripts/tts_process.py --book book.json [--voice Kyoko] [--rate 200]
"""

import argparse
import json
import subprocess
import tempfile
import wave
from pathlib import Path


def generate_block_audio(text: str, output_path: Path, voice: str, rate: int) -> float:
    """1テキストブロックの音声を生成し、長さ(秒)を返す"""
    aiff_path = output_path.with_suffix(".aiff")

    cmd = ["say", "-v", voice, "-r", str(rate), "-o", str(aiff_path), "--", text]
    try:
        subprocess.run(cmd, check=True, timeout=60)
    except subprocess.TimeoutExpired:
        print(f"    [WARN] say timed out for: {text[:40]}...")
        aiff_path.unlink(missing_ok=True)
        return 0.0
    except subprocess.CalledProcessError:
        print(f"    [WARN] say failed for: {text[:40]}...")
        aiff_path.unlink(missing_ok=True)
        return 0.0

    if not aiff_path.exists() or aiff_path.stat().st_size == 0:
        aiff_path.unlink(missing_ok=True)
        return 0.0

    # AIFF → WAV 変換
    subprocess.run([
        "afconvert", "-f", "WAVE", "-d", "LEI16",
        str(aiff_path), str(output_path),
    ], check=True)
    aiff_path.unlink()

    with wave.open(str(output_path), "r") as w:
        return w.getnframes() / w.getframerate()


def concatenate_wav_files(wav_paths: list[Path], output_path: Path):
    """複数の WAV ファイルを結合する"""
    if not wav_paths:
        return

    with wave.open(str(output_path), "w") as out:
        for i, path in enumerate(wav_paths):
            with wave.open(str(path), "r") as w:
                if i == 0:
                    out.setparams(w.getparams())
                out.writeframes(w.readframes(w.getnframes()))


def process_page(page: dict, audio_dir: Path, tmp_dir: Path, voice: str, rate: int) -> None:
    """1ページのテキストブロックをすべて音声化し、結合する"""
    page_num = page["page_number"]
    block_wavs = []
    current_time = 0.0

    for block in page["blocks"]:
        text = block["text"].strip()
        if not text:
            block["audio_start"] = current_time
            block["audio_end"] = current_time
            continue

        block_path = tmp_dir / f"page{page_num:03d}_block{block['id']:03d}.wav"
        duration = generate_block_audio(text, block_path, voice, rate)

        block["audio_start"] = round(current_time, 3)
        block["audio_end"] = round(current_time + duration, 3)
        current_time += duration
        if duration > 0:
            block_wavs.append(block_path)

    # ページ全体の音声ファイルを結合
    page_audio_path = audio_dir / f"page_{page_num:03d}.wav"
    concatenate_wav_files(block_wavs, page_audio_path)
    page["audio_path"] = f"audio/page_{page_num:03d}.wav"

    print(f"  Page {page_num}: {len(block_wavs)} blocks, {current_time:.1f}s total")


def main():
    parser = argparse.ArgumentParser(description="TTS処理 (macOS say)")
    parser.add_argument("--book", type=str, required=True, help="book.json のパス")
    parser.add_argument("--voice", type=str, default="Kyoko", help="macOS 音声名")
    parser.add_argument("--rate", type=int, default=200, help="読み上げ速度 (words per minute)")
    parser.add_argument("--start-page", type=int, default=1, help="処理開始ページ番号（既に生成済みのページをスキップ）")
    parser.add_argument("--end-page", type=int, default=None, help="処理終了ページ番号（含む）")
    args = parser.parse_args()

    book_path = Path(args.book).resolve()
    with open(book_path, encoding="utf-8") as f:
        book = json.load(f)

    audio_dir = book_path.parent / "audio"
    audio_dir.mkdir(exist_ok=True)

    tmp_dir = Path(tempfile.mkdtemp(prefix="tts_blocks_"))

    print(f"[INFO] Voice: {args.voice}, Rate: {args.rate}")
    print(f"[INFO] Audio output: {audio_dir}")

    for page in book["pages"]:
        if page["page_number"] < args.start_page:
            continue
        if args.end_page is not None and page["page_number"] > args.end_page:
            continue
        process_page(page, audio_dir, tmp_dir, args.voice, args.rate)

    with open(book_path, "w", encoding="utf-8") as f:
        json.dump(book, f, ensure_ascii=False, indent=2)

    print(f"[INFO] book.json 更新完了: {book_path}")


if __name__ == "__main__":
    main()
