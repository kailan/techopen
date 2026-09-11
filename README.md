# Fastly Fanout Chat Workshop

A ready-to-hack realtime chat app built entirely on [Fastly Compute](https://www.fastly.com/products/edge-compute)
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
2. Wait for setup to finish. It installs Node dependencies, Pushpin, the Fastly
   CLI and the local dev server, then builds the Wasm package. First run takes a
   few minutes; if the repo has prebuilds enabled it's near-instant.
3. The dev server starts automatically and you'll see its log in the terminal.
4. When port **7676** is forwarded, open it in your browser. Pick a nickname and
   start chatting. Open a second tab to watch messages arrive in realtime.

Messages aren't stored anywhere — you see what's sent while you're connected.
(Adding history is [exercise 6](WORKSHOP.md#6-add-history-with-a-kv-store).)

Rooms are just a query parameter: `/?room=lobby`. Any name works; no room needs
creating.

### Chat with the person next to you

Forwarded ports are private to you by default. To let someone else join your
chat room, make the port public and share the URL:

```sh
gh codespace ports visibility 7676:public -c "$CODESPACE_NAME"
echo "https://${CODESPACE_NAME}-7676.app.github.dev/"
```

## How it works

There is no origin server. One Compute app serves the page, holds nothing open,
and publishes messages:

| File | What it does |
| --- | --- |
| `src/index.js` | Routing: the page, the stream, the publish endpoint |
| `src/fanout.js` | The two Fanout-specific bits: GRIP responses and publishing |
| `src/page.html` | The whole frontend, embedded into the Wasm package at build time |

```
                    ┌─────────────────────────────────────────────┐
   browser ────────▶│  Fastly Compute  ·  :7676  ·  src/index.js   │
      ▲             │                                             │
      │             │  GET  /                    → page.html      │
      │             │  GET  /rooms/x/events/     → hand to Fanout ─┼──┐
      │             │  POST /rooms/x/messages/   → publish ────────┼─┐│
      │             └─────────────────────────────────────────────┘ ││
      │                                    ▲                        ││
      │                                    │ same app, 2nd request  ││
      │                                    │ (Grip-Sig) → GRIP hdrs ││
      │   SSE stream, held open            │                        ││
      └────────────────────────────┬───────┴────────────────────────┘│
                                   │                                 │
                            ┌──────┴─────────────────────┐           │
                            │           Fanout           │◀──────────┘
                            │     (Pushpin locally)      │  publish to channel
                            └────────────────────────────┘
```

### The realtime bit, step by step

1. The browser opens an `EventSource` to `GET /rooms/default/events/`.
2. The app sees no `Grip-Sig` header, so this request hasn't been through Fanout
   yet. It calls `createFanoutHandoff(request, 'self')` and returns. It is not
   holding anything open.
3. Fanout takes the connection and, to find out what to do with it, forwards the
   same request to the `self` backend — **which is this app again**. That request
   arrives with a `Grip-Sig` header.
4. This time the app replies with [GRIP](https://pushpin.org/docs/protocols/grip/)
   headers meaning *"hold this connection open and subscribe it to channel
   `room-default`"*. Then it's done. Fanout owns the socket from here, however
   long it lives.
5. When someone sends a message, that's an ordinary short-lived `POST`. The app
   publishes a JSON payload to the channel and returns `204`.
6. Fanout writes that message into every held connection subscribed to the
   channel.

The point of Fanout is step 4: your code stays a plain request/response app that
answers in milliseconds, and the edge absorbs every long-lived connection. Ten
thousand connected clients cost you no held sockets and no idle processes.

The self-referential `self` backend is worth sitting with for a second. The app
is invoked twice for one client connection: once as the thing being proxied,
once as the thing that tells Fanout what to do. There's no separate config
service — the routing decision lives in the same file as everything else.

### What stands in for Fanout locally

You don't have a Fastly account, so there's no real Fanout. Instead the Fastly
CLI starts **[Pushpin](https://pushpin.org/)** — the open-source GRIP proxy that
Fanout is built on — next to the local dev server. That's this bit of
`fastly.toml`:

```toml
[local_server.pushpin]
enable = true
```

Pushpin listens on 7677 (proxy) and 5561 (publish). Publishing goes to
`http://127.0.0.1:5561/publish/` locally and to
`https://api.fastly.com/service/<service-id>/publish/` when deployed — same
request body either way. See `publish()` in `src/fanout.js`.

## Things to try

See **[WORKSHOP.md](WORKSHOP.md)** for a set of exercises, from "add a response
header" to "add presence" and "keep history in a KV store".

## Commands

The dev server starts on its own, but you can drive it yourself:

```sh
npm run dev      # serve on 7676, rebuilding when anything in src/ changes
npm run build    # just build bin/main.wasm
npm run deploy   # publish to a real Fastly account (see below)
```

Ctrl+C in the terminal running `npm run dev` stops the server; `npm run dev`
starts it again.

Saving any file in `src/` — including `page.html` — triggers a rebuild and
reload. Watch the terminal for it; a syntax error shows up there and the old
Wasm keeps serving.

## Troubleshooting

**The page loads but messages never appear in the other tab.**
The SSE stream isn't getting through. First find out *where* it's broken, by
testing inside the container where no port forwarding is involved — that's
[exercise 0](WORKSHOP.md#0-watch-the-realtime-path-without-a-browser):

```sh
curl -N http://127.0.0.1:7676/rooms/default/events/   # in one terminal
curl -X POST http://127.0.0.1:7676/rooms/default/messages/ \
  -d 'from=t' -d 'text=hi'                            # in another
```

If the event arrives in the `curl` but not in the browser, the app is fine and
the issue is the forwarded-port proxy — try the browser preview, or make the
port public (see [above](#chat-with-the-person-next-to-you)). If it doesn't
arrive in `curl` either, look for errors in the dev server's terminal output.

**`failed to find 'pushpin' in your $PATH`.**
The Pushpin install didn't happen, so the dev server won't start. Verify with
`command -v pushpin`, then rebuild the container (*Codespaces: Rebuild
Container* in the command palette).

**`WARN backend 'self' ... is not up right now` at startup.**
Harmless. The dev server probes backends before it binds its own port, so `self`
— which is the dev server — can't answer yet. Same for `publisher` before Pushpin
is up. Neither warning means anything is broken.

**Sending a message returns 502.**
The publish request failed. The response body says why, and the dev server's
terminal has the same message. Locally this usually means Pushpin isn't up —
check that port 5561 is listening.

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
npm install                 # needs node 20+
npm run dev
```

## Deploying to real Fastly

Nothing here is Codespaces-specific, and the app code doesn't change. Once you
have a Fastly account and a [CLI token](https://www.fastly.com/documentation/reference/tools/cli/#configuring):

1. `npm run deploy`. The CLI creates a service and walks you through the setup
   declared in `fastly.toml`, which enables Fanout and asks for two backends:
   - **`self`** — this service's own domain, e.g. `my-app.edgecompute.app`, port
     443, with *Override Host* set to the same value. It points at itself; see
     [above](#the-realtime-bit-step-by-step).
   - **`publisher`** — `api.fastly.com`, port 443. Pre-filled for you.
2. Give the service an API token to publish with. Create a token with **global
   scope** ([docs](https://www.fastly.com/documentation/guides/account-info/account-management/using-api-tokens/)),
   then put it in a secret store named `fanout` under the key `api_token`:

   ```sh
   fastly secret-store create --name fanout
   fastly secret-store-entry create --store-id <id> --name api_token
   fastly resource-link create --service-id <service-id> --version latest \
     --resource-id <id> --autoclone
   fastly service-version activate --service-id <service-id> --version latest
   ```

   `src/fanout.js` reads it from there. Without it, `POST /rooms/*/messages/`
   returns a 502 explaining what's missing — the streaming half still works, and
   you can drive it by publishing through the API directly
   ([exercise 5](WORKSHOP.md#5-publish-to-a-channel-from-outside-the-app)).

The one thing to change before putting anything like this in production: verify
the `Grip-Sig` header's JWT instead of just checking it exists, so clients can't
forge a request that looks like it came from Fanout. See
[verifying requests from Fanout](https://www.fastly.com/documentation/guides/concepts/real-time-messaging/fanout/).

## Notes for the workshop organizer

Before the session:

- **Make the repo public** (or make sure every attendee has access) — the
  Codespaces badge needs it.
- **Turn on prebuilds**: *Settings ▸ Codespaces ▸ Set up prebuild* for `main`.
  Without one, each attendee waits several minutes while the image builds and
  dependencies install. With one, they're chatting almost immediately. This is
  the single biggest difference to how the session feels — the container build
  installs Pushpin and Qt dependencies, which is not fast.
- **Re-run the prebuild** after changing `.devcontainer/`, `package.json` or
  `package-lock.json`, otherwise attendees get the setup at create time instead.
- **Check attendee Codespaces quota.** Free personal accounts include monthly
  core-hours; a 2-core machine is enough here and uses the least quota.
- **Try the badge yourself** from an account without push access, to be sure
  permissions are right.

During the session, if someone's environment is broken, the fastest fixes are
Ctrl+C then `npm run dev`, and then *Codespaces: Rebuild Container*.

## Credits

The chat app is a rewrite of [fastly/fanout-chat-demo](https://github.com/fastly/fanout-chat-demo)
(MIT) with the Django origin removed — everything is served from Compute
instead, so there's one language and one process to think about. The
self-referential-backend pattern follows Fastly's
[Fanout starter kit](https://github.com/fastly/compute-starter-kit-javascript-fanout)
(MIT).

Added for the workshop: a devcontainer that installs Pushpin, so Fanout works
locally with no Fastly account.

Licensed under [MIT](LICENSE.md).
