// POST /_matrix/push/v1/notify (vercel.json routes it here).
import { notify } from '../lib/gateway.js';
import { credentialsFromEnvironment, send } from '../lib/apns.js';

let credentials;

export default async function handler(req, res) {
  if (req.method === 'GET') {
    // A health check: is the gateway up, and does it have Xenia's key?
    return res.status(200).json({ gateway: 'xenia', configured: Boolean(process.env.APNS_KEY && process.env.APNS_KEY_ID) });
  }
  if (req.method !== 'POST') {
    return res.status(405).json({ errcode: 'M_UNRECOGNIZED', error: 'Use POST' });
  }
  try {
    credentials ??= credentialsFromEnvironment();
  } catch (error) {
    console.error(`Not configured: ${error.message}`);
    // The homeserver keeps retrying with backoff, so pushes resume once the key is added.
    return res.status(503).json({ error: 'The gateway has no APNs key yet' });
  }
  const body = typeof req.body === 'string' ? safeParse(req.body) : req.body;
  const result = await notify(body, (request) => send(request, credentials));
  return res.status(result.status).json(result.body);
}

function safeParse(text) {
  try { return JSON.parse(text); } catch { return undefined; }
}
