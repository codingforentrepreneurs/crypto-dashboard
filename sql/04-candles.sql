-- One-hour candles, kept up to date by TimescaleDB. Powers the dashboard.
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

-- One-day candles, as in the Tiger Data tutorial.
CREATE MATERIALIZED VIEW one_day_candle
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 day', "time") AS bucket,
    symbol,
    first(price, "time")      AS "open",
    max(price)                AS high,
    min(price)                AS low,
    last(price, "time")       AS "close",
    last(day_volume, "time")  AS day_volume
FROM crypto_ticks
GROUP BY bucket, symbol;

SELECT add_continuous_aggregate_policy('one_day_candle',
    start_offset      => INTERVAL '3 days',
    end_offset        => INTERVAL '1 day',
    schedule_interval => INTERVAL '1 day');
