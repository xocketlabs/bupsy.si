#!/bin/bash
# Runs what CI runs, on this Mac, for free.
#
# GitHub bills a private repo's macOS minutes at ten times the Linux rate, so the cheap habit is to
# run this before pushing and let CI confirm rather than discover. Same checks, same order, so a
# green run here means a green run there.
#
#   ./scripts/ci-local.sh          everything
#   ./scripts/ci-local.sh --quick  skip the app build (the slowest step)
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n\033[1;35m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31m✗ %s\033[0m\n' "$1"; exit 1; }

step "Credential boundary"
if grep -rnE '\.claude/\.credentials|\.codex/auth\.json|CLAUDE_CODE_OAUTH_TOKEN|setup-token' \
     --include='*.swift' --include='*.go' Packages/ Apps/ Tools/ 2>/dev/null; then
  fail "Source references a vendor credential path. See docs/00-compliance-and-auth.md"
fi
if grep -rniE '\b(claude|anthropic|openai|codex|grok|xai)(kit|app|bot)\b' \
     --include='*.swift' --include='*.go' Packages/ Apps/ Tools/ 2>/dev/null; then
  fail "Vendor mark used in a product or type name. See compliance doc §5."
fi
echo clean

step "Headless core (Go)"
if command -v go >/dev/null; then
  (cd Tools/bupsy-run
   unformatted=$(gofmt -l .); [ -z "$unformatted" ] || fail "gofmt would change: $unformatted"
   go vet ./... && go build ./... && go test ./...) || fail "Go core"
else
  echo "go not installed — skipped (CI still runs it)"
fi

step "BupsyKit tests"
swift test --package-path Packages/BupsyKit 2>&1 | tail -3

if [ "${1:-}" != "--quick" ]; then
  step "The app builds"
  xcodegen generate >/dev/null
  set -o pipefail
  xcodebuild -project Bupsy.xcodeproj -scheme BupsyMac -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath build/ci-local \
    CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
  [ "${PIPESTATUS[0]}" -eq 0 ] || fail "App build"
fi

printf '\n\033[1;32m✓ All checks passed\033[0m\n'
