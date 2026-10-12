-- Size before
SELECT pg_size_pretty(hypertable_size('crypto_ticks')) AS total_size;

-- Move every chunk to the columnstore now instead of waiting for the policy.
-- (convert_to_columnstore is a procedure, so it cannot run once per row of a SELECT.)
SELECT compress_chunk(c, if_not_compressed => true)
FROM show_chunks('crypto_ticks') c;

-- Size after
SELECT pg_size_pretty(before_compression_total_bytes) AS before,
       pg_size_pretty(after_compression_total_bytes)  AS after,
       round(100 - 100.0 * after_compression_total_bytes / before_compression_total_bytes, 1) AS pct_saved
FROM hypertable_columnstore_stats('crypto_ticks');

-- The columnstore policy created with the table (compresses chunks older than 7 days, daily)
SELECT job_id, schedule_interval, config, next_start
FROM timescaledb_information.jobs
WHERE hypertable_name = 'crypto_ticks';
