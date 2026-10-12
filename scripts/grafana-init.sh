#!/usr/bin/env bash
# Skips step 5: creates the Grafana data source from DATABASE_URL and imports the
# Crypto Prices dashboard. Works on both setup options. Safe to re-run.
#   set -a; . ./.env; set +a
#   ./scripts/grafana-init.sh
#
# Talks to Grafana's HTTP API, so the dashboard stays editable in the UI. Run it
# after sql/04-candles.sql, or the symbol dropdown comes up empty.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DATABASE_URL:?set it first:  set -a; . ./.env; set +a}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
GRAFANA_AUTH="${GRAFANA_AUTH:-admin:admin}"

curl -fsS -o /dev/null "$GRAFANA_URL/api/health" \
  || { echo "Grafana is not up at $GRAFANA_URL — run: docker compose up -d --wait" >&2; exit 1; }

api() { curl -fsS -u "$GRAFANA_AUTH" -H 'Content-Type: application/json' "$@"; }

# DATABASE_URL -> data source JSON. Inside the Grafana container, localhost is the
# container itself, so the local database is reached by its service name instead.
datasource=$(python3 - "$DATABASE_URL" <<'PY'
import json, sys
from urllib.parse import urlparse, parse_qs, unquote
u = urlparse(sys.argv[1])
host = "timescaledb" if u.hostname in ("localhost", "127.0.0.1") else u.hostname
print(json.dumps({
    "name": "Tiger Data", "uid": "tigerdata", "type": "grafana-postgresql-datasource",
    "access": "proxy", "isDefault": True,
    "url": f"{host}:{u.port or 5432}",
    "user": unquote(u.username or "postgres"),
    "jsonData": {
        "database": u.path.lstrip("/") or "postgres",
        "sslmode": parse_qs(u.query).get("sslmode", ["disable"])[0],
        "timescaledb": True, "postgresVersion": 1700,
    },
    "secureJsonData": {"password": unquote(u.password or "")},
}))
PY
)

if api -o /dev/null "$GRAFANA_URL/api/datasources/uid/tigerdata" 2>/dev/null; then
  api -X PUT -o /dev/null "$GRAFANA_URL/api/datasources/uid/tigerdata" -d "$datasource"
  echo "updated data source: Tiger Data"
else
  api -X POST -o /dev/null "$GRAFANA_URL/api/datasources" -d "$datasource"
  echo "created data source: Tiger Data"
fi

api -o /dev/null "$GRAFANA_URL/api/datasources/uid/tigerdata/health" \
  || { echo "Grafana can't reach the database — check DATABASE_URL" >&2; exit 1; }

python3 -c '
import json, sys
dash = json.load(open(sys.argv[1]))
dash["uid"] = "crypto-prices"  # fixed uid, so re-runs overwrite instead of duplicating
print(json.dumps({"dashboard": dash, "overwrite": True, "folderUid": "",
  "inputs": [{"name": "DS_TIGER", "type": "datasource",
              "pluginId": "grafana-postgresql-datasource", "value": "tigerdata"}]}))
' grafana/crypto-prices-import.json \
  | api -X POST "$GRAFANA_URL/api/dashboards/import" -d @- \
  | python3 -c 'import json, sys; print("dashboard: '"$GRAFANA_URL"'" + json.load(sys.stdin)["importedUrl"])'
