#!/usr/bin/env node
// A push gateway for local development: the test homeserver sends it pushes like it would send
// Sygnal, and it delivers each one to the iOS Simulator that registered for it, as Apple would.
// That exercises the whole path (pusher, push rules, the notification extension decrypting the
// message) without an APNs key.
//
//   node scripts/dev/push-gateway.mjs        # listens on http://localhost:8009
//
// Builds under your own bundle ID (apple/Local.xcconfig) need XENIA_BUNDLE_ID set to it.
//
// The homeserver must be allowed to reach localhost: homeserver.sh sets that up.
// Real devices use the real gateway (services/push-gateway) with Xenia's APNs key; this one only
// logs their pushes.
import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
// The same payloads the real gateway (services/push-gateway) sends Apple.
import { apnsPayload, wakePayload, TOPIC } from '../../services/push-gateway/lib/gateway.js';

const PORT = Number(process.env.XENIA_PUSH_PORT ?? 8009);
const BUNDLE_ID = process.env.XENIA_BUNDLE_ID ?? TOPIC;
const folder = mkdtempSync(join(tmpdir(), 'xenia-push-'));

function deliver(udid, payload) {
  const file = join(folder, `${Date.now()}-${Math.random().toString(36).slice(2)}.json`);
  writeFileSync(file, JSON.stringify(payload));
  execFile('xcrun', ['simctl', 'push', udid, BUNDLE_ID, file], (error) => {
    rmSync(file, { force: true });
    if (error) console.warn(`Couldn't deliver to ${udid}: ${error.message.trim()}`);
    else if (payload.event_id) console.log(`Delivered ${payload.room_id} ${payload.event_id} to simulator ${udid}`);
    else if (payload.aps['content-available']) console.log(`Woke Xenia on simulator ${udid} to catch up`);
    else console.log(`Updated the badge on simulator ${udid} to ${payload.aps.badge}`);
  });
}

createServer((req, res) => {
  if (req.method !== 'POST' || req.url !== '/_matrix/push/v1/notify') {
    res.writeHead(404).end();
    return;
  }
  let body = '';
  req.on('data', (chunk) => {
    body += chunk;
    // A push is a few hundred bytes; anything huge isn't one.
    if (body.length > 64 * 1024) req.destroy();
  });
  req.on('end', () => {
    const rejected = [];
    try {
      const { notification } = JSON.parse(body);
      for (const device of notification.devices ?? []) {
        const payload = apnsPayload(notification, device);
        if (!payload) continue;
        // simctl skips the notification extension, which files each notification under its room.
        if (payload.room_id) payload.aps['thread-id'] = payload.room_id;
        if (device.pushkey.startsWith('simulator:')) {
          const udid = device.pushkey.slice('simulator:'.length);
          deliver(udid, payload);
          // Read on another device: the real gateway also wakes Xenia to take its notifications down.
          if (!notification.event_id) deliver(udid, wakePayload());
        } else {
          console.log(`Push for a real device (${device.app_id}); a real gateway would send it to APNs.`);
        }
      }
    } catch (error) {
      console.warn(`Unreadable push: ${error.message}`);
    }
    res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ rejected }));
  });
}).listen(PORT, '127.0.0.1', () => console.log(`Push gateway on http://localhost:${PORT}/_matrix/push/v1/notify`));
