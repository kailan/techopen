/// <reference types="@fastly/js-compute" />

import { env } from 'fastly:env';
import { SecretStore } from 'fastly:secret-store';

/**
 * Builds the response that tells Fanout to hold a request open as a
 * Server-Sent Events stream, subscribed to `channel`.
 *
 * This is a [GRIP](https://pushpin.org/docs/protocols/grip/) response: no body,
 * just instructions. It is the answer to the *second* request — the one Fanout
 * makes back to us after `createFanoutHandoff()` — and once we've sent it, this
 * app is finished with that connection. Fanout owns the socket from then on.
 *
 * @param {string} channel - Name of the channel to subscribe the connection to.
 */
export function gripResponse(channel) {
  return new Response(null, {
    headers: {
      'Content-Type': 'text/event-stream',

      // Hold the connection open and keep streaming to it, rather than closing
      // it after the first message ('response', which is long-polling).
      'Grip-Hold': 'stream',

      // Everything published to this channel goes down this connection.
      'Grip-Channel': channel,

      // Send a bare newline every 20 idle seconds. SSE ignores it, but it stops
      // intermediaries from deciding the connection is dead and closing it —
      // notably the Codespaces port-forwarding proxy. `format=cstring` means
      // the two characters below are unescaped into a real newline by Fanout.
      'Grip-Keep-Alive': '\\n; format=cstring; timeout=20',
    },
  });
}

/**
 * Publishes a message to everyone currently subscribed to `channel`.
 *
 * Publishing is just an HTTP POST — there's no special client library involved,
 * and it doesn't have to come from this app at all. Any system you own can push
 * to connected clients the same way (see WORKSHOP.md, exercise 5).
 *
 * @param {string} channel - Channel to publish to.
 * @param {object} message - Message payload; serialised as JSON for the client.
 * @throws {Error} if the publish endpoint rejects the request.
 */
export async function publish(channel, message) {
  const body = JSON.stringify({
    items: [
      {
        channel,
        formats: {
          // `http-stream` describes what to write into each held HTTP stream.
          // These bytes are exactly what subscribers receive, so this is where
          // the SSE framing is decided.
          'http-stream': {
            content: `event: message\ndata: ${JSON.stringify(message)}\n\n`,
          },
        },
      },
    ],
  });

  const headers = { 'Content-Type': 'application/json' };

  // Locally, publish straight to Pushpin's publish handler. Deployed, publish
  // through the Fastly API. Same request shape either way; the trailing slash
  // on /publish/ is required in both.
  let url = 'http://127.0.0.1:5561/publish/';
  if (!isLocal()) {
    url = `https://api.fastly.com/service/${env('FASTLY_SERVICE_ID')}/publish/`;
    headers['Fastly-Key'] = await apiToken();
  }

  const response = await fetch(url, {
    method: 'POST',
    headers,
    body,
    backend: 'publisher',
  });

  if (!response.ok) {
    const detail = (await response.text()).trim();
    throw new Error(`publish returned ${response.status}: ${detail}`);
  }
}

/**
 * Whether this is the local dev server (Viceroy) rather than a Fastly POP.
 * Deployed, FASTLY_HOSTNAME is the name of the cache node serving the request.
 */
function isLocal() {
  return env('FASTLY_HOSTNAME') === 'localhost';
}

/**
 * Fetches the Fastly API token used to publish, from a secret store.
 *
 * Only needed once deployed. The token can't be baked into the Wasm package, so
 * it lives in a secret store named `fanout` under the key `api_token` — see
 * README ▸ Deploying to real Fastly. Nothing to set up for local development.
 */
async function apiToken() {
  let store;
  try {
    store = new SecretStore('fanout');
  } catch {
    throw new Error(
      "this service has no secret store named 'fanout' (see README ▸ Deploying to real Fastly)",
    );
  }

  const secret = await store.get('api_token');
  if (secret == null) {
    throw new Error(
      "secret store 'fanout' has no key 'api_token' (see README ▸ Deploying to real Fastly)",
    );
  }

  return secret.plaintext();
}
