# 実装ノート

## 環境

- macOS (Darwin 25.3.0, Apple Silicon)
- Python 3.10.16 (pyenv)
- 仮想環境: `venv/` (プロジェクトルート直下)

## ndlocr-lite

### インストール

- `git clone` → `pip install -r requirements.txt` で完了
- モデルファイル (ONNX) はリポジトリに同梱されている（git clone に時間がかかる原因）
- `pyproject.toml` に `ndlocr-lite` コマンドとして登録されているが、今回は `python src/ocr.py` で直接実行

### 実行方法

```bash
cd ndlocr-lite/src
python ocr.py --sourcedir <画像ディレクトリ> --output <出力先> [--viz True]
```

- `--sourceimg` で単一画像も指定可能
- `--viz True` でバウンディングボックスを描画した画像を出力（`viz_*.jpg`）
- `--device cpu` がデフォルト（`cuda` もベータ対応）

### 処理速度

- Apple Silicon (M系) の CPU で 1画像あたり約1秒
- 3枚の写真 (3024x4032 JPEG) を合計約3秒で処理

### 出力形式

1画像につき3ファイルを出力:

- `*.json` - テキスト + バウンディングボックス + 画像メタ情報
- `*.xml` - XML形式のOCR結果
- `*.txt` - テキストのみ

**JSON出力の構造:**
```json
{
  "contents": [
    [
      {
        "boundingBox": [[x1,y1], [x1,y2], [x2,y1], [x2,y2]],
        "id": 0,
        "isVertical": "true",
        "text": "認識されたテキスト",
        "isTextline": "true",
        "confidence": 0.936
      }
    ]
  ],
  "imginfo": {
    "img_width": 3024,
    "img_height": 4032,
    "img_path": "元画像のパス",
    "img_name": "ファイル名"
  }
}
```

**boundingBox の座標形式:**
- 4隅の座標: `[[左上x, 左上y], [左下x, 左下y], [右上x, 右上y], [右下x, 右下y]]`
- ピクセル単位（元画像の解像度基準）
- `book.json` では `[x1, y1, x2, y2]`（左上、右下）に正規化して格納

### OCR精度

- iPhoneで撮影した本のページ写真（斜め・影あり）に対して実行
- **良い点**: テキスト行の検出・バウンディングボックスは正確
- **課題**: 写真の品質（斜め撮影、影、ピンボケ）に精度が左右される
  - 例: 「シミュレーション」→「シイクレーション」、「中学生や高校生の皆様」→「モンジ。アや高校生の管様」
  - スキャン画像や正面から撮った高品質な写真であれば精度は大幅に向上すると思われる
- `confidence` 値が各テキスト行について返される（0.8〜0.95程度）
- `isVertical` フラグで縦書き/横書きの判定結果も返される

### その他の所見

- 内部的に3段階のカスケード認識（文字数30/50/100）を行っている
- レイアウト認識 (DEIMv2) → 文字列認識 (PARSeq) → 読み順整序の3ステップ
- 読み順は XML 上の `reading_order` モジュールで推定される
- 縦書きが半数以上のページでは読み順が逆転される処理あり

## book.json

### 生成結果

- 3ページ、合計82テキストブロック
- `audio_start` / `audio_end` は TTS 処理後に埋める（現在 `null`）
- `confidence` と `is_vertical` フィールドを追加（DESIGN.md の仕様にはなかったが有用）

### DESIGN.md からの変更点

- `book.json` に `confidence` フィールドを追加（OCR の信頼度）
- `book.json` に `is_vertical` フィールドを追加（縦書き判定）
- `image_path` は絶対パスで格納（将来的に相対パスに変更すべきかもしれない）

## Phase 2: TTS (macOS say)

### 方針

- MVP では macOS 標準の `say` コマンドを使用（インストール不要、依存ゼロ）
- 音声品質を上げたい場合は Qwen3-TTS 等に差し替え可能な設計

### 実行方法

```bash
python scripts/tts_process.py --book book.json [--voice Kyoko] [--rate 200]
```

### 利用可能な日本語音声

macOS に9種類の日本語音声が搭載:
Kyoko, Eddy, Flo, Grandma, Grandpa, Reed, Rocko, Sandy, Shelley

### タイムスタンプの生成方法

1. テキストブロックごとに個別に `say -o` で AIFF 生成
2. `afconvert` で WAV に変換（macOS 標準ツール）
3. Python `wave` モジュールで音声長を取得
4. ブロックの音声長を積算して `audio_start` / `audio_end` を算出
5. 全ブロックの WAV を結合してページ単位の音声ファイルを生成

### 生成結果

| ページ | ブロック数 | 音声長 | ファイルサイズ |
|--------|-----------|--------|--------------|
| Page 1 | 29 | 140.6秒 | 5.9MB |
| Page 2 | 25 | 127.0秒 | 5.3MB |
| Page 3 | 28 | 139.5秒 | 5.9MB |

- 音声フォーマット: WAV, 22050Hz, 16bit mono
- `book.json` にタイムスタンプが正常に書き込まれることを確認

### 所見

- `say` コマンドは OCR の誤認識テキストもそのまま読み上げる（当然だが気になるポイント）
- 読み上げ速度は `--rate` で調整可能（デフォルト200 wpm）
- ブロック間にポーズがないため、連続して読み上げられる（自然さの点では改善余地あり）
- 将来的にブロック間に短い無音を挿入する処理を追加してもよい

## Phase 3: ビューア (PyQt6)

### 実行方法

```bash
source venv/bin/activate
python viewer/app.py --book book.json
```

### 依存

- PyQt6 6.10.2（`pip install PyQt6` でインストール）
- QMediaPlayer + QAudioOutput で音声再生（FFmpeg バックエンド）

### 実装した機能

- 画像表示: ウィンドウサイズに合わせて自動スケーリング、座標変換も連動
- バウンディングボックス: 全ブロックに薄い青枠、アクティブブロックは黄色ハイライト + オレンジ枠
- ハイライト同期: 50ms 間隔のタイマーで再生位置を監視し、対応ブロックをハイライト
- クリック再生: テキストブロックをクリック → `audio_start` の位置から再生開始
- ページ切替: 前/次ページボタン
- 自動ページ送り: ページ末尾到達で自動的に次ページへ移行し再生継続
- シークバー: ドラッグで任意位置にジャンプ
- 時間表示: `MM:SS / MM:SS` 形式で現在位置と全体時間を表示

### 技術的な所見

- 画像スケーリング: `QPixmap.scaled()` で KeepAspectRatio + SmoothTransformation
- 座標変換: `scale = scaled_width / original_width` で元画像座標をスケーリング
- フォント: macOS では `Menlo` を指定（`monospace` だと警告が出る）
- QMediaPlayer は FFmpeg 7.1.2 をバックエンドとして使用（PyQt6 に同梱）

### 改善候補（MVP後）

- ウィンドウリサイズ時の再描画最適化（現在は毎回全描画）
- キーボードショートカット（スペースで再生/一時停止など）
- 再生速度変更
- 縦書き/横書きで異なるハイライトスタイル

## Phase 4b: TODO / 課題メモ

### OCR 処理中のプログレス表示（優先度: 中）

- 本の追加時に OCR が長時間かかる（大量ページだと数分〜十数分）
- 現在は「OCR 処理中...」という静的テキストのみでフリーズしているか分からない
- 改善案:
  - `ocr_process.py` がページ毎に進捗を標準出力する（`[INFO] page 1/48 done` など）
  - `LibraryManager.addBook` の `onProgress` コールバックで受け取り `AddBookView` に表示
  - プログレスバー（`ProgressView(value: progress, total: 1.0)`）を追加
  - または処理済みページ数をカウントして「12 / 48ページ処理中」と表示
- 参考: `xcodebuild -project ...` の出力と同様に行単位でストリーミング受信できる
