// Sends pushes to Apple over HTTP/2 with a token from Xenia's APNs key.
import { connect } from 'node:http2';
import { createPrivateKey, sign } from 'node:crypto';

const HOSTS = {
  production: 'https://api.push.apple.com',
  sandbox: 'https://api.sandbox.push.apple.com',
};

/** Xenia's Apple developer team. */
const DEFAULT_TEAM_ID = 'W3Y3Z7CJH2';

/** Apple wants a fresh token at least hourly and refuses one renewed more than every 20 minutes.
 *  Pinning `iat` to the start of a 30-minute window gives every warm instance the same lifetime. */
const TOKEN_WINDOW_SECONDS = 30 * 60;

const base64url = (value) => Buffer.from(value).toString('base64url');

/** A provider token (ES256 JWT) for the key, issued at the start of the current window. */
export function providerToken({ keyID, teamID, key }, now = Date.now()) {
  const iat = Math.floor(now / 1000 / TOKEN_WINDOW_SECONDS) * TOKEN_WINDOW_SECONDS;
  const header = base64url(JSON.stringify({ alg: 'ES256', kid: keyID }));
  const claims = base64url(JSON.stringify({ iss: teamID, iat }));
  const signature = sign('sha256', Buffer.from(`${header}.${claims}`), { key, dsaEncoding: 'ieee-p1363' });
  return { token: `${header}.${claims}.${signature.toString('base64url')}`, iat };
}

/** Xenia's APNs key from the environment: `APNS_KEY` (the .p8 file's text), `APNS_KEY_ID` and
 *  optionally `APNS_TEAM_ID`. */
export function credentialsFromEnvironment(env = process.env) {
  if (!env.APNS_KEY || !env.APNS_KEY_ID) {
    throw new Error('APNS_KEY and APNS_KEY_ID must be set');
  }
  // Pasted keys sometimes lose their line breaks; the PEM body is the same either way.
  const pem = env.APNS_KEY.includes('\n') ? env.APNS_KEY : env.APNS_KEY.replace(/\\n/g, '\n');
  return { keyID: env.APNS_KEY_ID, teamID: env.APNS_TEAM_ID || DEFAULT_TEAM_ID, key: createPrivateKey(pem) };
}

let cachedToken;
const sessions = new Map();

function session(environment) {
  let current = sessions.get(environment);
  if (!current || current.closed || current.destroyed) {
    const created = connect(HOSTS[environment]);
    // Only forget this connection: a newer one may already have taken its place.
    const forget = () => { if (sessions.get(environment) === created) sessions.delete(environment); };
    created.on('error', forget);
    created.on('close', forget);
    current = created;
    current.inFlight = 0;
    sessions.set(environment, current);
  }
  return current;
}

/** Drops a connection that stopped answering. A warm instance unfrozen with a socket the
 *  network silently dropped would otherwise wait out the timeout on every push. */
function discard(environment, connection) {
  if (sessions.get(environment) === connection) sessions.delete(environment);
  if (!connection.destroyed) connection.destroy();
}

/** Sends one request from `apnsRequest`. Resolves to APNs's status and its reason, if any. */
export function send(request, credentials, timeoutMs = 10_000) {
  if (!cachedToken || cachedToken.iat !== providerToken(credentials).iat) {
    cachedToken = providerToken(credentials);
  }
  const connection = session(request.environment);
  // A warm function instance keeps the connection open between pushes, but only a push in
  // flight should keep the process alive.
  connection.inFlight += 1;
  connection.ref();
  let settled = false;
  const settle = () => {
    if (settled) return;
    settled = true;
    connection.inFlight -= 1;
    if (connection.inFlight === 0 && !connection.destroyed) connection.unref();
  };
  return new Promise((resolve, reject) => {
    const stream = connection.request({
      ':method': 'POST',
      ':path': `/3/device/${request.token}`,
      authorization: `bearer ${cachedToken.token}`,
      'content-type': 'application/json',
      ...request.headers,
    });
    let status = 0;
    let body = '';
    let timedOut = false;
    const startedAt = Date.now();
    stream.setEncoding('utf8');
    stream.setTimeout(timeoutMs, () => { timedOut = true; stream.close(); });
    stream.on('response', (headers) => {
      status = headers[':status'];
      connection.lastAnswerAt = Date.now();
    });
    stream.on('data', (chunk) => { body += chunk; });
    stream.on('error', (error) => { settle(); reject(error); });
    stream.on('close', () => {
      settle();
      if (!status) {
        // Silence on a connection that's answered nothing else meanwhile: it's dead. One
        // stream's reset or error leaves the connection to the other pushes using it.
        if (timedOut && !(connection.lastAnswerAt > startedAt)) discard(request.environment, connection);
        return reject(new Error('No answer from APNs'));
      }
      let reason;
      try { reason = body ? JSON.parse(body).reason : undefined; } catch { reason = body; }
      resolve({ status, reason });
    });
    stream.end(JSON.stringify(request.payload));
  });
}
