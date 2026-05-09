# Phase 6: iPhone/iPad 対応

## Context

macOS版オーディオブックアプリが完成し、Irodori TTS統合も動作確認済み。次のステップとして、iPhone/iPadでも本を読めるようにする。iOS版はOCR不要・再生専用のMVPとし、Macで作成した本のデータをiCloud Drive経由で共有する。TTSはiOS標準の`AVSpeechSynthesizer`を使用（既にmacOS版で実装済み）。

## 方針

- 既存のXcodeターゲットにiOS/iPadOSを追加（マルチプラットフォームターゲット）
- `#if os(macOS)` / `#if os(iOS)` で分岐（macOS専用機能を条件コンパイル）
- iOS版は**読み取り専用**（本の追加・削除・OCRは不可）
- データ共有: 通常のiCloud Driveフォルダ（Developer Program不要）
- TTS: `AVSpeechSynthesizer`のみ（Irodori TTSはmacOS専用）

## アーキテクチャ

```
┌──────────────────────────────────┐
│         macOS アプリ              │
│  - OCR + TTS で本を作成           │
│  - ライブラリ管理                  │
│  - AVSpeechSynthesizer / Irodori │
│  - iCloud Drive に保存            │
└──────────┬───────────────────────┘
           │ iCloud Drive 自動同期
           ▼
┌──────────────────────────────────┐
│       iPhone / iPad アプリ        │
│  - ライブラリ閲覧（読み取り専用）    │
│  - AVSpeechSynthesizer で再生     │
│  - WAV ファイルがあれば WAV 再生    │
│  - iCloud Drive から読み込み       │
└──────────────────────────────────┘
```

## ポータビリティ分析

### iOS互換（変更不要）
| コンポーネント | ファイル |
|-------------|---------|
| AVSpeechSynthesizer | AudioPlayerManager.swift |
| AVAudioPlayer (WAV再生) | AudioPlayerManager.swift |
| MPRemoteCommandCenter | AudioPlayerManager.swift |
| MPNowPlayingInfoCenter | AudioPlayerManager.swift |
| データモデル (Book, TextBlock) | BookModel.swift |
| ライブラリモデル (BookEntry) | LibraryModel.swift |
| 読み上げ設定 (TYPE別フィルタ) | ReadingSettings.swift |
| 再生コントロールUI | PlayerControlsView.swift |

### macOS専用（iOS不可）
| コンポーネント | 理由 |
|-------------|------|
| NSImage | UIImage に置換 |
| NSOpenPanel | iOS ではDocumentPicker |
| NSColor | UIColor に置換 |
| NSBitmapImageRep | iOS 不要（カバー生成はMac側） |
| Process() | iOS では利用不可 |
| Irodori TTS (mlx-audio) | MLXサーバー → macOS専用 |
| 本の追加 (OCR) | macOS のみ |

## 実装ステップ

### Step 1: プロジェクト設定変更

**ファイル**: `AudioBookApp.xcodeproj/project.pbxproj`

- Supported Destinations に iPhone / iPad を追加
- iOS deployment target: 17.0（`@Observable`が必要）
- macOS deployment target: 15.0（据え置き）
- `UIBackgroundModes = ["audio"]` 追加（iOS バックグラウンド再生）

**新規ファイル**: `AudioBookApp/AudioBookAppiOS.entitlements`
- `com.apple.security.app-sandbox = true`（iOS必須）

### Step 2: クロスプラットフォーム画像ヘルパー

**新規ファイル**: `AudioBookApp/Views/PlatformImage.swift`（約30行）

NSImage / UIImage の差分を吸収するヘルパー:
```swift
#if canImport(AppKit)
import AppKit
typealias PlatformNativeImage = NSImage
#elseif canImport(UIKit)
import UIKit
typealias PlatformNativeImage = UIImage
#endif

func loadPlatformImage(contentsOfFile path: String) -> PlatformNativeImage?
func swiftUIImage(from image: PlatformNativeImage) -> Image
func pixelSize(of image: PlatformNativeImage) -> CGSize
```

**変更ファイル**:
- `PageImageView.swift`: `NSImage` → `loadPlatformImage()`, `NSColor` → `UIColor`分岐
- `BookCardView.swift`: `NSImage` → `loadPlatformImage()`

### Step 3: macOS専用ファイルを条件コンパイル

ファイル全体を `#if os(macOS)` で囲む:
- `AddBookView.swift`（NSOpenPanel, OCR起動 → iOS不要）
- `IrodoriTTSService.swift`（Process() → iOS不可）
- `IrodoriChunkBuilder.swift`（Irodori専用 → iOS不要）

### Step 4: 共有ファイルの条件分岐

**`AudioPlayerManager.swift`**:
- Irodoriモードの全プロパティ・メソッドを `#if os(macOS)` で囲む
- `play()` 等の分岐内の `isIrodoriMode` ブロックを `#if os(macOS)` で囲む
- iOS用 `AVAudioSession` 設定を追加

**`ReadingSettings.swift`**:
- `TTSEngine.irodori` を `#if os(macOS)` で囲む
- Irodori関連プロパティ（serverURL, venvPath）を `#if os(macOS)` で囲む

**`LibraryManager.swift`**:
- `import AppKit` → `#if os(macOS)`
- `addBook()`, `generateCover()`, `runProcessAsync()`, `deleteBook()` → `#if os(macOS)`
- `init()` のライブラリルートをプラットフォーム分岐

**`ViewerView.swift`**:
- Irodoriサーバー起動・先読み → `#if os(macOS)`
- `.frame(minWidth:minHeight:)` → `#if os(macOS)`
- 設定画面: `.popover`(macOS) / `.sheet`(iOS)

**`ReadingSettingsView.swift`**:
- NSOpenPanel, Irodoriセクション → `#if os(macOS)`
- `.pickerStyle(.radioGroup)` → `#if os(macOS)`

**`ContentView.swift`**:
- コマンドライン引数解析 → `#if os(macOS)`

**`LibraryView.swift`**:
- 「+」ボタン、AddBookView sheet → `#if os(macOS)`
- 削除コンテキストメニュー → `#if os(macOS)`
- `.frame(minWidth:minHeight:)` → `#if os(macOS)`

**`PlayerControlsView.swift`**:
- `.keyboardShortcut()` → `#if os(macOS)`

### Step 5: iOS固有の対応

- `AVAudioSession` カテゴリ設定（バックグラウンド再生用）:
  ```swift
  #if os(iOS)
  try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenContent)
  try AVAudioSession.sharedInstance().setActive(true)
  #endif
  ```
- 設定画面を `.sheet` で表示（popoverはiOSで不適切）
- ライブラリ空状態のメッセージを「Macで本を追加し、iCloudで同期してください」に

### Step 6: iCloud Drive 連携（MVP版）

**方式**: アプリ専用コンテナではなく、通常のiCloud Driveフォルダを使う。
Apple Developer Program不要。Finderで見えるiCloud Driveに本のフォルダを置くだけ。

**同期フロー**:
```
Mac: ~/Library/Mobile Documents/com~apple~CloudDocs/AudioBookLibrary/
         ↓ iCloud Drive 自動同期
iOS: iCloud Drive/AudioBookLibrary/  (Filesアプリで見える)
```

**Mac側**:
- LibraryManagerの`libraryRoot`をiCloud Driveフォルダに設定可能にする
- パス: `~/Library/Mobile Documents/com~apple~CloudDocs/AudioBookLibrary/`
- 既存の本をこのフォルダにコピーまたは移動

**iOS側**:
- 初回起動時に`UIDocumentPickerViewController`でiCloud Drive上のライブラリフォルダを選択
- 選択したフォルダのURLをUserDefaultsに保存（security-scoped bookmark）
- 以降はそのフォルダからlibrary.json + 各ブックを読み込み

**Security-Scoped Bookmark** (iOS必須):
```swift
// フォルダ選択後にbookmark保存
let bookmark = try url.bookmarkData(options: .minimalBookmark)
UserDefaults.standard.set(bookmark, forKey: "libraryBookmark")

// 再起動時に復元
let data = UserDefaults.standard.data(forKey: "libraryBookmark")
var stale = false
let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
url.startAccessingSecurityScopedResource()
```

## 変更ファイル一覧

| ファイル | 変更内容 |
|---------|---------|
| `project.pbxproj` | iOS destination追加、background audio |
| **`PlatformImage.swift`** (新規) | NSImage/UIImage抽象化 |
| **`AudioBookAppiOS.entitlements`** (新規) | iOS sandbox |
| `Info.plist` | UIBackgroundModes追加 |
| `PageImageView.swift` | PlatformImage使用 (4行) |
| `BookCardView.swift` | PlatformImage使用 (2行) |
| `AddBookView.swift` | `#if os(macOS)` で全体ラップ |
| `IrodoriTTSService.swift` | `#if os(macOS)` で全体ラップ |
| `IrodoriChunkBuilder.swift` | `#if os(macOS)` で全体ラップ |
| `AudioPlayerManager.swift` | Irodori条件分岐 + AVAudioSession |
| `ReadingSettings.swift` | Irodori条件分岐 |
| `ReadingSettingsView.swift` | Irodori UI隠蔽 + NSOpenPanel分岐 |
| `ViewerView.swift` | Irodori分岐 + iOS layout + sheet |
| `ContentView.swift` | コマンドライン分岐 (2行) |
| `LibraryView.swift` | 追加/削除UI隠蔽 |
| `LibraryManager.swift` | iCloud Drive ルート + import分岐 |
| `PlayerControlsView.swift` | keyboardShortcut分岐 (3行) |

## 実装順序

1. Step 1-2: プロジェクト設定 + PlatformImage → iOSビルド基盤
2. Step 3: macOS専用ファイルの条件コンパイル → コンパイルエラー大幅削減
3. Step 4: 共有ファイルの条件分岐 → **iOS初回ビルド成功目標**
4. Step 5: iOS固有対応 → UIの最適化
5. Step 6: iCloud連携 → Mac↔iOS データ同期

## 検証方法

1. Xcodeでスキーム「AudioBookApp」のdestinationをiPhone simulatorに切り替え
2. ビルド成功を確認
3. シミュレータでライブラリ画面が表示されることを確認
4. demo_book/ のデータをシミュレータのDocumentsに配置してビューア動作確認
5. AVSpeechSynthesizerでの読み上げ動作確認
6. 実機でのバックグラウンド再生・ロック画面コントロール確認
7. iCloud同期でMacの本がiOSに表示されることを確認

## 実装状況

### Step 1-5: 完了 ✅ (commit `7040d82`)

全ステップのビルドが macOS / iOS Simulator の両方で成功。

**主な実装内容:**
- `project.pbxproj`: `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"`, iOS 17.0, `UIBackgroundModes = audio`
- `PlatformImage.swift` (新規): `NSImage`/`UIImage` 抽象化 (`loadPlatformImage()`, `swiftUIImage()`, `pixelSize()`)
- macOS専用ファイル3つを `#if os(macOS)` で全体ラップ: `AddBookView`, `IrodoriTTSService`, `IrodoriChunkBuilder`
- `AudioPlayerManager.swift`: `isCurrentlyIrodoriMode` 計算プロパティ導入 (iOSでは常にfalse), iOS用 `AVAudioSession(.playback)` 設定追加
- `PlayerControlsView.swift`: `.keyboardShortcut()` を macOS 限定に
- その他共有ファイル (`LibraryManager`, `ReadingSettings`, `ViewerView`, `LibraryView`, `ContentView`, `ReadingSettingsView`): 条件コンパイルで macOS/iOS 分岐

**技術的な発見:**
- Swift の `#if os()` は `if-else` チェーンを分割できない → `isCurrentlyIrodoriMode` 計算プロパティで解決
- `AVAudioSession.Mode.spokenContent` は iOS 26.4 SDK に存在しない → `.default` を使用
- コマンドラインから `-sdk iphonesimulator` でビルド可能（スキームが iOS destination を認識しなくても）

### Step 6: iCloud Drive 連携 ✅

**Mac側:**
- `LibraryManager.setLibraryRoot(path:)` でライブラリルートを変更可能
- `LibraryManager.iCloudDrivePath` で iCloud Drive のデフォルトパスを返す
- 既存ライブラリ → `~/Library/Mobile Documents/com~apple~CloudDocs/AudioBookLibrary/` にコピーで同期

**iOS側:**
- `LibraryView` にフォルダ選択ボタン (`folder.badge.plus`) + `.fileImporter` を追加
- `LibraryManager.setExternalFolder(url:)` で security-scoped bookmark を UserDefaults に保存
- 起動時に bookmark から URL を復元し `startAccessingSecurityScopedResource()` でアクセス権確保
- bookmark が stale な場合は自動で再保存を試みる

**同期フロー (実運用):**
```
1. Mac: ライブラリを iCloud Drive にコピー
   cp -r ~/Documents/AudioBookLibrary ~/Library/Mobile\ Documents/com~apple~CloudDocs/AudioBookLibrary

2. iCloud が自動同期（数分〜数十分、サイズによる）

3. iOS: アプリ起動 → 「フォルダを選択」→ iCloud Drive の AudioBookLibrary を指定

4. 以降はアプリ再起動時に bookmark から自動復元
```

### シミュレータでの動作確認 ✅

- iPhone 17 シミュレータでビルド・インストール・起動を確認
- ライブラリ画面、ビューア画面、ページ遷移、AVSpeechSynthesizer 読み上げが動作
- demo_book データを Documents に配置して表示確認済み

### 実機テスト ✅

- iPhone SE 3 実機でiCloud Drive経由のライブラリ表示・画像閲覧・音声再生を確認

#### 発見された問題と修正

**問題1: 本の画像が「画像を読み込めません」エラー**

原因が2つあった:

1. **`book.json` に Mac の絶対パスが保存されていた**
   - OCR処理 (`ocr_process.py`) が `image_path` を `/Users/yoshiaki/Documents/AudioBookLibrary/...` のように絶対パスで保存
   - iPhoneではこのパスは存在しない
   - 修正: `ocr_process.py` で `book.json` 出力先からの相対パス（例: `pages/image.jpg`）を保存するように変更
   - 同様に `tts_process.py` の `audio_path` も相対パスに修正

2. **iOS で `UIImage(contentsOfFile:)` が security-scoped bookmark のアクセス権を認識しない**
   - `PageImageView.swift` が `loadPlatformImage(contentsOfFile:)` （文字列パスベース）を使用していた
   - iCloud Drive のファイルは security-scoped bookmark 経由でアクセス権を得るが、文字列パスベースの API はこれを認識しない
   - 修正: URL ベースの `loadPlatformImage(contentsOf: url)` に変更（`Data(contentsOf: url)` 経由で security scope を通過）
   - `BookCardView` の表紙画像は元から URL 版を使用していたため問題なかった

3. **`BookModel.resolvePath()` の互換性対応**
   - 既存の `book.json` には絶対パスが残っている可能性があるため、`resolvePath()` にフォールバック処理を追加
   - 絶対パスがファイルシステムに存在しない場合、親ディレクトリ名+ファイル名で `baseDir` 基準に再解決

**既存データの修正:**
- ライブラリ内の全 `book.json`（4冊）の `image_path` / `audio_path` を相対パスに一括変換済み

## 注意事項

- MVP版iCloud連携は通常のiCloud Driveフォルダを使う（Developer Program不要）
- 将来的にアプリ専用iCloudコンテナに移行可能（Developer Program加入後）
- 大きなWAVファイルのiCloud同期には時間がかかる → AVSpeechSynthesizerフォールバックで対処
- `@Observable` は iOS 17+ 必須 → iOS 17未満は非対応
- iOS実機テストには最低限Apple IDでのXcodeサインインが必要（7日間の署名期限）
- iPhone側で「設定 > 一般 > VPNとデバイス管理」から開発者を信頼する操作が必要な場合あり
- `book.json` のパスは必ず相対パス（`pages/image.jpg`, `audio/page_001.m4a`）で保存すること。絶対パスだと Mac↔iOS 間で互換性がない
- iOS でファイルアクセスする際は URL ベースの API を使うこと（`UIImage(contentsOfFile:)` は security-scoped bookmark を認識しない）
