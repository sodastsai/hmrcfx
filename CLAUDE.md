# hmrc-fx-rates — Project Context for Claude Code

> Project-specific context only. General communication/workflow/debugging
> conventions come from the global `~/.claude/CLAUDE.md` — this file doesn’t
> repeat those.

## What this is

A small, pure-ish Python library that fetches HMRC’s published **monthly
customs exchange rates** and exposes them as typed, cached lookups by
`(year, month)` or by `date`/`datetime`.

Source: <https://www.trade-tariff.service.gov.uk/exchange_rates/monthly>

Primary (future) consumer: the UK CGT calculator side project, which needs
the official HMRC rate for a given transaction month to convert US/other
currency amounts to GBP. This package is being built standalone first.

**Non-goals**: not a general currency converter, not handling HMRC’s
*average* or *spot* rate endpoints (different URLs/use cases) — monthly
customs rates only.

## Data source — verified details

- HMRC publishes one set of rates per calendar month, on the penultimate
  Thursday of the *preceding* month. Rates apply to the following calendar
  month and don’t change retroactively once published.
- Download URL pattern (year + non-zero-padded month):
  - XML: `https://www.trade-tariff.service.gov.uk/api/v2/exchange_rates/files/monthly_xml_{year}-{month}.xml`
  - CSV: `https://www.trade-tariff.service.gov.uk/api/v2/exchange_rates/files/monthly_csv_{year}-{month}.csv`
  - e.g. June 2026 → `monthly_xml_2026-6.xml`
  - Use non-padded to match HMRC’s own links, but the server **normalises**:
    `monthly_xml_2026-06.xml` (zero-padded) returns the same valid XML
    (verified by live fetch, 2026-06-15). So don’t add a defensive assertion
    that padding is rejected — it isn’t.
- XML schema (verified by live fetch of `monthly_xml_2026-6.xml`, 2026-06-15):

  ```xml
  <exchangeRateMonthList Period="01/Jun/2026 to 30/Jun/2026">
    <exchangeRate>
      <countryName>...</countryName>
      <countryCode>...</countryCode>
      <currencyName>...</currencyName>
      <currencyCode>...</currencyCode>
      <rateNew>...</rateNew>
    </exchangeRate>
    <!-- repeated per currency -->
  </exchangeRateMonthList>
  ```

  `Period` attr format is `DD/Mon/YYYY to DD/Mon/YYYY`. `%b` (locale month
  abbreviation) is locale-dependent — use an explicit month-name map rather
  than relying on `strptime("%d/%b/%Y")` with the default C locale.
- `countryCode` is **not ISO** (first entry is Abu Dhabi → `DH`; ISO for the
  UAE is `AE`). Treat it as opaque metadata, never as a queryable key.
- A `currencyCode` repeats across entries: every Eurozone country emits its
  own `EUR` row, Abu Dhabi and Dubai both emit `AED`, etc. So the raw XML has
  multiple `<exchangeRate>` per currency. See collision policy under
  `MonthlyRates` below.
- **XML is the format. We don’t add CSV unless XML stops being an option** —
  e.g. HMRC drops the XML endpoint. It’s not a v1-deferral; it’s a standing
  decision. `xml.etree.ElementTree` (stdlib) handles XML cleanly, the schema
  is fetch-verified, and a second format is parsing surface and test surface
  for no benefit while XML works. If CSV ever becomes the only option, fetch
  a real file and confirm header/column order before parsing — don’t build
  against a guessed schema.
- A month with no published data (too far in the future, or before HMRC’s
  archive starts) returns 404 — surface as `RateDataNotAvailableError`, not
  a generic network error.

## Dependency policy

**Runtime: `httpx` only.** Rationale, since “fewest deps” and “async-ready”
pull in different directions:

- `requests` has no async client; `aiohttp` has no sync client. Using both
  to cover sync+async = two deps with inconsistent APIs.
- `httpx` gives one dependency and one API shape (`httpx.Client` /
  `httpx.AsyncClient`) for both. This is the better trade-off than
  requests + `asyncio.to_thread` shims, which would be “zero deps” but not
  *actual* non-blocking I/O.
- Parsing: stdlib only — `xml.etree.ElementTree`, `decimal.Decimal`,
  `datetime`. (Stdlib `csv` only enters the picture in the XML-dropped
  contingency — see Data source.)

If you (future Claude Code session) disagree with the httpx call after
seeing the real implementation effort, that’s a fine thing to revisit — just
update this section with the new rationale, don’t silently drift.

**Dev-only** (not shipped): `pytest`, `pytest-asyncio`, `respx` (mocks
`httpx` for tests, avoids live HTTP in the test suite). “Fewest deps” applies
to the runtime dependency tree, not test tooling.

## Public API shape

```python
from hmrc_fx_rates import HMRCFxRatesClient

client = HMRCFxRatesClient()  # cache_dir resolved per "Caching" below

rates = client.get_monthly_rates(2026, 6)        # sync, by year/month
rates = client.get_monthly_rates(date(2026, 6, 15))  # date/datetime → month extracted, day ignored

async with HMRCFxRatesClient() as client:
    rates = await client.aget_monthly_rates(2026, 6)
```

- One client class with both sync (`get_monthly_rates`) and async
  (`aget_monthly_rates`) methods, sharing cache/parsing logic — don’t fork
  into two parallel implementations.
- Accept `int, int`, `date`, or `datetime` for the month argument (extra
  overload, not separate functions). Use **plain `isinstance` checks**, not
  `singledispatchmethod`: singledispatch keys on the first arg’s type only,
  so it can’t distinguish two-`int` from one-`date` without awkward
  registration. isinstance is both less code and clearer here.
- Module-level convenience functions (`hmrc_fx_rates.get_monthly_rates(...)`
  using a default client) are a nice-to-have, not required for v1.

`MonthlyRates` (the return type):

- `period_start: date`, `period_end: date` — from the `Period` attribute.
  Also a sanity check against the requested `(year, month)`: on mismatch
  (HMRC served a different month than the URL implied), **raise** — that’s a
  real bug signal, not something to swallow silently.
- `rates: dict[str, Decimal]` keyed by currency code (`currencyCode`).
- **Collision policy** (currencies repeat across countries — see Data source):
  fold the multiple `<exchangeRate>` rows per currency by **asserting the
  rates are equal**, and raise an `HMRCFxRatesError` subclass if HMRC ever
  disagrees with itself. Don’t silently last/first-wins — a divergence feeds
  tax math wrong, so fail loud. A fixture test on `EUR` (many countries, one
  rate) covers this.
- `rate_for(currency_code: str) -> Decimal` — raises `UnknownCurrencyError`
  if absent. (Named `rate_for`, **not** `get`: `rates` is a dict, so a `get`
  method would shadow `dict.get`’s return-`None`-on-miss semantics with the
  opposite raising behaviour — a footgun.)
- **Always `Decimal`, never `float`** — this feeds tax calculations.
- Country name/code (`countryName`/`countryCode`) — keep if cheap as opaque
  metadata, but `rates` keyed by currency code is the primary interface
  (`countryCode` is not even ISO; see Data source).

## Caching

- Cache unit = one month’s **raw response body** (XML bytes), keyed as
  `{year}-{month}.xml`. Cache raw bytes, not the parsed `MonthlyRates` —
  keeps the cache format independent of model changes.
- Cache directory resolution order:
1. Explicit `cache_dir` argument to `HMRCFxRatesClient`
1. `HMRC_FX_CACHE_DIR` env var
1. `$XDG_CACHE_HOME/hmrc_fx_rates` if set, else `~/.cache/hmrc_fx_rates`
  - Linux/macOS paths only — personal sandbox tool, no Windows handling
    needed unless that changes.
- **Cache any HTTP 200 indefinitely; never cache a 404.** HMRC rates don’t
  change retroactively once published (see Data source), so *every*
  successful response is immutable — there’s no past-vs-current distinction
  to make and no TTL/revalidation needed. The only uncacheable response is a
  404 (month not yet published / out of archive range): surface it as
  `RateDataNotAvailableError` and retry on the next call, don’t persist it.
  This keeps the cache layer free of any `today`/clock dependency, which also
  makes it trivial to test.
- `cache_dir=None` (or `HMRC_FX_CACHE_DIR=""`) disables caching entirely —
  always hits the network. Useful for tests/debugging.
- Cache backend = small `Protocol`: `get(key: str) -> bytes | None`,
  `set(key: str, value: bytes) -> None`. Default = filesystem impl. Lets
  tests swap in a dict-backed fake without touching disk.
- Cache file I/O stays synchronous even on the async path — files are ~35KB,
  not worth an `aiofiles` dependency for this.

## Exceptions

- `HMRCFxRatesError` — base for this package’s own errors.
- `RateDataNotAvailableError(year, month)` — HMRC returned 404 for this
  month (not yet published / out of archive range).
- `UnknownCurrencyError(code)` — currency code not present in a given
  month’s data.
- `RateDataIntegrityError` (name TBD) — HMRC data is internally inconsistent:
  the `Period` doesn’t match the requested `(year, month)`, or the same
  currency carries differing rates across its country rows. Covers the
  raise-loud cases under `MonthlyRates`.
- Let `httpx`’s own exceptions (timeouts, connection errors) propagate
  rather than wrapping everything — only wrap where the package adds
  meaning (the package-specific errors listed above).

## Project layout

`src/` layout. Package name `hmrc_fx_rates` is a placeholder — rename before
it becomes a path dependency of the CGT calculator if you want something
different.

```
.
├── pyproject.toml
├── README.md
├── CLAUDE.md
├── src/
│   └── hmrc_fx_rates/
│       ├── __init__.py      # public API re-exports
│       ├── client.py        # HMRCFxRatesClient (sync + async)
│       ├── models.py        # MonthlyRates
│       ├── parsing.py        # XML parsing
│       ├── cache.py          # CacheBackend protocol + filesystem impl
│       └── exceptions.py
└── tests/
    ├── fixtures/             # committed sample XML response(s)
    └── ...
```

## Testing

- `respx` to mock `httpx` calls — no live HTTP in the unit test suite.
- Commit at least one real fixture XML file (manually downloaded) to
  `tests/fixtures/` for parser tests — don’t hand-write fake XML that might
  not match the real schema’s quirks.
- Cache tests: `tmp_path` for the filesystem backend, dict-backed fake for
  protocol-level tests.
- Mirror sync/async test cases against the same fixtures (`pytest-asyncio`).

## Open decisions / confirm while implementing

- [x] CSV — XML-only by standing decision; revisit only if HMRC drops XML
  (see Data source).
- [ ] Earliest year HMRC has published monthly XML for — affects input
  validation range for `(year, month)`. Resolve by binary-searching the
  archive (fetch back until 404) when implementing validation.
- [ ] Python minimum version — suggest **3.12** to match the existing
  devcontainer base image (`mcr.microsoft.com/devcontainers/python:3.12`).
- [ ] Packaging/distribution: PyPI, or path/git dependency from the CGT
  calculator repo? Affects whether package name needs to be globally
  unique.
