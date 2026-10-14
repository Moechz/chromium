#!/bin/bash
# TOS Developer Platform (TDP) Agent API helper.
#
# The API token is read from the environment ONLY - never pass it as an
# argument (it would leak into shell history, process listings and logs):
#
#   export TDP_API_TOKEN=...            # see ~/Documents/projects/TOS-DEVELOPER-API.md
#   scripts/tdp-submit.sh whoami
#   scripts/tdp-submit.sh status chromiumdocker
#   scripts/tdp-submit.sh submit chromiumdocker 13-7 \
#       https://github.com/Moechz/chromium/releases/download/v13-7/chromiumdocker.tar.gz
#
# Version creation is asynchronous and two-stage: POST creates a *task*, the
# task is polled until all_status=2, and only confirm() creates the version and
# puts it into review. This script does all three and never confirms a failed
# task.
set -euo pipefail

BASE="${TDP_BASE_URL:-https://api-developer.terra-master.com}"
: "${TDP_API_TOKEN:?export TDP_API_TOKEN first (never pass the token as an argument)}"

PY=python3

api () {  # api METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl --fail-with-body --silent --show-error -X "$method" \
      -H "Authorization: Bearer ${TDP_API_TOKEN}" \
      -H 'Content-Type: application/json' -H 'Accept: application/json' \
      --data "$body" "${BASE}${path}"
  else
    curl --fail-with-body --silent --show-error -X "$method" \
      -H "Authorization: Bearer ${TDP_API_TOKEN}" \
      -H 'Accept: application/json' "${BASE}${path}"
  fi
}

app_uuid () {  # app_uuid <business app_id>
  api GET "/v1/apps?kind=all" | "$PY" -c '
import sys, json
want = sys.argv[1]
for a in json.load(sys.stdin):
    if a.get("app_id") == want:
        print(a["id"]); break
' "$1"
}

STATUS_NAME=( [0]=Reviewing [1]=Approved-historical [2]=Published [3]=Rejected \
              [4]=Withdrawn [5]=Takedown-pending [6]=Taken-down [7]=Force-taken-down )

cmd_whoami () {
  api GET /v1/whoami | "$PY" -c '
import sys, json
d = json.load(sys.stdin)
print("developer :", d["developer"]["name"], "(id %s)" % d["developer"]["id"])
print("scopes    :", ", ".join(d["token"]["scopes"]))
print("expires_at:", d["token"]["expires_at"])
'
}

cmd_apps () {
  api GET "/v1/apps?kind=${1:-all}" | "$PY" -c '
import sys, json
rows = json.load(sys.stdin)
print("%d app(s)" % len(rows))
for a in rows:
    print("  %-18s %-28s kind=%-12s uuid=%s" % (a["app_id"], a["name"], a["kind"], a["id"]))
'
}

cmd_status () {  # cmd_status <business app_id>
  local uuid; uuid="$(app_uuid "$1")"
  [ -n "$uuid" ] || { echo "no app with app_id=$1" >&2; exit 1; }
  echo "app_id=$1  uuid=$uuid"
  api GET "/v1/apps/${uuid}" | "$PY" -c '
import sys, json
a = json.load(sys.stdin)
print("  name=%s kind=%s status=%s repo=%s" % (a.get("name"), a.get("kind"),
      a.get("status"), a.get("repo_url") or a.get("repository_url") or "?"))
' 2>/dev/null || true
  api GET "/v1/apps/${uuid}/versions" | "$PY" -c '
import sys, json
rows = json.load(sys.stdin)
names = {0:"Reviewing",1:"Approved(historical)",2:"Published",3:"Rejected",
         4:"Withdrawn",5:"Takedown-pending",6:"Taken-down",7:"Force-taken-down"}
print("  %d version(s)" % len(rows))
for v in rows:
    st = v.get("status")
    print("    tag=%-12s status=%s(%s) uuid=%s created=%s" %
          (v.get("tag"), st, names.get(st, "?"), v.get("id"), v.get("created_at")))
'
}

cmd_submit () {  # cmd_submit <business app_id> <version tag> <browser_download_url>
  local appid="$1" tag="$2" url="$3"
  local uuid; uuid="$(app_uuid "$appid")"
  [ -n "$uuid" ] || { echo "no app with app_id=$appid" >&2; exit 1; }

  # refuse if something is already under review (API returns 400/200201 anyway)
  api GET "/v1/apps/${uuid}/versions" | "$PY" -c '
import sys, json
rows = json.load(sys.stdin)
busy = [v for v in rows if v.get("status") == 0]
if busy:
    sys.exit("a version is already under review (tag=%s uuid=%s) - wait or withdraw it first"
             % (busy[0].get("tag"), busy[0].get("id")))
' || exit 1

  local body task
  body="$("$PY" -c 'import json,sys;print(json.dumps({"tag":sys.argv[1],"browser_download_url":sys.argv[2]}))' "$tag" "$url")"
  task="$(api POST "/v1/apps/${uuid}/versions" "$body" | "$PY" -c 'import sys,json;print(json.load(sys.stdin)["task_id"])')"
  echo "task_id=$task  (polling; version does not exist until confirm)"

  local all status
  for _ in $(seq 1 120); do
    all="$(api GET "/v1/apps/${uuid}/versions/tasks/${task}" | "$PY" -c 'import sys,json;print(json.load(sys.stdin).get("all_status"))')"
    case "$all" in
      2) break ;;
      3) echo "TASK FAILED - step details:" >&2
         api GET "/v1/apps/${uuid}/versions/tasks/${task}" | "$PY" -c '
import sys, json
d = json.load(sys.stdin)
for stage, steps in (d.get("steps") or {}).items():
    for name, s in steps.items():
        if isinstance(s, dict) and s.get("status") == 3:
            print("  [%s/%s] %s" % (stage, name, s.get("title")))
            print("     message:", (s.get("message") or "").strip())
            print("     advice :", (s.get("advice") or "").strip())
' >&2
         api POST "/v1/apps/${uuid}/versions/tasks/${task}/cancel" >/dev/null 2>&1 || true
         exit 1 ;;
    esac
    sleep 5
  done
  [ "$all" = 2 ] || { echo "timed out waiting for the task" >&2; exit 1; }

  echo "--- parse result ---"
  api GET "/v1/apps/${uuid}/versions/tasks/${task}/result" | "$PY" -c '
import sys, json
d = json.load(sys.stdin)
keep = {k: v for k, v in d.items() if k in ("app_id","version","platform","application_type","name")}
print(" ", json.dumps(keep, ensure_ascii=False))
'

  echo "--- confirm ---"
  api POST "/v1/apps/${uuid}/versions/tasks/${task}/confirm" | "$PY" -c '
import sys, json
v = json.load(sys.stdin)
print("  version created: id=%s tag=%s status=%s" % (v.get("id"), v.get("tag"), v.get("status")))
'
  echo "done - the version is now under review (status=0)"
}

case "${1:-}" in
  whoami) cmd_whoami ;;
  apps)   cmd_apps "${2:-all}" ;;
  status) cmd_status "${2:?usage: $0 status <app_id>}" ;;
  submit) cmd_submit "${2:?usage: $0 submit <app_id> <version> <asset_url>}" \
                     "${3:?missing version}" "${4:?missing browser_download_url}" ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
