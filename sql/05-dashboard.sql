-- Grafana panel queries. Paste into a panel, Code mode.
-- Dashboard time range: 2026-01-12 to 2026-01-30 (the dataset's range).
-- $symbol is a dashboard variable; create it from the "Variable" query at the bottom.

-- Candlestick (visualization: Candlestick, format: Time series)
SELECT bucket AS time, "open", high, low, "close", ticks AS volume
FROM one_hour_candle
WHERE symbol = '$symbol' AND $__timeFilter(bucket)
ORDER BY bucket;

-- Price from raw ticks (visualization: Time series). Bucket size follows the zoom level.
SELECT time_bucket('$__interval', "time") AS time, avg(price) AS avg_price
FROM crypto_ticks
WHERE symbol = '$symbol' AND $__timeFilter("time")
GROUP BY 1
ORDER BY 1;

-- Last price (visualization: Stat, format: Table)
SELECT last(price, "time") AS price
FROM crypto_ticks
WHERE symbol = '$symbol' AND $__timeFilter("time");

-- Change over the selected range (visualization: Stat, unit: percent)
SELECT 100 * (last("close", bucket) / first("open", bucket) - 1) AS pct_change
FROM one_hour_candle
WHERE symbol = '$symbol' AND $__timeFilter(bucket);

-- Change for every asset (visualization: Bar chart, horizontal, format: Table)
SELECT a."name" AS asset,
       round((100 * (last(c."close", c.bucket) / first(c."open", c.bucket) - 1))::numeric, 2) AS pct_change
FROM one_hour_candle c
JOIN crypto_assets a USING (symbol)
WHERE $__timeFilter(c.bucket)
GROUP BY a."name"
ORDER BY pct_change DESC;

-- Row count without scanning 10.8M rows (visualization: Stat)
SELECT approximate_row_count('crypto_ticks') AS rows;

-- Variable "symbol" (Dashboard settings > Variables > Query)
SELECT DISTINCT symbol FROM one_day_candle ORDER BY 1;
