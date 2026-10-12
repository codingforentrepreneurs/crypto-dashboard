-- Run from the workshop root:  psql "$DATABASE_URL" -f sql/02-load.sql
\timing on
\COPY crypto_assets FROM 'data/tutorial_sample_assets.csv' CSV HEADER
\COPY crypto_ticks  FROM 'data/tutorial_sample_tick.csv'   CSV HEADER
