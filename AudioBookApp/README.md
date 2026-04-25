# AudioBookApp

SwiftUI + AVFoundation で実装した macOS ネイティブオーディオブックアプリ

## 機能

- 📖 ページ画像表示 + OCR テキストブロックのバウンディングボックスオーバーレイ
- 🎵 音声再生（WAV ファイルまたはオンデマンド音声合成）
- ⚡️ 再生速度変更（0.5x〜2.0x、ピッチ変化なし）
- 🎧 AirPods メディアキー対応（MPRemoteCommandCenter）
- 📱 macOS Control Center 連携（MPNowPlayingInfoCenter）
- 🖱️ テキストブロッククリックで任意の位置から再生開始
- 📄 ページスライダーで自由なページ移動（Kindle 風）
- 🔄 自動ページ送り（ページ末尾で次ページへ自動遷移）
- 📚 ライブラリ管理（複数の本を管理、読書位置を記憶）

## ビルド方法

### 1. Xcode でビルド（推奨）

```bash
# Xcode でプロジェクトを開く
open AudioBookApp.xcodeproj

# Xcode のメニューから Product > Build (⌘B)
# または Product > Run (⌘R) で直接実行
```

### 2. コマンドラインでビルド

```bash
cd /Users/yoshiaki/Projects/audio-book/AudioBookApp

# ビルドのみ
xcodebuild -project AudioBookApp.xcodeproj -scheme AudioBookApp -configuration Debug build

# ビルド成果物の場所
# ~/Library/Developer/Xcode/DerivedData/AudioBookApp-*/Build/Products/Debug/AudioBookApp.app
```

## 起動方法

### 1. Xcode から起動

Xcode で Product > Run (⌘R)

### 2. コマンドラインから起動

```bash
# ライブラリモードで起動（デフォルト）
open ~/Library/Developer/Xcode/DerivedData/AudioBookApp-*/Build/Products/Debug/AudioBookApp.app

# 特定の book.json を直接開く（--book モード）
open ~/Library/Developer/Xcode/DerivedData/AudioBookApp-*/Build/Products/Debug/AudioBookApp.app \
  --args --book /Users/yoshiaki/Projects/audio-book/book.json
```

### 3. ビルド成果物を直接実行

```bash
# ビルド成果物のパスを取得
BUILD_DIR=$(ls -td ~/Library/Developer/Xcode/DerivedData/AudioBookApp-*/Build/Products/Debug 2>/dev/null | head -1)

# 実行（ライブラリモード）
"$BUILD_DIR/AudioBookApp.app/Contents/MacOS/AudioBookApp"

# 実行（--book モード）
"$BUILD_DIR/AudioBookApp.app/Contents/MacOS/AudioBookApp" --book /Users/yoshiaki/Projects/audio-book/book.json
```

## 使い方

### ライブラリモード

1. アプリを起動すると、ライブラリ画面が表示される
2. 「+」ボタンで新しい本を追加（画像フォルダを選択 → OCR → TTS）
3. 本をクリックして読む
4. 読書位置は自動保存され、次回開いた時に復元される

### --book モード（単一ファイルモード）

1. `--book` 引数で book.json を指定して起動
2. ライブラリを経由せず、直接ビューアが表示される
3. 読書位置は保存されない（一時的な閲覧用）

### ビューア操作

- **再生/一時停止**: スペースキー or 再生ボタン or AirPods メディアキー
- **ページ移動**:
  - 前後ボタン or 矢印キー
  - ページスライダーをドラッグ
- **速度変更**: 右下の速度ピッカー（0.5x, 0.75x, 1.0x, 1.25x, 1.5x, 2.0x）
- **任意の位置から再生**: テキストブロックをクリック

## プロジェクト構成

```
AudioBookApp/
├── AudioBookApp/
│   ├── AudioBookApp.swift           # @main エントリポイント
│   ├── Models/
│   │   ├── BookModel.swift          # Book, Page, TextBlock の Codable 構造体
│   │   └── LibraryManager.swift     # ライブラリ管理 (library.json)
│   ├── Audio/
│   │   └── AudioPlayerManager.swift # AVAudioPlayer + AVSpeechSynthesizer + MediaPlayer
│   └── Views/
│       ├── ContentView.swift        # ルート（ライブラリ or --book モード分岐）
│       ├── LibraryView.swift        # ライブラリ画面（本の一覧）
│       ├── AddBookView.swift        # 本の追加ワークフロー（OCR → TTS）
│       ├── ViewerView.swift         # ビューア画面（画像 + コントロール）
│       ├── PageImageView.swift      # 画像 + バウンディングボックス
│       └── PlayerControlsView.swift # 再生コントロール + ページスライダー
└── AudioBookApp.xcodeproj/
```

## 依存フレームワーク

- SwiftUI (UI)
- AVFoundation (AVAudioPlayer, AVSpeechSynthesizer)
- MediaPlayer (MPRemoteCommandCenter, MPNowPlayingInfoCenter)

## システム要件

- macOS 15.0 (Sequoia) 以降
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

- macOS の「システム設定 > Bluetooth」で AirPods が接続されているか確認
- 他のアプリ（Music, Spotify 等）が音声を占有していないか確認
