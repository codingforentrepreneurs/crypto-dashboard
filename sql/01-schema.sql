-- Tick data: one row per price update. A hypertable, segmented by symbol for the columnstore.
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

-- Reference data: a plain Postgres table.
CREATE TABLE crypto_assets (
    symbol TEXT UNIQUE,
    "name" TEXT
);
