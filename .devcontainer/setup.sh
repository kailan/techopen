#!/usr/bin/env bash
#
# One-time setup for the workshop environment. Installs dependencies and
# pre-downloads/pre-builds everything the dev server needs, so that the first
# run is as fast as possible.
#
# Safe to re-run: every step is idempotent.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$1" >&2; }

step "Checking Pushpin is available"
if command -v pushpin >/dev/null 2>&1; then
  echo "Found $(command -v pushpin) — $(pushpin --version 2>&1 | head -1)"
else
  warn "'pushpin' is not on PATH, so the dev server will not start. It is
         normally installed by .devcontainer/Dockerfile; try rebuilding the
         container."
fi

step "Installing JavaScript dependencies"
npm install --no-fund --no-audit

step "Configuring the Fastly CLI"
# The CLI otherwise asks about build metadata collection the first time it
# builds, which would hang when the dev server starts unattended.
npx fastly compute metadata --disable >/dev/null 2>&1 \
  || warn "Could not pre-set the CLI metadata preference."

step "Downloading the local Fastly dev server (Viceroy)"
# `fastly compute serve` fetches Viceroy on first use. Doing it now means the
# first run doesn't stall on a download — and lets prebuilds cache it.
npx fastly compute install-tools --non-interactive \
  || warn "Could not pre-download Viceroy; 'fastly compute serve' will fetch it on first run."

step "Pre-building the Wasm package"
npm run build \
  || warn "Pre-build failed; the dev server will try again when it starts."

step "Setup complete"
cat <<'EOF'
The dev server starts automatically when you attach to the container.

Useful commands:
  npm run dev      start the dev server (rebuilds when src/ changes)
  npm run build    build the Wasm package without serving it

Then open the forwarded port 7676 in your browser.
EOF
