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
| チャンクごとに話者（声質）が変わる | 高 | `voice: "no-ref"` だとランダム性あり。リファレンス音声の指定で統一可能か調査 |
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

## Phase 6: iPhone/iPad 対応

詳細は [DESIGN-iOS.md](DESIGN-iOS.md) を参照。
