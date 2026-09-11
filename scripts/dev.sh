#!/usr/bin/env bash
#
# Runs the workshop apps:
#
#   * origin — the Django backend, on port 3000
#   * edge   — the Fastly Compute app in the local dev server, on port 7676.
#              The Fastly CLI also starts Pushpin (ports 7677 and 5561) to
#              emulate Fanout.
#
# Browse to port 7676; that's the one that goes through the edge app.
#
# Usage:
#   scripts/dev.sh [start]   start both apps if needed, then follow the logs
#   scripts/dev.sh stop      stop both apps
#   scripts/dev.sh restart   stop, then start
#   scripts/dev.sh status    report what is running
#   scripts/dev.sh logs      follow the logs without starting anything

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

STATE_DIR="$REPO_ROOT/.dev"
LOG_DIR="$STATE_DIR/logs"
mkdir -p "$LOG_DIR"

ORIGIN_PORT=3000
EDGE_PORT=7676

C_RESET=$'\033[0m'
C_ORIGIN=$'\033[1;35m'
C_EDGE=$'\033[1;36m'
C_INFO=$'\033[1;32m'
C_WARN=$'\033[1;33m'

info() { printf '%s==>%s %s\n' "$C_INFO" "$C_RESET" "$1"; }
warn() { printf '%sWARNING:%s %s\n' "$C_WARN" "$C_RESET" "$1" >&2; }

# --- process bookkeeping ----------------------------------------------------
#
# Each app is started in its own process group, and we record the process group
# id rather than a single pid. Both apps spawn children — Django's autoreloader
# forks, and the Fastly CLI runs Viceroy and Pushpin as subprocesses — so
# signalling the whole group is what actually stops them.

pgid_file() { echo "$STATE_DIR/$1.pgid"; }

running() {
  local pgid_path
  pgid_path="$(pgid_file "$1")"
  [ -f "$pgid_path" ] || return 1
  local pgid
  pgid="$(cat "$pgid_path" 2>/dev/null)"
  [ -n "$pgid" ] || return 1
  kill -0 -- "-$pgid" 2>/dev/null
}

# start_app <name> <working-dir> <command...>
start_app() {
  local name="$1" workdir="$2"
  shift 2
  local log="$LOG_DIR/$name.log"

  # `setsid` puts the command in a fresh process group so that it survives this
  # script exiting (e.g. when the attendee closes the terminal), and so that we
  # can signal it and all of its children together.
  ( cd "$workdir" && exec setsid "$@" ) >"$log" 2>&1 &
  local pid=$!

  # Read back the real process group id, and wait until it differs from our own.
  # Until setsid(2) has actually been called the child is still in this script's
  # process group, and recording that would mean a later `kill -- -$pgid` took
  # down this script and its siblings instead of the app.
  local self_pgid pgid=""
  self_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
  for _ in $(seq 1 50); do
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [ -n "$pgid" ] && [ "$pgid" != "$self_pgid" ]; then
      break
    fi
    pgid=""
    sleep 0.1
  done

  if [ -z "$pgid" ]; then
    # Either it exited immediately, or it never got its own group. Fall back to
    # the bare pid: signalling a non-existent group is harmless, and the logs
    # will show what went wrong.
    warn "Could not confirm a process group for $name — see $log"
    pgid="$pid"
  fi
  echo "$pgid" > "$(pgid_file "$name")"
}

stop_app() {
  local name="$1"
  local pgid_path
  pgid_path="$(pgid_file "$name")"

  if running "$name"; then
    local pgid
    pgid="$(cat "$pgid_path")"
    info "Stopping $name"
    kill -TERM -- "-$pgid" 2>/dev/null
    for _ in $(seq 1 30); do
      kill -0 -- "-$pgid" 2>/dev/null || break
      sleep 0.2
    done
    if kill -0 -- "-$pgid" 2>/dev/null; then
      warn "$name did not stop gracefully; sending SIGKILL"
      kill -KILL -- "-$pgid" 2>/dev/null
    fi
  fi
  rm -f "$pgid_path"
}

port_open() {
  # Bash's /dev/tcp avoids depending on lsof/ss being present. The subshell's
  # exit status is whether the connection succeeded.
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

wait_for_port() {
  local port="$1" label="$2" attempts="${3:-100}"
  for _ in $(seq 1 "$attempts"); do
    port_open "$port" && return 0
    sleep 0.3
  done
  warn "$label did not come up on port $port in time — check 'scripts/dev.sh logs'."
  return 1
}

# --- setup safety net ------------------------------------------------------

ensure_setup() {
  if [ ! -x origin/venv/bin/python ] || [ ! -d edge/node_modules ]; then
    warn "Dependencies are missing — running .devcontainer/setup.sh first."
    bash .devcontainer/setup.sh || {
      warn "Setup failed. Fix the errors above, then re-run scripts/dev.sh."
      exit 1
    }
  fi
}

# --- commands --------------------------------------------------------------

do_start() {
  ensure_setup

  if running origin; then
    info "origin is already running (port $ORIGIN_PORT)"
  elif port_open "$ORIGIN_PORT"; then
    warn "Something is already listening on port $ORIGIN_PORT; not starting origin."
  else
    info "Starting origin (Django) on port $ORIGIN_PORT"
    start_app origin "$REPO_ROOT/origin" ./venv/bin/python manage.py runserver "$ORIGIN_PORT"
    wait_for_port "$ORIGIN_PORT" "origin"
  fi

  if running edge; then
    info "edge is already running (port $EDGE_PORT)"
  elif port_open "$EDGE_PORT"; then
    warn "Something is already listening on port $EDGE_PORT; not starting edge."
  else
    info "Starting edge (Fastly Compute + Pushpin) on port $EDGE_PORT"
    # `npm run dev` runs the Fastly CLI from edge/node_modules, so the version
    # is pinned by edge/package.json. It rebuilds the Wasm package when files
    # in edge/src change.
    start_app edge "$REPO_ROOT/edge" npm run dev
    wait_for_port "$EDGE_PORT" "edge"
  fi

  echo
  info "Open port $EDGE_PORT in your browser to use the chat app."
  echo "    In Codespaces: the Ports panel, or the notification that just appeared."
  echo
}

do_stop() {
  stop_app edge
  stop_app origin
  info "Stopped."
}

do_status() {
  for name in origin edge; do
    if running "$name"; then
      printf '%-8s running (pgid %s)\n' "$name" "$(cat "$(pgid_file "$name")")"
    else
      printf '%-8s stopped\n' "$name"
    fi
  done
  for port in "$ORIGIN_PORT" "$EDGE_PORT" 7677 5561; do
    if port_open "$port"; then
      printf 'port %-5s listening\n' "$port"
    else
      printf 'port %-5s closed\n' "$port"
    fi
  done
}

do_logs() {
  echo "Following logs. Press Ctrl+C to stop watching — the apps keep running."
  echo

  # Tail both logs into one stream, colour-coded per app.
  tail -n 20 -F "$LOG_DIR/origin.log" 2>/dev/null \
    | sed -u "s/^/${C_ORIGIN}[origin]${C_RESET} /" &
  local origin_tail=$!
  tail -n 20 -F "$LOG_DIR/edge.log" 2>/dev/null \
    | sed -u "s/^/${C_EDGE}[edge]  ${C_RESET} /" &
  local edge_tail=$!

  # Stop only the tails on Ctrl+C, never the apps themselves.
  trap 'kill "$origin_tail" "$edge_tail" 2>/dev/null; exit 0' INT TERM
  wait "$origin_tail" "$edge_tail" 2>/dev/null
}

case "${1:-start}" in
  start)
    do_start
    do_logs
    ;;
  stop)
    do_stop
    ;;
  restart)
    do_stop
    # Give the OS a moment to release the ports before rebinding them.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      port_open "$EDGE_PORT" || port_open "$ORIGIN_PORT" || break
      sleep 0.3
    done
    do_start
    do_logs
    ;;
  status)
    do_status
    ;;
  logs)
    do_logs
    ;;
  *)
    echo "Usage: scripts/dev.sh [start|stop|restart|status|logs]" >&2
    exit 64
    ;;
esac
