# Workshop exercises

Roughly ordered by difficulty. Do them in any order — or ignore them and build
something else.

Assumed running: the dev server is up and port 7676 works in your browser. If
not, see [README.md](README.md#troubleshooting).

The loop: **edit anything in `src/` → save → it rebuilds and reloads** (about
three seconds). Watch the terminal for the rebuild; a syntax error shows up there
and the old Wasm keeps serving until you fix it.

Three files, all at the root:

- `src/index.js` — routing
- `src/fanout.js` — the GRIP response and the publish call
- `src/page.html` — the frontend

Two things that will otherwise cost you ten minutes each:

- **Only `src/` is watched.** If you edit `fastly.toml` — which exercise 6 asks
  you to — Ctrl+C the dev server and start it again with `npm run dev`. Nothing
  will tell you that you needed to.
- **A crash is reported as a bare 500.** If your code throws, the response is a
  500 and the terminal says only `Error while running request handler.` — no
  message, no stack trace, no line number. When that happens, wrap the suspect
  code and print the error yourself:

  ```js
  try {
    // ...your change...
  } catch (error) {
    console.error(`BOOM: ${error.name}: ${error.message}`);
    throw error;
  }
  ```

  `console.error` goes to the terminal. This is the single most useful debugging
  trick here, so it's worth doing before you get stuck rather than after.

---

## 0. Watch the realtime path without a browser

Before changing anything, see the mechanism directly. You'll need two terminals.

**Terminal A** — subscribe to a room. This is the request that gets handed off to
Fanout, and it will just sit there holding open:

```sh
curl -N http://127.0.0.1:7676/rooms/default/events/
```

**Terminal B** — post a message, exactly like the web UI does:

```sh
curl -X POST http://127.0.0.1:7676/rooms/default/messages/ \
  -d 'from=terminal' -d 'text=hello from curl'
```

Terminal A should print an SSE event within a moment:

```
event: message
data: {"from":"terminal","text":"hello from curl"}
```

Leave terminal A running and look at the dev server's log. You'll see **two**
requests for one `curl`, and the log nests the second inside the first:

```
request{id=0}: handling request GET .../rooms/default/events/
request{id=0}: Pushpin redirect signaled to backend 'self'
request{id=0}:request{id=1}: handling request GET .../rooms/default/events/
```

`id=0` is the browser's request; `id=1` is Fanout coming back to ask what to do,
carrying `Grip-Sig`. Both completed in about a millisecond. Nothing in your code
is holding terminal A's connection open — Pushpin is.

Wait 20 seconds and terminal A gets a blank line. That's `Grip-Keep-Alive`
(see `src/fanout.js`), and it's why the stream survives idle proxies.

---

## 1. Prove the edge is in the path

**Goal:** get comfortable with the edit/rebuild cycle.

Add a header to the page response in `src/index.js`:

```js
return new Response(PAGE, {
  headers: {
    'Content-Type': 'text/html; charset=utf-8',
    'x-workshop': 'edge was here',
  },
});
```

**Verify:**

```sh
curl -sI http://127.0.0.1:7676/ | grep -i x-workshop
```

**Then try:** add a header to the *streaming* response instead — the one
`gripResponse()` builds in `src/fanout.js` — and compare what you returned with
what the client gets:

```sh
# what the client sees, through Fanout.
# -D - dumps the headers, -o /dev/null throws the (endless) body away.
curl -sD - -o /dev/null --max-time 3 http://127.0.0.1:7676/rooms/default/events/

# what you actually returned: pretend to be Fanout, and you get it raw
curl -sD - -o /dev/null -H 'Grip-Sig: fake' http://127.0.0.1:7676/rooms/default/events/
```

(`curl -I` won't work on these — that sends `HEAD`, and the stream route only
answers `GET`.)

Your own header survives both ways. But the second command shows
`grip-hold`, `grip-channel`, `grip-keep-alive` and `content-length: 0`, and the
first shows none of them — instead you get `transfer-encoding: chunked`. Fanout
ate the instructions, acted on them, and wrote its own response.

That second command is the most useful debugging tool in this repo: setting
`Grip-Sig` yourself takes Fanout out of the picture and shows you exactly what
your code produced.

---

## 2. Break the handoff on purpose

**Goal:** understand what `createFanoutHandoff()` actually buys you.

In `src/index.js`, make the events route skip the handoff and always return the
GRIP response:

```js
if (events && request.method === 'GET') {
  const room = events[1];
  return gripResponse(`room-${room}`);   // no createFanoutHandoff
}
```

Reload the chat. Watch the status dot in the header, and the dev server log.

**What to look for:** the browser now receives the `Grip-Hold` and `Grip-Channel`
headers *itself* — and does nothing with them, because it is not a GRIP proxy. The
response has an empty body, so it ends immediately (in about 1.5ms), so
`EventSource` reconnects, forever. You get a hot loop of requests and no messages.

```sh
curl -s -o /dev/null -w '%{http_code} in %{time_total}s\n' \
  http://127.0.0.1:7676/rooms/default/events/     # 200 in 0.0015s — not held
```

The lesson: those headers aren't a feature of HTTP. They're instructions, and they
only mean anything because there's something in the path that speaks GRIP. That
something is Fanout, and `createFanoutHandoff()` is how you put it there.

Now try the opposite mistake — hand off unconditionally, without the `Grip-Sig`
check:

```js
return createFanoutHandoff(request, 'self');
```

Fanout hands the request to `self`, which hands it to Fanout, which hands it to
`self`… and nothing stops it. **One** request measured here produced 3,868 nested
handoffs, 798 levels deep, in ten seconds, with no loop detection anywhere in the
stack — the log shows an ever-growing
`request{id=0}:request{id=2}:request{id=4}:…` chain.

So: send exactly one request, with a timeout, and stop it yourself.

```sh
curl -s -o /dev/null --max-time 5 http://127.0.0.1:7676/rooms/default/events/
```

Put the `Grip-Sig` check back afterwards. The dev server recovers on its own once
the request is abandoned — no restart needed — but a browser tab left open on this
will keep the loop going indefinitely.

**The real lesson:** the `Grip-Sig` check isn't a nicety, it's what terminates the
recursion. A self-referential backend is a loop with a base case, and that header
is the base case.

---

## 3. Filter messages before they're published

**Goal:** validate and rewrite requests in Compute.

The publish endpoint already truncates and rejects empty messages. Extend it in
`src/index.js` — pick whichever appeals:

```js
// Reject a blocklist of words.
const BLOCKED = ['spam', 'crypto'];
if (BLOCKED.some((word) => message.text.toLowerCase().includes(word))) {
  return badRequest('No.');
}

// Or stamp something on server-side, so clients can't lie about it.
message.at = new Date().toISOString();
message.country = event.client.geo?.country_code ?? '??';
```

If you add a field, render it in `src/page.html` (`addMessage()`).

**Verify:**

```sh
curl -si http://127.0.0.1:7676/rooms/default/messages/ \
  -d 'from=test' -d 'text=buy crypto now' | head -1
```

**Worth noticing:** the client can't route around any of this. There is no
"backend" to reach past — the edge *is* the app. And a rate limit or a blocklist
here runs in every POP, not in one datacentre.

---

## 4. Subscribe one connection to two channels

**Goal:** learn the shape of GRIP beyond the happy path.

A held connection can be subscribed to several channels. Give every connection an
`announcements` channel alongside its room.

A plain object can't have two keys of the same name, so use `Headers` and
`append`:

```js
export function gripResponse(channel) {
  const headers = new Headers({
    'Content-Type': 'text/event-stream',
    'Grip-Hold': 'stream',
    'Grip-Keep-Alive': '\\n; format=cstring; timeout=20',
  });
  headers.append('Grip-Channel', channel);
  headers.append('Grip-Channel', 'announcements');
  return new Response(null, { headers });
}
```

Look at what that actually sends, with the `Grip-Sig` trick from exercise 1:

```sh
curl -sD - -o /dev/null -H 'Grip-Sig: fake' \
  http://127.0.0.1:7676/rooms/aaa/events/ | grep -i channel
# grip-channel: room-aaa, announcements
```

Two `append` calls, one header, comma-joined — and GRIP reads that as two
channels. (Which means `'Grip-Channel': \`${channel}, announcements\`` on a plain
object would have worked too. `Headers` is the tidier habit.)

**Verify:** subscribe to two different rooms, then publish to `announcements`
using the recipe in exercise 5 below, changing the channel to `announcements`:

```sh
curl -N http://127.0.0.1:7676/rooms/aaa/events/   # terminal A
curl -N http://127.0.0.1:7676/rooms/bbb/events/   # terminal B
```

Both terminals should get the announcement; a message sent to room `aaa` should
still appear only in terminal A.

**Extensions:** a per-user channel (`user-<nickname>`) for direct messages;
`Grip-Channel: name; prev-id=<id>` to make the stream detect gaps.

---

## 5. Publish to a channel from outside the app

**Goal:** see that publishing is just an HTTP request, decoupled from the app
that serves the page.

`publish()` in `src/fanout.js` POSTs to Pushpin's publish endpoint on port 5561.
Nothing stops you doing the same by hand. Open the chat in a browser, then:

```sh
curl -X POST http://127.0.0.1:5561/publish/ \
  -H 'Content-Type: application/json' \
  -d '{
    "items": [{
      "channel": "room-default",
      "formats": {
        "http-stream": {
          "content": "event: message\ndata: {\"from\":\"ghost\",\"text\":\"boo\"}\n\n"
        }
      }
    }]
  }'
```

The message appears in every open tab on `room-default`, and your Compute service
was not involved at all.

If nothing renders, the SSE framing probably doesn't match what the client
expects — go back to exercise 0, look at the real bytes on the wire, and copy that
shape exactly. Both `\n\n` at the end matter.

**Why this matters:** in production this same publish goes to
`https://api.fastly.com/service/<service-id>/publish/`, so *any* system you own
can push to connected clients — a cron job, a webhook receiver, a CI pipeline,
another service — with an HTTP request and an API token. Realtime stops being an
architectural commitment and becomes a thing you can curl.

---

## 6. Add history with a KV store

**Goal:** the app is currently amnesiac; give it a memory. Also the most
interesting corner of GRIP.

The trick: a `Grip-Hold: stream` response can *have a body*. Fanout sends that
body to the client first, then holds the connection open for whatever gets
published later. So "the last N messages, then live updates" is one response, and
the client needs no extra request and no extra code.

**1.** Declare a [KV store](https://www.fastly.com/documentation/guides/concepts/edge-state/data-stores/#kv-stores)
in `fastly.toml`:

```toml
[local_server.kv_stores]
history = []
```

`fastly.toml` isn't watched, so restart the dev server (Ctrl+C, `npm run dev`).

**2.** Append to it when publishing, in the POST branch of `src/index.js`:

```js
import { KVStore } from 'fastly:kv-store';

const history = new KVStore('history');
const key = `room-${room}`;
const previous = await history.get(key);
const messages = previous ? await previous.json() : [];
messages.push(message);
await history.put(key, JSON.stringify(messages.slice(-20)));
```

**3.** Let `gripResponse()` take a backlog and emit it as the body, in
`src/fanout.js`:

```js
export function gripResponse(channel, backlog = []) {
  const body = backlog
    .map((m) => `event: message\ndata: ${JSON.stringify(m)}\n\n`)
    .join('');
  return new Response(body, { headers: { /* as before */ } });
}
```

**4.** Read the history back and pass it, in the `Grip-Sig` branch of
`src/index.js` — this is the step that's easy to forget:

```js
const stored = await new KVStore('history').get(`room-${room}`);
return gripResponse(`room-${room}`, stored ? await stored.json() : []);
```

**Verify:** send a few messages with nobody listening, then open a fresh
subscriber. It gets the backlog immediately, then live messages after it:

```sh
for t in one two three; do
  curl -s -X POST http://127.0.0.1:7676/rooms/hist/messages/ -d 'from=a' -d "text=$t"
done
curl -N http://127.0.0.1:7676/rooms/hist/events/   # all three arrive at once
```

**Things that will bite you, and are worth discussing:**

- Read-modify-write on a shared key is a race. Two simultaneous messages and one
  wins. Fixes: a key per message plus a
  [list](https://www.fastly.com/documentation/reference/api/services/resources/kv-store-item/)
  prefix scan, or accept the loss — which is often the right answer for chat.
- KV writes are eventually consistent between POPs, so a reader in another region
  may briefly not see the newest message. The realtime stream is what makes this
  survivable: the live path is Fanout, and KV is only the catch-up path.
- Locally, Viceroy keeps the store in memory and **loses it when the dev server
  restarts** — including on every rebuild. Don't debug that for ten minutes.
- `const messages = ...` in step 2 shadows nothing now, but if you name a new
  variable after one that already exists in the same block, you get a bare 500 and
  `Cannot access 'x' before initialization` — which the terminal won't tell you.
  See the `console.error` trick at the top of this file.

---

## 7. Add presence ("N people here")

**Goal:** an open-ended one, with a genuinely hard part.

Sketch:

1. Publish a `presence` event when someone joins a room. The nickname is already
   posted with each message; you'll need the client to announce itself.
2. Give it a distinct event type (`event: presence` instead of `event: message`)
   and handle it in `page.html` with `stream.addEventListener('presence', ...)`.

The hard part is knowing when someone *leaves*. Fanout holds the connection, so
your code is never told that it dropped — that's the whole trade. Options worth
arguing about: a periodic heartbeat POST from the client plus a TTL, or Fanout's
[subscription callbacks](https://www.fastly.com/documentation/guides/concepts/real-time-messaging/fanout/),
which tell your app when a channel gains or loses subscribers.

---

## 8. Deploy it for real

If you have (or make) a Fastly account, see
[README.md ▸ Deploying to real Fastly](README.md#deploying-to-real-fastly).

The app code doesn't change. `src/fanout.js` already picks its publish endpoint
based on `FASTLY_HOSTNAME`, and `fastly.toml` already declares the backends and
enables Fanout. The one real difference is the API token, which has to come from
a secret store rather than being baked into the package.

---

## Reference

- [Fanout documentation](https://www.fastly.com/documentation/guides/concepts/real-time-messaging/fanout/)
- [GRIP protocol](https://pushpin.org/docs/protocols/grip/) — the full set of `Grip-*` headers
- [`fastly:fanout` API](https://js-compute-reference-docs.edgecompute.app/docs/fastly:fanout/createFanoutHandoff)
- [JavaScript on Compute](https://www.fastly.com/documentation/guides/compute/javascript/)
- [Fanout starter kit](https://github.com/fastly/compute-starter-kit-javascript-fanout) — long-polling and WebSockets too
- [Original chat demo](https://github.com/fastly/fanout-chat-demo) — the same app with a Django origin
