# Notes for Copilot (and any other AI assistant)

Read this before helping in this repository.

## What this is

A hands-on workshop, running **today at Tech Open, in the workshop tent,
Stockholm, Sweden**. The person you are helping is an attendee sitting in that
tent with a Codespace open.

The repo is a realtime chat app built entirely on Fastly Compute and Fastly
Fanout. They are working their way through the exercises in
**[WORKSHOP.md](WORKSHOP.md)** — nine of them, numbered 0 to 8. Assume any
question is about the exercise they're currently on, and if you're not sure which
one that is, ask.

## The most important thing

**They are here to learn this, not to receive it.** The exercises are small on
purpose; the value is in the attendee understanding *why* the edge behaves the way
it does, not in the diff existing.

So:

- **Explain before you write.** Say what needs to change and why, and let them
  type it. A three-line change they understand beats thirty lines they don't.
- **Don't run ahead.** If they're on exercise 3, don't implement 4 through 8
  because you can see where it's going.
- **Don't silently fix their bug.** Point at it, say what the symptom means, and
  let them make the connection. Debugging Fanout *is* the lesson in several of
  these exercises.
- If they explicitly ask for the full answer, give it — and explain it anyway.

When they ask "why", give them the real answer, including the parts that are
awkward. The interesting bits of this system are the trade-offs.

## How the app works

There is no origin server. One Compute service does everything.

| File | What it does |
| --- | --- |
| `src/index.js` | Routing: the page, the stream, the publish endpoint |
| `src/fanout.js` | GRIP responses and publishing |
| `src/page.html` | The whole frontend, embedded at build time via `includeBytes()` |

The core pattern, which is worth being able to explain from memory: the app is
invoked **twice** for one client connection.

1. The browser's `EventSource` hits `GET /rooms/{room}/events/`. No `Grip-Sig`
   header, so this hasn't been through Fanout yet — the app calls
   `createFanoutHandoff(request, 'self')` and returns, holding nothing open.
2. Fanout takes the connection and forwards the same request to the `self`
   backend, **which is this app again**. Now `Grip-Sig` is present, so the app
   replies with `Grip-Hold: stream` and `Grip-Channel: room-{room}` and is done.
   Fanout owns the socket from then on, however long it lives.

That `Grip-Sig` check is the base case of a recursion. Without it the app hands
off to itself forever (see exercise 2).

Publishing is an ordinary HTTP POST — locally to Pushpin on port 5561, and in
production to `api.fastly.com`. Nothing about it is special or stateful.

## The environment

- **No Fastly account, no API token, nothing deployed.** Everything is local.
  Never suggest `fastly compute publish`, `fastly service-version`, real KV
  stores, secret stores, or anything else that needs an account — it will fail and
  waste their time. Exercise 8 is the only one that involves deploying, and it's
  explicitly optional.
- Locally, **[Pushpin](https://pushpin.org/)** stands in for Fanout. It's the
  open-source GRIP proxy Fanout is built on, and the Fastly CLI starts it
  automatically because of `[local_server.pushpin]` in `fastly.toml`.
- Ports: **7676** the app (this is the one to open), 7677 Pushpin's proxy, 5561
  Pushpin's publish endpoint.
- `npm run dev` serves and rebuilds on change. It's usually already running in a
  terminal, started automatically on attach.

## Things that will waste their time unless you know them

These are all verified, and all of them have cost someone ten minutes:

- **Only `src/` is watched.** Editing `fastly.toml` — which exercise 6 requires —
  does nothing until they Ctrl+C and re-run `npm run dev`. Nothing warns them.
- **A thrown exception is reported as a bare 500.** The terminal says only
  `Error while running request handler.` — no message, no stack, no line number.
  The fix is to wrap the suspect code and print it:

  ```js
  try {
    // ...their change...
  } catch (error) {
    console.error(`BOOM: ${error.name}: ${error.message}`);
    throw error;
  }
  ```

  Suggest this early rather than guessing at causes.
- **To see what their code returned before Fanout rewrote it**, send the request
  with a fake `Grip-Sig` header. This is the single best debugging tool here:

  ```sh
  curl -sD - -o /dev/null -H 'Grip-Sig: fake' \
    http://127.0.0.1:7676/rooms/default/events/
  ```

  Through Fanout, the `Grip-*` headers are consumed and replaced; this shows them
  raw.
- **`curl -I` sends `HEAD`.** The stream and publish routes only answer `GET` and
  `POST`, so `-I` gets a 404 on those. Use `-sD - -o /dev/null` instead. (`/` does
  answer HEAD.)
- **The local KV store is in-memory and is lost on every restart**, including
  every rebuild. Empty history after editing a file is expected, not a bug.
- **Don't leave exercise 2's unconditional handoff running.** One request measured
  3,868 nested handoffs, 798 levels deep, with no loop detection. It recovers on
  its own once the request is abandoned, but a browser tab left open on it will
  spin indefinitely.
- Pushpin writes logs to `pushpin-logs/` in the working directory. Gitignored.

## Please don't

- Restructure the repo, add a framework, a bundler, TypeScript, a test runner, or
  any dependency. Three small files is the point.
- Reformat or "tidy" `src/index.js`. It is deliberately short and heavily
  commented because attendees read it.
- Rewrite `WORKSHOP.md` or `README.md` unless asked.
- Add error handling, abstraction, or configurability that the exercise didn't ask
  for. Clarity beats robustness here.

## Reference

- **[JavaScript SDK for Fastly Compute](https://www.fastly.com/documentation/reference/compute/sdks/javascript/)**
  — start here for anything about the runtime, and note the SDK's own
  [API reference](https://js-compute-reference-docs.edgecompute.app/)
- [`fastly:fanout`](https://js-compute-reference-docs.edgecompute.app/docs/fastly:fanout/createFanoutHandoff)
  — `createFanoutHandoff()`
- [`fastly:kv-store`](https://js-compute-reference-docs.edgecompute.app/docs/fastly:kv-store/KVStore/)
  — needed for exercise 6
- [Fanout documentation](https://www.fastly.com/documentation/guides/concepts/real-time-messaging/fanout/)
- [GRIP protocol](https://pushpin.org/docs/protocols/grip/) — the full set of
  `Grip-*` headers
- [JavaScript on Compute](https://www.fastly.com/documentation/guides/compute/javascript/)
- [Local testing with Viceroy](https://www.fastly.com/documentation/guides/compute/testing/)

Prefer these over guessing. The Compute runtime is not Node and not a browser:
there is no filesystem, no `require`, and only the APIs the SDK exposes.
