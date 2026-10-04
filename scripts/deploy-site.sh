#!/bin/bash
# Deploys the landing page (site/) and its waitlist function (functions/) to Cloudflare Pages.
#
# One-time: the Neon connection string is a Pages secret, set by you, never committed:
#   wrangler pages secret put DATABASE_URL --project-name bupsy
# Secrets apply to new deployments, so run this script again after setting it.
set -euo pipefail
cd "$(dirname "$0")/.."
wrangler pages deploy site --project-name bupsy --branch main --commit-dirty=true
