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
`WKWebView(frame: .zero)` を どのウィンドウにも追加せず使っていた。
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
これにより stale になった瞬間にメニューバーの色とアイコンが自動更新される。

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
