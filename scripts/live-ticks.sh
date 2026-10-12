#!/usr/bin/env bash
# Load Twelve Data prices into the existing crypto_ticks hypertable.
set -euo pipefail

TS_URL=https://api.twelvedata.com/time_series
PRICE_URL=https://api.twelvedata.com/price
TS_HEADER=datetime,open,high,low,close,volume
DEFAULT_SYMBOL=BTC/USD
NUM='^-?[0-9]+(\.[0-9]+)?$'

usage() {
  cat >&2 <<'EOF'
usage: live-ticks.sh backfill [SYMBOL]           one /time_series call -> \COPY into crypto_ticks
       live-ticks.sh stream [SYMBOL] [SECONDS]   poll /price and INSERT one row per poll
defaults: SYMBOL=BTC/USD, SECONDS=10 (6 req/min, under the free 8/min limit)
EOF
  exit 1
}

# Repo root, so .env and relative paths resolve the same from anywhere.
cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; . ./.env; set +a; }

require_env() {
  [ -n "${DATABASE_URL:-}" ] || { echo "DATABASE_URL is not set: add it to .env in the repo root" >&2; exit 1; }
  [ -n "${TWELVEDATA_API_KEY:-}" ] || { echo "TWELVEDATA_API_KEY is not set: add it to .env (free key at https://twelvedata.com/pricing)" >&2; exit 1; }
}

# Symbols reach SQL and CSV, so allow only the characters Twelve Data uses.
check_symbol() {
  [[ $1 =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "bad symbol: $1" >&2; exit 1; }
}

# The API answers with JSON on error, so refuse anything that is not the CSV we asked for.
backfill() {
  local symbol="${1:-$DEFAULT_SYMBOL}" raw rows n
  check_symbol "$symbol"
  require_env
  raw=$(mktemp) rows=$(mktemp)
  trap 'rm -f "$raw" "$rows"' EXIT
  curl -sS --get "$TS_URL" \
    --data-urlencode "symbol=$symbol" \
    --data-urlencode "apikey=$TWELVEDATA_API_KEY" \
    -d interval=1min -d outputsize=390 -d timezone=UTC -d format=CSV -d delimiter=, \
    | tr -d '\r' >"$raw"
  if [ "$(head -n 1 "$raw")" != "$TS_HEADER" ]; then
    echo "Twelve Data did not return CSV for $symbol:" >&2
    cat "$raw" >&2
    exit 1
  fi
  # datetime->time (+00 so the session TimeZone cannot shift it), close->price, volume->day_volume.
  awk -F, -v sym="$symbol" '
    NR == 1 { next }
    $1 == "" || $5 !~ /^-?[0-9]+(\.[0-9]+)?$/ { next }
    { printf "%s+00,%s,%s,%s\n", $1, sym, $5, ($6 ~ /^-?[0-9]+(\.[0-9]+)?$/ ? $6 : "") }
  ' "$raw" >"$rows"
  n=$(wc -l <"$rows")
  [ "$n" -gt 0 ] || { echo "no usable rows for $symbol" >&2; exit 1; }
  psql "$DATABASE_URL" -q -v ON_ERROR_STOP=1 \
    -c '\COPY crypto_ticks("time", symbol, price, day_volume) FROM STDIN WITH (FORMAT csv)' <"$rows"
  echo "backfilled $n rows for $symbol"
}

stream() {
  local symbol="${1:-$DEFAULT_SYMBOL}" interval="${2:-10}" resp price
  check_symbol "$symbol"
  [[ $interval =~ ^[0-9]+$ ]] && [ "$interval" -ge 1 ] || { echo "SECONDS must be a positive integer" >&2; exit 1; }
  require_env
  trap 'echo "stopped"; exit 0' INT TERM
  echo "streaming $symbol every ${interval}s, Ctrl-C to stop"
  while true; do
    resp=$(curl -sS --get "$PRICE_URL" \
      --data-urlencode "symbol=$symbol" \
      --data-urlencode "apikey=$TWELVEDATA_API_KEY" \
      -d format=CSV | tr -d '\r')
    price=$(printf '%s\n' "$resp" | awk 'NR == 2 { print $1 }')
    if [ "$(printf '%s\n' "$resp" | head -n 1)" != "price" ] || ! [[ $price =~ $NUM ]]; then
      echo "Twelve Data did not return a price for $symbol:" >&2
      printf '%s\n' "$resp" >&2
      exit 1
    fi
    psql "$DATABASE_URL" -q -v ON_ERROR_STOP=1 \
      -c "INSERT INTO crypto_ticks(\"time\", symbol, price, day_volume) VALUES (now(), '$symbol', $price, NULL)"
    echo "$(date -u +%H:%M:%S) $symbol $price"
    sleep "$interval"
  done
}

case "${1:-}" in
  backfill) shift; backfill "$@" ;;
  stream) shift; stream "$@" ;;
  *) usage ;;
esac
