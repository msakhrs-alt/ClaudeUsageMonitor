# Implementation Tips

ClaudeUsageMonitorを参考に独自実装する際のポイントをまとめています。

---

## 1. WKWebViewはウィンドウのビュー階層に載せる

`WKWebView(frame: .zero)` をどのウィンドウにも追加せず使うと、ページロードは試みるがJavaScriptが発火しない、または不安定になります。

macOSのWebKitはWKWebViewがウィンドウのビュー階層に属していないと、レンダリングおよびJavaScript実行が正常に動作しない場合があります。

**解決策：** 画面外に小サイズの非表示ウィンドウを作り、そこにWebViewを載せる。

```swift
let window = NSWindow(
    contentRect: NSRect(x: -2048, y: 0, width: 400, height: 300),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
webView.autoresizingMask = [.width, .height]
window.contentView!.addSubview(webView)
window.orderBack(nil)
offscreenWindow = window  // 強参照を保持して解放されないようにする
```

WebViewのサイズは400×300程度に抑えること。大きすぎるとWebKitのメモリプレッシャーが発生してアプリが不安定になります。

---

## 2. APIは2段階フェッチが必要

`/api/organizations/current/usage` のような直接エンドポイントは存在しません。まず `/api/bootstrap` でorg UUIDを取得してから使用量を叩く2段階構成が必要です。

```javascript
// Step 1: bootstrap で org UUID を取得
const bsRes = await fetch('/api/bootstrap', { credentials: 'include' });
const bs = await bsRes.json();

const orgUuids = new Set();
const memberships = bs.account?.memberships || bs.memberships || [];
memberships.forEach(m => {
    if (m.organization?.uuid) orgUuids.add(m.organization.uuid);
});

// Step 2: org UUID で使用量を取得
for (const uuid of orgUuids) {
    const r = await fetch('/api/organizations/' + uuid + '/usage', { credentials: 'include' });
    if (r.ok) {
        const data = await r.json();
        return JSON.stringify({ org_uuid: uuid, usage: data });
    }
}
```

`account.uuid`（ユーザーUUID）をorg UUIDとして使うと `permission_error` になります。`account.memberships[].organization.uuid` が正しいキーです。

---

## 3. `evaluateJavaScript` ではなく `callAsyncJavaScript` を使う

`evaluateJavaScript` はasync関数の戻り値（Promise）を受け取れず、以下のエラーになります：

```
JavaScript execution returned a result of an unsupported type
```

`callAsyncJavaScript`（macOS 11+）を使うとasync JSの完了を待機して結果を受け取れます。

```swift
// NG
webView.evaluateJavaScript(fetchJS) { result, error in ... }

// OK
webView.callAsyncJavaScript(
    fetchJS,
    arguments: [:],
    in: nil,
    in: .defaultClient
) { result in
    switch result {
    case .failure(let error): print(error)
    case .success(let value):
        guard let json = value as? String else { return }
        // パース処理
    }
}
```

JS側もIIFE `(async function(){...})()` ではなく、トップレベルawait形式で書くこと。

---

## 4. `seven_day.utilization` は0〜1スケール

レスポンスのJSONに注意が必要です：

- `five_hour.utilization` → **0〜100スケール**（例: `37.0` = 37%）
- `seven_day.utilization` → **0〜1スケール**（例: `0.04` = 4%）

スケールが異なるため、そのまま使うと週間使用量が常に0%に見えます。

```swift
let raw = wk["utilization"] as? Double ?? 0
// スケールを自動判定して正規化
weeklyPct = raw > 1.0 ? Int(raw.rounded()) : Int((raw * 100).rounded())
```

---

## 5. デバッグログは `NSLog` を使う

`Logger(subsystem:category:).info()` はConsole.appのデフォルト設定では非表示になります（`Action > Include Info Messages` を有効にしないと見えない）。

開発中は `NSLog` を使うと設定に関係なく常にConsole.appに出力されます。

```swift
NSLog("[ClaudeMonitor] session=%d%% reset=%ds weekly=%d%%",
      parsed.sessionUsagePct, parsed.sessionResetSeconds, parsed.weeklyUsagePct)
```
