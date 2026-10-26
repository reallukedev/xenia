// Xenia's push gateway: what a homeserver's push (Matrix Push Gateway API) becomes for Apple.
//
// The homeserver sends a room and an event ID, never the message (Xenia registers its pushers
// with `event_id_only`). Apple wakes Xenia's notification extension, which fetches and decrypts
// the message itself.

/** Xenia's bundle ID: the only app this gateway pushes to. */
export const TOPIC = 'dev.xenia.matrix';

/** The pusher app IDs Xenia registers, and the APNs environment each one's tokens belong to.
 *  Builds installed from Xcode get sandbox tokens; TestFlight and App Store builds get production
 *  ones. The iPhone and Mac apps share a bundle ID, so one topic serves both. */
export const APPS = {
  'dev.xenia.matrix.ios': 'production',
  'dev.xenia.matrix.ios.dev': 'sandbox',
  'dev.xenia.matrix.mac': 'production',
  'dev.xenia.matrix.mac.dev': 'sandbox',
};

/** Marks the silent push that wakes Xenia to catch up after something was read elsewhere. */
export const READ_KEY = 'xenia_read';

/** A homeserver sends one push per device; a few allows for batching, while a request naming
 *  hundreds is someone using Xenia's APNs key to spam. */
export const MAX_DEVICES = 10;

/** Matrix room and event IDs, as Xenia's extension will look them up. */
const ROOM_ID = /^![^\s]{1,254}$/;
const EVENT_ID = /^\$[^\s]{1,254}$/;

/** APNs answers that mean the token will never work again: the homeserver should drop the pusher. */
const DEAD_TOKEN_REASONS = new Set(['BadDeviceToken', 'DeviceTokenNotForTopic', 'Unregistered']);

/** What Apple should deliver for one device, or null when there's nothing to send. */
export function apnsPayload(notification) {
  const unread = notification.counts?.unread;
  if (!notification.event_id) {
    // The unread count changed (read on another device, say): just the badge.
    return Number.isInteger(unread) ? { aps: { badge: unread } } : null;
  }
  // Built here, never taken from the pusher's `default_payload`: anyone who knows a device's token
  // could otherwise put their own words on its lock screen.
  const aps = { 'mutable-content': 1, alert: { 'loc-key': 'New Message' }, sound: 'default' };
  if (Number.isInteger(unread)) aps.badge = unread;
  return {
    aps,
    room_id: notification.room_id,
    event_id: notification.event_id,
    ...(Number.isInteger(unread) ? { unread_count: unread } : {}),
  };
}

/** The APNs request for one device, or a reason it can't have one. */
export function apnsRequest(notification, device) {
  const environment = APPS[device.app_id];
  if (!environment) return { reject: `unknown app ${device.app_id}` };
  // APNs tokens are hex. Anything else is a stale or forged pushkey.
  if (typeof device.pushkey !== 'string' || !/^[0-9a-f]{32,200}$/i.test(device.pushkey)) {
    return { reject: 'malformed pushkey' };
  }
  const payload = apnsPayload(notification);
  if (!payload) return { skip: true };
  const isMessage = Boolean(notification.event_id);
  return {
    environment,
    token: device.pushkey.toLowerCase(),
    headers: {
      'apns-topic': TOPIC,
      'apns-push-type': 'alert',
      // Messages go out at once, even the ones the homeserver marks low priority (unencrypted
      // group messages without a sound): someone is waiting on them. Badge updates can wait.
      'apns-priority': isMessage ? '10' : '5',
    },
    payload,
  };
}

/** For a count-only push (read on another device, say): a silent push that wakes Xenia for a
 *  moment, so it can take down the notifications of what was read. Background pushes can carry
 *  nothing for the system to show, so the badge goes separately. Null for message pushes. */
export function wakeRequest(notification, device) {
  if (notification.event_id) return null;
  const request = apnsRequest(notification, device);
  if (request.reject || request.skip) return null;
  return {
    environment: request.environment,
    token: request.token,
    headers: { 'apns-topic': TOPIC, 'apns-push-type': 'background', 'apns-priority': '5' },
    payload: wakePayload(),
  };
}

/** What the wake-up push carries: nothing to show, only a reason to catch up. */
export function wakePayload() {
  return { aps: { 'content-available': 1 }, [READ_KEY]: true };
}

/** Whether APNs said this token is dead. */
export function isDeadToken(status, reason) {
  return status === 410 || (status === 400 && DEAD_TOKEN_REASONS.has(reason));
}

/**
 * Handles one `/_matrix/push/v1/notify` body. `send(request)` delivers to APNs and resolves to
 * `{ status, reason }`; it throws on a network failure.
 *
 * Resolves to the HTTP status and body for the homeserver: 200 with the pushkeys to forget, or
 * 502 when Apple couldn't be reached, so the homeserver tries again later.
 */
export async function notify(body, send, log = console) {
  const notification = body?.notification;
  if (!notification || !Array.isArray(notification.devices)) {
    return { status: 400, body: { errcode: 'M_BAD_JSON', error: 'Expected a notification with devices' } };
  }
  if (notification.devices.length > MAX_DEVICES) {
    return { status: 400, body: { errcode: 'M_BAD_JSON', error: `At most ${MAX_DEVICES} devices per notification` } };
  }
  const { room_id: roomID, event_id: eventID } = notification;
  if (eventID != null && (typeof eventID !== 'string' || !EVENT_ID.test(eventID)
      || typeof roomID !== 'string' || !ROOM_ID.test(roomID))) {
    return { status: 400, body: { errcode: 'M_BAD_JSON', error: 'Expected Matrix room and event IDs' } };
  }
  const rejected = [];
  let retry = false;
  await Promise.all(notification.devices.map(async (device) => {
    const request = apnsRequest(notification, device);
    if (request.reject) {
      log.warn(`Rejected a pushkey: ${request.reject}`);
      rejected.push(device.pushkey);
      return;
    }
    if (request.skip) return;
    const wake = wakeRequest(notification, device);
    for (const each of wake ? [request, wake] : [request]) {
      try {
        const { status, reason } = await send(each);
        if (status === 200) continue;
        if (isDeadToken(status, reason)) {
          log.warn(`APNs says a ${each.environment} token is dead (${status} ${reason ?? ''}); asking the homeserver to drop it`);
          rejected.push(device.pushkey);
          return;
        }
        log.error(`APNs refused a push (${each.environment}): ${status} ${reason ?? ''}`);
        // A missed wake-up costs nothing: the badge already went, and the app catches up when opened.
        if (each === request) retry = true;
      } catch (error) {
        log.error(`Couldn't reach APNs (${each.environment}): ${error.message}`);
        if (each === request) retry = true;
      }
    }
  }));
  if (retry) return { status: 502, body: { error: 'APNs is unavailable; try again later', rejected } };
  return { status: 200, body: { rejected } };
}
