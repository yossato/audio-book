# オーディオブックアプリ 設計ドキュメント

## 概要

PDF・画像・テキストファイルから OCR でテキストを抽出し、TTS で読み上げるオーディオブックアプリ。
読み上げ中のテキスト位置をハイライト表示し、クリックでそこから再生できる。

---

## Phase 1-3: MVP（完了）

PyQt6 ベースのプロトタイプ。単一ブックの OCR → TTS → ビューア再生を実現。

### MVP で実現したこと
- ndlocr-lite による OCR（テキスト + バウンディングボックス座標）
- macOS `say` コマンドによる TTS（ブロック単位タイムスタンプ付き）
- PyQt6 ビューア（画像表示、ハイライト同期、クリック再生、ページ送り）

### MVP で判明した課題
- 再生速度の変更ができない
- AirPods 等 Bluetooth ヘッドホンのメディアキー（一時停止）が効かない
- 再生中に Bluetooth デバイスを接続すると音声出力が切り替わらない
- 本が1冊しか管理できない

→ これらを解決するため、Phase 4 で SwiftUI ネイティブアプリに移行する。

---

## Phase 4: SwiftUI ネイティブアプリ + ライブラリ管理

### アーキテクチャ

```
┌──────────────────────────────────────────────────┐
│              SwiftUI アプリ (Mac native)            │
│                                                    │
│  ┌────────────┐      ┌─────────────────────┐     │
│  │ ライブラリ   │─────→│ ビューア画面          │     │
│  │ 画面        │      │                     │     │
│  │ - 表紙一覧  │      │ - 画像+ハイライト     │     │
│  │ - 進捗表示  │      │ - AVFoundation再生  │     │
│  │ - 本の追加  │      │ - 速度変更 0.5x-2x  │     │
│  └────────────┘      │ - メディアキー対応   │     │
│                       │ - Bluetooth自動切替  │     │
│                       └─────────────────────┘     │
└──────────────────────────────────────────────────┘
         ↕ library/ フォルダ + JSON を読み書き
┌──────────────────────────────────────────────────┐
│            Python バックエンド（既存を活用）          │
│                                                    │
│  scripts/ocr_process.py  → OCR 処理               │
│  scripts/tts_process.py  → TTS 処理               │
│                                                    │
│  SwiftUI アプリから Process として呼び出す            │
└──────────────────────────────────────────────────┘
```

### 技術スタック

| コンポーネント | 技術 | 備考 |
|-------------|------|------|
| OCR | ndlocr-lite (Python) | 既存スクリプトを Process で呼び出す |
| TTS | AVSpeechSynthesizer / Irodori TTS (MLX) | 設定で切替。Irodori は mlx-audio サーバー経由 |
| ビューア | SwiftUI + AVFoundation | Mac ネイティブ |
| 音声再生 | AVAudioPlayer | rate プロパティで速度変更 |
| メディアキー | MPRemoteCommandCenter | AirPods / Bluetooth 対応 |
| NowPlaying | MPNowPlayingInfoCenter | コントロールセンター連携 |
| データ保存 | JSON (フォルダベース) | library.json + 各ブックの book.json |
| 言語 | Swift (UI) + Python (バックエンド) | |

### 画面遷移

```
┌─────────────────────────────────┐
│          ライブラリ画面           │
│                                  │
│  ┌───────┐ ┌───────┐ ┌──────┐  │
│  │       │ │       │ │  +   │  │
│  │  表紙  │ │  表紙  │ │ 追加 │  │
│  │       │ │       │ │      │  │
│  └───────┘ └───────┘ └──────┘  │
│  シミュレー   別の本    新しい本   │
│  ションの基礎                    │
│  48P中 12Pまで読了               │
└─────────────────────────────────┘
          ↓ クリック
┌─────────────────────────────────┐
│  [← ライブラリ] シミュレーションの基礎  │
│  ┌─────────────────────────┐   │
│  │                         │   │
│  │    画像 + ハイライト      │   │
│  │                         │   │
│  └─────────────────────────┘   │
│  [◀] ▶/⏸ [▶]  速度: [1.0x ▼]  │
│  ────●──────────── 00:32/01:45  │
│  ページ 12 / 48                 │
└─────────────────────────────────┘
```

### ライブラリデータ構造

```
library/
├── library.json                    # ライブラリ全体のメタデータ
├── シミュレーションの基礎/
│   ├── book.json                   # ブックデータ（既存形式と同じ）
│   ├── cover.jpg                   # 表紙画像（1ページ目から自動生成）
│   ├── pages/                      # 元画像
│   │   ├── 20260324_000.jpg
│   │   └── ...
│   ├── audio/                      # 生成音声
│   │   ├── page_001.wav
│   │   └── ...
│   └── ocr_cache/                  # OCR 生出力
│       ├── 20260324_000.json
│       └── ...
├── 別の本/
│   ├── book.json
│   └── ...
```

#### `library.json`

```json
{
  "books": [
    {
      "id": "sim-basics-20260324",
      "title": "シミュレーションの基礎",
      "directory": "シミュレーションの基礎",
      "cover": "シミュレーションの基礎/cover.jpg",
      "page_count": 48,
      "last_read_page": 12,
      "last_read_position": 45.3,
      "status": "ready",
      "created_at": "2026-04-11"
    }
  ]
}
```

#### `status` の値

| 値 | 意味 |
|----|------|
| `importing` | 画像取り込み中 |
| `ocr_processing` | OCR 処理中 |
| `tts_processing` | TTS 処理中 |
| `ready` | 再生可能 |
| `error` | 処理中にエラーが発生 |

### 本の追加ワークフロー

```
1. 「+」ボタン → 画像フォルダを選択（NSOpenPanel）
2. タイトルを入力
3. library/ 配下にフォルダ作成、画像をコピー
4. Python スクリプトを Process で呼び出し:
   a. ocr_process.py → book.json 生成（プログレス表示）
   b. tts_process.py → 音声生成（プログレス表示）
5. cover.jpg を1ページ目から生成
6. library.json に追加、status を "ready" に
```

### book.json 形式（既存と同じ）

```json
{
  "title": "シミュレーションの基礎",
  "pages": [
    {
      "page_number": 1,
      "image_path": "pages/20260324_000.jpg",
      "audio_path": "audio/page_001.wav",
      "blocks": [
        {
          "id": 0,
          "text": "はじめに…本冊子の構成と狙い",
          "bbox": [1021, 518, 1909, 611],
          "confidence": 0.936,
          "is_vertical": true,
          "audio_start": 0.0,
          "audio_end": 2.8
        }
      ]
    }
  ]
}
```

注: `image_path` / `audio_path` は book.json からの相対パスに変更（ポータビリティ向上）。

### SwiftUI ビューア機能

| 機能 | 実装方法 |
|------|---------|
| 画像表示 + スケーリング | SwiftUI `Image` + `GeometryReader` |
| バウンディングボックス描画 | `Canvas` or `Path` オーバーレイ |
| ハイライト同期 | `AVAudioPlayer.currentTime` を Timer で監視 |
| クリック再生 | `onTapGesture` + 座標→ブロック逆引き |
| ページ切替 | `TabView` or カスタムページング |
| 再生速度変更 | `AVAudioPlayer.rate` (0.5〜2.0) |
| メディアキー対応 | `MPRemoteCommandCenter` |
| Bluetooth 切替 | `AVAudioSession` の routeChangeNotification |
| NowPlaying 表示 | `MPNowPlayingInfoCenter` |
| 読書位置の記憶 | `library.json` の `last_read_page` / `last_read_position` |

### 開発ステップ

#### Phase 4a: SwiftUI ビューア（単一ブック）✅ 完了
1. ✅ Xcode プロジェクト作成
2. ✅ book.json の読み込み
3. ✅ 画像表示 + バウンディングボックスオーバーレイ
4. ✅ AVAudioPlayer で音声再生 + ハイライト同期
5. ✅ 再生速度変更 (0.5x〜2.0x)
6. ✅ メディアキー / NowPlaying 対応
7. ✅ ページスライダー（Kindle 風）+ 前後ボタン
8. ✅ 音声シークバー削除（テキストブロッククリックで十分）

詳細は `AudioBookApp/README.md` を参照。

#### Phase 4b: ライブラリ管理 ✅ 完了
1. ✅ ライブラリ画面（表紙一覧）
2. ✅ library.json の読み書き
3. ✅ 本の追加ワークフロー（画像フォルダ選択 → OCR → TTS）
4. ✅ 読書位置の記憶・復元
5. ✅ 本の削除
6. ✅ オンデマンド音声合成（AVSpeechSynthesizer）- WAV なしでも再生可能

#### Phase 4c: 読み上げ品質向上 ✅ 完了
1. ✅ TYPE 別読み上げ設定（ReadingSettings + ReadingSettingsView）
   - ndlocr-lite の全 TYPE（本文・タイトル本文・割注・キャプション・広告文字・柱・ノンブル・ルビ・図版・組織図・数式・表組）を個別にスキップ可能
   - 設定は UserDefaults に永続化（デフォルト: 割注・キャプション・柱・ノンブル・ルビ・図版・広告文字をスキップ）
   - ビューアタイトルバーの ⚙ ボタンから popover で開く
2. ✅ OCR エラーパターン自動スキップ
   - 同一文字5回以上連続（例: `0,,0000000`）を読み飛ばす
   - 記号のみ構成される短いテキストを読み飛ばす
3. ✅ 句読点単位の音声合成
   - ブロック内の改行を除去して結合、句読点（。！？）単位で AVSpeechUtterance を分割
   - 改行を跨いでブロックを結合することで不自然な途切れを防止
4. ✅ 句読点内ハイライト追従
   - `SpeechGroup` に各ブロックの UTF-16 文字位置を記録
   - `willSpeakRangeOfSpeechString` デリゲートで発話中の文字位置からブロックを特定し `activeBlockId` をリアルタイム更新
   - 句読点内で行を跨いでもハイライトが正しいブロックに移動する

---

## テキストブロックのフィルタリング（✅ 実装済み）

ndlocr-lite の `TYPE` 属性と OCR エラー検出により、読み上げ不要なブロックを自動スキップする。
詳細は「Phase 4c」の実装内容を参照。

### 将来の課題: より高度なフィルタリング

| 課題 | 対策案 |
|------|-------|
| TYPE が付与されない旧形式の book.json | 位置ベース（上下端%）またはフォントサイズによる自動判定 |
| ユーザーが特定ブロックを手動で除外したい | ビューアで「このブロックをスキップ」を右クリックメニューから指定 |
| book.json に skip フラグを永続保存したい | 各ブロックに `"skip": true` を追加して保存 |

---

## Phase 5: Irodori TTS 統合 ✅ 基本動作確認済み

### 背景

Qwen3-TTSはメモリ消費と速度の問題で実用困難。Irodori TTS (MLX実装/mlx-audio) は Apple Silicon Mac で長文 RTF 0.96 を達成し、リアルタイム生成が可能。ただし短文(11文字)では RTF 2.76 と遅いため、テキストを大きな単位にまとめる戦略が必要。ストリーミングは未実装(`NotImplementedError`)のため、先読み生成(look-ahead)で対応する。

### アーキテクチャ

```
Swift App (AudioPlayerManager)
    │  HTTP POST /v1/audio/speech
    ▼
mlx-audio server (localhost:8000)  ← アプリが Process() で自動起動 or 外部起動を検出
    │  モデル常駐 (4.3GB)
    ▼
WAV レスポンス → temp file → AVAudioPlayer(rate変更で速度調整) で再生
```

- Irodori TTS 選択時、アプリが `Process()` で mlx-audio サーバーをサブプロセス起動
- 外部で既にサーバーが起動していればそれを使う（healthcheck で検出）
- `IrodoriTTSService` がサーバーライフサイクル・HTTP通信・キャッシュ・先読みを管理
- 速度制御: 生成は通常速度、再生時に AVAudioPlayer.rate で 0.5x〜2.0x 調整

### 実装内容

#### 1. Settings 追加
**ファイル**: `ReadingSettings.swift`

- `TTSEngine` enum: `.system`(AVSpeechSynthesizer) / `.irodori`(mlx-audio)
- `ttsEngine`, `irodoriServerURL`, `irodoriVenvPath` プロパティ (UserDefaults 永続化)

#### 2. Settings UI
**ファイル**: `ReadingSettingsView.swift`

- TTS エンジン選択 Picker (radioGroup)
- サーバー URL 入力フィールド
- Python venv パス選択 (NSOpenPanel)
- サーバー接続状態インジケーター

#### 3. IrodoriTTSService (新規)
**ファイル**: `Audio/IrodoriTTSService.swift`

- サーバー起動/停止 (`Process()` でサブプロセス管理)
- 外部起動サーバーの自動検出 (`checkHealth()`)
- ウォームアップ機能 (`warmup()`) - 初回モデルロードのトリガー
- POST `/v1/audio/speech` で音声生成 (タイムアウト 180秒)
- 生成済み WAV を temp ディレクトリにキャッシュ (テキストハッシュキー)
- 先読み生成 (pregenerate) - 逐次実行（サーバーは並列処理不可のため）

#### 4. テキストチャンキング (新規)
**ファイル**: `Audio/IrodoriChunkBuilder.swift`

- テキストブロックを句読点（。！？）で分割し、60〜200文字に結合
- `IrodoriBlockRange` (charOffset, blockId) を保持してハイライト追従を維持

#### 5. AudioPlayerManager Irodori モード追加

- チャンク単位で AVAudioPlayer を順次再生
- チャンク間シームレス遷移 (`audioPlayerDidFinishPlaying` → 次チャンク)
- ブロックハイライト: チャンク内文字位置比例で該当ブロックを特定
- 生成失敗時は再生停止（カスケード防止）

#### 6. 先読み (Look-ahead) 生成

- サーバー検出 → ウォームアップ → 現ページの全チャンクを逐次生成
- 再生中: 次チャンクが未生成なら待機（通常は先読み済み）
- ページ遷移時: 次ページのチャンクも先行生成

#### 7. Info.plist (ATS 設定)

- `NSAllowsLocalNetworking = true` を設定
- HTTP (非HTTPS) での localhost 接続を許可

### 開発中に判明した知見・注意点

#### mlx-audio サーバーの特性

| 項目 | 内容 |
|------|------|
| ストリーミング | **未実装** (`NotImplementedError`) - 先読みで対処 |
| 並列処理 | **不可** - リクエストは逐次処理される |
| 初回リクエスト | モデルロード (4.3GB) で **60〜120秒**かかる |
| 2回目以降 | モデル常駐のため高速 (RTF < 1.0) |
| API エンドポイント | `POST /v1/audio/speech` (OpenAI互換形式) |
| ヘルスチェック | `GET /v1/models` → 200 OK |
| 必須パッケージ | uvicorn, fastapi, webrtcvad, python-multipart, setuptools<81 |
| setuptools | v82 で `pkg_resources` 削除 → webrtcvad が壊れるため `<81` に固定 |

#### macOS アプリ開発の注意点

| 問題 | 原因 | 解決 |
|------|------|------|
| HTTP 接続がブロックされる | App Transport Security (ATS) | Info.plist に `NSAllowsLocalNetworking = true` |
| サンドボックス off でも ATS は有効 | ATS は URLSession レベルで適用 | Info.plist で例外設定が必要 |
| 60秒でタイムアウト | 初回モデルロードが遅い | タイムアウト 180秒 + ウォームアップ |
| 全チャンク同時送信でキュー詰まり | サーバーが逐次処理のため | pregenerate を逐次実行に変更 |
| 生成失敗時に高速スクロール | エラー → スキップ → 連鎖的に全チャンク失敗 | 失敗時は再生停止 |

#### サーバー起動方法

```bash
# venv のセットアップ (初回のみ)
cd /path/to/irodori-tts-experiment/mlx-impl
python -m venv .venv
source .venv/bin/activate
pip install mlx-audio uvicorn fastapi webrtcvad python-multipart "setuptools<81"

# サーバー起動 (モデルは初回リクエスト時に自動ダウンロード)
.venv/bin/python -m mlx_audio.server --port 8000

# 動作確認
curl -X POST http://localhost:8000/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"mlx-community/Irodori-TTS-500M-v2-fp16","input":"テスト","voice":"no-ref","response_format":"wav"}' \
  --output test.wav
```

### Irodori TTS 性能参考値 (M3 / 16GB)

| テキスト | 文字数 | 処理時間 | 音声長 | RTF | メモリ |
|---------|-------|---------|-------|-----|-------|
| 短文 | 11 | 10.8s | 3.9s | 2.76 | 4.31GB |
| 中文 | 34 | 11.4s | 9.7s | 1.17 | 4.31GB |
| 長文 | 66 | 11.5s | 12.0s | 0.96 | 4.31GB |

### 残課題

| 課題 | 優先度 | 備考 |
|------|--------|------|
| ~~チャンクごとに話者（声質）が変わる~~ | ~~高~~ | ✅ Phase 8 で解決（ref-wav サポート追加） |
| ウォームアップ中のUI表示 | 中 | 「モデル読み込み中...」の表示があると親切 |
| サーバー自動起動の安定性 | 中 | venv パスの設定ミス時のエラーメッセージ改善 |
| チャンク間の無音ギャップ | 低 | チャンク末尾の無音トリムで改善可能 |
| ページ遷移時の先読みキャンセル | 低 | 不要になった先読みタスクのキャンセル |

---

## 既存の Python スクリプト（引き続き使用）

### OCR 処理

```bash
source venv/bin/activate
python scripts/ocr_process.py --input <画像ディレクトリ> --output book.json [--title "タイトル"]
```

### TTS 処理

```bash
python scripts/tts_process.py --book book.json [--voice Kyoko] [--rate 200] [--start-page N] [--end-page N]
```

### PyQt6 ビューア（MVP、引き続き利用可能）

```bash
python viewer/app.py --book book.json
```

---

## Phase 7: バッチIrodori TTS音声生成 + Forced Alignment

### 背景

Irodori TTSによるリアルタイム音声生成はMacの負荷が高く実用的でないため、電源接続した状態で夜間にバッチ処理する方式に変更する。生成した音声にはForced Alignmentでタイムスタンプを付与し、テキストのバウンディングボックスをクリックした位置から再生できるようにする。

### 全体フロー

```
ユーザーが本カードを右クリック → "Irodori TTSで音声を生成"
  ↓
Phase 1: mlx-audioサーバー起動 → TTSでページ単位WAV生成
  ↓  (各ページ完了時にtts_progress.json更新 = 中断安全)
Phase 2: サーバー停止(メモリ解放) → Qwen3-ForcedAlignerでタイムスタンプ生成
  ↓
Phase 3: afconvertでWAV → AAC M4A (mono, 64kbps) 変換 → book.json更新
  ↓
完了: BookStatus → .ready
```

メモリ制約(16GB)のため、TTSモデルとFAモデルを同時にロードしない。Phase 1完了後にサーバーを停止してからPhase 2を開始する。

### アーキテクチャ

#### Pythonスクリプト `scripts/irodori_tts_batch.py`

Swiftアプリから `runProcessAsync()` で呼び出されるバッチ処理スクリプト。

```bash
# TTS生成のみ（Swiftアプリがサーバーを起動済み）
python scripts/irodori_tts_batch.py --book book.json --phase tts

# Forced Alignment + AAC圧縮（サーバー停止後に実行）
python scripts/irodori_tts_batch.py --book book.json --phase fa-compress

# リファレンス音声で話者固定
python scripts/irodori_tts_batch.py --book book.json --ref-wav ref.wav
```

- ページ単位で音声生成（ブロックテキストを60-200文字チャンクに結合、IrodoriChunkBuilderと同じロジック）
- `tts_progress.json` で進捗管理（中断→再開対応）
- `PROGRESS:phase=tts,page=3,total=150,status=done` 形式でSwiftアプリに進捗通知
- Forced Alignment: `mlx_audio.stt.load("mlx-community/Qwen3-ForcedAligner-0.6B-8bit")` で単語レベルタイムスタンプ取得
- 圧縮: `afconvert -f m4af -d aac -c 1 -b 64000` (mono, 64kbps)

#### Swift側の変更

| ファイル | 変更内容 |
|---------|---------|
| `LibraryManager.swift` | `generateBatchTTS()` / `cancelTTS()` メソッド追加。`addBook()` パターンに倣い `Task.detached` + `runProcessAsync` で実行 |
| `LibraryView.swift` | BookCardのコンテキストメニューに「Irodori TTSで音声を生成」/「キャンセル」追加。進捗オーバーレイ表示 |
| `ReadingSettings.swift` | `irodoriRefWavPath` プロパティ追加（話者固定用リファレンス音声パス） |
| `ReadingSettingsView.swift` | リファレンス音声ファイル選択UI追加 |

#### 変更不要な箇所

- `AudioPlayerManager.swift` : `AVAudioPlayer` はM4A/AACネイティブ対応。`seekToBlock()` は既存の `audioStart` を使用
- `PageImageView.swift` : `onBlockTapped` コールバックは既に接続済み
- `BookModel.swift` : `audioStart`/`audioEnd` フィールドは定義済み
- `LibraryModel.swift` : `BookStatus.ttsProcessing` は定義済み

### 話者固定

- Irodori-TTS v2: `--ref-wav` でゼロショット声質クローニング対応
- VoiceDesign v2: 別モデル (`Irodori-TTS-VoiceDesign-500M-v2`) でテキスト記述による音声制御
- 初期実装は `no-ref` (ランダム) をデフォルトとし、リファレンス音声指定をオプションで提供

### Forced Alignment (Qwen3-ForcedAligner)

```python
from mlx_audio.stt import load
aligner = load("mlx-community/Qwen3-ForcedAligner-0.6B-8bit")
result = aligner.generate("audio.wav", text="テキスト", language="Japanese")
for item in result:
    print(f"[{item.start_time:.2f}s - {item.end_time:.2f}s] {item.text}")
```

- 日本語対応、単語レベルタイムスタンプ出力
- 各単語の時間範囲をbook.jsonの各ブロックの文字位置にマッピング → `audio_start`/`audio_end` に設定
- **依存パッケージ**: 日本語トークナイズに `nagisa` が必要 (`pip install nagisa`)

### 実装上の知見・注意点

#### venv の追加依存

Forced Alignment の日本語対応には以下のパッケージが追加で必要:

```bash
uv pip install --python /path/to/.venv/bin/python nagisa
```

`nagisa` がないと `ImportError: Japanese tokenization requires nagisa` で FA が失敗する。
FA 失敗時は文字数比率によるフォールバックタイムスタンプが使用される。

#### バッチ TTS 中にビューアを操作する場合

`ViewerView.onDisappear` で `IrodoriTTSService.shared.stopServer()` が呼ばれるため、
バッチ TTS 実行中に本を開いて閉じるとサーバーが停止し、残りのページの TTS 生成が失敗する。
対策として `libraryManager.ttsGeneratingBookId != nil` の場合はサーバーを停止しないようにした。

#### 生成結果の実測値 (M3 MacBook Air / 16GB, 「吾輩は猫である」4ページ)

| ページ | チャンク数 | 音声長 | M4Aサイズ |
|--------|-----------|--------|----------|
| 1 | 1 | 5.2s | 38KB |
| 2 | 3 | 60.7s | 500KB |
| 3 | 2 | 45.3s | 396KB |
| 4 | 1 | - | 247KB |

- AAC mono 64kbps で十分な音質（人の読み上げ声）
- WAV (48kHz) → M4A 変換で大幅にサイズ削減
- `AVAudioPlayer` は M4A をネイティブ再生可能（コード変更不要）

#### タスクバーからの起動

タスクバー (Dock) から起動すると環境変数 `PATH` が制限されるため、
venv の Python が見つからずサーバー起動に失敗する場合がある。
ターミナルから直接起動するか、Xcode デバッグ実行が確実。

#### 中断・再開

- `tts_progress.json` に `last_completed_tts_page` / `last_completed_fa_page` を記録
- SIGTERM / SIGINT を受信すると現在のページ完了後に安全に停止
- 再実行時は完了済みページを自動スキップ

---

## Phase 6: iPhone/iPad 対応

詳細は [DESIGN-iOS.md](DESIGN-iOS.md) を参照。

---

## Phase 8: Irodori TTS 声の一貫性調査 (2026-05-10)

### 問題

Irodori TTS でバッチ音声生成すると、チャンクごとに声質（話者）が変わってしまう。
同じ本の中で統一された声で読み上げたい。

### 原因

Irodori TTS は拡散モデル（Rectified Flow Diffusion Transformer）をベースとしている。
生成時にランダムなガウスノイズから音声を合成するため、リファレンス音声なしの `voice: "no-ref"` では
毎回異なる話者特性の音声が生成される。これは**バグではなく仕様**である。

現在の実装箇所:
- `IrodoriTTSService.swift:196-201` — リアルタイム再生時に `"voice": "no-ref"` をハードコード
- `irodori_tts_batch.py:174` — バッチ生成時に `ref_wav` が未設定なら `"no-ref"` を使用

### Irodori TTS にはプリセットがない

Kokoro TTS（hexgrad）は 54 個の声プリセット（`af_heart`, `jf_alpha` 等）を持つが、
Irodori TTS（Aratako）にはそのような固定プリセットは存在しない。

| モデル | プリセット | リファレンス音声 | 声の一貫性 | 日本語品質 |
|--------|-----------|----------------|-----------|-----------|
| Irodori TTS v2 (現行) | なし | ゼロショットクローニング対応 | ref-wav必須 | 高（日本語特化） |
| Kokoro TTS | 54個 | なし | プリセットで安定 | 中（多言語） |
| Irodori VoiceDesign v2 | なし（テキスト記述） | なし | 中程度 | 高 |

### 声を固定する方法

#### 方法1: リファレンス音声（ref-wav）— 推奨

5-10秒の音声サンプルを指定すると、そのサンプルの声質をクローニングして一貫した音声を生成する。

- **バッチスクリプト**: `--ref-wav` フラグで既にサポート済み
- **リアルタイム再生**: `IrodoriTTSService.swift` が `irodoriRefWavPath` を使用していない（**要修正**）
- **UI**: `ReadingSettingsView.swift` にファイル選択UI実装済み

```bash
python scripts/irodori_tts_batch.py --book book.json --ref-wav path/to/voice_sample.wav
```

#### 方法2: 固定シード（rng_seed）

mlx-audio の `sampling.py` は `rng_seed` パラメータをサポートしている。
`mx.random.seed(rng_seed)` で初期ノイズを固定すれば、同じテキスト・同じシードで同じ声になる。
ただし `/v1/audio/speech` API がこのパラメータを転送しているか未確認。

#### 方法3: VoiceDesign variant + caption

別モデル `Aratako/Irodori-TTS-500M-v2-VoiceDesign` を使い、
テキストで声質を記述する（例: `"落ち着いた、近い距離感の女性話者"`）。
拡散プロセスのランダム性は残るため、完全な一貫性は得られない。

### 発見されたバグ

#### 1. IrodoriTTSService がリファレンス音声を使っていない

`IrodoriTTSService.swift:196-201` で `voice` が `"no-ref"` にハードコードされており、
`ReadingSettings.shared.irodoriRefWavPath` が設定されていても無視される。

```swift
// 現在（バグ）
let body: [String: Any] = [
    "model": "mlx-community/Irodori-TTS-500M-v2-fp16",
    "input": text,
    "voice": "no-ref",  // ← irodoriRefWavPath を使っていない
    "response_format": "wav",
]
```

#### 2. 再生モード選択で Say コマンドを選べない

`AudioPlayerManager.loadAudio()` では、事前生成済み音声ファイル（M4A）が存在する場合、
TTS エンジン設定に関係なく必ず WAV モードで再生する。
そのため `ttsEngine = .system`（Say コマンド）を選択しても、
音声ファイルがある本ではリアルタイム合成に切り替えることができない。

```swift
// 現在のロジック（line 85-125）
func loadAudio(url: URL?, blocks: [TextBlock]) {
    if let url, FileManager.default.fileExists(atPath: url.path) {
        // ← 音声ファイルが存在すれば無条件でWAVモード
        // ttsEngine の設定は確認しない
    } else if loadIrodoriIfNeeded(blocks: blocks) {
        // Irodori モード
    } else {
        // Say コマンドモード
    }
}
```

### 修正内容 (✅ 完了)

#### 1. ref-wav 改善

`IrodoriTTSService.swift` の `requestGeneration()` を修正し、`ReadingSettings.shared.irodoriRefWavPath` が設定されている場合はそのパスを `voice` パラメータに渡すようにした。

```swift
// 修正後
let refWavPath = ReadingSettings.shared.irodoriRefWavPath
let voice = refWavPath.isEmpty ? "no-ref" : refWavPath
let body: [String: Any] = [
    "model": "mlx-community/Irodori-TTS-500M-v2-fp16",
    "input": text,
    "voice": voice,
    "response_format": "wav",
]
```

#### 2. 再生ソース選択

`ReadingSettings` に `usePreGeneratedAudio: Bool` プロパティを追加（デフォルト: `true`）。
`AudioPlayerManager.loadAudio()` でこの設定を参照し、オフの場合は事前生成済み音声があっても Say コマンドで再生する。

設定 UI: `ReadingSettingsView` の「再生音声」セクションに「生成済み音声を使用」トグルを追加。

---

## Phase 9: Markdown ファイル対応 ✅ 完了

### 背景

AI エージェントとの協業で生成される Markdown ドキュメントを読み上げたいニーズがあるため、
`.md` ファイルを画像ベースの本と同様にインポート・表示・TTS 再生できるようにした。

### データモデル変更

#### BookModel.swift

| 変更 | 内容 |
|------|------|
| `TextBlock.bbox` | `[Double]` → `[Double]?` (Markdown ブロックには bbox なし) |
| `Page.imagePath` | `String` → `String?` (Markdown ページには画像なし) |
| `Page.contentType` | 新規 `String?` (`"image"` or `"markdown"`) |
| `Page.isMarkdownPage` | 新規 computed property |
| `TextBlock.markdownType` | 新規 `String?` (`"heading"`, `"paragraph"`, `"list_item"`, `"code_block"`, `"blockquote"`) |
| `TextBlock.headingLevel` | 新規 `Int?` (1-6) |
| `TextBlock.rawMarkdown` | 新規 `String?` (表示用の元 Markdown テキスト) |

既存の book.json との後方互換性は `decodeIfPresent` で維持。

### MarkdownParser (新規: `Models/MarkdownParser.swift`)

`.md` ファイルを `Book` 構造体に変換するパーサー。

```
parse(fileURL, title) → Book
  1. ファイル読み込み
  2. `\n## ` で分割 → 各セクションが1ページ
  3. 最初の ## 前のコンテンツ → ページ0（イントロ）
  4. 各セクション内のパラグラフ → TextBlock
```

ブロック種別マッピング:

| Markdown 要素 | type | markdownType |
|---|---|---|
| `#`〜`######` 見出し | `"タイトル本文"` | `"heading"` |
| 通常段落 | `"本文"` | `"paragraph"` |
| リスト項目 | `"本文"` | `"list_item"` |
| コードブロック | `"コードブロック"` | `"code_block"` |
| 引用 | `"本文"` | `"blockquote"` |

- `bbox` は全て `nil`、`confidence` は `1.0`、`isVertical` は `false`
- `text` にプレーンテキスト（TTS 用、インライン Markdown 記法を除去）
- `rawMarkdown` に元の Markdown（表示用）

### PageMarkdownView (新規: `Views/PageMarkdownView.swift`)

Markdown ページ専用のリッチテキスト表示ビュー。

- `ScrollViewReader` + `ScrollView` で縦スクロール
- ブロック種別に応じたレンダリング:
  - 見出し: `headingLevel` に応じたフォントサイズ・太字
  - 段落: `AttributedString(markdown:)` でインライン装飾（太字・斜体・コード・リンク）
  - コードブロック: モノスペースフォント + グレー背景
  - 引用: 左ボーダー + インデント + セカンダリカラー
  - リスト項目: `•` プレフィックス + インデント
- アクティブブロック: `Color.yellow.opacity(0.3)` 背景ハイライト
- `activeBlockId` 変更時に `.scrollTo(id, anchor: .center)` で自動スクロール
- ブロックタップ → `onBlockTapped` → `seekToBlock` で再生位置ジャンプ
- 背景タップ → `onBackgroundTapped` → 全画面トグル

### インポートフロー

#### AddBookView.swift (macOS)

- `InputSource` enum で「画像フォルダ（OCR）」と「Markdown ファイル」を切替
- Segmented Picker で入力形式選択
- Markdown 選択時は `.md` ファイル用の `NSOpenPanel` を表示
- Python 設定セクションは画像モード時のみ表示

#### LibraryManager.swift

`addMarkdownBook(title:sourceFile:onComplete:)` メソッド追加:
1. ブックディレクトリ作成
2. `.md` ファイルをコピー
3. `MarkdownParser.parse()` で `Book` 生成 → `book.json` 書き出し
4. テキストベースのカバー画像生成（青背景 + 📄 + タイトル、200×280px JPEG）
5. `BookEntry` をライブラリに追加

### TTS 互換性

既存の TTS パイプラインは変更不要:
- `AudioPlayerManager`: `text`, `id`, `audioStart/End` のみ使用
- `irodori_tts_batch.py`: `block["text"]`, `block["type"]`, `block["id"]` のみ参照
- `IrodoriChunkBuilder`: `TextBlock.text` のみ使用
- `ReadingSettings.shouldRead()`: Markdown テキストでは OCR エラー誤検出なし

---

## Phase 10: iPhone UI 改善 ✅ 完了

### 実装内容

#### 1. スワイプでページ送り (iOS)

`ViewerView.swift` で iOS 向けに `TabView(.page)` を使用:
- `TabView(selection: $currentPageIndex)` でページコンテンツをラップ
- `.tabViewStyle(.page(indexDisplayMode: .never))` でドットインジケーター非表示
- `.onChange(of: currentPageIndex)` でオーディオ読み込み・位置保存
- macOS は既存のキーボードショートカット（←→）のため変更なし

#### 2. ピンチズーム (iOS) — 新規: `Views/ZoomableContainer.swift`

- `MagnificationGesture` でピンチズーム（1.0x〜5.0x）
- ズーム中は `DragGesture` でパン操作
- ダブルタップで 2.5x ズーム / リセット切替
- ページ変更時に自動リセット
- `scale > 1.0` 時のみパン操作を有効化（TabView スワイプと競合しない）

#### 3. タップで全画面トグル

- `@State private var isFullscreen = false` を `ViewerView` に追加
- `isFullscreen` 時にタイトルバーと `PlayerControlsView` を非表示
- iOS: `.statusBarHidden(isFullscreen)` でステータスバーも非表示
- `PageImageView` / `PageMarkdownView` の `onBackgroundTapped` で発火
- バウンディングボックス/テキストブロック以外の領域タップで動作

### ファイル変更一覧

| ファイル | 変更内容 |
|---------|---------|
| `Views/ViewerView.swift` | TabView スワイプ (iOS)、全画面トグル、pageContent() 抽出 |
| `Views/PageImageView.swift` | optional bbox ガード、`onBackgroundTapped` コールバック追加 |
| `Views/ZoomableContainer.swift` | 新規ファイル |
