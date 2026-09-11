/// <reference types="@fastly/js-compute" />

import { includeBytes } from 'fastly:experimental';
import { createFanoutHandoff } from 'fastly:fanout';
import { gripResponse, publish } from './fanout.js';

// The chat UI, baked into the Wasm package at build time. There is no origin
// server anywhere in this app — the page is served from the edge too.
const PAGE = includeBytes('./src/page.html');

// Room names become channel names, so keep them boring.
const ROOM_NAME = /^[a-zA-Z0-9_-]{1,64}$/;

const EVENTS_PATH = /^\/rooms\/([^/]+)\/events\/?$/;
const MESSAGES_PATH = /^\/rooms\/([^/]+)\/messages\/?$/;

addEventListener('fetch', (event) => event.respondWith(handleRequest(event)));

/**
 * @param {FetchEvent} event
 */
async function handleRequest(event) {
  const request = event.request;
  const path = new URL(request.url).pathname;

  // --- the page -------------------------------------------------------------

  if (request.method === 'GET' && (path === '/' || path === '/index.html')) {
    return new Response(PAGE, {
      headers: { 'Content-Type': 'text/html; charset=utf-8' },
    });
  }

  // --- subscribe to a room --------------------------------------------------
  //
  // This path is requested twice for a single client connection:
  //
  //   1. The browser's EventSource arrives here first. We hand it to Fanout and
  //      return, holding nothing open ourselves.
  //   2. Fanout then makes the same request back to us — that's what the `self`
  //      backend is — this time with a Grip-Sig header. We answer with GRIP
  //      instructions, and Fanout keeps the client's connection from there.
  //
  // Step 2 is the interesting one: after it, this app is not involved in the
  // connection at all, however long it lives.

  const events = EVENTS_PATH.exec(path);
  if (events && request.method === 'GET') {
    const room = events[1];
    if (!ROOM_NAME.test(room)) {
      return badRequest('Invalid room name');
    }

    if (request.headers.has('Grip-Sig')) {
      // Note: in production you should verify this header's JWT rather than
      // just checking it exists, so that clients can't forge it. See
      // https://www.fastly.com/documentation/guides/concepts/real-time-messaging/fanout/#verifying-requests-from-fanout
      return gripResponse(`room-${room}`);
    }

    return createFanoutHandoff(request, 'self');
  }

  // --- send a message to a room ---------------------------------------------
  //
  // An ordinary, short-lived POST. Nothing is stored: the message is published
  // to the channel, reaches whoever is connected right now, and is gone. Adding
  // history is exercise 6 in WORKSHOP.md.

  const messages = MESSAGES_PATH.exec(path);
  if (messages && request.method === 'POST') {
    const room = messages[1];
    if (!ROOM_NAME.test(room)) {
      return badRequest('Invalid room name');
    }

    const form = new URLSearchParams(await request.text());
    const message = {
      from: (form.get('from') || 'anonymous').slice(0, 40),
      text: (form.get('text') || '').slice(0, 500),
    };

    if (message.text === '') {
      return badRequest('Message text is required');
    }

    try {
      await publish(`room-${room}`, message);
    } catch (error) {
      console.error(`Publishing to room-${room} failed: ${error.message}`);
      return new Response(`Could not publish: ${error.message}\n`, {
        status: 502,
        headers: { 'Content-Type': 'text/plain; charset=utf-8' },
      });
    }

    return new Response(null, { status: 204 });
  }

  return new Response('Not found\n', {
    status: 404,
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}

/**
 * @param {string} reason
 */
function badRequest(reason) {
  return new Response(`${reason}\n`, {
    status: 400,
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}
