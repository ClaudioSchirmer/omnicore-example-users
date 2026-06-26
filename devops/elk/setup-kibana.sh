#!/usr/bin/env bash
# Provisions Kibana for the OmniCore log stack: imports the data view
# (omnicore-logs-*) plus saved searches that split the logs by purpose —
# All / Audit / Generic / HTTP outbound — each filterable by `service`.
# Idempotent (overwrite=true). Run after `docker compose up -d` once Kibana is up.
set -u
KIBANA="${KIBANA_URL:-http://localhost:5601}"
ES="${ES_URL:-http://localhost:9200}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# 1) Elasticsearch index template — MUST exist before the first log is indexed,
# so the polymorphic audit payload (snapshot/changes/children) maps as flattened
# instead of triggering a mapping conflict (HTTP 400, dropped events).
echo "applying Elasticsearch index template (omnicore-logs*) ..."
curl -sf -X PUT "$ES/_index_template/omnicore-logs" \
  -H 'Content-Type: application/json' --data-binary @"$HERE/es-template.json" \
  >/dev/null && echo "  template applied" || echo "  template PUT failed (is ES up?)"

echo "waiting for Kibana at $KIBANA ..."
for i in $(seq 1 60); do
  if curl -sf "$KIBANA/api/status" >/dev/null 2>&1; then break; fi
  sleep 3
done

echo "importing data view + saved searches ..."
curl -sf -X POST "$KIBANA/api/saved_objects/_import?overwrite=true" \
  -H "kbn-xsrf: true" \
  --form file=@"$HERE/kibana-objects.ndjson" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('  success:',d.get('success'),'| imported:',d.get('successCount'))" 2>/dev/null \
  || { echo '  import failed (is Kibana ready? is there data in ES yet?)'; exit 1; }

echo "done. Open $KIBANA → Discover → pick a saved search:"
echo "  • OmniCore — All logs"
echo "  • OmniCore — Audit            (msg:audit)"
echo "  • OmniCore — Generic          (not msg:audit)"
echo "  • OmniCore — HTTP outbound    (msg:http.outbound)"
echo "Every log carries  service:\"omnicore-example-users\"  (the emitting microservice)."
echo "On HTTP-outbound logs, the called target is the 'upstream' field (e.g. echo, keycloak-public)."
