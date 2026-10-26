import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, verify } from 'node:crypto';
import { notify } from '../lib/gateway.js';
import { providerToken } from '../lib/apns.js';

const TOKEN = 'a1'.repeat(32);
const quiet = { warn() {}, error() {} };

/** A push as Synapse sends it for an `event_id_only` pusher. */
function push(devices, extra = {}) {
  return {
    notification: {
      event_id: '$event',
      room_id: '!room:example.org',
      counts: { unread: 3 },
      prio: 'low',
      devices,
      ...extra,
    },
  };
}

function device(appID = 'dev.xenia.matrix.ios', pushkey = TOKEN) {
  return {
    app_id: appID,
    pushkey,
    data: {
      format: 'event_id_only',
      default_payload: { aps: { 'mutable-content': 1, alert: { 'loc-key': 'New Message' }, sound: 'default' } },
    },
  };
}

function recorder(answer = () => ({ status: 200 })) {
  const sent = [];
  return { sent, send: async (request) => { sent.push(request); return answer(request); } };
}

test('a message push reaches the right APNs environment at once, carrying only IDs', async () => {
  const { sent, send } = recorder();
  const result = await notify(push([
    device(),
    device('dev.xenia.matrix.ios.dev', 'b2'.repeat(32)),
    device('dev.xenia.matrix.mac', 'd4'.repeat(32)),
    device('dev.xenia.matrix.mac.dev', 'e5'.repeat(32)),
  ]), send, quiet);

  assert.deepEqual(result, { status: 200, body: { rejected: [] } });
  assert.deepEqual(sent.map((r) => r.environment).sort(), ['production', 'production', 'sandbox', 'sandbox']);
  const [request] = sent;
  assert.equal(request.headers['apns-topic'], 'dev.xenia.matrix');
  assert.equal(request.headers['apns-priority'], '10', 'low-priority messages still go out immediately');
  assert.deepEqual(request.payload, {
    aps: { 'mutable-content': 1, alert: { 'loc-key': 'New Message' }, sound: 'default', badge: 3 },
    room_id: '!room:example.org',
    event_id: '$event',
    unread_count: 3,
  });
});

test('a count-only push updates the badge quietly and wakes Xenia to catch up, and one with neither sends nothing', async () => {
  const { sent, send } = recorder();
  await notify(push([device()], { event_id: undefined, room_id: undefined, counts: { unread: 0 } }), send, quiet);
  assert.deepEqual(sent[0].payload, { aps: { badge: 0 } });
  assert.equal(sent[0].headers['apns-priority'], '5');
  // Background pushes may carry nothing the system shows, so the wake-up is a push of its own.
  assert.deepEqual(sent[1].payload, { aps: { 'content-available': 1 }, xenia_read: true });
  assert.equal(sent[1].headers['apns-push-type'], 'background');
  assert.equal(sent[1].headers['apns-priority'], '5');
  assert.equal(sent[1].token, sent[0].token);

  const result = await notify(push([device()], { event_id: undefined, counts: undefined }), send, quiet);
  assert.equal(sent.length, 2);
  assert.deepEqual(result.body.rejected, []);
});

test('a message push sends one alert and no wake-up', async () => {
  const { sent, send } = recorder();
  await notify(push([device()]), send, quiet);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].headers['apns-push-type'], 'alert');
});

test('a wake-up Apple refuses is not worth the homeserver retrying', async () => {
  const send = async (request) => (request.headers['apns-push-type'] === 'background' ? { status: 500, reason: 'InternalServerError' } : { status: 200 });
  const result = await notify(push([device()], { event_id: undefined, counts: { unread: 1 } }), send, quiet);
  assert.equal(result.status, 200);
});

test('a pusher without a default payload still wakes the extension', async () => {
  const { sent, send } = recorder();
  await notify(push([{ app_id: 'dev.xenia.matrix.ios', pushkey: TOKEN }]), send, quiet);
  assert.equal(sent[0].payload.aps['mutable-content'], 1);
  assert.deepEqual(sent[0].payload.aps.alert, { 'loc-key': 'New Message' });
});

test('dead tokens, other apps and forged pushkeys are handed back to be removed', async () => {
  const dead = 'c3'.repeat(32);
  const { sent, send } = recorder((r) => (r.token === dead ? { status: 410, reason: 'Unregistered' } : { status: 200 }));
  const result = await notify(push([
    device(),
    device('dev.xenia.matrix.ios', dead),
    device('im.vector.app.ios'),
    device('dev.xenia.matrix.ios', '../../3/device/x'),
  ]), send, quiet);

  assert.equal(result.status, 200);
  assert.deepEqual(result.body.rejected.sort(), [dead, '../../3/device/x', TOKEN].sort());
  assert.equal(sent.length, 2, 'only Xenia devices with real tokens reach Apple');
});

test('when Apple is unreachable or refuses the gateway itself, the homeserver is asked to retry', async () => {
  const down = await notify(push([device()]), async () => { throw new Error('ECONNRESET'); }, quiet);
  assert.equal(down.status, 502);

  const badKey = await notify(push([device()]), async () => ({ status: 403, reason: 'InvalidProviderToken' }), quiet);
  assert.equal(badKey.status, 502);
  assert.deepEqual(badKey.body.rejected, [], 'a bad key must never cost anyone their pusher');
});

test('malformed bodies are refused', async () => {
  const { send } = recorder();
  assert.equal((await notify(undefined, send, quiet)).status, 400);
  assert.equal((await notify({ notification: {} }, send, quiet)).status, 400);
  assert.equal((await notify(push(Array.from({ length: 11 }, () => device())), send, quiet)).status, 400);
  assert.equal((await notify(push([device()], { event_id: 'not an id' }), send, quiet)).status, 400);
  assert.equal((await notify(push([device()], { room_id: { $ne: 1 } }), send, quiet)).status, 400);
});

test('the alert is always Xenia\'s own, whatever the pusher\'s default payload says', async () => {
  const { sent, send } = recorder();
  const forged = device();
  forged.data.default_payload = { aps: { alert: 'Your account is locked. Visit evil.example' }, url: 'https://evil.example' };
  await notify(push([forged]), send, quiet);
  assert.deepEqual(sent[0].payload.aps.alert, { 'loc-key': 'New Message' });
  assert.equal(sent[0].payload.url, undefined);
});

test('provider tokens verify with the key and stay the same within a window', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const credentials = { keyID: 'KEY123', teamID: 'TEAM456', key: privateKey };
  const now = Date.UTC(2026, 9, 1, 12, 5);
  const { token, iat } = providerToken(credentials, now);

  const [header, claims, signature] = token.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(header, 'base64url')), { alg: 'ES256', kid: 'KEY123' });
  assert.deepEqual(JSON.parse(Buffer.from(claims, 'base64url')), { iss: 'TEAM456', iat: Date.UTC(2026, 9, 1, 12, 0) / 1000 });
  assert.ok(verify('sha256', Buffer.from(`${header}.${claims}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')));

  assert.equal(providerToken(credentials, now + 20 * 60_000).iat, iat);
  assert.notEqual(providerToken(credentials, now + 30 * 60_000).iat, iat);
});
