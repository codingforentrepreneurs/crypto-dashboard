-- Clean slate: drops the tables and views created in steps 1 and 4. Leaves data/ alone.
DROP MATERIALIZED VIEW IF EXISTS public.one_day_candle;
DROP MATERIALIZED VIEW IF EXISTS public.one_hour_candle;
DROP TABLE IF EXISTS public.crypto_ticks;
DROP TABLE IF EXISTS public.crypto_assets;
