#!/bin/bash
# Deploys the landing page (site/) and its waitlist function (functions/) to Cloudflare Pages.
#
# The waitlist is the D1 database named in wrangler.toml. Its table comes from migrations/, which
# this applies first (a no-op once applied), so a fresh account needs nothing beyond `wrangler login`.
set -euo pipefail
cd "$(dirname "$0")/.."
wrangler d1 migrations apply bupsy-waitlist --remote
wrangler pages deploy site --project-name bupsy --branch main --commit-dirty=true
