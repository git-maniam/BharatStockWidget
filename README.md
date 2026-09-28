# BharatStock Widget

A macOS Tahoe desktop and Notification Centre widget showing daily prices for a list of Indian
stocks and mutual funds you define in one hand-editable file.

- **Stocks** show the low and high of a trading session, plus the date that session belongs to.
- **Mutual funds** show NAV to four decimal places, always beside the NAV's own date.
- Four sizes: 3, 5, 10 and 15 rows, filled in the order you list your instruments.
- Numbers use Indian lakh/crore grouping (`1,23,456.78`).
- Never goes blank. Network down, bad key, broken config — each produces a legible state that tells
  you what happened.

```
Reliance            L 1,210.50  H 1,227.40 · 25 Sep   ▲ 0.56%
Tata Consultancy…   L 2,038.10  H 2,090.20 · 25 Sep   ▼ 0.24%
HDFC Bank           L 723.00  H 739.65 · 25 Sep       ▲ 0.92%
Parag Parikh Flexi  ₹108.1525   NAV · 25 Sep          ▲ 0.09%
Quant Small Cap     ₹113.0225   NAV · 25 Sep          ▲ 0.09%
────────────────────────────────────────────────────────────
21:30 IST · updated 4m ago
```

---

## Install

You need Xcode (for the widget extension) and a Team ID (for the App Group). A free Apple ID is
enough — no paid Developer Program membership.

```bash
brew install xcodegen          # one-off
```

**1. Set your Team ID.** Edit `Config/Signing.xcconfig`:

```
DEVELOPMENT_TEAM = ABCDE12345
```

Find it with `security find-identity -v -p codesigning` — it is the value in parentheses, as in
`Apple Development: you@example.com (ABCDE12345)`. If you have never signed anything, open Xcode ▸
Settings ▸ Accounts and add your Apple ID first; that creates a Personal Team.

This matters more than it looks: macOS requires an App Group identifier to be prefixed with your
Team ID, and the App Group is the only channel between the widget and the app. Leave it unset and
the widget installs but shows nothing. The app's window says so if this happens.

**2. Build and install.**

```bash
make install
```

**3. Open the app once.** That creates your config, writes a `README.txt` explaining every field
beside it, and links it to a friendly path. Paste your API key into the setup screen.

**4. Add the widget.** Right-click the desktop (or open Notification Centre) ▸ Edit Widgets ▸
BharatStock. Pick a size.

Get an API key free at [bharatstockapi.com](https://bharatstockapi.com). The free plan allows 50
requests a day, which is roughly eight times what this widget needs.

---

## Where the config lives

Edit this file:

```
~/Library/Application Support/BharatStockWidget/config.json
```

That path is a symlink. The real file is inside the app's App Group container, because a sandboxed
widget extension is not permitted to read anything else — but you can edit either path with any
editor and it is the same file. `make where` prints both.

Beside it you will find `README.txt`, which documents every field with worked examples, and
`config.example.json` to copy from if you break something.

Save the file and the widget picks the change up at the next refresh, or immediately if you press
**Refresh now**. No rebuild, no restart.

### Adding an instrument

Append to `instruments`. Order is the only thing that decides what appears where — the first three
entries show at Small, the first five at Medium, ten at Large, fifteen at Extra Large. Entries past
the fifteenth are kept but never shown; the app tells you when that happens rather than truncating
silently.

```json
{ "type": "ST", "symbol": "INFY" },
{ "type": "ST", "symbol": "SBIN", "name": "SBI" },
{ "type": "MF", "symbol": "119551", "name": "ICICI Pru Bluechip" }
```

- `type` is `"ST"` for a stock or `"MF"` for a fund. Case does not matter.
- `symbol` is the NSE ticker for a stock, or the AMFI scheme code for a fund.
- `name` is optional. Give one and it is used exactly as written; leave it out and the API's name is
  shortened for you — "Reliance Industries Limited" becomes "Reliance".

Finding a scheme code:

```bash
curl -s "https://bharatstockapi.com/v1/mf/schemes?q=parag+parikh&plan=Direct&option=Growth" \
  -H "X-API-Key: $BHARATSTOCK_API_KEY" | python3 -m json.tool
```

Pick carefully: Direct and Regular plans of the same scheme have different codes and different NAVs.

Check your edit without spending a request:

```bash
make dry-run
```

That parses your real config, reports any problems per entry, and prints what each widget size would
render — using canned API responses, so it never touches the network.

---

## How the request budget works

`maxRequestsPerDay` in your config is a hard ceiling, counted per day and reset at **midnight IST**.
It defaults to 50, matching the free plan's server-side limit.

A refresh costs **one request for all your stocks together** — the API has a batch quote endpoint —
**plus one per mutual fund**. The default watchlist costs 3 requests per refresh, 6 a day across both
windows. Even fifteen funds with no stocks at all costs 30 a day.

The rules the code actually enforces:

- Every outbound request is charged *before* it is issued, so a crash can only over-count.
- A refresh cycle is refused unless its **worst case including retries** fits, and 5 requests are
  always held in reserve so a manual refresh stays possible.
- Duplicated symbols are fetched once.
- Retries are capped at two, 2s then 8s with ±20% jitter, and only for transport errors, 5xx and
  429. A 401 or a 404 is never retried — a bad key or a typo will not get better, and retrying it
  only burns the ceiling.
- Manual refresh is throttled to one per five minutes regardless of remaining budget.

The app's window shows `7 of 50 requests used today, resets at midnight IST.`

### Refresh schedule

Two windows a day, **10:30 and 21:30 IST**, configurable in `refresh.times`.

These are best-effort, not alarms. macOS decides when to wake a widget extension, so a refresh may
land anywhere from on the minute to a few hours late. That costs nothing in practice, because the
API publishes completed trading sessions only — the numbers do not change between the two windows.
What *is* guaranteed is the ceiling: each window is fetched at most once per day however often macOS
wakes the widget, because eligibility is derived from which window boundary has elapsed rather than
from time since the last fetch.

The 21:30 window is the one that matters most: it lands after both the day's closing bar and that
evening's NAV publication.

### Forcing a refresh

Open the app and press **Refresh now** (or ⌘R). It ignores the schedule but honours the five-minute
cooldown, and reloads the widget immediately on success.

---

## Reading the logs

```bash
make logs       # tail the plaintext log
make console    # stream os_log for both the widget and the app
```

The plaintext log is at `~/Library/Logs/BharatStockWidget/helper.log`, capped at 1 MB with one
generation of rotation. Your API key is redacted in both sinks — to the first twelve characters,
`bsk_live_0Rs…` — so the file is safe to attach to a bug report.

---

## Uninstalling

```bash
make uninstall
```

That removes the app, the App Group container (**including your config and watchlist**), the config
symlink, and the logs. There is no LaunchAgent and no login item to clean up — this build has
neither.

---

## Development

```bash
make test        # 106 offline tests, no Xcode project needed
make test-live   # 5 more against the real API (~6 requests from your ceiling)
make build       # compile every target, no signing required
make dry-run     # full refresh cycle against fixtures
make check       # all of the above, in order
make open        # open in Xcode
```

### Layout

```
Packages/BharatStockCore/   Config, cache, budget, schedule gate, REST client, name shortener.
                            Pure Swift — no WidgetKit, no AppKit — so it is testable with
                            `swift test` alone. Also holds the dry-run CLI.
App/                        The container app: setup, status, diagnostics, Refresh now.
Widget/                     The WidgetKit extension: timeline provider and views.
docs/                       Decision record, MCP substitution record, endpoint inventory.
project.yml                 XcodeGen source for BharatStockWidget.xcodeproj, which is generated.
```

The Xcode project is generated, not committed as the source of truth. Edit `project.yml` and run
`make project`.

### Two things worth knowing before changing anything

**The widget fetches its own data.** There is no helper process and no LaunchAgent. `RefreshGate`,
not `launchd`, is what stops the widget exhausting the API — see `Widget/QuoteTimelineProvider.swift`
and `Packages/BharatStockCore/Sources/BharatStockCore/Schedule/RefreshGate.swift`.

**The app is deliberately not sandboxed; the widget is.** A widget extension must be sandboxed, and
the app must not be, because it maintains the symlink at `~/Library/Application Support`, which a
sandboxed process has redirected into its own container. App Groups work either way for a
Developer-ID app.

### Testing

Everything is offline and fixture-backed. The suite covers config parsing (valid, one bad entry
among good, wrong type, missing symbol, duplicates, 20 entries, unknown keys, total garbage),
budget accounting (exhaustion mid-cycle, IST midnight rollover, the five-request reserve, a
simulated day of two scheduled plus two manual refreshes staying under 50), the schedule (windows
resolved across time zones, a US DST transition, catch-up after a two-day sleep), the name shortener
(20 real NSE tickers and 20 real fund names, asserting length and non-ambiguity at three widths),
atomic cache writes, forward-compatible reads of a `schemaVersion: 2` file, `en_IN` formatting, and
the retry ladder.

A separate, opt-in suite (`make test-live`) hits the real API to catch the one thing fixtures
cannot: the response shape drifting away from what the client decodes. It also asserts that MCP is
still refused for the configured key — if that test ever fails, the plan has been upgraded and
`docs/mcp-tools.md` should be revisited.

SwiftUI previews cover the size × appearance matrix and every degraded state — see
`Widget/Previews.swift`.

---

## Documentation

- **[`docs/decisions.md`](docs/decisions.md)** — every deviation from the original spec, what forced
  it, and what it cost. Read this first if something looks different from what you expected.
- **[`docs/mcp-tools.md`](docs/mcp-tools.md)** — why this uses the REST API rather than the MCP
  server, what tool discovery actually returned, and how to switch to MCP if the key's plan is
  upgraded.
- **[`docs/rest-endpoints.json`](docs/rest-endpoints.json)** — endpoint inventory distilled from the
  live OpenAPI document.

---

## A note on the numbers

The BharatStock API publishes **completed trading sessions only**. There is no intraday data: at
15:40 IST on a trading day, the latest available bar is still the previous session's. So a stock
row's low and high are that session's range, not today's so far, and the date shown beside each row
is not decoration — it tells you which day you are reading.

Mutual fund NAV is published once a day after markets close, typically 21:00–23:00 IST. A NAV is
labelled with its own date and only ever reads "NAV today" when that date really is today in India.

Market data from [BharatStock API](https://bharatstockapi.com).
