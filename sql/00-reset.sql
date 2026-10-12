-- Clean slate for the live run. Leaves the preloaded schema alone.
DROP MATERIALIZED VIEW IF EXISTS public.one_day_candle;
DROP MATERIALIZED VIEW IF EXISTS public.one_hour_candle;
DROP TABLE IF EXISTS public.crypto_ticks;
DROP TABLE IF EXISTS public.crypto_assets;
