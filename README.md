# Fastly Fanout Chat Workshop

A ready-to-hack realtime chat app built on [Fastly Compute](https://www.fastly.com/products/edge-compute)
and [Fastly Fanout](https://docs.fastly.com/products/fanout), packaged as a
GitHub Codespace.

**No Fastly account, no local installs, no signup.** Click the button, wait for
the container to build, and you have a working Compute + Fanout app running in
your browser.

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/kailan/techopen)

---

## Getting started

1. Click **Open in GitHub Codespaces** above (or *Code ▸ Codespaces ▸ Create
   codespace* on the repo).
2. Wait for setup to finish. It installs Python and Node dependencies, Pushpin,
   the Fastly CLI and the local dev server, then builds the Wasm package. First
   run takes a few minutes; if the repo has prebuilds enabled it's near-instant.
3. Both apps start automatically and you'll see their logs in the terminal.
4. When port **7676** is forwarded, open it in your browser. Pick a nickname and
   start chatting. Open a second tab to watch messages arrive in realtime.

The chat is served at `/` (nickname prompt), then `/<room-id>?user=<name>`. Any
room id works — `/default`, `/lobby`, whatever you type.

### Chat with the person next to you

Forwarded ports are private to you by default. To let someone else join your
chat room, make the port public and share the URL:

```sh
gh codespace ports visibility 7676:public -c "$CODESPACE_NAME"
echo "https://${CODESPACE_NAME}-7676.app.github.dev/"
```

## How it works

Two apps run side by side:

| Directory | What it is | Port |
| --- | --- | --- |
| `edge/` | Fastly Compute app (JavaScript) — the thing at the edge | 7676 |
| `origin/` | Django backend + frontend, from the upstream demo | 3000 |

Traffic goes **browser → edge → origin**. Port 7676 is the one you want; 3000 is
exposed only so you can poke at the backend directly.

```
                       ┌───────────────────────────────────────────┐
    browser ──────────▶│  edge/   Fastly Compute  ·  :7676         │
       ▲               │          edge/src/index.js                │
       │               └──────┬─────────────────────────┬──────────┘
       │                      │                         │
       │       normal proxy   │                         │  createFanoutHandoff()
       │         (HTML, CSS,  │                         │  for GET /rooms/*/events/
       │          POST msg)   │                         ▼
       │                      │              ┌─────────────────────┐
       │   SSE stream, held   │              │       Fanout        │
       └──────────────────────┼──────────────│  (Pushpin locally)  │
                              │              └──────────┬──────────┘
                              │                         │ GRIP: hold + subscribe
                              ▼                         ▼
                       ┌───────────────────────────────────────────┐
                       │  origin/   Django  ·  :3000               │
                       │  publishes messages ──▶ Pushpin :5561     │
                       └───────────────────────────────────────────┘
```

### The realtime bit, step by step

1. The browser opens an `EventSource` to `GET /rooms/default/events/`.
2. The edge app spots that path and calls `createFanoutHandoff(request, 'origin')`.
   That hands the request to Fanout instead of returning a response itself.
3. Fanout forwards the request to Django. Django (via `django-eventstream` and
   `django-grip`) replies with [GRIP](https://pushpin.org/docs/protocols/grip/)
   headers meaning *"hold this connection open and subscribe it to channel
   `room-default`"* — and then the Django worker is **done**. It isn't holding
   thousands of open sockets; Fanout is.
4. When someone sends a message, that's an ordinary proxied `POST`. Django saves
   it and calls `send_event('room-default', ...)`, publishing to `GRIP_URL`.
5. Fanout pushes the event down every held connection subscribed to that channel.

That's the whole point of Fanout: your backend stays a plain request/response
app, and the edge absorbs the long-lived connections.

### What stands in for Fanout locally

You don't have a Fastly account, so there's no real Fanout. Instead the Fastly
CLI starts **[Pushpin](https://pushpin.org/)** — the open-source GRIP proxy that
Fanout is built on — next to the local dev server. That's this bit of
`edge/fastly.toml`:

```toml
[local_server.pushpin]
enable = true
```

Pushpin listens on 7677 (proxy) and 5561 (publish). `origin/.env` points
`GRIP_URL` at `http://127.0.0.1:5561/` so Django publishes there. In production
`GRIP_URL` would be a `https://api.fastly.com/service/<service-id>?...` URL
instead — same protocol, same app code.

## Things to try

See **[WORKSHOP.md](WORKSHOP.md)** for a set of exercises, from "change the
message format" to "add presence" and "rate-limit at the edge".

The two files worth knowing:

- `edge/src/index.js` — the Compute app. Deliberately short. Saving it triggers
  an automatic rebuild and reload.
- `origin/chat/views.py` — the backend endpoints, including where messages get
  published.

## Commands

The apps start on their own, but you can drive them manually:

```sh
scripts/dev.sh            # start both (or follow logs if already running)
scripts/dev.sh restart    # restart both
scripts/dev.sh stop       # stop both
scripts/dev.sh status     # what's running, which ports are listening
scripts/dev.sh logs       # follow logs without starting anything
```

Ctrl+C while following logs stops *watching*, not the apps.

Logs are also files, if you'd rather open them in the editor:
`.dev/logs/origin.log` and `.dev/logs/edge.log`.

Editing `edge/src/index.js` rebuilds automatically. Editing Python is picked up
by Django's autoreloader. If something gets wedged, `scripts/dev.sh restart`.

## Troubleshooting

**The page loads but messages never appear in the other tab.**
The SSE stream isn't getting through. Check `scripts/dev.sh status` shows ports
7677 and 5561 listening — those are Pushpin. If they're closed, look for Pushpin
errors in `.dev/logs/edge.log`.

**`failed to find 'pushpin' in your $PATH`.**
The Pushpin install didn't happen. Verify with `command -v pushpin`. Rebuild the
container (*Codespaces: Rebuild Container* in the command palette).

**Port 7676 shows a Fastly error page.**
Usually the origin is down. Check `.dev/logs/origin.log`, then
`scripts/dev.sh restart`.

**Setup half-finished / dependencies missing.**
Re-run it; it's idempotent:

```sh
bash .devcontainer/setup.sh
```

## Running without Codespaces

The devcontainer also works in VS Code locally via *Dev Containers: Reopen in
Container* — **but only on x86_64**. Pushpin's apt repository publishes amd64
packages only, so on an Apple Silicon Mac the image build stops with an
explanatory error. You can either add `"runArgs": ["--platform=linux/amd64"]` to
`.devcontainer/devcontainer.json` and accept the emulation slowdown, or skip the
container entirely:

```sh
brew install pushpin        # macOS; see https://pushpin.org/docs/install/
bash .devcontainer/setup.sh # needs python3 (3.10 recommended) and node 20+
scripts/dev.sh
```

## Deploying to real Fastly

Nothing here is Codespaces-specific — it's the upstream demo. Once you have a
Fastly account:

1. Deploy the backend somewhere publicly reachable and set `GRIP_URL` to
   `https://api.fastly.com/service/<service-id>?verify-iss=fastly:<service-id>&key=<api-token>`.
2. `cd edge && npm run deploy`, using the backend's hostname for the `origin`
   backend.
3. Enable Fanout on the service: `fastly products --enable=fanout`.

Full instructions are in the
[upstream demo README](https://github.com/fastly/fanout-chat-demo#production).

## Credits

Based on [fastly/fanout-chat-demo](https://github.com/fastly/fanout-chat-demo)
(MIT). Changes made for the workshop:

- A devcontainer that installs Pushpin, so local Fanout works with no accounts.
- `scripts/dev.sh` to run both apps together.
- `edge/src/index.js` trimmed to just the Fanout logic (the upstream version also
  serves a demo manifest and screenshot for Fastly's demo gallery).
- `@fastly/cli` bumped to v16 — `[local_server.pushpin]` needs ≥ 13.1.0.
- `ALLOWED_HOSTS` extended to cover Codespaces forwarded-port domains.

Licensed under [MIT](LICENSE.md).
