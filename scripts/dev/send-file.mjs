#!/usr/bin/env node
// Sends a file as one of the seeded test accounts: photos as m.image (with their size), videos,
// audio and anything else as m.file, the way other Matrix clients send them.
//   node scripts/dev/send-file.mjs maya @luke ~/Pictures/beach.jpg "Look at this"
//   node scripts/dev/send-file.mjs priya "#weekend-trip" packing-list.pdf
//   node scripts/dev/send-file.mjs maya @luke photo.jpg --name "Image"   (no extension, as some clients send)
//   node scripts/dev/send-file.mjs maya @luke memo.m4a --voice           (a voice message)
import { execFileSync } from 'node:child_process';
import { readFileSync, statSync } from 'node:fs';
import { basename, extname } from 'node:path';
import { HOMESERVER, PASSWORD } from './seed-homeserver.mjs';

const args = process.argv.slice(2);
const nameFlag = args.indexOf('--name');
const overrideName = nameFlag >= 0 ? args.splice(nameFlag, 2)[1] : null;
const voiceFlag = args.indexOf('--voice');
const isVoice = voiceFlag >= 0 && args.splice(voiceFlag, 1).length > 0;
const [who, where, path, ...captionWords] = args;
if (!who || !where || !path) {
  console.error('usage: send-file.mjs <user> <#alias | @user> <file> [caption] [--name "shown name"]');
  process.exit(64);
}

const TYPES = {
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.gif': 'image/gif', '.heic': 'image/heic',
  '.mov': 'video/quicktime', '.mp4': 'video/mp4', '.m4a': 'audio/mp4', '.mp3': 'audio/mpeg', '.aiff': 'audio/aiff', '.ogg': 'audio/ogg', '.opus': 'audio/ogg',
  '.pdf': 'application/pdf', '.txt': 'text/plain', '.md': 'text/markdown', '.csv': 'text/csv', '.json': 'application/json',
  '.zip': 'application/zip', '.key': 'application/vnd.apple.keynote', '.pages': 'application/vnd.apple.pages',
};

async function api(token, method, path, body, base = '/_matrix/client/v3') {
  const res = await fetch(`${HOMESERVER}${base}${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json();
  if (!res.ok) throw new Error(`${path}: ${json.error ?? res.status}`);
  return json;
}

/** Pixel size and duration, through sips for photos and ffprobe (Homebrew) for video and audio. */
function dimensions(file, mimetype) {
  try {
    if (mimetype.startsWith('image/')) {
      const out = execFileSync('sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', file], { encoding: 'utf8' });
      const w = Number(/pixelWidth: (\d+)/.exec(out)?.[1]);
      const h = Number(/pixelHeight: (\d+)/.exec(out)?.[1]);
      return w && h ? { w, h } : {};
    }
    if (!/^(video|audio)\//.test(mimetype)) return {};
    const probe = JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'stream=width,height:format=duration', '-of', 'json', file], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }));
    const video = probe.streams?.find((s) => s.width);
    const seconds = Number(probe.format?.duration);
    return { ...(video ? { w: video.width, h: video.height } : {}), ...(seconds ? { duration: Math.round(seconds * 1000) } : {}) };
  } catch {
    return {};
  }
}

/** A JPEG poster frame for a video, as clients send with it, or null without ffmpeg. */
function posterFrame(file) {
  try {
    return execFileSync('ffmpeg', ['-v', 'error', '-ss', '0.5', '-i', file, '-frames:v', '1', '-f', 'mjpeg', 'pipe:1']);
  } catch {
    return null;
  }
}

async function uploadBytes(token, bytes, type, filename) {
  const res = await fetch(`${HOMESERVER}/_matrix/media/v3/upload?filename=${encodeURIComponent(filename)}`, {
    method: 'POST',
    headers: { 'Content-Type': type, Authorization: `Bearer ${token}` },
    body: bytes,
  });
  const { content_uri: uri } = await res.json();
  if (!uri) throw new Error(`Upload failed: ${res.status}`);
  return uri;
}

const { access_token: token, user_id: userId } = await api(null, 'POST', '/login', {
  type: 'm.login.password',
  identifier: { type: 'm.id.user', user: who },
  password: PASSWORD,
  initial_device_display_name: 'send-file.mjs',
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

const bytes = readFileSync(path);
const mimetype = TYPES[extname(path).toLowerCase()] ?? 'application/octet-stream';
const name = overrideName ?? basename(path);
const url = await uploadBytes(token, bytes, mimetype, name);

const { w, h, duration } = dimensions(path, mimetype);
const info = { mimetype, size: statSync(path).size, ...(w ? { w, h } : {}), ...(duration ? { duration } : {}) };
const poster = mimetype.startsWith('video/') ? posterFrame(path) : null;
if (poster) {
  info.thumbnail_url = await uploadBytes(token, poster, 'image/jpeg', 'thumbnail.jpg');
  info.thumbnail_info = { mimetype: 'image/jpeg', size: poster.length, w, h };
}
const msgtype = mimetype.startsWith('image/') ? 'm.image' : mimetype.startsWith('video/') ? 'm.video' : mimetype.startsWith('audio/') ? 'm.audio' : 'm.file';
const caption = captionWords.join(' ');
const content = caption ? { msgtype, body: caption, filename: name, url, info } : { msgtype, body: name, url, info };
if (isVoice) {
  content['org.matrix.msc3245.voice'] = {};
  content['org.matrix.msc1767.audio'] = { duration: info.duration };
}
await api(token, 'PUT', `/rooms/${encodeURIComponent(roomId)}/send/m.room.message/${Date.now()}`, content);
await api(token, 'POST', '/logout', {});
console.log(`${userId} → ${where}: ${msgtype} ${name}${caption ? ` “${caption}”` : ''}`);
