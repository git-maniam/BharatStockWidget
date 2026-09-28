# Decision record — deltas from `bharatstock-widget-spec.md`

Recorded 2026-09-28. The spec is binding except where this document overrides it. Every override
below was either (a) forced by a verified fact about the API or this machine, or (b) explicitly
chosen by the project owner after that fact was surfaced.

---

## 1. Verified facts that forced changes

All of these were established against the live API and this machine on 2026-09-28, not assumed.

| # | Finding | Evidence |
|---|---|---|
| F1 | **MCP is unavailable on the supplied key.** | `tools/list` against the hosted endpoint returns JSON-RPC error `-32003`: `MCP access requires the Developer or Pro plan (current: 'free')`. `initialize` succeeds (`serverInfo: bharatstock 0.1.0`), so the gate is on tool access, not on auth. |
| F2 | **Node is not installed.** | `npx not found`; neither `/opt/homebrew/bin/npx` nor `/usr/local/bin/npx` exists. The `npx -y bharatstock-mcp` path of §3 cannot run at all. |
| F3 | **A hosted remote MCP endpoint exists**, undocumented in the spec: `https://bharatstockapi.com/v1/mcp`, `Authorization: Bearer <key>`. | Landing page at `/mcp`; confirmed by a successful `initialize`. Moot for now per F1, but it means §1's "the widget cannot fork a subprocess" argument has a subprocess-free MCP answer if the plan is ever upgraded. |
| F4 | **Xcode is not installed** — Command Line Tools only (Swift 6.4, target `arm64-apple-macosx26.0`), and `security find-identity -v -p codesigning` reports `0 valid identities found`. | A WidgetKit extension cannot be compiled, signed or installed in this state. |
| F5 | **The REST API is fully sufficient**, and publishes an OpenAPI 3.1 document at `/openapi.json` (33 paths). | `GET /v1/stocks/RELIANCE` → 200 with prices, metrics and fundamentals. |
| F6 | **A batch quote endpoint exists**: `GET /v1/stocks/quotes?symbols=…` (max 50 tickers). | Returned `high`, `low`, `close`, `prev_close`, `change_pct`, `volume`, `trade_date`, `found` for RELIANCE, TCS, HDFCBANK in **one** request. |
| F7 | **MF NAV is keyed by AMFI scheme code** — §11 Assumption 1 confirmed. | `GET /v1/mf/schemes/120503/nav` → dated NAV series. No batch variant, so funds cost one request each. |
| F8 | **There is no intraday data.** At 15:40 IST on Mon 28 Sep — mid-session — every quote still reported `trade_date: "2026-09-25"` (Friday). | §11 Assumption 2 is **false**: `low`/`high` is the last *completed* session's range and can never mean "so far today". |
| F9 | **The 50/day ceiling of §5 is precisely the Free plan limit.** | `/v1/plans` → `free: daily_request_limit: 50`; starter 2000, developer 10000, pro 50000. |
| F10 | **Two of the spec's example scheme codes are wrong.** `120503` is *Axis ELSS Tax Saver Fund*, not Parag Parikh Flexi Cap. | `/v1/mf/schemes/120503/nav` returns `scheme_name: "Axis ELSS- Tax Saver Fund"`. |

### Corrected identifiers (F10)

| Instrument | Spec said | Correct code | Resolved name |
|---|---|---|---|
| Parag Parikh Flexi Cap | `120503` | **`122639`** | Parag Parikh Flexi Cap Fund — Direct Plan, Growth (PPFAS Mutual Fund) |
| Quant Small Cap | `118989` | **`120828`** | Quant Small Cap Fund — Direct Plan, Growth (quant Mutual Fund) |

Both resolved via `GET /v1/mf/schemes?q=…&amc=…&plan=Direct&option=Growth`.

---

## 2. Owner decisions

| Topic | Spec said | Decision | Consequence |
|---|---|---|---|
| **Data path** | MCP via `npx -y bharatstock-mcp`, REST as fallback | **REST only.** | Forced by F1+F2. `docs/mcp-tools.md` records the substitution as §3 requires, in place of the unobtainable `docs/mcp-tools.json`. |
| **Targets** | Three: App + Widget + Helper, helper owns all network I/O | **Two: App + Widget. The widget fetches directly.** | §1's "hard architectural rule" existed solely because a sandboxed extension cannot spawn `npx`. With `URLSession` that constraint is gone. Drops the LaunchAgent, the plist time-zone recomputation, and `install-agent`/`uninstall-agent`. |
| **Refresh schedule** | One daily run at 10:30 IST | **Two windows: 10:30 and 21:30 IST**, best-effort. | 21:30 lands after both the EOD bar and NAV publication, so the widget shows the current trading day rather than yesterday's. Costs ~12 of 50 requests/day. |
| **Schedule precision** | `launchd` `StartCalendarInterval` | **Widget-side window gate.** | See §3 below. |
| **Config location** | `~/Library/Application Support/BharatStockWidget/config.json` | **Canonical file in the App Group container; the app creates a symlink at the spec's path.** | A sandboxed widget cannot read `~/Library/Application Support`. The user still hand-edits the documented path — their editor is not sandboxed and follows the link — while the widget reads the real path legally. §4's intent is preserved. |
| **Signing** | `com.<you>.` placeholders | **Free Apple ID Personal Team**, bundle prefix `com.ravisubramaniam`. | App Group is `group.com.ravisubramaniam.bharatstockwidget`, Team-ID-prefixed at build time. Team ID to be supplied once Xcode is signed in. |
| **Xcode** | assumed present | **Owner installs from the App Store.** | Meanwhile `Packages/BharatStockCore` is built and unit-tested with the CLT Swift 6.4 toolchain, which needs no Xcode. App and Widget targets are verified after the install. |
| **API key in git** | §10: must not appear in source control | **Owner rotates the key.** Already-committed key in `bharatstock-widget-spec.md` @ `620e798` is left in history and becomes worthless on rotation. | The generated config ships with `apiKey: ""`; the app's first-run screen collects the key. §2's `0600` mode and redaction rules still apply in full. |
| **Default watchlist** | 3 stocks + 2 funds, two codes wrong | **Same five instruments, with F10's corrected scheme codes.** | |

---

## 3. Consequences that need care in implementation

### 3.1 Scheduling is best-effort, and the gate is what makes the budget safe

WidgetKit owns the wake-up clock; a timeline reload request is a hint, not a guarantee. So "two windows"
is implemented as a **gate**, not a timer:

- The timeline provider requests the next reload just after the upcoming IST boundary.
- On *any* wake, a fetch is attempted only if a window boundary has elapsed **and** `lastServedWindow`
  in the shared state is older than that boundary.
- Therefore: at most two network fetches per day, arriving anywhere from on-time to a few hours late.
  Because the data is EOD-only (F8), lateness costs the user nothing.

This gate — not `launchd` — is now the mechanism that makes §5's ceiling a provable property.

### 3.2 `BHARATSTOCK_API_KEY` is largely moot

§2 offers an environment-variable override so a security-conscious user can keep the key out of the
file. A widget extension is launched by the system and inherits no user environment, so this route
cannot work for the component that now does the fetching. The override is kept where it still has
meaning — the container app and the `dry-run` tool — and the config-file field is the only path that
works for the widget. Documented plainly in the generated `README.txt` rather than silently broken.

### 3.3 Low/high must be labelled as a completed session

Per F8, a row can never legitimately say "today's range". Rows carry the bar's `trade_date` and the
UI labels the range against that date (e.g. `L 1,210.50  H 1,227.40 · 25 Sep`), exactly as §6 already
requires for NAV's `navDate`. §11 Assumption 2's instruction — "say so explicitly in the UI" — is
honoured in its stricter branch.

### 3.4 The request budget is roomier than §5 assumes

F6 collapses the cost model: one batch call covers every stock regardless of count, and funds cost one
each. A full refresh of the default watchlist is **3 requests** (1 batch + 2 NAV), not 15. Two windows
per day is 6. The `RequestBudget` actor, the five-request reserve, the IST-midnight rollover and the
five-minute manual-refresh throttle are all still implemented as specified — the ceiling is a safety
property, and it is shared with anything else using the same key.

### 3.5 The container app is not sandboxed; the widget is

Discovered while wiring up entitlements, and it constrains the choice made above. A sandboxed
process has `~/Library/Application Support` **redirected into its own container**, so a sandboxed
container app could not create the symlink at the path §4 documents — the very thing that decision
was meant to preserve. Meanwhile a widget extension *must* be sandboxed; that is not negotiable.

So the two targets differ:

| Target | `com.apple.security.app-sandbox` | Why |
|---|---|---|
| `BharatStockApp` | `false` | Needs the real `~/Library/Application Support` to maintain the friendly symlink. Legitimate for a Developer-ID app; would be rejected by the Mac App Store, which is not a target. |
| `BharatStockWidgetExtension` | `true` | Mandatory for widget extensions. Reads and writes only inside the App Group container. |

App Groups work for a non-sandboxed macOS app provided the entitlement is present and the identifier
is Team-ID-prefixed, so both targets resolve the same container path. Both also carry
`com.apple.security.network.client`: the widget for its scheduled fetches, the app for "Refresh now".

### 3.6 Deliverables that change shape

- `docs/mcp-tools.json` → **not obtainable** (F1). Replaced by `docs/rest-endpoints.json`, generated
  from the live OpenAPI document, plus `docs/mcp-tools.md` explaining the substitution and recording
  the hosted-MCP endpoint (F3) for a future upgrade.
- `Makefile` targets `install-agent` / `uninstall-agent` → **removed**; there is no agent. Replaced by
  `install` (build + copy to /Applications) and `uninstall` (remove app, App Group container, symlink).
- `build`, `test`, `dry-run` are unchanged.
