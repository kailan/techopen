/*
 * Fanout chat workshop — edge application.
 *
 * Based on https://github.com/fastly/fanout-chat-demo
 * Copyright Fastly, Inc. Licensed under the MIT license.
 *
 * This is a Fastly Compute service that sits in front of the Django backend
 * (the "origin"). Most requests are proxied straight through. The interesting
 * part is the long-lived SSE stream: that request gets handed off to Fanout,
 * which holds the connection open on our behalf so the origin doesn't have to.
 */

/// <reference types="@fastly/js-compute" />
import { createFanoutHandoff } from 'fastly:fanout';

addEventListener('fetch', (event) => event.respondWith(handleRequest(event)));

/**
 * @param { FetchEvent } event
 */
async function handleRequest(event) {
  const request = event.request;
  const { pathname } = new URL(request.url);

  // Hand the SSE stream off to Fanout.
  //
  // createFanoutHandoff() returns immediately with a Response that tells
  // Fastly: "take this request, forward it to the named backend, and then
  // keep the client connection open according to the GRIP instructions the
  // backend sends back." The origin replies with GRIP headers describing which
  // channel to subscribe the client to, then returns — freeing up the origin
  // worker while Fanout keeps holding the client connection.
  //
  // Later, when someone posts a message, the origin publishes to that channel
  // and Fanout pushes it to every subscribed client.
  if (request.method === 'GET' && pathname.startsWith('/rooms/') && pathname.endsWith('/events/')) {
    return createFanoutHandoff(request, 'origin');
  }

  // Everything else — the HTML page, static assets, and the POST that sends a
  // message — is a normal proxied request to the origin.
  return fetch(request, { backend: 'origin' });
}
