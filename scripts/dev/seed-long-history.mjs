#!/usr/bin/env node
// Adds "Family", a group with six years of history (about 4,000 messages, backdated), to the
// local test homeserver, for scrolling far back, day headers across years, and search. Its
// members are app service users (only an app service may set a message's timestamp; see
// scripts/dev/homeserver.sh), plus @luke:localhost. Safe to run again: it does nothing once the
// room exists.
//
//   scripts/dev/homeserver.sh && node scripts/dev/seed-long-history.mjs
import { HOMESERVER, PASSWORD } from './seed-homeserver.mjs';

const AS_TOKEN = 'relay-dev-history-as-token';
const ALIAS = 'family-history';
const YEARS = 6;

const FAMILY = {
  history_mom: 'Mom',
  history_dad: 'Dad',
  history_nina: 'Nina',
  history_theo: 'Theo',
};

const LINES = [
  'Did everyone see the weather for this weekend?',
  'Dinner on Sunday? I can make the lasagna',
  'Running late, start without me',
  'Happy birthday!! 🎂🎉',
  'Who has the spare key to the garage?',
  'The dog figured out how to open the back door again',
  'Sending photos from the lake later',
  'Can someone pick up milk on the way home?',
  'I found the old photo albums in the attic, we need to go through these together',
  'Flight lands at 6:40, I’ll grab a taxi',
  'Grandma says hi and asks when you’re visiting',
  'Is the WiFi down for anyone else?',
  'That movie was so much better than I expected',
  'Remember to call the dentist before Friday',
  'Leaving now 🚗',
  'Made too many cookies again. Come get some',
  'The tomatoes are finally ripe!',
  'Who’s hosting Thanksgiving this year?',
  'Okay but who ate the last slice of pie',
  'Love you all ❤️',
  'Long one, sorry: I’ve been thinking about the summer trip. If we leave on the Friday we miss the traffic, stop at the cabin overnight, and get to the coast by lunch on Saturday. Thoughts?',
  'Agreed',
  'Haha',
  'On my way',
  'Can’t wait to see everyone',
];

async function api(path, { method = 'GET', body, as, ts, token = AS_TOKEN } = {}) {
  const url = new URL(`${HOMESERVER}/_matrix/client/v3${path}`);
  if (as) url.searchParams.set('user_id', `@${as}:localhost`);
  if (ts) url.searchParams.set('ts', String(ts));
  const res = await fetch(url, {
    method,
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(`${method} ${path}: ${res.status} ${json.errcode ?? ''} ${json.error ?? ''}`);
    err.errcode = json.errcode;
    throw err;
  }
  return json;
}

async function exists() {
  try {
    await api(`/directory/room/${encodeURIComponent(`#${ALIAS}:localhost`)}`);
    return true;
  } catch (e) {
    if (e.errcode === 'M_NOT_FOUND') return false;
    throw e;
  }
}

async function main() {
  if (await exists()) {
    console.log(`#${ALIAS}:localhost already exists.`);
    return;
  }
  for (const [localpart, name] of Object.entries(FAMILY)) {
    try {
      await api('/register', { method: 'POST', body: { type: 'm.login.application_service', username: localpart } });
    } catch (e) {
      if (e.errcode !== 'M_USER_IN_USE') throw e;
    }
    await api(`/profile/@${localpart}:localhost/displayname`, { method: 'PUT', as: localpart, body: { displayname: name } });
  }
  const people = Object.keys(FAMILY);
  const [creator, ...others] = people;
  const { room_id: roomId } = await api('/createRoom', {
    method: 'POST',
    as: creator,
    body: {
      name: 'Family',
      topic: 'Six years of everything',
      preset: 'private_chat',
      invite: [...others.map((p) => `@${p}:localhost`), '@luke:localhost'],
    },
  });
  for (const person of others) {
    await api(`/join/${encodeURIComponent(roomId)}`, { method: 'POST', as: person, body: {} });
  }
  const login = await api('/login', {
    method: 'POST',
    token: '',
    body: { type: 'm.login.password', identifier: { type: 'm.id.user', user: 'luke' }, password: PASSWORD, initial_device_display_name: 'Seed script' },
  });
  await api(`/join/${encodeURIComponent(roomId)}`, { method: 'POST', token: login.access_token, body: {} });
  // The address comes from Luke: app service users may only make addresses in their namespace.
  await api(`/directory/room/${encodeURIComponent(`#${ALIAS}:localhost`)}`, {
    method: 'PUT',
    token: login.access_token,
    body: { room_id: roomId },
  });

  // Most days are quiet; some are busy. A fixed seed keeps runs alike.
  let seed = 7;
  const random = () => ((seed = (seed * 1103515245 + 12345) % 2 ** 31) / 2 ** 31);
  const day = 24 * 60 * 60 * 1000;
  const end = Date.now() - 2 * day;
  const start = end - YEARS * 365 * day;
  let sent = 0;
  for (let t = start; t < end; t += day) {
    if (random() < 0.3) continue;
    const count = 1 + Math.floor(random() * random() * 9);
    let at = t + (8 + Math.floor(random() * 10)) * 60 * 60 * 1000;
    for (let i = 0; i < count; i++) {
      const who = people[Math.floor(random() * people.length)];
      const line = LINES[Math.floor(random() * LINES.length)];
      at += Math.floor(random() * 20 * 60 * 1000);
      await api(`/rooms/${encodeURIComponent(roomId)}/send/m.room.message/h${sent}`, {
        method: 'PUT',
        as: who,
        ts: at,
        body: { msgtype: 'm.text', body: line },
      });
      sent++;
    }
    process.stdout.write(`\r${sent} messages`);
  }
  console.log(`\rSeeded #${ALIAS}:localhost with ${sent} messages over ${YEARS} years.`);
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
