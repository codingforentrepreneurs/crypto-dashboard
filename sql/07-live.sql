-- Run this after scripts/live-ticks.sh has put some live rows in the table.

-- 1. The newest raw ticks: the live rows landed, months past the January sample
SELECT "time", symbol, price, day_volume
FROM crypto_ticks
ORDER BY "time" DESC
LIMIT 10;

-- 2. A brand-new chunk was created for today and is still uncompressed.
--    If you ran sql/06-columnstore.sql, the January chunks sit in the columnstore
--    next to it: compression is per chunk, and new writes land in the rowstore.
SELECT chunk_name, range_start, range_end, is_compressed
FROM timescaledb_information.chunks
WHERE hypertable_name = 'crypto_ticks'
ORDER BY range_start;

-- 3. Today is missing from the hourly candles. Since TimescaleDB 2.13,
--    timescaledb.materialized_only defaults to true, so the view returns only what has
--    been materialized, up to its watermark. The live ticks are past that watermark.
SELECT bucket, symbol, "open", high, low, "close", ticks
FROM one_hour_candle
WHERE symbol = 'BTC/USD'
ORDER BY bucket DESC
LIMIT 5;

-- 4. Option one: materialize the recent window by hand instead of waiting for the policy
CALL refresh_continuous_aggregate('one_hour_candle', now() - INTERVAL '2 days', now());

-- 5. Today's finished hours are now there, but the hour still in progress is NOT.
--    A refresh only materializes buckets that have closed; it will not store a partial one.
--    So with `backfill` this fills in, and with `stream` the newest bucket stays missing.
SELECT bucket, symbol, "close", ticks
FROM one_hour_candle
WHERE symbol = 'BTC/USD'
ORDER BY bucket DESC
LIMIT 5;

-- 6. Option two: real-time aggregation. Merge the unmaterialized tail in at query time.
--    Always current, including the open bucket, but every query now does a little work
--    over the raw ticks past the watermark instead of only reading precomputed rows.
ALTER MATERIALIZED VIEW one_hour_candle SET (timescaledb.materialized_only = false);

-- 7. The hour in progress shows up, with no refresh in between
SELECT bucket, symbol, "close", ticks
FROM one_hour_candle
WHERE symbol = 'BTC/USD'
ORDER BY bucket DESC
LIMIT 3;

-- 8. For a live Grafana panel, read the raw ticks: no watermark, always current
SELECT last(price, "time") AS price, max("time") AS as_of
FROM crypto_ticks
WHERE symbol = 'BTC/USD' AND "time" > now() - INTERVAL '1 hour';
