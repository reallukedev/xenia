#!/usr/bin/env node
// Starts a poll as a seeded test account, with votes from others, to see polls in the app.
//   node scripts/dev/poll.mjs maya "#weekend-trip" "Where should we eat?" Tacos Pho Salad
//   VOTES="sam:0 alex:1 priya:0" node scripts/dev/poll.mjs ...   (who votes for which answer)
//   HIDDEN=1 (results only when ended), MULTI=1 (several answers allowed)
import { HOMESERVER, PASSWORD } from './seed-homeserver.mjs';

const [who, where, question, ...answers] = process.argv.slice(2);
if (!who || !where || !question || answers.length < 2) {
  console.error('usage: poll.mjs <user> <#alias | @user> <question> <answer> <answer> [...]');
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

async function login(user) {
  return api(null, 'POST', '/login', {
    type: 'm.login.password',
    identifier: { type: 'm.id.user', user },
    password: PASSWORD,
    initial_device_display_name: 'poll.mjs',
  });
}

const me = await login(who);
let roomId;
if (where.startsWith('#')) {
  roomId = (await api(me.access_token, 'GET', `/directory/room/${encodeURIComponent(where.includes(':') ? where : `${where}:localhost`)}`)).room_id;
} else {
  const other = where.includes(':') ? where : `${where}:localhost`;
  const direct = await api(me.access_token, 'GET', `/user/${encodeURIComponent(me.user_id)}/account_data/m.direct`);
  roomId = direct[other]?.[0];
  if (!roomId) throw new Error(`No DM between ${me.user_id} and ${other}`);
}
const ids = answers.map((_, i) => `answer-${i}`);
const fallback = [question, ...answers.map((a, i) => `${i + 1}. ${a}`)].join('\n');
const start = await api(me.access_token, 'PUT', `/rooms/${encodeURIComponent(roomId)}/send/org.matrix.msc3381.poll.start/${Date.now()}`, {
  'org.matrix.msc3381.poll.start': {
    question: { 'org.matrix.msc1767.text': question },
    kind: process.env.HIDDEN ? 'org.matrix.msc3381.poll.undisclosed' : 'org.matrix.msc3381.poll.disclosed',
    max_selections: process.env.MULTI ? answers.length : 1,
    answers: answers.map((text, i) => ({ id: ids[i], 'org.matrix.msc1767.text': text })),
  },
  'org.matrix.msc1767.text': fallback,
});
await api(me.access_token, 'POST', '/logout', {});
for (const vote of (process.env.VOTES ?? '').split(/\s+/).filter(Boolean)) {
  const [voter, index] = vote.split(':');
  const session = await login(voter);
  await api(session.access_token, 'PUT', `/rooms/${encodeURIComponent(roomId)}/send/org.matrix.msc3381.poll.response/${Date.now()}`, {
    'm.relates_to': { rel_type: 'm.reference', event_id: start.event_id },
    'org.matrix.msc3381.poll.response': { answers: [ids[Number(index)]] },
  });
  await api(session.access_token, 'POST', '/logout', {});
}
console.log(`${me.user_id} → ${where}: poll ${start.event_id}`);
