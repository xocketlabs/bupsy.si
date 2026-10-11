#!/bin/bash
# Who joined the waitlist, newest first. `scripts/waitlist.sh count` for just the number,
# `scripts/waitlist.sh csv > waitlist.csv` to export.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-list}" in
  count) wrangler d1 execute bupsy-waitlist --remote --command "SELECT COUNT(*) AS signups FROM waitlist" ;;
  csv)   wrangler d1 execute bupsy-waitlist --remote --json \
           --command "SELECT email, source, country, created_at FROM waitlist ORDER BY id" \
         | python3 -c 'import csv,json,sys; rows=json.load(sys.stdin)[0]["results"]; w=csv.writer(sys.stdout); w.writerow(["email","source","country","created_at"]); [w.writerow([r["email"],r["source"],r["country"],r["created_at"]]) for r in rows]' ;;
  *)     wrangler d1 execute bupsy-waitlist --remote \
           --command "SELECT email, source, country, created_at FROM waitlist ORDER BY id DESC LIMIT 100" ;;
esac
