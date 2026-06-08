# ClaudeUsageMonitor — 開発仕様書

## 概要

macOSメニューバーに常駐し、claude.aiの使用量（セッション・週間）をパーセント表示するネイティブアプリ。  
参照OSS: [theDanButuc/Claude-Usage-Monitor](https://github.com/theDanButuc/Claude-Usage-Monitor)（MIT）をベースに独自実装。

---

## 技術スタック

| 項目 | 内容 |
|---|---|
| 言語 | Swift 5.9+ |
| UI | SwiftUI |
| 最低macOSバージョン | macOS 13 Ventura |
| アーキテクチャ | Apple Silicon (arm64) + Intel (x86_64) ユニバーサルバイナリ |
| 署名 | ad-hoc（Apple Developer ID不要） |
| 依存ライブラリ | なし（Swift Package Manager / 外部ライブラリ不使用） |

---

## データ取得方式

### 方式：WKWebView + JSフェッチインターセプター

1. `WKWebView`で `https://claude.ai/settings/usage` を非表示ロード
2. ページロード開始前にJavaScriptインターセプターを注入し、`fetch` / `XMLHttpRequest` を上書き
3. 使用量・制限・リセット時刻を含むAPIレスポンス（JSON）をキャプチャ → Swiftに`postMessage`で転送
4. DOM読み込み完了5秒後にフォールバックとしてDOMテキストも抽出
5. セッションCookieは `WKWebsiteDataStore.default()` で永続化（初回ログイン後は自動維持）

### 取得するデータフィールド

```json
{
  "session_usage_pct": 42,        // 現在セッション使用率 (%)
  "session_reset_seconds": 7200,  // セッションリセットまでの秒数
  "weekly_usage_pct": 18,         // 週間使用率 (%)
  "weekly_reset_at": "2026-06-09T10:00:00Z"  // 週間リセット日時
}
```

---

## 機能仕様

### メニューバー表示

- 形式: `42% | 18%`（セッション% | 週間%）
- 色分け:
  - 緑: 両方 < 50%
  - オレンジ: どちらか 50〜80%
  - 赤: どちらか > 80%
  - グレー + ⚠: データが10分以上古い（stale）

### ポップオーバー（クリック時）

- セッション使用量バー（残り時間カウントダウン付き）
- 週間使用量バー（リセット日時付き）
- 手動更新ボタン（↻）
- 終了ボタン

### 右クリックコンテキストメニュー

- 現在の使用量テキスト表示
- 更新間隔サブメニュー: 30秒 / 1分 / 2分 / 5分 / 10分（設定はUserDefaultsに永続化）
- 今すぐ更新
- 終了

### 通知

- 使用量が 80% / 90% / 100% を超えたタイミングで `UNUserNotificationCenter` 通知
- セッションリセット時にも通知

### 自動更新チェック

- 起動時にGitHub Releases APIを叩き、新バージョンがあればポップオーバー内にバナー表示
  - エンドポイント: `https://api.github.com/repos/{owner}/{repo}/releases/latest`

---

## ファイル構成

```
ClaudeUsageMonitor/
├── ClaudeUsageMonitor/
│   ├── ClaudeUsageMonitorApp.swift     # @main エントリポイント
│   ├── AppDelegate.swift               # ステータスバー・ポップオーバー・タイマー管理
│   ├── LoginWindowController.swift     # 初回ログイン用WebViewウィンドウ
│   ├── Models/
│   │   └── UsageData.swift             # データモデル・計算プロパティ
│   ├── Services/
│   │   ├── ClaudeAPIService.swift      # WKWebView + JSインターセプター
│   │   ├── NotificationService.swift   # 閾値通知・リセット通知
│   │   └── UpdateService.swift         # GitHub Releases 更新チェック
│   ├── Views/
│   │   ├── ContentView.swift           # ポップオーバーUI
│   │   └── UsageBarView.swift          # 使用量プログレスバーコンポーネント
│   ├── Assets/
│   │   └── AppIcon.icns
│   ├── Info.plist
│   └── ClaudeUsageMonitor.entitlements
├── scripts/
│   └── build.sh                        # ビルド + DMG生成スクリプト
├── project.yml                         # XcodeGen定義
└── README.md
```

---

## 各ファイルの実装要件

### `ClaudeUsageMonitorApp.swift`
- `@main` App構造体
- `NSApplicationDelegateAdaptor` で `AppDelegate` を接続
- Dockアイコン非表示（`LSUIElement = YES` in Info.plist）

### `AppDelegate.swift`
- `NSStatusBar.system.statusItem` でメニューバーアイコン生成
- `NSPopover` でContentViewを表示
- `Timer` で自動更新（デフォルト: 5分、UserDefaultsで永続化）
- `ClaudeAPIService` からデータ取得後、ステータスバーのタイトルと色を更新
- staleチェック: 最終更新から10分超でグレー+⚠表示

### `LoginWindowController.swift`
- `WKWebView` で `claude.ai` を表示するフルウィンドウ
- ログイン成功を検知（URLが `/settings/usage` または `/` になったタイミング）してウィンドウを閉じる

### `ClaudeAPIService.swift`（コアロジック）
- `WKWebView` + `WKUserContentController` を使用
- `userContentController(_:didReceive:)` でJSメッセージ受信
- 注入するJSインターセプター:
  ```javascript
  // fetch と XHR を上書きして、usage/limits/quota を含むレスポンスをキャプチャ
  const originalFetch = window.fetch;
  window.fetch = async function(...args) {
    const response = await originalFetch.apply(this, args);
    const cloned = response.clone();
    const text = await cloned.text();
    if (text.includes('usage') || text.includes('limit') || text.includes('quota')) {
      window.webkit.messageHandlers.usageData.postMessage(text);
    }
    return response;
  };
  ```
- フォールバック: DOMテキスト抽出（`document.body.innerText`）
- デリゲートパターンで `AppDelegate` にデータを返す

### `UsageData.swift`
```swift
struct UsageData {
    var sessionUsagePct: Int       // 0〜100
    var sessionResetSeconds: Int   // 残り秒数
    var weeklyUsagePct: Int        // 0〜100
    var weeklyResetAt: Date?
    var fetchedAt: Date
    
    var isStale: Bool {
        Date().timeIntervalSince(fetchedAt) > 600 // 10分
    }
    
    var statusBarTitle: String {
        "\(sessionUsagePct)% | \(weeklyUsagePct)%"
    }
    
    var statusBarColor: NSColor {
        let max = Swift.max(sessionUsagePct, weeklyUsagePct)
        if isStale { return .gray }
        if max > 80 { return .systemRed }
        if max > 50 { return .systemOrange }
        return .systemGreen
    }
}
```

### `ContentView.swift`
- SwiftUI製ポップオーバー
- 幅: 280pt 固定
- セクション構成:
  1. "Current Session" — `UsageBarView` + リセットカウントダウン
  2. "Weekly Limits" — `UsageBarView` + リセット日時
  3. 更新ボタン / 終了ボタン
- 新バージョンありの場合: バナー（"Update available: vX.X.X"）

### `UsageBarView.swift`
- `GeometryReader` + `Rectangle` でプログレスバー描画
- 色: 50%未満=緑、50〜80%=オレンジ、80%超=赤

---

## Info.plist 設定

```xml
<key>LSUIElement</key>
<true/>  <!-- Dockアイコン非表示 -->
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <false/>
    <key>NSExceptionDomains</key>
    <dict>
        <key>claude.ai</key>
        <dict>
            <key>NSExceptionAllowsInsecureHTTPLoads</key>
            <false/>
        </dict>
    </dict>
</dict>
```

## Entitlements

```xml
<key>com.apple.security.network.client</key>
<true/>
```

---

## ビルド方法

```bash
# XcodeGen でプロジェクト生成（初回のみ）
brew install xcodegen
xcodegen generate

# ビルド（arm64）
xcodebuild -project ClaudeUsageMonitor.xcodeproj \
           -scheme ClaudeUsageMonitor \
           -configuration Release \
           -arch arm64 \
           CONFIGURATION_BUILD_DIR=./build

# ユニバーサルバイナリ（オプション）
lipo -create -output ClaudeUsageMonitor build/arm64/ClaudeUsageMonitor build/x86_64/ClaudeUsageMonitor
```

---

## 実装上の注意点

1. **WKWebViewはメインスレッド**で初期化・操作すること（UIスレッド制約）
2. **JSインターセプターのタイミング**: `.atDocumentStart` で注入しないとページスクリプトに上書きされる
3. **staleデータ判定**: Timerが止まった場合（スリープ復帰など）を考慮し、`fetchedAt` からの経過時間で判定
4. **ログイン検知**: `webView(_:didFinish:)` でURLをチェック。`/settings/usage` への遷移がなければログイン未完了
5. **メモリ管理**: `WKWebView` は `ClaudeAPIService` 内で強参照を保持し、解放されないようにする
6. **UserDefaults キー一覧**:
   - `refreshInterval`: Int（秒）
   - `notifiedAt80`: Bool
   - `notifiedAt90`: Bool

---

## 実装しないもの（スコープ外）

- iCloud同期
- Apple Watch / iPhone コンパニオン
- 使用量ヒストリー・グラフ
- 複数アカウント対応
- Windowsサポート

---

## 参照リポジトリ

- [theDanButuc/Claude-Usage-Monitor](https://github.com/theDanButuc/Claude-Usage-Monitor)（MIT）— 実装の主参照
- [claudeusagebar.com](https://www.claudeusagebar.com/)（セッションCookie方式の参考）
- [rjwalters/claude-monitor](https://github.com/rjwalters/claude-monitor)（OAuthトークン方式の参考）
