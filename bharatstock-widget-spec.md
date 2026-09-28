# Build Prompt — BharatStock Widget for macOS Tahoe

You are building a native macOS desktop/Notification-Centre widget called **BharatStock Widget** that
displays daily prices for a user-defined list of Indian stocks and mutual funds, sourced from the
BharatStock API via its official MCP server.

Read this entire document before writing code. Where this document states a decision, treat it as
binding. Where it says *Assumption*, the decision was inferred and you may flag it but should
implement as written unless it is technically impossible.

---

## 1. Product summary

A single macOS product composed of three targets:

1. **`BharatStockWidget`** — a WidgetKit extension (SwiftUI) that renders the data. It never touches
   the network. It reads a pre-built cache file and renders it. This is a hard architectural rule.
2. **`BharatStockHelper`** — a small non-UI companion executable, run by `launchd`, that owns all
   network I/O. It spawns the official MCP server (`npx -y bharatstock-mcp`), speaks MCP over stdio,
   resolves every symbol in the user's config, and writes a normalised cache file.
3. **`BharatStockApp`** — a minimal container app. macOS requires a host app to deliver a widget
   extension. It also provides first-run setup (create config, install the LaunchAgent, show status)
   and a "Refresh now" button.

### Why this split

A WidgetKit extension on macOS runs in a hard App Sandbox. It cannot fork a subprocess, has no Node
runtime available, and its timeline provider is given only a few seconds of wall-clock budget before
the system kills it. Spawning `npx` from inside the widget is therefore not an option. The helper
process does the work; the widget is a pure renderer over a local file. This also means the widget
still displays correct, clearly-timestamped data when the network is down or the API is rate-limited.

---

## 2. Resolved decisions (do not re-litigate)

| Topic | Decision |
|---|---|
| Data path | Helper app runs the MCP server; widget reads a shared JSON cache. No network calls from the widget. |
| API key location | Stored **in the config JSON** as a plaintext field. |
| Config file location | `~/Library/Application Support/BharatStockWidget/config.json` |
| Row selection | Config array order, truncated to the size's row count. "Top N" means the first N entries in the file. |

### Required note about the key decision

The API key lives in plaintext in the config file because the user wants a single hand-editable file.
Implement it that way, but also implement these mitigations, which are not optional:

- Create the config file with POSIX mode `0600` (owner read/write only) and re-assert that mode on
  every write. If the helper starts and finds the file group- or world-readable, log a warning and
  `chmod` it back to `0600`.
- Never write the key into the cache file, into any log line, into crash reports, or into the widget
  UI. When logging a request, redact to the first 12 characters, e.g. `bsk_live_0Rs…`.
- Support an optional override: if the environment variable `BHARATSTOCK_API_KEY` is set for the
  helper process, it wins over the config file value. This lets a security-conscious user keep the
  key out of the file entirely and leave `apiKey` as an empty string.
- In the container app's setup screen, include one plain sentence telling the user the file contains
  their key and should not be shared or committed to a repo.

---

## 3. Credentials and endpoints

```
API key:       bsk_live_REDACTED_SEE_docs_decisions_md
REST base:     https://bharatstockapi.com/v1
Auth header:   X-API-Key: <key>
MCP server:    npx -y bharatstock-mcp   (env: BHARATSTOCK_API_KEY)
MCP docs:      https://bharatstockapi.com/mcp
```

Known-good smoke test:

```bash
curl https://bharatstockapi.com/v1/stocks/RELIANCE \
  -H "X-API-Key: bsk_live_REDACTED_SEE_docs_decisions_md"
```

**Ship this key as a default but do not hard-code it in Swift source.** Write it into the generated
config file on first run, and read it from there at runtime. A user must be able to replace it with
their own key by editing one field and nothing else.

### Tool discovery is a required first step

The MCP server exposes roughly thirty market-data tools, and this document does **not** know their
exact names or parameter shapes. Before writing the fetch layer:

1. Run `BHARATSTOCK_API_KEY=<key> npx -y bharatstock-mcp` and issue an MCP `initialize` followed by
   `tools/list`.
2. Dump the full tool list with input schemas to `docs/mcp-tools.json` and commit it.
3. Identify the tool that returns a current stock quote including the session low and high, and the
   tool that returns a mutual fund NAV. Also look for a batch/multi-symbol variant and a
   symbol-search variant.
4. Write the chosen tool names and argument mappings into `docs/mcp-tools.md` with a short note on
   why each was chosen, then implement against them.

If a tool you expect does not exist, adapt and record the substitution in that file. Do not invent
tool names. If `tools/list` shows a batch tool, prefer it — it directly reduces request count.

---

## 4. Config file

Path: `~/Library/Application Support/BharatStockWidget/config.json`

The container app creates this on first launch if absent, with a commented-by-example set of
entries. The helper watches it with `DispatchSource`/FSEvents and reloads within a second of a save.

### Schema

```json
{
  "schemaVersion": 1,
  "apiKey": "bsk_live_REDACTED_SEE_docs_decisions_md",
  "refresh": {
    "time": "10:30",
    "timeZone": "Asia/Kolkata",
    "maxRequestsPerDay": 50
  },
  "display": {
    "currencySymbol": "₹",
    "maxNameLength": 18,
    "showChangePercent": true,
    "decimalPlaces": 2
  },
  "instruments": [
    { "type": "ST", "symbol": "RELIANCE",   "name": "Reliance Industries" },
    { "type": "ST", "symbol": "TCS" },
    { "type": "ST", "symbol": "HDFCBANK",   "name": "HDFC Bank" },
    { "type": "MF", "symbol": "120503",     "name": "Parag Parikh Flexi Cap" },
    { "type": "MF", "symbol": "118989",     "name": "Quant Small Cap Fund" }
  ]
}
```

### Field rules

- `instruments` is an **ordered array**. Order is the only thing that determines which rows appear in
  which widget size. Entry 1 shows in every size; entry 15 shows only in Extra Large.
- `type` must be exactly `"ST"` (stock) or `"MF"` (mutual fund). Case-insensitive on read, but
  validate and reject anything else with a clear per-entry error.
- `symbol` is required. For `ST` use the exchange ticker as BharatStock expects it (e.g. `RELIANCE`).
  For `MF` use whatever identifier the MCP mutual-fund tool accepts — most likely an AMFI scheme
  code. Confirm this during tool discovery and document it in the generated config's sibling
  `README.txt`.
- `name` is optional. When present it overrides the API-supplied name, which lets the user write
  their own short label. When absent, use the API's name and shorten it per §7.
- Unknown keys must be ignored, not fatal, so the file stays forward-compatible.
- Entries beyond index 14 are parsed and kept but never rendered. Surface the count in the container
  app ("18 instruments configured, 15 shown at Extra Large") so the truncation is not silent.

### Validation behaviour

Parse permissively and report precisely. A single malformed entry must not sink the whole file. Build
a `ConfigLoadResult` containing the valid instruments plus an array of per-entry diagnostics
(`index`, `rawValue`, `reason`). Show diagnostics in the container app. If the file is entirely
unparseable JSON, keep serving the last good cache, surface an error state in the widget footer, and
do **not** overwrite the user's file.

Ship a `config.example.json` and a plain-text `README.txt` alongside the real config explaining every
field, with two or three worked examples.

---

## 5. Refresh schedule and the 50-request ceiling

### Schedule

Exactly one scheduled refresh per day at **10:30 Asia/Kolkata**. Implement with a `launchd`
LaunchAgent at `~/Library/LaunchAgents/com.<you>.bharatstockwidget.helper.plist`.

`launchd`'s `StartCalendarInterval` fires in the machine's local time, not IST. Do not hard-code
10:30. Instead:

- Have the container app compute the local wall-clock time that corresponds to 10:30 IST **today**
  and write that into the plist.
- Re-compute and rewrite the plist whenever the system time zone changes (observe
  `NSSystemTimeZoneDidChangeNotification`) and on every container-app launch. This keeps the agent
  correct across travel and across DST transitions in the user's own zone. India has no DST, so IST
  is a fixed UTC+05:30 anchor.
- Set `RunAtLoad` to `false`, but add a catch-up rule in the helper: on any invocation, if the cache's
  `lastSuccessfulFetch` is older than the most recent 10:30 IST boundary, fetch now. This covers the
  common case where the Mac was asleep or shut down at 10:30. Together with launchd's own missed-run
  behaviour this gives at-least-once semantics per day.

### Request budget — treat as a hard safety property

`maxRequestsPerDay` defaults to 50 and is a ceiling the code must never cross, including retries,
manual refreshes, and tool-discovery calls.

Implement a persistent `RequestBudget` actor backed by
`~/Library/Application Support/BharatStockWidget/budget.json`:

```json
{ "windowStartUTC": "2026-09-28T05:00:00Z", "spent": 7, "limit": 50 }
```

Rules:

- The window rolls at 00:00 IST. On each helper start, if `windowStartUTC` is older than the most
  recent IST midnight, reset `spent` to 0 and advance the window.
- Every outbound API call — whether via MCP tool invocation or the REST fallback — must
  `try await budget.consume(1)` **before** it is issued. If the budget is exhausted, the call is not
  made; it throws `BudgetExhausted`.
- A batch tool call that resolves many symbols counts as **one** request. Prefer it.
- Reserve headroom: refuse to *start* a refresh cycle whose worst-case cost exceeds
  `limit - spent - 5`. The five-request reserve exists so a manual refresh or a retry is always
  possible.
- Deduplicate symbols before fetching. If the user lists `RELIANCE` twice, fetch it once.
- Fetch only what is renderable. With a 15-row maximum and per-symbol tools, one full refresh costs
  at most 15 requests, leaving comfortable room for one scheduled run plus two manual runs per day.
- Manual refresh from the container app is rate-limited client-side to at most one per five minutes
  regardless of remaining budget, to stop a user from click-spamming the ceiling away.
- Surface the budget in the container app: "7 of 50 requests used today, resets at midnight IST."

### Retry policy

Per-symbol, at most two retries, exponential backoff of 2s then 8s, with ±20% jitter. Each retry
consumes budget. Retry only on transport errors, HTTP 5xx, and HTTP 429. Never retry 4xx other than
429 — those mean a bad symbol or a bad key, and retrying wastes the ceiling. On 429, honour a
`Retry-After` header if present and abandon the cycle if it exceeds 120 seconds.

---

## 6. The cache file — contract between helper and widget

Widget extensions cannot read arbitrary paths under the sandbox. Use an **App Group**
(`group.com.<you>.bharatstockwidget`) shared between all three targets and write the cache to the
group container:

```
<AppGroupContainer>/Library/Caches/quotes.json
```

Write atomically: serialise to `quotes.json.tmp` in the same directory, `fsync`, then
`FileManager.replaceItemAt`. The widget must never observe a half-written file.

After a successful write the helper calls `WidgetCenter.shared.reloadAllTimelines()`.

### Cache schema

```json
{
  "schemaVersion": 1,
  "generatedAtUTC": "2026-09-28T05:00:12Z",
  "lastSuccessfulFetchUTC": "2026-09-28T05:00:12Z",
  "sourceTradingDate": "2026-09-28",
  "dataSource": "mcp",
  "budget": { "spent": 15, "limit": 50 },
  "status": "ok",
  "messages": [],
  "rows": [
    {
      "order": 0,
      "type": "ST",
      "symbol": "RELIANCE",
      "displayName": "Reliance Ind.",
      "fullName": "Reliance Industries Ltd",
      "state": "fresh",
      "stock": {
        "low": 2812.40,
        "high": 2877.95,
        "last": 2860.10,
        "previousClose": 2840.00,
        "changePercent": 0.71,
        "currency": "INR"
      },
      "mf": null,
      "asOfUTC": "2026-09-28T05:00:11Z"
    },
    {
      "order": 3,
      "type": "MF",
      "symbol": "120503",
      "displayName": "Parag Parikh Flexi",
      "fullName": "Parag Parikh Flexi Cap Fund Direct Growth",
      "state": "stale",
      "stock": null,
      "mf": {
        "nav": 78.4312,
        "navDate": "2026-09-26",
        "previousNav": 78.1044,
        "changePercent": 0.42,
        "currency": "INR"
      },
      "asOfUTC": "2026-09-26T13:00:00Z"
    }
  ]
}
```

- `status` ∈ `ok | partial | stale | budget_exhausted | config_error | auth_error`.
- Per-row `state` ∈ `fresh | stale | error | unavailable`. `stale` means the row is real data from an
  earlier fetch that this cycle failed to refresh. Keep the old values rather than blanking the row.
- `messages` carries short human-readable strings the widget may show in its footer.
- Mutual fund NAV is published once a day after markets close, typically around 21:00–23:00 IST. A
  10:30 IST fetch will therefore almost always return the **previous** business day's NAV. This is
  correct and expected. Always show `navDate` next to the NAV so the user is never misled about which
  day they are looking at. Do not label it "Today's NAV" unless `navDate` genuinely equals today in
  IST — label it `NAV · 26 Sep` instead.

---

## 7. Display rules

### Rows per size

| WidgetFamily | Rows | Notes |
|---|---|---|
| `.systemSmall` | 3 | Name + one primary number only. Extremely tight. |
| `.systemMedium` | 5 | Name + primary number + change %. |
| `.systemLarge` | 10 | Full two-column layout. |
| `.systemExtraLarge` | 15 | Full layout, comfortable leading. |

Declare `.supportedFamilies` for all four. `.systemExtraLarge` is macOS-only; guard it with
`#if os(macOS)` so the code stays portable if you ever add iPadOS.

If the config has fewer entries than the size allows, render only what exists and leave the remaining
space empty. Do not pad with placeholder rows.

### What each row shows

**Stock (`ST`)** — the low and high of the trading session are the required values:

```
RELIANCE            2,812.40 – 2,877.95
Reliance Ind.       L 2,812.40  H 2,877.95     ▲ 0.71%
```

At Small, space permits only one number. Show the range compactly as `2,812–2,878` with no decimals,
or if that still overflows, show `H 2,878` only and let the accessibility label carry both.

**Mutual fund (`MF`)** — NAV is the required value:

```
Parag Parikh Flexi     ₹78.4312   NAV · 26 Sep
```

NAV renders with four decimal places (AMFI convention); stock prices with two. Use
`NumberFormatter` with the `en_IN` locale so grouping follows the Indian lakh/crore convention
(`1,23,456.78`, not `123,456.78`).

### Name shortening

Required behaviour: long names must be shortened, not clipped mid-glyph at random.

Apply in this order and stop at the first that fits:

1. If the config entry has an explicit `name`, use it verbatim. The user's choice always wins, even
   if it overflows — then and only then fall back to tail truncation.
2. Strip noise suffixes, case-insensitively, one pass:
   `Ltd`, `Limited`, `Ltd.`, `Pvt`, `Private`, `Corporation`, `Corp`, `Industries`,
   and for funds: `Fund`, `Scheme`, `Plan`, `Direct`, `Regular`, `Growth`, `IDCW`, `Payout`,
   `Reinvestment`, `Option`.
3. Abbreviate known long words via a lookup table, e.g. `Flexi Cap → FlexiCap`,
   `Small Cap → SmallCap`, `Large & Mid Cap → L&M Cap`, `Technology → Tech`,
   `Pharmaceuticals → Pharma`, `Financial Services → Fin Svcs`,
   `Index Fund → Index`, `Nifty Fifty → Nifty 50`. Put this table in a JSON resource, not in code,
   so it can be extended without a rebuild.
4. Collapse the AMC name to its common short form for funds (`Parag Parikh`, `HDFC`, `ICICI Pru`,
   `SBI`, `Nippon India`, `Kotak`, `Axis`, `Mirae`, `Quant`, `Motilal Oswal` → `MO`).
5. Truncate to `display.maxNameLength` graphemes at a word boundary and append `…`.

Regardless of what is shown, every row's accessibility label and its `.help()` tooltip must contain
the untruncated `fullName` plus all numeric values spelled out.

### Theme, Liquid Glass, and appearance

- Never hard-code colours. Use semantic colours only: `.primary`, `.secondary`, `Color(nsColor:
  .separatorColor)`, `.quaternaryLabelColor`. Light and Dark then follow the system automatically.
- Gains and losses need a semantic pair that survives both themes and is distinguishable by users
  with deuteranopia. Use a green/red pair drawn from the system palette (`.systemGreen`/`.systemRed`)
  **plus** a ▲/▼ glyph, so colour is never the sole carrier of meaning.
- For the widget background use `containerBackground(for: .widget)`. On macOS Tahoe, supplying
  `.clear` or a very low-opacity material inside that modifier lets the system's Liquid Glass
  treatment show through when the user has it enabled, and falls back to an opaque material when they
  have reduced transparency on. Do not paint your own opaque rectangle — that defeats the effect.
- Respect `accessibilityReduceTransparency`: when true, substitute a solid
  `Color(nsColor: .windowBackgroundColor)`.
- Respect `accessibilityReduceMotion`: no animated transitions on refresh.
- Support Dynamic Type via `@ScaledMetric` for row height and spacing. At the largest sizes, drop the
  change-% column before you let the name truncate further.
- Verify all four sizes in Light, Dark, Increased Contrast, Reduced Transparency, and with Liquid
  Glass both on and off. That is a 4 × 5 matrix of SwiftUI previews; generate them with a
  `PreviewProvider` loop rather than by hand.

### Footer

Every size except Small shows a one-line footer: the as-of time in the user's local zone with the IST
equivalent in parentheses, and a status glyph when `status != "ok"`. Example:
`10:30 IST · updated 2m ago`. When data is stale, say so explicitly —
`Stale · last updated Fri 10:30 IST` — because a silently stale stock widget is worse than an empty
one.

---

## 8. Implementation notes

### Tooling

Swift 6 with strict concurrency, SwiftUI, WidgetKit, minimum deployment target macOS 26 (Tahoe).
Prefer Swift Package Manager for the shared core so it is unit-testable outside Xcode. Layout:

```
BharatStockWidget/
  Packages/BharatStockCore/       # Config, Cache, Budget, MCP client, name shortener — pure Swift, no UI
  App/                            # BharatStockApp container
  Helper/                         # BharatStockHelper CLI
  Widget/                         # WidgetKit extension
  docs/mcp-tools.json
  docs/mcp-tools.md
  Tests/
```

`BharatStockCore` must not import WidgetKit or AppKit. All three executables depend on it.

### MCP client

Implement a minimal JSON-RPC-2.0-over-stdio client: launch the server with `Process`, write
newline-delimited JSON to stdin, read framed responses from stdout, and drain stderr to the log.
Support `initialize`, `tools/list`, `tools/call`. Enforce a 20-second timeout per call and a
60-second ceiling on the whole refresh cycle, then terminate the child process and reap it. Always
kill the child in a `defer` block; never leak a Node process.

Resolve the `npx` path explicitly rather than relying on `PATH`, which launchd does not populate the
way a shell does. Probe `/opt/homebrew/bin/npx`, `/usr/local/bin/npx`, then
`/usr/bin/env npx`. If none is found, write `status: "config_error"` with a message telling the user
to install Node, and keep serving the last good cache.

Cache the npx download by invoking `npx -y bharatstock-mcp` once at setup so the first scheduled run
does not pay a network install cost inside its timeout.

### Logging

Use `os.Logger` with subsystem `com.<you>.bharatstockwidget` and categories `config`, `mcp`,
`budget`, `widget`. Also append a rotating plaintext log at
`~/Library/Logs/BharatStockWidget/helper.log`, capped at 1 MB with one generation of rotation, so a
non-technical user can attach it to a bug report. Redact the API key in both sinks.

### Testing

Unit tests, all offline, against a fixture-backed fake MCP transport:

- Config parsing: valid, one bad entry among good ones, wrong `type`, missing `symbol`, duplicate
  symbols, empty array, 20 entries, unknown keys, total garbage.
- Budget: consumption, exhaustion mid-cycle, IST midnight rollover, the five-request reserve, a
  simulated day of one scheduled plus two manual refreshes staying under 50.
- Schedule: 10:30 IST resolved into local time for a machine in IST, US Pacific, and UTC; behaviour
  across a US DST transition; catch-up after a two-day sleep.
- Name shortener: a table-driven test with at least twenty real NSE tickers and twenty real fund
  scheme names, asserting output length and that no shortened name becomes ambiguous within the same
  config.
- Cache: atomic write under a simulated crash, forward-compatible read of a `schemaVersion: 2` file.
- Number formatting: `en_IN` grouping, 2 dp for stocks, 4 dp for NAV.

Add a `--dry-run` flag to the helper that runs a full cycle against fixtures, consumes zero budget,
and prints the cache it would have written. Use it as the smoke test.

---

## 9. Deliverables

1. A building Xcode project with the four targets above, plus the SPM core package.
2. `docs/mcp-tools.json` and `docs/mcp-tools.md` produced by real tool discovery against the live
   server.
3. Generated `config.example.json` and `README.txt` for the config directory.
4. A `Makefile` or `just` file with `build`, `test`, `install-agent`, `uninstall-agent`, `dry-run`.
5. A top-level `README.md` covering install, where the config lives, how to add an instrument, how the
   request budget works, how to force a refresh, how to read the logs, and how to fully uninstall
   (including removing the LaunchAgent and the App Group container).
6. SwiftUI previews covering the appearance matrix in §7.

## 10. Definition of done

- All four widget sizes render 3/5/10/15 rows from config order, with correct Light, Dark, and Liquid
  Glass appearance.
- Stocks show session low and high; funds show NAV with its `navDate`.
- Editing `config.json` and saving causes the widget to reflect the change on the next refresh, and
  immediately on "Refresh now", with no rebuild.
- A full day of operation, including a manual refresh and one forced failure-plus-retry, provably
  consumes fewer than 50 requests, demonstrated by a test.
- Network off, API down, bad key, and malformed config each produce a legible widget state, never a
  blank or crashed widget.
- No API key appears in any log, in the cache file, or in source control.

---

## 11. Assumptions you should confirm before coding

1. *Assumption*: mutual funds are identified by AMFI scheme code. Confirm during tool discovery; if
   the MCP server expects a name or ISIN instead, support that and update the config README.
2. *Assumption*: the stock quote tool returns intraday session low/high. If it returns only a daily
   OHLC bar for the previous close, say so explicitly in the UI — a 10:30 IST fetch is barely an hour
   into the trading session, so "low/high" will mean "so far today" and should be labelled as such.
3. *Assumption*: a single daily 10:30 IST refresh is genuinely what is wanted, even though it lands
   early in the session and before the day's NAV is published. If the intent was end-of-day values,
   a second window around 19:00 IST would serve better and still fit the 50-request budget. Raise
   this, implement 10:30 as specified, and make the time a config field so it costs the user one edit
   to change.
4. *Assumption*: Node is installed on the target machine. If it may not be, add the REST fallback
   described in §5 so the widget still works without it.
5. *Open*: whether the widget should be clickable. A sensible default is that clicking a row opens
   the container app focused on that instrument. Implement the `widgetURL`/`Link` plumbing but keep
   the destination view minimal.
