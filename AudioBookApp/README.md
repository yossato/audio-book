# AudioBookApp

SwiftUI + AVFoundation で実装した macOS / iOS ネイティブオーディオブックアプリ

## 機能

### 画像ベースの本
- 📖 ページ画像表示 + OCR テキストブロックのバウンディングボックスオーバーレイ
- 🎵 音声再生（WAV ファイルまたはオンデマンド音声合成）
- 🖱️ テキストブロッククリック（macOS）/ タップ（iOS）で任意の位置から再生開始

### Markdown ベースの本
- 📄 Markdown ファイルを直接ライブラリに追加して読書・再生
- **見出し** (H1〜H6)、**段落**（インライン Markdown: 太字・斜体・リンク）、**コードブロック**、**引用**、**リスト**、**水平線**
- **テーブル** — ヘッダー太字・ゼブラ縞・角丸ボーダーで表示
- **Mermaid 図** — バンドル済み mermaid.js を WKUserScript でインジェクト（オフライン動作）
  - 構文エラー時は 💣 マーク + エラーメッセージを表示
- **インライン画像** (`![alt](path)`) をローカルファイルから表示

### 共通機能
- ⚡️ 再生速度変更（0.5x〜2.0x、ピッチ変化なし）
- 🎧 AirPods メディアキー対応（MPRemoteCommandCenter）
- 📱 macOS Control Center 連携（MPNowPlayingInfoCenter）
- 📄 ページスライダーで自由なページ移動（Kindle 風）
- 🔄 自動ページ送り（ページ末尾で次ページへ自動遷移）
- 📚 ライブラリ管理（複数の本を管理、読書位置を記憶）
- ⚙️ TYPE 別読み上げ設定（割注・キャプション等を個別にスキップ、UserDefaults に永続化）
- 🚫 OCR エラーパターン自動スキップ（同一文字連続・記号のみ等）
- 🔤 句読点単位での音声合成（改行またぎで自然なイントネーション）
- 🟠 句読点内でのブロックハイライト追従（`willSpeakRangeOfSpeechString` で文字位置を監視）
- 📲 iCloud Drive 対応 — iOS 実機で iCloud 内の book.json / 画像を読み込み
- 👆 iOS: スワイプでページ送り、ピンチズーム (1x〜5x)、ダブルタップでズームリセット
- 🖥️ iOS: タップで全画面トグル（コントロール / ステータスバーを非表示）

## ビルド方法

### 1. Xcode でビルド（推奨）

```bash
# Xcode でプロジェクトを開く
open AudioBookApp.xcodeproj
```

Xcode のメニューから **Product > Build (⌘B)** または **Product > Run (⌘R)** で直接実行。  
iOS 実機でビルドする場合は Scheme で対象デバイスを選択する。

### 2. コマンドラインでビルド（macOS）

```bash
cd /Users/yoshiaki/Projects/audio-book/AudioBookApp

# ビルドのみ
xcodebuild -project AudioBookApp.xcodeproj -scheme AudioBookApp \
  -destination 'platform=macOS' -configuration Debug build

# ビルド成果物の場所
# ~/Library/Developer/Xcode/DerivedData/AudioBookApp-*/Build/Products/Debug/AudioBookApp.app
```

## 起動方法

### 1. Xcode から起動

Xcode で **Product > Run (⌘R)**

### 2. コマンドラインから起動（macOS）

```bash
# ライブラリモードで起動（デフォルト）
open ~/Library/Developer/Xcode/DerivedData/AudioBookApp-*/Build/Products/Debug/AudioBookApp.app

# 特定の book.json を直接開く（--book モード）
open ~/Library/Developer/Xcode/DerivedData/AudioBookApp-*/Build/Products/Debug/AudioBookApp.app \
  --args --book /Users/yoshiaki/Projects/audio-book/book.json
```

### 3. ビルド成果物を直接実行

```bash
BUILD_DIR=$(ls -td ~/Library/Developer/Xcode/DerivedData/AudioBookApp-*/Build/Products/Debug 2>/dev/null | head -1)

# ライブラリモード
"$BUILD_DIR/AudioBookApp.app/Contents/MacOS/AudioBookApp"

# --book モード
"$BUILD_DIR/AudioBookApp.app/Contents/MacOS/AudioBookApp" --book /path/to/book.json
```

## 使い方

### ライブラリモード

1. アプリを起動すると、ライブラリ画面が表示される
2. 「+」ボタンで新しい本を追加
   - **画像フォルダ**: 選択 → OCR → TTS
   - **Markdown ファイル** (.md): 選択するとそのまま追加（OCR / TTS 不要）
3. 本をタップして読む
4. 読書位置は自動保存され、次回開いた時に復元される

### --book モード（単一ファイルモード、macOS のみ）

1. `--book` 引数で book.json を指定して起動
2. ライブラリを経由せず、直接ビューアが表示される
3. 読書位置は保存されない（一時的な閲覧用）

### ビューア操作

| 操作 | macOS | iOS |
|------|-------|-----|
| 再生/一時停止 | スペース / 再生ボタン / AirPods | 再生ボタン / AirPods |
| 前後ページ | 矢印キー / ボタン / スライダー | スワイプ / ボタン / スライダー |
| 任意の位置から再生 | テキストブロッククリック | テキストブロックタップ |
| 速度変更 | 右下の速度ピッカー | 右下の速度ピッカー |
| ズーム（画像ページ） | — | ピンチズーム / ダブルタップ |
| 全画面トグル | — | バックグラウンドタップ |
| 読み上げ設定 | タイトルバー右 ⚙ | タイトルバー右 ⚙ |

## プロジェクト構成

```
AudioBookApp/
├── AudioBookApp/
│   ├── AudioBookApp.swift               # @main エントリポイント
│   ├── Models/
│   │   ├── BookModel.swift              # Book, Page, TextBlock の Codable 構造体
│   │   ├── LibraryModel.swift           # ライブラリ用モデル (BookEntry)
│   │   ├── LibraryManager.swift         # ライブラリ管理 (library.json)
│   │   ├── MarkdownParser.swift         # Markdown → Book 変換パーサー
│   │   └── ReadingSettings.swift        # TYPE 別読み上げ設定 (UserDefaults 永続化)
│   ├── Audio/
│   │   └── AudioPlayerManager.swift     # AVAudioPlayer + AVSpeechSynthesizer + MediaPlayer
│   ├── Resources/
│   │   └── mermaid.min.js               # バンドル済み Mermaid.js（オフライン動作用、3.3MB）
│   └── Views/
│       ├── ContentView.swift            # ルート（ライブラリ or --book モード分岐）
│       ├── LibraryView.swift            # ライブラリ画面（本の一覧）
│       ├── AddBookView.swift            # 本の追加ワークフロー（OCR → TTS / Markdown）
│       ├── ViewerView.swift             # ビューア画面（ページ + コントロール）
│       ├── PageImageView.swift          # 画像 + バウンディングボックス
│       ├── PageMarkdownView.swift       # Markdown ブロックのリッチテキスト表示
│       ├── MermaidView.swift            # Mermaid 図レンダラー（WKWebView + WKUserScript）
│       ├── ZoomableContainer.swift      # iOS ピンチズーム / ダブルタップ
│       ├── PlayerControlsView.swift     # 再生コントロール + ページスライダー
│       └── ReadingSettingsView.swift    # 読み上げ設定 UI（popover）
└── AudioBookApp.xcodeproj/
```

## 依存フレームワーク

- SwiftUI (UI)
- AVFoundation (AVAudioPlayer, AVSpeechSynthesizer)
- MediaPlayer (MPRemoteCommandCenter, MPNowPlayingInfoCenter)
- WebKit (WKWebView — Mermaid 図レンダリング)

## システム要件

- macOS 15.0 (Sequoia) 以降 **または** iOS 17.0 以降
- Xcode 16.0 以降（ビルド時）
- Swift 6.0

## トラブルシューティング

### ビルドエラー: "xcodebuild: error: Unable to find a destination..."

Xcode の初回起動時にコマンドラインツールのインストールが必要です:

```bash
xcodebuild -runFirstLaunch
```

### 音声が再生されない

- `book.json` の `audio_path` が正しいか確認
- WAV ファイルが存在するか確認
- `audio_path` が null の場合、AVSpeechSynthesizer でオンデマンド合成される（初回は遅延あり）

### AirPods で操作できない

- macOS: 「システム設定 > Bluetooth」で AirPods が接続されているか確認
- 他のアプリ（Music, Spotify 等）が音声を占有していないか確認

### Mermaid 図が表示されない

- アプリバンドルに `mermaid.min.js` が含まれているか確認（Xcode の "Copy Bundle Resources" フェーズ）
- 構文エラーの場合は 💣 マーク + エラーメッセージが表示される
- macOS でスクロールが Mermaid 図の上で止まる場合は最新ビルドを使用（`PassThroughWKWebView` で修正済み）

### iOS でのiCloud Drive 画像が表示されない

- iCloud Drive の「AudioBookApp」フォルダに book.json とともに画像フォルダが存在するか確認
- book.json 内の `image_path` が相対パス（例: `pages/001.jpg`）になっているか確認
