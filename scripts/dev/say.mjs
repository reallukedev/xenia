#!/usr/bin/env node
// Sends a message as one of the seeded test accounts, to try live updates and notifications.
//   node scripts/dev/say.mjs maya "#weekend-trip" "See you Friday!"
//   node scripts/dev/say.mjs maya @luke "Are you around?"      (their DM with Luke)
//   node scripts/dev/say.mjs maya "#design-crit" "@luke can you look at this?"
// An @user in the message becomes a mention pill (with m.mentions), and @room mentions everyone.
import { HOMESERVER, PASSWORD } from './seed-homeserver.mjs';

const [who, where, ...words] = process.argv.slice(2);
if (!who || !where || words.length === 0) {
  console.error('usage: say.mjs <user> <#alias | @user> <message>');
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
  initial_device_display_name: 'say.mjs',
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

// Mentions, as clients send them: the name in the body, a pill in the HTML, and m.mentions.
const escape = (text) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const mentions = { user_ids: [] };
const body = [];
const html = [];
for (const word of words.join(' ').split(/(\s+)/)) {
  const match = /^@([a-z0-9._=\/-]+(?::[a-z0-9.:-]+)?)([^a-z0-9._=\/:-]*)$/i.exec(word);
  if (match && match[1] === 'room') {
    mentions.room = true;
  } else if (match) {
    const id = `@${match[1].includes(':') ? match[1] : `${match[1]}:localhost`}`;
    const name = (await api(token, 'GET', `/profile/${encodeURIComponent(id)}/displayname`).catch(() => ({}))).displayname ?? id;
    if (!mentions.user_ids.includes(id)) mentions.user_ids.push(id);
    body.push(name + match[2]);
    html.push(`<a href="https://matrix.to/#/${id}">${escape(name)}</a>${escape(match[2])}`);
    continue;
  }
  body.push(word);
  html.push(escape(word));
}
const content = { msgtype: 'm.text', body: body.join(''), 'm.mentions': mentions };
if (mentions.user_ids.length > 0) Object.assign(content, { format: 'org.matrix.custom.html', formatted_body: html.join('') });
await api(token, 'PUT', `/rooms/${encodeURIComponent(roomId)}/send/m.room.message/${Date.now()}`, content);
await api(token, 'POST', '/logout', {});
console.log(`${userId} → ${where}: ${body.join('')}`);
