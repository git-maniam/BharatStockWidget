# Tool discovery, and why this project does not use MCP

Spec §3 makes MCP tool discovery a required first step and asks for `docs/mcp-tools.json` produced
by real discovery against the live server. That file is **not present**, and cannot be: the MCP
server refuses the supplied API key. §3 also says "If a tool you expect does not exist, adapt and
record the substitution in that file" — this document is that record.

---

## 1. What discovery actually returned

Two MCP transports exist. Both were tried.

### The hosted remote server (undocumented in the spec, found on the landing page)

`https://bharatstockapi.com/v1/mcp`, authenticated with `Authorization: Bearer <key>`.

`initialize` succeeds:

```
POST /v1/mcp
{"jsonrpc":"2.0","id":1,"method":"initialize",
 "params":{"protocolVersion":"2025-06-18","capabilities":{},
           "clientInfo":{"name":"probe","version":"0.1"}}}

→ 200 {"jsonrpc":"2.0","id":1,"result":{
     "protocolVersion":"2025-06-18",
     "capabilities":{"tools":{}},
     "serverInfo":{"name":"bharatstock","version":"0.1.0"}}}
```

`tools/list` does not:

```
POST /v1/mcp
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}

→ 200 {"jsonrpc":"2.0","id":2,"error":{
     "code":-32003,
     "message":"MCP access requires the Developer or Pro plan (current: 'free').
                Upgrade at https://bharatstockapi.com/#pricing"}}
```

So the gate is on **tool access**, not on authentication. The key is valid; its plan is not
entitled. Per `/v1/plans`, MCP requires Developer (₹1,500/month) or Pro (₹5,000/month); the supplied
key is on Free.

### The local stdio server (`npx -y bharatstock-mcp`)

Cannot run on the target machine and would not help if it could:

- Node is not installed. `npx` is absent, and neither `/opt/homebrew/bin/npx` nor
  `/usr/local/bin/npx` — the two paths §8 tells us to probe — exists.
- The npm package is the same server behind the same plan check. Its landing page states the check
  happens at startup: *"The server verifies your plan on startup — Free and Starter keys are
  declined with an upgrade prompt, since MCP is a Developer/Pro feature."* Installing Node would
  therefore produce the same `-32003`.

**Conclusion:** the tool names and input schemas §3 asks for are unobtainable with this key, by
either transport. No tool names have been invented, as §3 forbids.

---

## 2. The substitution

The REST API is used instead, via `URLSession`. It is not a degraded fallback — for this widget it
is strictly better, for reasons that only became clear during discovery.

| What the widget needs | MCP tool | Substituted REST endpoint | Cost |
|---|---|---|---|
| Stock session low/high | *unknown — "Stock quotes (single + batch)" per the landing page* | `GET /v1/stocks/quotes?symbols=A,B,C` | **1 request for up to 50 tickers** |
| Mutual fund NAV | *unknown — "Mutual-fund NAV & returns"* | `GET /v1/mf/schemes/{scheme_code}/nav?limit=2` | 1 request per fund |
| Resolve a scheme code | *unknown — "Mutual-fund scheme search"* | `GET /v1/mf/schemes?q=…&amc=…&plan=…&option=…` | 1 request |
| Resolve a ticker | *unknown — "Stock search"* | `GET /v1/search?q=…` | 1 request |

Every endpoint above is documented in the live OpenAPI 3.1 spec at
`https://bharatstockapi.com/openapi.json`, distilled into
[`rest-endpoints.json`](rest-endpoints.json) alongside this file. The landing page states that
"Every tool wraps the same endpoint as the REST API, so your plan's rate limits and history depth
apply identically" — so the substitution costs no data and no fidelity.

### Why each was chosen

**`/v1/stocks/quotes` over `/v1/stocks/{ticker}`.** Both return prices, but the per-ticker endpoint
returns a very large company profile — fundamentals, 40-odd ratios, shareholding patterns, the top
ten mutual funds holding the stock — of which the widget renders four numbers. Worse, it costs one
request per ticker. The batch endpoint returns exactly the fields needed, for up to 50 tickers, in
one request:

```json
{ "symbol": "RELIANCE", "company_name": "Reliance Industries Limited",
  "trade_date": "2026-09-25", "open": 1210.5, "high": 1227.4, "low": 1210.5,
  "close": 1226.0, "prev_close": 1219.2, "change_pct": 0.56,
  "volume": 13138735, "found": true }
```

This single choice is what makes spec §5's 50-request ceiling comfortable rather than tight. §5
assumed "one full refresh costs at most 15 requests"; it actually costs **one**, plus one per fund.
A 15-stock watchlist refreshed at both daily windows spends 2 requests a day.

`found: false` is also worth noting: an unrecognised ticker comes back as a normal 200 with null
prices and `found: false`, not as an HTTP error. That is why a typo in the config renders as an
`unavailable` row and is never retried — retrying a typo would only burn the ceiling.

**`/v1/mf/schemes/{scheme_code}/nav` with `limit=2`.** The endpoint returns a dated NAV series,
newest first, defaulting to a year of history. Two points is all the widget needs: the latest NAV,
and the one before it to compute a change the API does not itself provide.

```json
{ "scheme_code": "122639", "scheme_name": "Parag Parikh Flexi Cap Fund",
  "count": 2, "data": [ { "date": "2026-09-25", "nav": 108.1525 },
                        { "date": "2026-09-24", "nav": 108.0528 } ] }
```

There is no batch NAV endpoint, so funds are the only per-instrument cost in a refresh.

---

## 3. Two spec assumptions settled by discovery

**§11 Assumption 1 — "mutual funds are identified by AMFI scheme code" — confirmed.**
`/v1/mf/schemes/{scheme_code}/nav` takes the AMFI code directly. `/v1/mf/schemes` also accepts an
`isin` filter, so an ISIN can be resolved to a code, but the code is the identifier the NAV endpoint
wants. This is what the generated `README.txt` documents.

Worth flagging: **two of the spec's example scheme codes are wrong.** `120503` is *Axis ELSS Tax
Saver Fund*, not Parag Parikh Flexi Cap. The verified codes for the schemes §4 names are:

| Scheme | Spec | Correct |
|---|---|---|
| Parag Parikh Flexi Cap, Direct, Growth | `120503` | **`122639`** |
| Quant Small Cap, Direct, Growth | `118989` | **`120828`** |

Both were resolved with `GET /v1/mf/schemes?q=…&amc=…&plan=Direct&option=Growth`. Note that Direct
and Regular plans of one scheme have different codes and different NAVs — `122640` is the Regular
plan of the same fund.

**§11 Assumption 2 — "the stock quote tool returns intraday session low/high" — false.**
There is no intraday data at all. At 15:40 IST on Monday 28 September 2026 — mid-session on a
trading day — every quote still reported `trade_date: "2026-09-25"`, the previous Friday. The API
publishes **completed sessions only**.

§11 tells us that in this case we must "say so explicitly in the UI", and it is honoured in the
stricter of the two branches it offers: `low`/`high` can never legitimately be labelled "today's
range", so every stock row carries the date of the session it belongs to (`L 1,210.50 H 1,227.40 ·
25 Sep`), exactly as §6 already required for a fund's `navDate`. The accessibility label spells it
out — "for the session of 25 Sep" — and the generated `README.txt` explains it in prose.

This is also why the refresh schedule moved to a second 21:30 IST window: with EOD-only data, a
10:30 fetch returns the same numbers an 18:00 one would, and a 21:30 fetch is the one that picks up
the current day's bar and that evening's NAV.

---

## 4. If the plan is ever upgraded

The fetch layer is written against a `QuoteSource` protocol with two methods, so an MCP
implementation slots in without touching the refresh cycle, the cache, or any view:

```swift
public protocol QuoteSource: Sendable {
    func fetchStockQuotes(symbols: [String]) async throws -> [StockQuote]
    func fetchFundNAV(schemeCode: String) async throws -> FundNAV
}
```

`RefreshCoordinator` takes a `makeSource` closure, which is how the test suite injects a
fixture-backed source; an `MCPQuoteSource` would arrive the same way, and `QuoteCache.dataSource`
already carries `"rest"` vs `"mcp"` so a cache file records which path produced it.

Two things worth knowing before writing it:

1. **Use the hosted endpoint, not `npx`.** §1's central architectural claim — that the widget cannot
   own network I/O because a sandboxed extension cannot fork `npx` — does not apply to
   `https://bharatstockapi.com/v1/mcp`. It is plain HTTP POST with JSON-RPC bodies, so a sandboxed
   extension with `com.apple.security.network.client` can speak it directly. No subprocess, no Node,
   no `Process` lifecycle to get wrong, nothing to leak.
2. **Run real discovery first.** This document deliberately does not guess at tool names. Upgrade the
   key, then:

   ```bash
   curl -s https://bharatstockapi.com/v1/mcp \
     -H "Authorization: Bearer $BHARATSTOCK_API_KEY" \
     -H "Content-Type: application/json" \
     -H "Accept: application/json, text/event-stream" \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
     | python3 -m json.tool > docs/mcp-tools.json
   ```

   Then prefer whichever tool wraps `/v1/stocks/quotes`, per §3's instruction to prefer a batch tool
   where one exists.

Note that a Developer plan also raises the daily limit from 50 to 10,000 requests, at which point
the `RequestBudget` machinery becomes largely vestigial — though it is cheap to keep, and it is the
only thing that makes the ceiling a provable property rather than an estimate.

---

## 5. Reproducing these findings

```bash
# Plan limits — where the 50/day figure comes from.
curl -s https://bharatstockapi.com/v1/plans | python3 -m json.tool

# MCP initialize succeeds, tools/list is refused.
curl -s https://bharatstockapi.com/v1/mcp \
  -H "Authorization: Bearer $BHARATSTOCK_API_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

# The substituted endpoints.
curl -s "https://bharatstockapi.com/v1/stocks/quotes?symbols=RELIANCE,TCS,HDFCBANK" \
  -H "X-API-Key: $BHARATSTOCK_API_KEY" | python3 -m json.tool
curl -s "https://bharatstockapi.com/v1/mf/schemes/122639/nav?limit=2" \
  -H "X-API-Key: $BHARATSTOCK_API_KEY" | python3 -m json.tool

# Regenerate rest-endpoints.json's source document.
curl -s https://bharatstockapi.com/openapi.json > /tmp/oas.json
```

Each of these costs one request against the daily ceiling, except `/v1/plans` and `/openapi.json`,
which need no key.
