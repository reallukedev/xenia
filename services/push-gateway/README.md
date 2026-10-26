# Xenia push gateway

Homeservers can't reach Apple themselves: they POST each push to the gateway URL a device
registered (the Matrix Push Gateway API), and the gateway forwards it to APNs with Xenia's key.
This one gateway serves every homeserver and account Xenia signs in to.

Pushes carry only a room and an event ID. The notification extension on the iPhone fetches and
decrypts the message itself, so neither this gateway nor Apple sees who wrote what.

Live at `https://xenia-push-gateway.vercel.app/_matrix/push/v1/notify` (`apple/project.yml`,
`XENIA_PUSH_GATEWAY`). A GET there says whether the key is configured.

## Setup

1. In the Apple Developer site, under Keys, make a key with Apple Push Notifications service
   (APNs) in the team that owns the `dev.xenia.matrix` bundle ID, or use an existing one. One
   key works for sandbox and production.
2. From this folder:

   ```bash
   vercel env add APNS_KEY_ID production --sensitive
   ```

   ```bash
   vercel env add APNS_KEY production --sensitive < /path/to/AuthKey_XXXXXXXXXX.p8
   ```

   ```bash
   vercel deploy --prod
   ```

   `APNS_TEAM_ID` is optional; it defaults to Xenia's team (`lib/apns.js`).

Until the key is set, the gateway answers 503 and homeservers retry with backoff.

## What it does

- `dev.xenia.matrix.ios` pushers go to production APNs (TestFlight and App Store builds),
  `dev.xenia.matrix.ios.dev` to sandbox (builds installed from Xcode); the `.mac` and `.mac.dev`
  IDs do the same for the Mac. Anything else is rejected.
- Message pushes go out at priority 10 with `mutable-content`, so the extension can decrypt
  them. Count-only pushes (read on another device) set the badge and also send a silent
  background push (`xenia_read`) that wakes Xenia to take down the notifications of what was read.
- Tokens Apple calls dead are handed back as `rejected`, and the homeserver removes the pusher.
  Anything else (Apple unreachable, a bad key) answers 502, so the homeserver retries and nobody
  loses their pusher over a gateway problem.

## Running your own

A fork that ships under its own bundle ID needs its own gateway: change `TOPIC` and `APPS` in
`lib/gateway.js` to its IDs, deploy with its team's key and `APNS_TEAM_ID`, and point
`XENIA_PUSH_GATEWAY` in `apple/project.yml` at it.

## Tests

```bash
npm test
```
