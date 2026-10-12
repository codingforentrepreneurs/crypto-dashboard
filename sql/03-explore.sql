-- 1. How much data?
SELECT count(*) FROM crypto_ticks;

-- 2. What does a row look like?
SELECT * FROM crypto_ticks ORDER BY "time" DESC LIMIT 10;

-- 3. The hypertable split itself into chunks by time
SELECT chunk_name, range_start, range_end, is_compressed
FROM timescaledb_information.chunks
WHERE hypertable_name = 'crypto_ticks'
ORDER BY range_start;

-- 4. Latest price per asset: a time-series function plus a plain Postgres JOIN
SELECT a."name", t.symbol, last(t.price, t."time") AS price, max(t."time") AS as_of
FROM crypto_ticks t
JOIN crypto_assets a USING (symbol)
GROUP BY a."name", t.symbol
ORDER BY a."name";

-- 5. Hourly average BTC price with time_bucket
SELECT time_bucket('1 hour', "time") AS bucket, avg(price) AS avg_price
FROM crypto_ticks
WHERE symbol = 'BTC/USD'
GROUP BY bucket
ORDER BY bucket DESC
LIMIT 24;

-- 6. Daily candles (open, high, low, close) straight from 10.8M raw ticks
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

-- 7. Only the chunks that match the time filter get scanned
EXPLAIN (ANALYZE, COSTS OFF)
SELECT avg(price)
FROM crypto_ticks
WHERE symbol = 'BTC/USD' AND "time" >= '2026-01-28';
