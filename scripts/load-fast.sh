#!/usr/bin/env bash
# Parallel alternative to sql/02-load.sql. Run from anywhere, after sql/01-schema.sql:
#   set -a; . ./.env; set +a
#   ./scripts/load-fast.sh            # JOBS=8 by default; try JOBS=16 on a fast link
#
# A single \COPY is one connection, so it is capped by one stream's upload speed.
# This splits the CSV and loads the pieces over JOBS connections at once.
#
# The chunks are created first: the transaction that creates a chunk locks the
# hypertable until it commits, so parallel COPYs racing to create chunks would
# just take turns.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DATABASE_URL:?set it first:  set -a; . ./.env; set +a}"
JOBS="${JOBS:-8}"
CSV=data/tutorial_sample_tick.csv
[ -f "$CSV" ] || { echo "missing $CSV — run ./scripts/get-data.sh first" >&2; exit 1; }

q() { psql "$DATABASE_URL" -X -q -At -v ON_ERROR_STOP=1 "$@"; }

existing=$(q -c "SELECT count(*) FROM (SELECT 1 FROM crypto_ticks LIMIT 1) s") \
  || { echo "crypto_ticks not found — run: psql \"\$DATABASE_URL\" -f sql/01-schema.sql" >&2; exit 1; }
[ "$existing" = 0 ] || { echo "crypto_ticks already has rows. Start clean: psql \"\$DATABASE_URL\" -f sql/00-reset.sql -f sql/01-schema.sql" >&2; exit 1; }

start=$(date +%s)

# Assets: 25 rows, not worth splitting.
q -c "TRUNCATE crypto_assets" -c "\copy crypto_assets FROM 'data/tutorial_sample_assets.csv' CSV HEADER"

# Pre-create every chunk: one throwaway row per day across the file's range, then delete them.
# The emptied chunks stay, so the parallel COPYs below only append.
read -r first last < <(awk -F, 'NR > 1 { d = substr($1, 1, 10); if (min == "" || d < min) min = d; if (d > max) max = d }
                                END { print min, max }' "$CSV")
q <<SQL
BEGIN;
INSERT INTO crypto_ticks ("time", symbol)
SELECT d, '__chunk__' FROM generate_series('$first'::timestamptz, '$last'::timestamptz + interval '1 day', interval '1 day') d;
DELETE FROM crypto_ticks WHERE symbol = '__chunk__';
COMMIT;
SQL

# Split the ticks (minus the header) into JOBS pieces and COPY them concurrently.
parts=$(mktemp -d)
trap 'rm -rf "$parts"' EXIT
rows=$(( $(wc -l < "$CSV") - 1 ))
tail -n +2 "$CSV" | split -l $(( (rows + JOBS - 1) / JOBS )) - "$parts/part_"

echo "Loading $rows ticks ($first → $last) over $JOBS connections..."
export DATABASE_URL
ls "$parts"/part_* | xargs -P "$JOBS" -I{} \
  psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -c "\copy crypto_ticks FROM '{}' CSV" \
  || { echo "A piece failed; the table is partly loaded. Reset and rerun (see above)." >&2; exit 1; }

loaded=$(q -c "SELECT count(*) FROM crypto_ticks")
echo "crypto_ticks: $loaded rows in $(( $(date +%s) - start ))s"
[ "$loaded" = "$rows" ] || { echo "expected $rows rows" >&2; exit 1; }
