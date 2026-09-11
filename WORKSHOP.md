# Workshop exercises

Roughly ordered by difficulty. Do them in any order — or ignore them and build
something else.

Assumed running: `scripts/dev.sh` has started both apps, and port 7676 works in
your browser. If not, see [README.md](README.md#troubleshooting).

Reminder of the loop: **edit `edge/src/index.js` → save → it rebuilds itself.**
Watch `.dev/logs/edge.log` (or the terminal) for the rebuild. Python changes are
picked up by Django's autoreloader.

---

## 0. Watch the realtime path without a browser

Before changing anything, see the mechanism directly. You'll need two terminals.

**Terminal A** — subscribe to a room's event stream. This is the request that
gets handed off to Fanout, and it will just sit there holding open:

```sh
curl -N http://127.0.0.1:7676/rooms/default/events/
```

**Terminal B** — post a message, exactly like the web UI does:

```sh
curl -X POST http://127.0.0.1:7676/rooms/default/messages/ \
  -d 'from=terminal' -d 'text=hello from curl'
```

Terminal A should print an SSE event within a moment. Keep this output — the
exact framing is useful in exercise 5.

**Worth noticing:** terminal A's connection is held by Pushpin (Fanout), *not* by
Django. Django answered that request in milliseconds and moved on.

---

## 1. Prove the edge is in the path

**Goal:** get comfortable with the edit/rebuild cycle.

Add a header to every response in `edge/src/index.js`:

```js
const response = await fetch(request, { backend: 'origin' });
response.headers.set('x-workshop', 'edge was here');
return response;
```

**Verify:**

```sh
curl -sI http://127.0.0.1:7676/ | grep -i x-workshop
```

If you don't see it, check the rebuild finished — a syntax error will show up in
`.dev/logs/edge.log` and the old Wasm keeps serving.

---

## 2. Serve a route entirely at the edge

**Goal:** respond without touching the origin at all.

Add a handler that returns a synthetic response before any `fetch()`:

```js
if (pathname === '/edge-info') {
  return new Response(
    JSON.stringify({
      method: request.method,
      path: pathname,
      // Try event.client here too — see what's available locally vs deployed.
    }, null, 2),
    { headers: { 'Content-Type': 'application/json' } },
  );
}
```

**Verify:** `curl -s http://127.0.0.1:7676/edge-info`

Stop the origin (`scripts/dev.sh stop` then start only what you need, or just
kill Django) and confirm `/edge-info` still answers while `/` doesn't. That's
work the origin never sees.

---

## 3. Break the handoff on purpose

**Goal:** understand what `createFanoutHandoff()` actually buys you.

Comment out the Fanout branch so the events request is proxied like any other
request:

```js
// if (request.method === 'GET' && pathname.startsWith('/rooms/') && pathname.endsWith('/events/')) {
//   return createFanoutHandoff(request, 'origin');
// }
```

Reload the chat in two tabs and try sending a message.

**What to look for:** the stream no longer behaves like it did. Without Fanout in
front, nothing is holding the connection open and subscribing it to a channel, so
the origin has to deal with the long-lived request itself. Watch
`.dev/logs/origin.log` while you do this, and note that Django is now the thing
tied up by each connected client — which is exactly what Fanout exists to avoid.

Put the branch back when you're done.

---

## 4. Filter messages at the edge

**Goal:** inspect and act on a request body in Compute.

Reject overly long messages before they ever reach the origin. The catch: once
you read the body, you have to build the forwarded request yourself.

```js
if (request.method === 'POST' && pathname.endsWith('/messages/')) {
  const body = await request.text();
  const text = new URLSearchParams(body).get('text') ?? '';

  if (text.length > 200) {
    return new Response(JSON.stringify({ error: 'message too long' }), {
      status: 413,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  return fetch(
    new Request(request.url, {
      method: 'POST',
      headers: request.headers,
      body,
    }),
    { backend: 'origin' },
  );
}
```

**Verify:** send a short message (works), then a very long one:

```sh
curl -si http://127.0.0.1:7676/rooms/default/messages/ \
  -d 'from=test' --data-urlencode "text=$(python3 -c 'print("x"*300)')" | head -1
```

**Extensions:** a word blocklist; rejecting empty `from`; adding a
`Fastly-Client-IP`-based rate limit with a
[KV store](https://www.fastly.com/documentation/guides/concepts/edge-state/data-stores/#kv-stores)
(deployed only).

---

## 5. Publish to a channel from outside the app

**Goal:** see that publishing is just an HTTP request, decoupled from Django.

Django publishes to Pushpin's publish endpoint on port 5561. Nothing stops you
doing the same by hand. Open the chat in a browser, then:

```sh
curl -X POST http://127.0.0.1:5561/publish/ \
  -H 'Content-Type: application/json' \
  -d '{
    "items": [{
      "channel": "room-default",
      "formats": {
        "http-stream": {
          "content": "event: message\ndata: {\"from\":\"ghost\",\"text\":\"boo\",\"id\":999999}\n\n"
        }
      }
    }]
  }'
```

If the message doesn't render, the SSE framing probably doesn't match what the
client expects — go back to exercise 0, look at the real bytes on the wire, and
copy that shape exactly (`django-eventstream` includes an `id:` line and its own
JSON structure).

**Why this matters:** in production this same publish goes to
`https://api.fastly.com/service/<service-id>/publish/`, so *any* system you own
can push to connected clients — a cron job, a webhook receiver, another service —
without going through the app that serves the page.

---

## 6. Add presence ("N people here")

**Goal:** a change spanning both apps.

Sketch:

1. In `origin/chat/views.py`, publish an event when someone joins a room.
2. Give it a distinct event type (e.g. `presence` rather than `message`).
3. Handle it in `origin/chat/templates/chat/chat.html` with another
   `es.addEventListener('presence', ...)`.

The hard part is knowing when someone *leaves* — Fanout holds the connection, so
the origin isn't told. Options worth discussing: a keepalive ping the client
sends periodically, or Fanout's
[subscription callbacks](https://www.fastly.com/documentation/guides/concepts/real-time-messaging/fanout/).

---

## 7. Deploy it for real

If you have (or make) a Fastly account, see
[README.md ▸ Deploying to real Fastly](README.md#deploying-to-real-fastly). The
app code doesn't change at all — only `GRIP_URL` and the backend definition do.

---

## Reference

- [Fanout documentation](https://www.fastly.com/documentation/guides/concepts/real-time-messaging/fanout/)
- [GRIP protocol](https://pushpin.org/docs/protocols/grip/)
- [`fastly:fanout` API](https://js-compute-reference-docs.edgecompute.app/docs/fastly:fanout/createFanoutHandoff)
- [JavaScript on Compute](https://www.fastly.com/documentation/guides/compute/javascript/)
- [Upstream demo](https://github.com/fastly/fanout-chat-demo)
