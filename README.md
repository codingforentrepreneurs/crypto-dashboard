# Crypto Price Dashboard

10.8M real crypto ticks in Postgres, queried in plain SQL, charted as candlesticks in Grafana.

Built on [TimescaleDB](https://github.com/timescale/timescaledb) — a Postgres extension from [Tiger Data](https://www.tigerdata.com). No new query language: `psql`, JOINs, indexes and any Postgres driver all work as usual.

## What you build

- A **hypertable** holding 10,772,350 ticks across 19 symbols
- Candlesticks (open/high/low/close) from raw ticks with `time_bucket`, `first` and `last`
- A **continuous aggregate** that precomputes those candles and keeps them fresh
- A Grafana dashboard with a candlestick panel and a symbol dropdown
- The same data in the **columnstore**: ~90% smaller, faster scans

## Requirements

- Docker with Compose v2 — `docker compose version` must print 2.1.1 or newer, since `--wait` needs it. Grafana runs in Docker on both setup options below.
- `git`, `curl` and `unzip` — all three ship with macOS; `apt install git curl unzip` on Debian/Ubuntu
- `psql` — `brew install libpq` on macOS, `apt install postgresql-client` on Debian/Ubuntu
- ~1 GB free disk — the zip and the extracted CSVs coexist until the script removes the zip
- Port `3000` free on the host, plus `5432` if you use the local database (Option 1)

## Setup

Start the same way either way:

```bash
git clone https://github.com/codingforentrepreneurs/crypto-dashboard.git
cd crypto-dashboard
./scripts/get-data.sh          # downloads + unzips 430 MB of sample ticks into data/
cp .env.example .env
```

Now pick one of the two. Everything from step 1 on is identical.

### Option 1 — everything local, in Docker

```bash
docker compose up -d --wait
```

Postgres + TimescaleDB on `:5432`, Grafana on `:3000`. The `DATABASE_URL` already in `.env` points at it, so there is nothing to edit.

### Option 2 — database on Tiger Cloud, Grafana local

Create a free service at [console.cloud.tigerdata.com](https://console.cloud.tigerdata.com), then copy its connection string into `.env` as `DATABASE_URL` — keep the `?sslmode=require` on the end:

```bash
DATABASE_URL=postgres://tsdbadmin:<password>@<host>:<port>/tsdb?sslmode=require
```

Then start Grafana on its own:

```bash
docker compose up -d --wait grafana
```

Naming the service starts only Grafana, so port `5432` stays free for whatever Postgres you already run locally.

### Then, either way

Load the connection string into your shell. Do this in every new terminal:

```bash
set -a; . ./.env; set +a
psql "$DATABASE_URL" -c 'SELECT version();'
```

That last line is just a connection check. The steps below each run a file, so you do not need to stay in an interactive `psql` session.

## About the data

`crypto_sample.zip` is the sample set from the [Tiger Data financial tick tutorial](https://www.tigerdata.com/docs/learn/tutorials/analyze-financial-tick-data), sourced from [Twelve Data](https://twelvedata.com).

> [!IMPORTANT]
> The ticks run **2026-01-12 18:34 → 2026-01-29 12:05 UTC**. Point every query and the Grafana time picker at that window. Relative filters like `NOW() - INTERVAL '14 days'` return zero rows.

`day_volume` is only populated for ETH, SOL, DOGE and DAI, so the dashboard uses tick count as its volume bar.

Row counts, sizes and timings quoted below come from one run on local Docker (TimescaleDB 2.30.2, PG 17). Your own numbers will differ.

## 1. Create the tables

[`sql/01-schema.sql`](sql/01-schema.sql)

```sql
CREATE TABLE crypto_ticks (
    "time"     TIMESTAMPTZ NOT NULL,
    symbol     TEXT NOT NULL,
    price      DOUBLE PRECISION,
    day_volume NUMERIC
) WITH (
    tsdb.hypertable,
    tsdb.segmentby = 'symbol',
    tsdb.orderby   = 'time DESC'
);

CREATE TABLE crypto_assets (
    symbol TEXT UNIQUE,
    "name" TEXT
);
```

- `tsdb.hypertable` — one ordinary table on top, time-partitioned into **chunks** underneath. The partition column is the first `timestamptz`.
- `segmentby = 'symbol'` — in the columnstore, rows are grouped per symbol, so `WHERE symbol = 'BTC/USD'` can skip the rest.
- `crypto_assets` is a plain Postgres table. Same database, ordinary JOINs.

```bash
psql "$DATABASE_URL" -f sql/01-schema.sql
```

## 2. Load 10.8M rows

[`sql/02-load.sql`](sql/02-load.sql)

```bash
psql "$DATABASE_URL" -f sql/02-load.sql
```

Or from inside `psql`:

```sql
\COPY crypto_assets FROM 'data/tutorial_sample_assets.csv' CSV HEADER
\COPY crypto_ticks  FROM 'data/tutorial_sample_tick.csv'   CSV HEADER
```

`\COPY` streams the file from your machine, so run it from the repo root for the relative paths to resolve. Expect ~30 s on local Docker, longer against Tiger Cloud since it is bound by your upload speed.

## 3. Query it in plain SQL

[`sql/03-explore.sql`](sql/03-explore.sql) — run these one at a time.

```sql
SELECT count(*) FROM crypto_ticks;
```

See how the hypertable partitioned itself:

```sql
SELECT chunk_name, range_start, range_end, is_compressed
FROM timescaledb_information.chunks
WHERE hypertable_name = 'crypto_ticks'
ORDER BY range_start;
```

Four chunks, seven days each (the default). `is_compressed` should read `f` for all of them — step 6 is what changes that. If any chunk already says `t`, the columnstore policy on the table has fired, and step 6's before/after will already reflect it.

Now the latest price per asset — a TimescaleDB function next to an ordinary JOIN:

```sql
SELECT a."name", t.symbol, last(t.price, t."time") AS price, max(t."time") AS as_of
FROM crypto_ticks t
JOIN crypto_assets a USING (symbol)
GROUP BY a."name", t.symbol
ORDER BY a."name";
```

`last(value, time)` returns the value at the latest time. Three functions turn raw ticks into a candlestick:

```sql
SELECT time_bucket('1 day', "time") AS bucket,
       first(price, "time") AS "open",
       max(price)           AS high,
       min(price)           AS low,
       last(price, "time")  AS "close",
       count(*)             AS ticks
FROM crypto_ticks
WHERE symbol = 'BTC/USD'
GROUP BY bucket
ORDER BY bucket;
```

Try `'1 hour'` or `'15 minutes'` in place of `'1 day'`. Finally, watch chunk exclusion:

```sql
\timing on
EXPLAIN (ANALYZE, COSTS OFF)
SELECT avg(price)
FROM crypto_ticks
WHERE symbol = 'BTC/USD' AND "time" >= '2026-01-28';
```

Only the chunks overlapping that filter show up in the plan.

## 4. Precompute the candles

[`sql/04-candles.sql`](sql/04-candles.sql)

A continuous aggregate is the candle query from step 3, stored and kept current.

```sql
CREATE MATERIALIZED VIEW one_hour_candle
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', "time") AS bucket,
    symbol,
    first(price, "time")      AS "open",
    max(price)                AS high,
    min(price)                AS low,
    last(price, "time")       AS "close",
    last(day_volume, "time")  AS day_volume,
    count(*)                  AS ticks
FROM crypto_ticks
GROUP BY bucket, symbol;

SELECT add_continuous_aggregate_policy('one_hour_candle',
    start_offset      => INTERVAL '3 hours',
    end_offset        => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour');
```

The policy re-aggregates only the recent window on a schedule, not the whole table.

```bash
psql "$DATABASE_URL" -f sql/04-candles.sql
```

The same file creates `one_day_candle` the same way on a `'1 day'` bucket, with a daily refresh policy. Step 5's symbol dropdown reads from it.

Time the precomputed daily candles against step 3's raw-tick version:

```sql
\timing on
SELECT * FROM one_day_candle WHERE symbol = 'BTC/USD' ORDER BY bucket;
```

Roughly 225 ms down to 1 ms.

## 5. Build the dashboard

Open http://localhost:3000, log in with `admin` / `admin`, and skip the password change.

**Connections → Data sources → Add new data source → PostgreSQL**

| Field | Option 1, local Docker | Option 2, Tiger Cloud |
|---|---|---|
| Host URL | `timescaledb:5432` | `<host>:<port>` — the port is required |
| Database | `postgres` | `tsdb` |
| User | `postgres` | `tsdbadmin` |
| Password | `password` | from your service |
| TLS/SSL Mode | `disable` | `require` |
| PostgreSQL options → TimescaleDB | on | on |

> [!TIP]
> Use `timescaledb:5432`, not `localhost`. Inside the Grafana container `localhost` means the container itself.

**Save & test**, then **Dashboards → New → New dashboard → Add visualization** and pick the data source.

1. Set the time range, top right, to `2026-01-12 00:00:00` → `2026-01-30 00:00:00`. Without this every panel reads *No data*.
2. Set the visualization to **Candlestick**. Switch the query editor to **Code**, format **Time series**:

   ```sql
   SELECT bucket AS time, "open", high, low, "close", ticks AS volume
   FROM one_hour_candle
   WHERE symbol = 'BTC/USD' AND $__timeFilter(bucket)
   ORDER BY bucket;
   ```

   `$__timeFilter` expands into a `WHERE` clause, so dragging to zoom re-queries Postgres instead of filtering in the browser.
3. Add a symbol dropdown: **Dashboard settings → Variables → New variable**, type **Query**, data source **PostgreSQL** (the one you just added), name `symbol`:

   ```sql
   SELECT DISTINCT symbol FROM one_day_candle ORDER BY 1;
   ```

   Replace `'BTC/USD'` with `'$symbol'` in the panel query, then pick ETH/USD from the dropdown.

[`sql/05-dashboard.sql`](sql/05-dashboard.sql) has more panel queries: a price line straight from raw ticks, a last-price stat, percent change over the selected range, a bar chart comparing every asset, and a row count that never scans the table.

## 6. Move it to the columnstore

[`sql/06-columnstore.sql`](sql/06-columnstore.sql)

```sql
SELECT pg_size_pretty(hypertable_size('crypto_ticks')) AS total_size;

SELECT compress_chunk(c, if_not_compressed => true)
FROM show_chunks('crypto_ticks') c;

SELECT pg_size_pretty(before_compression_total_bytes) AS before,
       pg_size_pretty(after_compression_total_bytes)  AS after,
       round(100 - 100.0 * after_compression_total_bytes / before_compression_total_bytes, 1) AS pct_saved
FROM hypertable_columnstore_stats('crypto_ticks');
```

690 MB → 65 MB. Re-run the raw BTC daily candle query from step 3 and compare `\timing`: ~225 ms → ~31 ms. Refresh Grafana — identical charts, same SQL.

The table was created with a policy that does this on a schedule for chunks older than seven days:

```sql
SELECT job_id, schedule_interval, config, next_start
FROM timescaledb_information.jobs
WHERE hypertable_name = 'crypto_ticks';
```

## 7. Stream live prices

`main` stops at the January sample. This branch adds a live feed from the [Twelve Data](https://twelvedata.com) API into the same hypertable.

Get a free API key at [twelvedata.com/pricing](https://twelvedata.com/pricing) — 8 requests per minute, 800 per day, no card. Put it in `.env`:

```bash
TWELVEDATA_API_KEY=your_key_here
```

### Backfill the last few hours

```bash
./scripts/live-ticks.sh backfill BTC/USD
```

One API call pulls 390 one-minute bars and `\COPY`s them in, mapping each bar's close to `price`.

### Then stream

In a second terminal:

```bash
./scripts/live-ticks.sh stream BTC/USD 10
```

One row per poll, every 10 seconds — 6 requests a minute, under the free limit. `Ctrl-C` to stop.

### What to look for

```bash
psql "$DATABASE_URL" -f sql/07-live.sql
```

[`sql/07-live.sql`](sql/07-live.sql) walks three things:

1. **A new chunk appears.** The live rows are months newer than the sample, so the hypertable creates a fresh chunk for today. If you ran step 6, it sits uncompressed right next to the compressed January chunks — compression is per chunk, and new writes land in the rowstore.
2. **The candles do not move.** `one_hour_candle` keeps returning January. Since TimescaleDB 2.13, `materialized_only` defaults to `true`, so a continuous aggregate returns only what has been materialized, up to its watermark — and your live ticks are past it.
3. **Two ways to surface them.** `refresh_continuous_aggregate` materializes a recent window, but only buckets that have *closed* — the hour in progress stays invisible no matter how often you refresh. `ALTER MATERIALIZED VIEW ... SET (timescaledb.materialized_only = false)` switches on real-time aggregation, merging the unmaterialized tail at query time, so the open bucket finally shows up. The tradeoff is that every query then does a little work over the raw tail instead of only reading precomputed rows.

### A live Grafana panel

The dashboard's time range is pinned to January, so a live panel needs a per-panel override. Add a panel, switch the query to **Code**, format **Time series**:

```sql
SELECT time_bucket('$__interval', "time") AS time, last(price, "time") AS price
FROM crypto_ticks
WHERE symbol = '$symbol' AND $__timeFilter("time")
GROUP BY 1
ORDER BY 1;
```

Expand **Query options** under the query editor and set **Relative time** to `30m`. That panel now ignores the dashboard's January range and shows the last 30 minutes. Set the dashboard refresh to `10s` to watch ticks arrive.

[`grafana/live-panel.json`](grafana/live-panel.json) is the same panel as JSON, if you would rather paste it in under **Inspect -> Panel JSON**. It carries no data source of its own, so Grafana binds it to the dashboard's current one.

> [!NOTE]
> Crypto trades around the clock, so `BTC/USD` returns fresh prices at any hour. A stock symbol returns its last close outside market hours, which looks like a stalled feed.

## Branches

| Branch | What it adds |
|---|---|
| `main` | The walkthrough above |
| [`api`](../../tree/api) | Live prices streamed from the Twelve Data API into the same hypertable |
| [`finished`](../../tree/finished) | Grafana with the data source and all 7 panels already provisioned |

```bash
git switch api
```

## Start over

```bash
psql "$DATABASE_URL" -f sql/00-reset.sql     # drops the tables and views, keeps the data/ CSVs
docker compose down -v                       # or throw away the database entirely
```

## FAQ

**Is this still Postgres?** Yes. `psql`, JOINs, indexes, and any Postgres driver or tool.

**Why do `first`/`last` shift slightly after compression?** The feed contains several ticks sharing one timestamp, and on a tie "first" is undefined. Add a tiebreaker column if it matters to you.

**Can I change the chunk size?** Default is 7 days. `set_chunk_time_interval` changes it for chunks created from then on.

**How do I get live data instead of a sample?** See the [`api`](../../tree/api) branch.
