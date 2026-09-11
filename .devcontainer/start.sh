#!/usr/bin/env bash
#
# Starts the local Fastly dev server, which also starts Pushpin (the stand-in
# for Fanout). Run on every attach to the container.
#
# There is only one process to manage, so this is mostly a guard: reattaching to
# a container that already has the server running shouldn't try to bind port
# 7676 a second time and fail confusingly.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PORT=7676

port_open() {
  # Bash's /dev/tcp avoids depending on lsof or ss being installed.
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

if port_open "$PORT"; then
  echo "The dev server is already running on port $PORT."
  echo "Open that port in your browser to use the chat app."
  echo
  echo "To restart it, find the terminal it is running in and press Ctrl+C,"
  echo "then run: npm run dev"
  exit 0
fi

if [ ! -d node_modules ]; then
  echo "Dependencies are missing — running .devcontainer/setup.sh first."
  bash .devcontainer/setup.sh || {
    echo "Setup failed. Fix the errors above, then run: npm run dev" >&2
    exit 1
  }
fi

cat <<EOF

Starting the Fastly Compute dev server on port $PORT.

It builds the Wasm package and boots Pushpin before it starts listening, which
takes a little while on a 2-core machine — the first run is the slowest. When
it's ready, open port $PORT in your browser.

Press Ctrl+C to stop it; 'npm run dev' starts it again.

EOF

# Rebuilds and reloads whenever anything in src/ changes.
exec npm run dev
