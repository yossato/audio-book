"""
Irodori TTS バッチ音声生成 + Forced Alignment + AAC圧縮

mlx-audio サーバー経由でIrodori TTSにより本全体の音声を生成し、
Qwen3-ForcedAlignerでタイムスタンプを付与、AACに圧縮する。

使い方:
    # 全フェーズ実行（Swift アプリからは --phase tts / fa-compress で分割呼び出し）
    python scripts/irodori_tts_batch.py --book book.json

    # TTS生成のみ（サーバーが起動済みの前提）
    python scripts/irodori_tts_batch.py --book book.json --phase tts

    # Forced Alignment + 圧縮のみ（サーバー停止済みの前提）
    python scripts/irodori_tts_batch.py --book book.json --phase fa-compress

    # リファレンス音声で話者固定
    python scripts/irodori_tts_batch.py --book book.json --ref-wav ref.wav
"""

import argparse
import json
import re
import signal
import struct
import subprocess
import sys
import time
import wave
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen

# --- 中断フラグ ---
_interrupted = False


def _handle_signal(signum, frame):
    global _interrupted
    _interrupted = True
    print("\n[INFO] 中断シグナルを受信しました。現在のページ完了後に停止します...", file=sys.stderr)


signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT, _handle_signal)

# --- 定数 ---
DEFAULT_SERVER_URL = "http://localhost:8000"
DEFAULT_MODEL = "mlx-community/Irodori-TTS-500M-v2-fp16"
DEFAULT_SKIP_TYPES = {"割注", "キャプション", "柱", "ノンブル", "ルビ", "図版", "広告文字"}
CHUNK_MIN = 60
CHUNK_MAX = 200
SENTENCE_ENDINGS = re.compile(r"([。！？])")


# --- ブロックフィルタリング（ReadingSettings.shouldRead と同じロジック） ---
def is_readable_block(block: dict, skip_types: set[str]) -> bool:
    block_type = block.get("type", "本文")
    if block_type in skip_types:
        return False
    text = block.get("text", "").strip()
    if not text:
        return False
    # OCR エラー検出: 同一文字が5回以上連続
    max_repeat = 1
    current_repeat = 1
    chars = list(text)
    for i in range(1, len(chars)):
        if chars[i] == chars[i - 1]:
            current_repeat += 1
            max_repeat = max(max_repeat, current_repeat)
        else:
            current_repeat = 1
    if max_repeat >= 5:
        return False  # OCRエラー → 読まない
    # 句読点・記号のみで3文字以下
    if len(text) <= 3:
        import unicodedata
        if all(
            unicodedata.category(c).startswith(("P", "S", "Z"))
            or c in "0123456789,，.。、"
            for c in text
        ):
            return False
    return True


def preprocess_text(text: str) -> str:
    """改行除去・トリム（IrodoriChunkBuilder と同じ前処理）"""
    return text.replace("\n", "").replace("\r", "").strip()


# --- チャンク構築（IrodoriChunkBuilder と同等ロジック） ---
def build_chunks(segments: list[tuple[str, int]]) -> list[dict]:
    """
    segments: [(text, block_id), ...]
    returns: [{"text": str, "block_ranges": [{"block_id": int, "char_offset": int}, ...]}, ...]
    """
    if not segments:
        return []

    # 全テキストを結合して句読点で分割
    all_text = ""
    char_to_block = []  # 各文字がどのblock_idに属するか
    for text, block_id in segments:
        for ch in text:
            char_to_block.append(block_id)
        all_text += text

    # 句読点で分割（区切り文字は前のセグメントに含める）
    parts = SENTENCE_ENDINGS.split(all_text)
    sentence_segments = []
    i = 0
    while i < len(parts):
        seg = parts[i]
        if i + 1 < len(parts) and SENTENCE_ENDINGS.match(parts[i + 1]):
            seg += parts[i + 1]
            i += 2
        else:
            i += 1
        if seg:
            sentence_segments.append(seg)

    # チャンクに結合（60-200文字）
    chunks = []
    current_text = ""
    current_offset = 0

    for seg in sentence_segments:
        if len(current_text) + len(seg) > CHUNK_MAX and len(current_text) >= CHUNK_MIN:
            # 現在のチャンクを確定
            chunks.append(_make_chunk(current_text, current_offset, char_to_block))
            current_offset += len(current_text)
            current_text = seg
        else:
            current_text += seg

    if current_text:
        chunks.append(_make_chunk(current_text, current_offset, char_to_block))

    return chunks


def _make_chunk(text: str, offset: int, char_to_block: list[int]) -> dict:
    """チャンクテキストとブロック範囲情報を作成"""
    block_ranges = []
    seen_blocks = set()
    for i, ch in enumerate(text):
        abs_pos = offset + i
        if abs_pos < len(char_to_block):
            bid = char_to_block[abs_pos]
            if bid not in seen_blocks:
                seen_blocks.add(bid)
                block_ranges.append({"block_id": bid, "char_offset": i})
    return {"text": text, "block_ranges": block_ranges}


# --- TTS API 呼び出し ---
def tts_generate(
    text: str,
    server_url: str,
    model: str,
    voice: str,
    ref_wav: str | None,
    output_path: Path,
    timeout: int = 300,
) -> bool:
    """mlx-audio サーバーに音声生成をリクエストし、WAV を保存する"""
    url = f"{server_url}/v1/audio/speech"

    body: dict = {
        "model": model,
        "input": text,
        "response_format": "wav",
    }
    if ref_wav:
        body["ref_audio"] = ref_wav
        print(f"[DEBUG] Using ref_audio: {ref_wav}")
    else:
        body["voice"] = voice

    data = json.dumps(body).encode("utf-8")
    req = Request(url, data=data, headers={"Content-Type": "application/json"})

    try:
        with urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                print(f"  [ERROR] HTTP {resp.status}", file=sys.stderr)
                return False
            wav_data = resp.read()
            output_path.write_bytes(wav_data)
            return True
    except Exception as e:
        print(f"  [ERROR] TTS生成失敗: {e}", file=sys.stderr)
        return False


# --- WAV 結合 ---
def concatenate_wav_files(wav_paths: list[Path], output_path: Path) -> float:
    """複数の WAV ファイルを結合し、合計の長さ(秒)を返す"""
    if not wav_paths:
        return 0.0

    total_frames = 0
    with wave.open(str(output_path), "w") as out:
        for i, path in enumerate(wav_paths):
            try:
                with wave.open(str(path), "r") as w:
                    if i == 0:
                        out.setparams(w.getparams())
                    frames = w.readframes(w.getnframes())
                    out.writeframes(frames)
                    total_frames += w.getnframes()
            except Exception as e:
                print(f"  [WARN] WAV読み込みエラー: {path}: {e}", file=sys.stderr)

    if total_frames == 0:
        return 0.0

    with wave.open(str(output_path), "r") as w:
        return w.getnframes() / w.getframerate()


def get_wav_duration(path: Path) -> float:
    """WAV ファイルの長さ(秒)を返す"""
    try:
        with wave.open(str(path), "r") as w:
            return w.getnframes() / w.getframerate()
    except Exception:
        return 0.0


# --- 進捗管理 ---
def load_progress(audio_dir: Path) -> dict:
    progress_file = audio_dir / "tts_progress.json"
    if progress_file.exists():
        try:
            return json.loads(progress_file.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {"last_completed_tts_page": 0, "last_completed_fa_page": 0, "phase": ""}


def save_progress(audio_dir: Path, progress: dict):
    progress_file = audio_dir / "tts_progress.json"
    progress_file.write_text(json.dumps(progress, indent=2), encoding="utf-8")


def emit_progress(phase: str, page: int, total: int, status: str):
    print(f"PROGRESS:phase={phase},page={page},total={total},status={status}", flush=True)


# --- Phase 1: TTS 生成 ---
def phase_tts(book: dict, book_path: Path, args) -> bool:
    audio_dir = book_path.parent / "audio"
    audio_dir.mkdir(exist_ok=True)

    skip_types = set(args.skip_types.split(",")) if args.skip_types else DEFAULT_SKIP_TYPES
    progress = load_progress(audio_dir)
    last_done = progress.get("last_completed_tts_page", 0)

    pages = book["pages"]
    total = len(pages)

    print(f"[INFO] TTS生成開始: {total}ページ (page {last_done + 1} から再開)")

    for page in pages:
        if _interrupted:
            print("[INFO] 中断しました。")
            return False

        page_num = page["page_number"]
        if page_num <= last_done:
            continue

        emit_progress("tts", page_num, total, "generating")

        # 読み上げ対象ブロックを抽出
        segments = []
        for block in page["blocks"]:
            if not is_readable_block(block, skip_types):
                continue
            processed = preprocess_text(block["text"])
            if processed:
                segments.append((processed, block["id"]))

        if not segments:
            # 読み上げ対象なし → スキップ
            emit_progress("tts", page_num, total, "skipped")
            progress["last_completed_tts_page"] = page_num
            save_progress(audio_dir, progress)
            continue

        # チャンク構築
        chunks = build_chunks(segments)

        # 各チャンクの音声を生成
        chunk_wavs = []
        success = True
        for ci, chunk in enumerate(chunks):
            chunk_path = audio_dir / f"page_{page_num:03d}_chunk_{ci:03d}.wav"
            if not tts_generate(
                text=chunk["text"],
                server_url=args.server_url,
                model=args.model,
                voice=args.voice,
                ref_wav=args.ref_wav,
                output_path=chunk_path,
            ):
                success = False
                break
            chunk_wavs.append(chunk_path)

            if _interrupted:
                # チャンク途中で中断 → 中間ファイル削除
                for p in chunk_wavs:
                    p.unlink(missing_ok=True)
                print("[INFO] 中断しました。")
                return False

        if not success:
            # エラー → 中間ファイル削除して次のページへ
            for p in chunk_wavs:
                p.unlink(missing_ok=True)
            print(f"  [ERROR] Page {page_num}: TTS生成失敗", file=sys.stderr)
            emit_progress("tts", page_num, total, "error")
            continue

        # チャンクWAV結合 → ページWAV
        page_wav = audio_dir / f"page_{page_num:03d}.wav"
        if len(chunk_wavs) == 1:
            chunk_wavs[0].rename(page_wav)
        else:
            concatenate_wav_files(chunk_wavs, page_wav)
            for p in chunk_wavs:
                p.unlink(missing_ok=True)

        duration = get_wav_duration(page_wav)
        print(f"  Page {page_num}: {len(chunks)} chunks, {duration:.1f}s")
        emit_progress("tts", page_num, total, "done")

        # 進捗保存
        progress["last_completed_tts_page"] = page_num
        save_progress(audio_dir, progress)

    print(f"[INFO] TTS生成完了")
    return True


# --- Phase 2: Forced Alignment + 圧縮 ---
def phase_fa_compress(book: dict, book_path: Path, args) -> bool:
    audio_dir = book_path.parent / "audio"
    skip_types = set(args.skip_types.split(",")) if args.skip_types else DEFAULT_SKIP_TYPES
    progress = load_progress(audio_dir)
    last_fa_done = progress.get("last_completed_fa_page", 0)

    pages = book["pages"]
    total = len(pages)

    # Forced Alignment モデルをロード
    print("[INFO] Forced Alignment モデルをロード中...")
    try:
        from mlx_audio.stt import load as stt_load

        aligner = stt_load("mlx-community/Qwen3-ForcedAligner-0.6B-8bit")
        print("[INFO] FAモデルロード完了")
    except Exception as e:
        print(f"[ERROR] FAモデルロード失敗: {e}", file=sys.stderr)
        print("[INFO] FAをスキップして圧縮のみ実行します")
        aligner = None

    for page in pages:
        if _interrupted:
            # book.json を保存してから終了
            with open(book_path, "w", encoding="utf-8") as f:
                json.dump(book, f, ensure_ascii=False, indent=2)
            print("[INFO] 中断しました。book.json を保存しました。")
            return False

        page_num = page["page_number"]
        if page_num <= last_fa_done:
            continue

        page_wav = audio_dir / f"page_{page_num:03d}.wav"
        if not page_wav.exists():
            continue

        emit_progress("fa", page_num, total, "aligning")

        # 読み上げ対象ブロックのテキストを再構築
        segments = []
        for block in page["blocks"]:
            if not is_readable_block(block, skip_types):
                continue
            processed = preprocess_text(block["text"])
            if processed:
                segments.append((processed, block["id"]))

        if not segments:
            continue

        # Forced Alignment 実行
        if aligner is not None:
            full_text = "".join(text for text, _ in segments)

            # 文字→ブロックID マッピング構築
            char_to_block = []
            for text, block_id in segments:
                for _ in text:
                    char_to_block.append(block_id)

            try:
                result = aligner.generate(
                    str(page_wav), text=full_text, language="Japanese"
                )

                # タイムスタンプをブロックにマッピング
                block_times: dict[int, tuple[float, float]] = {}
                char_pos = 0
                for item in result:
                    item_text = item.text if hasattr(item, "text") else str(item)
                    item_len = len(item_text)
                    start_t = item.start_time if hasattr(item, "start_time") else 0.0
                    end_t = item.end_time if hasattr(item, "end_time") else 0.0

                    for offset in range(item_len):
                        abs_pos = char_pos + offset
                        if abs_pos < len(char_to_block):
                            bid = char_to_block[abs_pos]
                            if bid not in block_times:
                                block_times[bid] = (start_t, end_t)
                            else:
                                block_times[bid] = (
                                    min(block_times[bid][0], start_t),
                                    max(block_times[bid][1], end_t),
                                )
                    char_pos += item_len

                # book.json のブロックにタイムスタンプを書き込み
                for block in page["blocks"]:
                    bid = block["id"]
                    if bid in block_times:
                        block["audio_start"] = round(block_times[bid][0], 3)
                        block["audio_end"] = round(block_times[bid][1], 3)

                print(f"  Page {page_num}: FA完了 ({len(block_times)} blocks)")
            except Exception as e:
                print(
                    f"  [WARN] Page {page_num}: FA失敗: {e}",
                    file=sys.stderr,
                )
                # FA失敗時は文字数比率でフォールバック
                _fallback_timestamps(page, segments, audio_dir)
        else:
            # FAモデルなし → 文字数比率でフォールバック
            _fallback_timestamps(page, segments)

        # AAC M4A 圧縮
        page_m4a = audio_dir / f"page_{page_num:03d}.m4a"
        emit_progress("compress", page_num, total, "compressing")
        try:
            subprocess.run(
                [
                    "afconvert",
                    "-f", "m4af",
                    "-d", "aac",
                    "-c", "1",
                    "-b", "64000",
                    "-s", "3",
                    str(page_wav),
                    str(page_m4a),
                ],
                check=True,
                capture_output=True,
            )
            # audio_path を M4A に更新
            page["audio_path"] = f"audio/page_{page_num:03d}.m4a"
            # WAV を削除
            page_wav.unlink(missing_ok=True)
        except subprocess.CalledProcessError as e:
            print(
                f"  [WARN] Page {page_num}: AAC変換失敗: {e.stderr.decode()}",
                file=sys.stderr,
            )
            # WAV のまま使用
            page["audio_path"] = f"audio/page_{page_num:03d}.wav"

        emit_progress("fa", page_num, total, "done")

        # 進捗保存
        progress["last_completed_fa_page"] = page_num
        save_progress(audio_dir, progress)

    # book.json を保存
    with open(book_path, "w", encoding="utf-8") as f:
        json.dump(book, f, ensure_ascii=False, indent=2)

    print(f"[INFO] Forced Alignment + 圧縮完了")
    emit_progress("complete", total, total, "done")
    return True


def _fallback_timestamps(page: dict, segments: list[tuple[str, int]], audio_dir: Path | None = None):
    """FA失敗時のフォールバック: 文字数比率でタイムスタンプを推定"""
    page_num = page["page_number"]

    # WAV ファイルのパスを特定
    page_wav = None
    if audio_dir is not None:
        candidate = audio_dir / f"page_{page_num:03d}.wav"
        if candidate.exists():
            page_wav = candidate
    if page_wav is None:
        audio_path = page.get("audio_path")
        if audio_path:
            page_wav = Path(audio_path)
    if page_wav is None or not page_wav.exists():
        return

    total_chars = sum(len(text) for text, _ in segments)
    if total_chars == 0:
        return

    duration = get_wav_duration(page_wav)
    if duration <= 0:
        return

    current_time = 0.0
    block_id_to_text = {bid: text for text, bid in segments}
    for block in page["blocks"]:
        bid = block["id"]
        if bid in block_id_to_text:
            text_len = len(block_id_to_text[bid])
            block_duration = duration * (text_len / total_chars)
            block["audio_start"] = round(current_time, 3)
            block["audio_end"] = round(current_time + block_duration, 3)
            current_time += block_duration


# --- メイン ---
def main():
    parser = argparse.ArgumentParser(description="Irodori TTS バッチ音声生成")
    parser.add_argument("--book", type=str, required=True, help="book.json のパス")
    parser.add_argument(
        "--server-url", type=str, default=DEFAULT_SERVER_URL, help="mlx-audio サーバー URL"
    )
    parser.add_argument("--model", type=str, default=DEFAULT_MODEL, help="TTS モデル名")
    parser.add_argument("--voice", type=str, default="no-ref", help="voice パラメータ")
    parser.add_argument(
        "--ref-wav", type=str, default=None, help="リファレンス音声 WAV ファイルのパス"
    )
    parser.add_argument(
        "--phase",
        type=str,
        default="all",
        choices=["all", "tts", "fa-compress"],
        help="実行フェーズ",
    )
    parser.add_argument(
        "--skip-types",
        type=str,
        default=",".join(DEFAULT_SKIP_TYPES),
        help="スキップするブロックタイプ（カンマ区切り）",
    )
    args = parser.parse_args()

    book_path = Path(args.book).resolve()
    if not book_path.exists():
        print(f"[ERROR] book.json が見つかりません: {book_path}", file=sys.stderr)
        sys.exit(1)

    with open(book_path, encoding="utf-8") as f:
        book = json.load(f)

    print(f"[INFO] 本: {book.get('title', '不明')}")
    print(f"[INFO] ページ数: {len(book['pages'])}")
    print(f"[INFO] フェーズ: {args.phase}")
    if args.ref_wav:
        print(f"[INFO] リファレンス音声: {args.ref_wav}")

    if args.phase in ("all", "tts"):
        if not phase_tts(book, book_path, args):
            if _interrupted:
                print("[INFO] TTS生成が中断されました。次回 --phase tts で再開できます。")
                sys.exit(0)
            else:
                print("[WARN] TTS生成で一部エラーがありました。", file=sys.stderr)

    if args.phase in ("all", "fa-compress"):
        # book.json を再読み込み（TTS フェーズで更新された可能性）
        if args.phase == "all":
            with open(book_path, encoding="utf-8") as f:
                book = json.load(f)
        if not phase_fa_compress(book, book_path, args):
            if _interrupted:
                print(
                    "[INFO] FA/圧縮が中断されました。次回 --phase fa-compress で再開できます。"
                )
                sys.exit(0)

    print("[INFO] 全処理完了")


if __name__ == "__main__":
    main()
