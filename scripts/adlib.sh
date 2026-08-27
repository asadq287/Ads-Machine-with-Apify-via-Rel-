#!/usr/bin/env bash
#
# Meta Ad Library access for The Ads Machine.
#
# Routes every Ad Library call through a Relevance AI tool that wraps Apify on
# Relevance's own platform key. There is NO Apify account and NO APIFY_TOKEN.
# Runs bill Relevance credits on the project that owns the key in .env.
#
# Usage:
#   scripts/adlib.sh scrape_ads   --page-url https://www.facebook.com/SHEINOFFICIAL [--limit 100] [--variant primary|fallback1|fallback2]
#   scripts/adlib.sh scrape_ads   --page-id 380039845369159 [--limit 100]
#   scripts/adlib.sh resolve_page --urls "https://www.facebook.com/a/,https://www.facebook.com/b/"
#   scripts/adlib.sh discover     --query "boxing gym" --location "Belfast" [--limit 20]
#
# Prints the tool's JSON output to stdout. Exits non-zero on failure.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- config -----------------------------------------------------------------
# Values already exported by the caller take precedence over .env, so a one-off
# override like `ADLIB_MAX_RECORDS=10 scripts/adlib.sh ...` actually works.
_ENV_KEYS="RELEVANCE_API_KEY RELEVANCE_PROJECT RELEVANCE_REGION RELEVANCE_ADLIB_STUDIO_ID RELEVANCE_POLL_TIMEOUT ADLIB_MAX_RECORDS"
for _k in $_ENV_KEYS; do eval "_pre_${_k}=\"\${${_k}:-}\""; done

if [ -f "$ROOT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT_DIR/.env"
  set +a
fi

for _k in $_ENV_KEYS; do
  eval "_v=\"\$_pre_${_k}\""
  if [ -n "$_v" ]; then eval "export ${_k}=\"\$_v\""; fi
done
unset _k _v

: "${RELEVANCE_REGION:=f1db6c}"
: "${RELEVANCE_ADLIB_STUDIO_ID:=ef522aa0-5a0c-4847-83de-b1220de49a08}"
: "${RELEVANCE_POLL_TIMEOUT:=600}"
# Per-run ceiling on returned records. Protects credits. Absolute maximum is 250.
: "${ADLIB_MAX_RECORDS:=50}"

die() { echo "adlib: $*" >&2; exit 1; }

[ -n "${RELEVANCE_API_KEY:-}" ] || die "RELEVANCE_API_KEY is not set. Add it to .env (see .env.example)."
[ -n "${RELEVANCE_PROJECT:-}" ] || die "RELEVANCE_PROJECT is not set. Add it to .env (see .env.example)."
command -v curl    >/dev/null 2>&1 || die "curl is required."
command -v python3 >/dev/null 2>&1 || die "python3 is required."

BASE="https://api-${RELEVANCE_REGION}.stack.tryrelevance.com/latest"
AUTH="${RELEVANCE_PROJECT}:${RELEVANCE_API_KEY}"

# ---- args -------------------------------------------------------------------
OP="${1:-}"; shift || true
case "$OP" in
  scrape_ads|resolve_page|discover) ;;
  *) die "first argument must be scrape_ads, resolve_page or discover (got '${OP:-<none>}')." ;;
esac

PAGE_URL=""; PAGE_ID=""; URLS=""; QUERY=""; LOCATION=""; LIMIT=""; VARIANT=""; COUNTRY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --page-url) PAGE_URL="${2:-}"; shift 2 ;;
    --page-id)  PAGE_ID="${2:-}";  shift 2 ;;
    --urls)     URLS="${2:-}";     shift 2 ;;
    --query)    QUERY="${2:-}";    shift 2 ;;
    --location) LOCATION="${2:-}"; shift 2 ;;
    --limit)    LIMIT="${2:-}";    shift 2 ;;
    --variant)  VARIANT="${2:-}";  shift 2 ;;
    --country)  COUNTRY="${2:-}";  shift 2 ;;
    *) die "unknown flag '$1'." ;;
  esac
done

PARAMS_JSON="$(
  OP="$OP" PAGE_URL="$PAGE_URL" PAGE_ID="$PAGE_ID" URLS="$URLS" QUERY="$QUERY" \
  LOCATION="$LOCATION" LIMIT="$LIMIT" VARIANT="$VARIANT" COUNTRY="$COUNTRY" \
  MAXREC="$ADLIB_MAX_RECORDS" \
  python3 -c '
import json, os
p = {"operation": os.environ["OP"]}
def put(key, env, cast=None):
    v = os.environ.get(env, "").strip()
    if v:
        p[key] = cast(v) if cast else v
put("page_url", "PAGE_URL"); put("page_id", "PAGE_ID"); put("page_urls", "URLS")
put("query", "QUERY"); put("location", "LOCATION"); put("country", "COUNTRY")
put("actor_variant", "VARIANT")
try:
    put("limit", "LIMIT", int)
except ValueError:
    raise SystemExit("adlib: --limit must be a number.")
try:
    put("max_records", "MAXREC", int)
except ValueError:
    raise SystemExit("adlib: ADLIB_MAX_RECORDS must be a number.")
print(json.dumps(p))
'
)"

# ---- trigger ----------------------------------------------------------------
BODY="$(python3 -c '
import json, sys
print(json.dumps({"project": sys.argv[1], "params": json.loads(sys.argv[2])}))
' "$RELEVANCE_PROJECT" "$PARAMS_JSON")"

TRIGGER_RES="$(curl -sS --max-time 60 -X POST "$BASE/studios/$RELEVANCE_ADLIB_STUDIO_ID/trigger_async" \
  -H "Authorization: $AUTH" -H "Content-Type: application/json" -d "$BODY")"

JOB_ID="$(printf '%s' "$TRIGGER_RES" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(d.get("job_id") or d.get("_id") or "")
')"

if [ -z "$JOB_ID" ]; then
  echo "adlib: could not start the run. Relevance replied:" >&2
  printf '%s\n' "$TRIGGER_RES" >&2
  exit 1
fi

# ---- poll -------------------------------------------------------------------
DEADLINE=$(( $(date +%s) + RELEVANCE_POLL_TIMEOUT ))
while :; do
  POLL="$(curl -sS --max-time 90 -G "$BASE/studios/$RELEVANCE_ADLIB_STUDIO_ID/async_poll/$JOB_ID" \
    -H "Authorization: $AUTH" --data-urlencode "ending_update_only=true" || true)"

  STATE="$(printf '%s' "$POLL" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("retry"); raise SystemExit
print(d.get("type") or "retry")
')"

  case "$STATE" in
    complete)
      printf '%s' "$POLL" | python3 -c '
import json, sys
d = json.load(sys.stdin)
out = {}
for u in d.get("updates") or []:
    if u.get("type") == "chain-success":
        out = (u.get("output") or {}).get("output") or {}
errs = out.get("actor_errors") or []
if errs:
    sys.stderr.write("adlib: scraper reported: " + "; ".join(map(str, errs)) + "\n")
notice = out.get("limit_notice")
if notice:
    sys.stderr.write("adlib: " + str(notice) + "\n")
print(json.dumps(out, indent=2))
'
      exit 0
      ;;
    failed)
      printf '%s' "$POLL" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.stderr.write("adlib: the run failed and the response could not be parsed.\n")
    raise SystemExit
msgs = []
for u in d.get("updates") or []:
    for e in u.get("errors") or []:
        # "raw" is the short human-readable form; "body" embeds the whole step input.
        m = e.get("raw") or e.get("body") or ""
        m = str(m).split(" on state with input")[0].strip()
        if m and m not in msgs:
            msgs.append(m)
sys.stderr.write("adlib: the run failed.\n")
for m in msgs or ["no error detail returned by Relevance."]:
    sys.stderr.write("  " + m + "\n")
'
      exit 1
      ;;
    *)
      if [ "$(date +%s)" -ge "$DEADLINE" ]; then
        die "timed out after ${RELEVANCE_POLL_TIMEOUT}s waiting for job $JOB_ID."
      fi
      sleep 5
      ;;
  esac
done
