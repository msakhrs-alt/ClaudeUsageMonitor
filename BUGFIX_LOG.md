# ClaudeUsageMonitor — バグ修正ログ

作成日: 2026-06-08

---

## BUG-01｜プロトコルの @MainActor 欠落によるデータ競合リスク

**ファイル:** `ClaudeAPIService.swift`

**症状:**
`ClaudeAPIServiceDelegate` プロトコル自体に `@MainActor` がなく、
`AppDelegate` の extension に `@MainActor` を付けても呼び出し側から
非MainActorコンテキストで呼べてしまう状態だった。

**原因:**
プロトコル要件はプロトコル定義で隔離を指定する必要がある。
extension に付けた `@MainActor` はその extension 内の実装を隔離するだけで、
プロトコル要件の呼び出し規約は変わらない。

**修正:**
```swift
// Before
protocol ClaudeAPIServiceDelegate: AnyObject { ... }
@MainActor
extension AppDelegate: ClaudeAPIServiceDelegate { ... }

// After
@MainActor
protocol ClaudeAPIServiceDelegate: AnyObject { ... }
extension AppDelegate: ClaudeAPIServiceDelegate { ... }
```

---

## BUG-02｜nonisolated コンテキストで @MainActor プロパティを参照

**ファイル:** `ClaudeAPIService.swift`

**症状:**
`WKScriptMessageHandler.userContentController(_:didReceive:)` は `nonisolated` で
実装する必要があるが、`message.body`（`@MainActor` 隔離プロパティ）を
`Task { @MainActor in }` の外で参照していた。

**原因:**
`let body = message.body` の行が nonisolated コンテキストでの参照になる。
`Task { @MainActor in }` に渡した時点では `body` はキャプチャ済みだが、
取得自体がメインアクター外で行われているためコンパイラ警告が出る。

**修正:**
WebKit は `userContentController` を常にメインスレッドで呼び出すことが保証されているため
`MainActor.assumeIsolated` を使って同期的に処理する。

```swift
// Before
nonisolated func userContentController(..., didReceive message: WKScriptMessage) {
    let body = message.body          // ← nonisolated で @MainActor プロパティ参照
    Task { @MainActor in
        guard let text = body as? String else { return }
        self.parseAndDeliver(text)
    }
}

// After
nonisolated func userContentController(..., didReceive message: WKScriptMessage) {
    MainActor.assumeIsolated {       // WebKit は常にメインスレッドで呼ぶので安全
        guard let text = message.body as? String else { return }
        self.parseAndDeliver(text)
    }
}
```

---

## BUG-03｜WKWebView がビュー階層に属さず描画・JS実行が不安定

**ファイル:** `ClaudeAPIService.swift`

**症状:**
`WKWebView(frame: .zero)` をどのウィンドウにも追加せず使っていた。
ページロードは試みるが JSインターセプターが発火しない、または
不安定なタイミングで実行されていた。

**原因:**
macOS の WebKit は WKWebView がウィンドウのビュー階層に属していないと
レンダリングおよびJavaScript実行が正常に動作しない場合がある。

**修正:**
画面外（x: -2048）に小サイズ（400×300）の非表示ウィンドウを作成し、
`orderBack(nil)` でウィンドウリストに載せた上で WKWebView を配置。

```swift
let window = NSWindow(contentRect: NSRect(x: -2048, y: 0, width: 400, height: 300), ...)
webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
webView.autoresizingMask = [.width, .height]
window.contentView!.addSubview(webView)
window.orderBack(nil)
offscreenWindow = window
```

---

## BUG-04｜WKWebView の大サイズによるメモリプレッシャー

**ファイル:** `ClaudeAPIService.swift`

**症状:**
Console.app に `WebProcessPool::handleMemoryPressureWarning` と
`WebBackForwardCache::clear` が連続して出力され、WebKit プロセスが不安定になっていた。

**原因:**
オフスクリーンウィンドウに 1024×768 の WKWebView を配置していたため
WebKit の backing store が大量のメモリを消費した。

**修正:**
WKWebView サイズを 400×300 に縮小。

---

## BUG-05｜`evaluateJavaScript` で async 関数の戻り値が取れない

**ファイル:** `ClaudeAPIService.swift`

**症状:**
`JS error: JavaScript execution returned a result of an unsupported type`

**原因:**
`evaluateJavaScript` は即時値しか受け取れない。
`async function` は `Promise` を返すが、Promise オブジェクトは
Objective-C ブリッジで扱えない型のためエラーになる。

**修正:**
`callAsyncJavaScript` を使用（macOS 11+ 対応）。
この API は async JS の完了を待機して結果を返す。

```swift
// Before
webView.evaluateJavaScript(fetchJS) { result, error in ... }

// After
webView.callAsyncJavaScript(fetchJS, arguments: [:], in: nil, in: .defaultClient) { result in
    switch result {
    case .failure(let error): ...
    case .success(let value): ...
    }
}
```

JS 側も IIFE `(async function(){...})()` から
`callAsyncJavaScript` 用のトップレベル await 形式に変更。

---

## BUG-06｜`didFinish` 内で `webView.url` を nonisolated コンテキストから参照

**ファイル:** `ClaudeAPIService.swift`

**症状:**
Xcode に warning 2件: `Main actor-isolated property 'url' cannot be referenced from a nonisolated autoclosure`

**原因:**
`WKNavigationDelegate` のデリゲートメソッドは `nonisolated` で実装する必要があるが、
`webView.url` は `@MainActor` 隔離プロパティのため直接参照できない。

**修正:**
`MainActor.assumeIsolated` で囲む（WebKit はメインスレッドで呼び出しを保証）。

```swift
// Before
nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    let urlStr = webView.url?.absoluteString ?? ""   // ← 警告
    Task { @MainActor in ... }
}

// After
nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    MainActor.assumeIsolated {
        let urlStr = webView.url?.absoluteString ?? ""
        ...
    }
}
```

---

## BUG-07｜os_log の info レベルが Console.app に表示されない

**ファイル:** `ClaudeAPIService.swift`

**症状:**
`Logger(subsystem:category:).info()` で書いたログが Console.app の
「すべてのメッセージ」ビューに一切表示されなかった。

**原因:**
Console.app はデフォルトで `.info` レベルのログを非表示にする。
「Action > Include Info Messages」を有効にしない限り見えない。

**修正:**
デバッグログをすべて `NSLog` に変更。
`NSLog` は設定に関係なく常に Console.app に出力される。

---

## BUG-08｜API エンドポイントの特定（使用量データが取得できない）

**ファイル:** `ClaudeAPIService.swift`

**症状:**
メニューバーが「loading...」のまま。データが一切表示されない。

**原因・調査過程:**
1. `/api/organizations/current/usage` → 400（organization_uuid が必要）
2. `/api/bootstrap` → 200（成功）、`account.memberships` に org UUID が含まれる
3. `account.uuid`（ユーザー UUID）を org UUID として使っていた → permission_error
4. `account.memberships[].organization.uuid` が正しい org UUID

**正しいエンドポイント:**
```
GET /api/bootstrap
  → account.memberships[].organization.uuid を取得

GET /api/organizations/{org_uuid}/usage
  → {"five_hour": {"utilization": 37.0, "resets_at": "..."}, "seven_day": {...}}
```

**修正:**
2段階フェッチ方式に変更。
bootstrap で org UUID を取得し、usage エンドポイントを叩く。

---

## BUG-09｜週間使用量（seven_day）のパースに失敗

**ファイル:** `ClaudeAPIService.swift`

**症状:**
セッション使用量は正しく表示されるが、週間使用量が常に 0% になる。

**原因:**
- キー名を `weekly` と想定していたが実際は `seven_day`
- `five_hour.utilization` は 0〜100 スケール（例: 37.0）
- `seven_day.utilization` は 0〜1 スケール（例: 0.04）で格納されていた

**修正:**
```swift
let raw = wk["utilization"] as? Double ?? 0
// スケールを自動判定して正規化
weeklyPct = raw > 1.0 ? Int(raw.rounded()) : Int((raw * 100).rounded())
```

---

## BUG-10｜メニューバーの stale 表示が自動更新されない

**ファイル:** `AppDelegate.swift`

**症状:**
データ取得から 10 分以上経過しても、メニューバーがグレー+⚠に変わらない。

**原因:**
`updateStatusBar` はデータ受信時（`didReceiveUsageData`）にしか呼ばれていなかった。
stale になるのはその後 10 分経過してからなので、タイミングが合わない。

**修正:**
カウントダウンタイマー（1秒ごと）内でも `updateStatusBar` を呼ぶよう変更。

```swift
countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    Task { @MainActor in
        if var data = self.contentViewModel.usageData {
            if data.sessionResetSeconds > 0 { data.sessionResetSeconds -= 1 }
            self.contentViewModel.usageData = data
            self.updateStatusBar(data: data)   // ← 追加
        }
    }
}
```

---

## BUG-11｜週間使用量が100%と誤表示（実際は1%）

**ファイル:** `ClaudeAPIService.swift`

**症状:**
週間使用量が実際には1%程度なのに、100%と表示される。

**原因:**
`seven_day.utilization = 1.0` のとき、スケール自動判定の条件 `raw > 1.0` が
false になるため `1.0 × 100 = 100%` と計算されていた。
BUG-09 の修正で導入したスケール判定ロジックの閾値が不適切だった。

**修正:**
`seven_day` のスケール判定に `five_hour.utilization` の値を参照する方式に変更。
`five_hour > 1.0` なら両フィールドとも 0〜100 スケールとしてそのまま使用。

```swift
let fiveHourRaw = fh["utilization"] as? Double ?? 0
let sevenDayRaw = wk["utilization"] as? Double ?? 0
let isLargeScale = fiveHourRaw > 1.0
sessionPct = isLargeScale ? Int(fiveHourRaw.rounded()) : Int((fiveHourRaw * 100).rounded())
weeklyPct  = isLargeScale ? Int(sevenDayRaw.rounded()) : Int((sevenDayRaw * 100).rounded())
```

---

## BUG-12｜Xcode等起動時に claude.ai の画面が画面中央に表示される

**ファイル:** `ClaudeAPIService.swift`

**症状:**
Xcode や他のアプリを起動するたびに、オフスクリーンに置いていたはずの
WKWebView ウィンドウが画面中央に飛び出してくる。

**原因:**
`orderBack(nil)` したオフスクリーンウィンドウ（x: -4000）を、macOS の
ウィンドウマネージャーが新しいアプリ起動時に可視領域へ自動移動させていた。

**修正:**
ウィンドウを完全に不可視・非インタラクティブに設定し、Mission Control 等からも除外。

```swift
window.alphaValue = 0
window.ignoresMouseEvents = true
window.collectionBehavior = [
    .canJoinAllSpaces,
    .stationary,
    .ignoresCycle,
    .fullScreenNone
]
```

---

## BUG-13｜Finder でアプリアイコンが表示されない

**ファイル:** `Assets.xcassets/AppIcon.appiconset/Contents.json`, `Info.plist`

**症状:**
ビルド・インストール後も Finder およびLaunchpad でアプリアイコンが
デフォルトのグリッドアイコンのまま表示される。

**原因:**
1. `Contents.json` が `AppIcon.icns` を全サイズスロットに割り当てる誤った形式だった。
   Xcode のアセットカタログは各サイズごとに個別の PNG を要求するため、
   `.icns` をそのまま各スロットに指定してもビルド成果物の `Resources/` に
   `AppIcon.icns` がコピーされない。
2. `Info.plist` に `CFBundleIconName` の記述がなく、OS がアイコンを参照できなかった。

**修正:**
`AppIcon.icns`（1024×1024）から `sips` で各サイズ PNG を生成し、
`Contents.json` を正しい形式に書き直した。

```bash
ICONSET=~/Developer/ClaudeUsageMonitor/ClaudeUsageMonitor/Assets.xcassets/AppIcon.appiconset
sips -s format png "$ICONSET/AppIcon.icns" --out /tmp/icon_1024.png
sips -z 16 16     /tmp/icon_1024.png --out "$ICONSET/icon_16x16.png"
sips -z 32 32     /tmp/icon_1024.png --out "$ICONSET/icon_16x16@2x.png"
sips -z 32 32     /tmp/icon_1024.png --out "$ICONSET/icon_32x32.png"
sips -z 64 64     /tmp/icon_1024.png --out "$ICONSET/icon_32x32@2x.png"
sips -z 128 128   /tmp/icon_1024.png --out "$ICONSET/icon_128x128.png"
sips -z 256 256   /tmp/icon_1024.png --out "$ICONSET/icon_128x128@2x.png"
sips -z 256 256   /tmp/icon_1024.png --out "$ICONSET/icon_256x256.png"
sips -z 512 512   /tmp/icon_1024.png --out "$ICONSET/icon_256x256@2x.png"
sips -z 512 512   /tmp/icon_1024.png --out "$ICONSET/icon_512x512.png"
sips -z 1024 1024 /tmp/icon_1024.png --out "$ICONSET/icon_512x512@2x.png"
```

`Info.plist` に `CFBundleIconName = AppIcon` を追加後リビルド。
`/Applications/` の古いバイナリを削除・再コピーし、Finder キャッシュをリセット。

```bash
rm -rf /Applications/ClaudeUsageMonitor.app
cp -R ~/Library/Developer/Xcode/DerivedData/ClaudeUsageMonitor-*/Build/Products/Debug/ClaudeUsageMonitor.app /Applications/
sudo find /private/var/folders -name "com.apple.iconservices" -exec rm -rf {} + 2>/dev/null
killall Finder
```

---

## BUG-14｜スリープ復帰時に WebContent プロセスが ~2.4GB に膨張（再発）

**ファイル:** `ClaudeAPIService.swift`, `AppDelegate.swift`

**症状:**
スリープからの復帰時、高確率でメモリ使用量が 2.4GB 付近に張り付く。
BUG-04 で一度対処したはずだが再発していた。

**原因（BUG-04 の対処が不十分だった理由）:**
使用量取得のたびに、常駐オフスクリーン WKWebView へ
`https://claude.ai/settings/usage` の React SPA を**まるごとロード**していた。
実際に使うのは `callAsyncJavaScript` 内の `fetch('/api/...')` だけで SPA 本体は不要。

- BUG-04 のウィンドウ縮小・取得後の空HTMLロードは backing store のサイズを
  縮めただけで、**SPA の JS ヒープがロードされること自体**は防げていなかった。
- スリープ/復帰のハンドリングが無く（`NSWorkspace` 監視なし）、スリープ中は
  繰り返し `Timer` も WebKit のメモリプレッシャー回収も停止する。
- 復帰時、スリープ突入時に進行中だったロードは完了せず空HTMLクリーンアップが
  走らないまま SPA が居座り、その上に refresh タイマーが新しい SPA ロードを重ねる。
  claude.ai の service worker / 再接続する websocket も一斉に立ち上がり、
  `WebContent` プロセスが ~2.4GB に膨張していた。

**修正:**
1. **SPA をロードしない。** `loadSimulatedRequest` で claude.ai オリジン上に
   空の最小 HTML を置く。ドキュメントのオリジンが claude.ai なので保存済み
   Cookie を使った same-origin の `fetch` はそのまま動くが、重い React バンドルは
   一切実行されない（メモリ膨張の根治）。
   ```swift
   let response = HTTPURLResponse(url: usageURL, statusCode: 200,
       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html; charset=utf-8"])!
   webView.loadSimulatedRequest(URLRequest(url: usageURL),
       response: response, responseData: Data("<!DOCTYPE html>...".utf8))
   ```
2. **ログイン判定を HTTP ステータスベースに。** 簡易ドキュメントでは login へ
   自動リダイレクトされないため、`fetch` の 401/403 で `needsLogin()` を呼ぶ。
3. **sleep/wake ハンドリング追加。** `NSWorkspace.willSleepNotification` で
   タイマー停止＋ページ解放（`prepareForSleep()`）、`didWakeNotification` で
   タイマー再開＋再取得。進行中ロードの取り残しを防ぐ。

---

## 修正サマリー

| # | 種別 | ファイル | 影響 |
|---|---|---|---|
| 01 | Swift Concurrency | ClaudeAPIService | データ競合リスク |
| 02 | Swift Concurrency | ClaudeAPIService | コンパイラ警告 |
| 03 | WebKit | ClaudeAPIService | JS非実行・データ取得不可 |
| 04 | メモリ | ClaudeAPIService | アプリ不安定 |
| 05 | WebKit API | ClaudeAPIService | データ取得不可 |
| 06 | Swift Concurrency | ClaudeAPIService | コンパイラ警告 |
| 07 | ロギング | ClaudeAPIService | デバッグ不可 |
| 08 | API仕様 | ClaudeAPIService | データ取得不可（根本原因） |
| 09 | API仕様 | ClaudeAPIService | 週間使用量が常に0% |
| 10 | UI更新 | AppDelegate | stale表示が機能しない |
| 11 | API仕様 | ClaudeAPIService | 週間使用量が100%と誤表示 |
| 12 | WebKit | ClaudeAPIService | オフスクリーンウィンドウが前面に出る |
| 13 | アセット設定 | Assets.xcassets / Info.plist | Finderでアイコンが表示されない |
| 14 | メモリ | ClaudeAPIService / AppDelegate | スリープ復帰時に~2.4GBへ膨張（BUG-04再発） |
