#!/usr/bin/env node
// Reacts to a recent message as one of the seeded test accounts, to see Tapbacks arrive.
//   node scripts/dev/react.mjs maya @luke ❤️          (the newest message in their DM)
//   node scripts/dev/react.mjs sam "#launch" 👍 2     (the third newest message there)
import { HOMESERVER, PASSWORD } from './seed-homeserver.mjs';

const [who, where, key, back = '0'] = process.argv.slice(2);
if (!who || !where || !key) {
  console.error('usage: react.mjs <user> <#alias | @user> <emoji> [how many messages back]');
  process.exit(64);
}

async function api(token, method, path, body) {
  const res = await fetch(`${HOMESERVER}/_matrix/client/v3${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json();
  if (!res.ok) throw new Error(`${path}: ${json.error ?? res.status}`);
  return json;
}

const { access_token: token, user_id: userId } = await api(null, 'POST', '/login', {
  type: 'm.login.password',
  identifier: { type: 'm.id.user', user: who },
  password: PASSWORD,
  initial_device_display_name: 'react.mjs',
});
let roomId;
if (where.startsWith('#')) {
  roomId = (await api(token, 'GET', `/directory/room/${encodeURIComponent(where.includes(':') ? where : `${where}:localhost`)}`)).room_id;
} else {
  const other = where.includes(':') ? where : `${where}:localhost`;
  const direct = await api(token, 'GET', `/user/${encodeURIComponent(userId)}/account_data/m.direct`);
  roomId = direct[other]?.[0];
  if (!roomId) throw new Error(`No DM between ${userId} and ${other}`);
}
const { chunk } = await api(token, 'GET', `/rooms/${encodeURIComponent(roomId)}/messages?dir=b&limit=50`);
const target = chunk.filter((e) => e.type === 'm.room.message')[Number(back)];
if (!target) throw new Error('No message that far back');
await api(token, 'PUT', `/rooms/${encodeURIComponent(roomId)}/send/m.reaction/${Date.now()}`, {
  'm.relates_to': { rel_type: 'm.annotation', event_id: target.event_id, key },
});
console.log(`${userId} reacted ${key} to: ${target.content.body}`);
await api(token, 'POST', '/logout', {});
