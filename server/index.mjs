import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { createServer as createSecureServer } from 'node:https';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { createStore } from './store.mjs';

const catalog = JSON.parse(readFileSync(new URL('./catalog.json', import.meta.url), 'utf8'));
const bannerIds = new Set(catalog.banners.map(({ id }) => id));
const giftIds = new Set(catalog.gifts.map(({ id }) => id));
const validPeer = (peer) => typeof peer === 'string' && /^[1-9][0-9]{0,15}$/.test(peer);
const mediaLimit = 8 * 1024 * 1024;
const packetLimit = mediaLimit + 2052;

function reply(response, status, value) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(value));
}

function cached(request, response, etag, contentType, cacheControl, bytes) {
  const headers = { ETag: etag, 'Cache-Control': cacheControl, Vary: 'Authorization' };
  if (request.headers['if-none-match'] === etag) {
    response.writeHead(304, headers);
    return response.end();
  }
  response.writeHead(200, { ...headers, 'Content-Type': contentType, 'Content-Length': bytes.byteLength });
  return response.end(bytes);
}

async function readBytes(request, limit) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size <= limit) chunks.push(chunk);
  }
  return size <= limit ? Buffer.concat(chunks) : null;
}

async function readBody(request) {
  const data = await readBytes(request, 2048);
  try {
    return data && JSON.parse(data.toString('utf8'));
  } catch {
    return null;
  }
}

function validAppearance(packet) {
  if (!packet || packet.length < 5) return false;
  const length = packet.readUInt32BE(0);
  if (length < 1 || length > 2048 || packet.length < length + 4) return false;
  let header;
  try {
    header = JSON.parse(packet.subarray(4, length + 4));
  } catch {
    return false;
  }
  const profile = header?.profile;
  if (header?.version !== 2 || header.gift != null || !profile || Array.isArray(profile) ||
      typeof profile !== 'object' || (profile.banner != null && !bannerIds.has(profile.banner)) ||
      (profile.color != null && (typeof profile.color !== 'string' || !/^[A-F0-9]{6}$/.test(profile.color))) ||
      (profile.status != null && (typeof profile.status !== 'string' || [...profile.status].length > 32 || /\p{Cc}/u.test(profile.status))) ||
      (profile.received != null && (!Array.isArray(profile.received) || profile.received.length > 18 ||
        profile.received.some((gift) => typeof gift !== 'string' || !/^(gift:[1-9][0-9]{0,18}|nft:[A-Za-z0-9]{1,60}-[1-9][0-9]{0,11})$/.test(gift))))) {
    return false;
  }
  const bytes = packet.subarray(length + 4);
  if (profile.media == null) return bytes.length === 0;
  const { kind, id } = profile.media;
  if (!['photo', 'gif', 'video'].includes(kind) || bytes.length < 1 || bytes.length > mediaLimit) return false;
  return createHash('sha256').update(kind).update(bytes).digest('hex') === id;
}

export function profileServer(store, botUsername, { tls, collector } = {}) {
  const options = { requestTimeout: 15_000, headersTimeout: 5_000 };
  const handle = async (request, response) => {
    const { method, url } = request;
    try {
      if (method === 'GET' && url === '/health') {
        return reply(response, 200, { service: 'veilgram', bot: Boolean(botUsername) });
      }
      if (method === 'GET' && url === '/v1/catalog') {
        if (!botUsername) return reply(response, 503, { error: 'bot_unavailable' });
        return reply(response, 200, { ...catalog, botUsername });
      }
      if (method === 'POST' && url === '/v1/session') {
        const { peer, code } = await readBody(request) ?? {};
        if (!validPeer(peer) || typeof code !== 'string' || !/^[A-F0-9]{8}$/.test(code)) {
          return reply(response, 400, { error: 'invalid_code_format' });
        }
        const token = store.redeemCode(peer, code);
        return token ? reply(response, 200, { token }) : reply(response, 401, { error: 'invalid_or_expired_code' });
      }
      const peerRoute = /^\/v1\/profiles\/([1-9][0-9]{0,15})$/.exec(url);
      const isSave = method === 'PUT' && url === '/v1/me';
      const appearancePeer = method === 'GET' && /^\/v1\/appearance\/([1-9][0-9]{0,15})$/.exec(url);
      const appearancePart = method === 'GET' && /^\/v1\/appearance\/([1-9][0-9]{0,15})\/(metadata|media\/([a-f0-9]{64}))$/.exec(url);
      const isAppearanceSave = method === 'PUT' && url === '/v1/appearance/me';
      const isArchive = method === 'GET' && url === '/v1/deleted';
      const isPair = ['GET', 'POST', 'DELETE'].includes(method) && url === '/v1/deleted/connection';
      const isPassword = method === 'POST' && url === '/v1/deleted/password';
      if (!(method === 'GET' && peerRoute) && !isSave && !appearancePeer && !appearancePart && !isAppearanceSave && !isArchive && !isPair && !isPassword) {
        return reply(response, 404, { error: 'not_found' });
      }
      const bearer = /^Bearer ([\w-]{43})$/.exec(request.headers.authorization ?? '');
      const owner = bearer && store.authenticatedPeer(bearer[1]);
      if (!owner) return reply(response, 401, { error: 'authentication_required' });
      if (isArchive) {
        return reply(response, 200, store.deletedMessages(owner));
      }
      if (isPair || isPassword) {
        if (!collector) return reply(response, 503, { error: 'archive_unavailable' });
        if (isPassword) {
          const { password } = await readBody(request) ?? {};
          if (typeof password !== 'string' || password.length < 1 || password.length > 256) {
            return reply(response, 400, { error: 'invalid_password' });
          }
          if (!await collector.checkPassword(owner, password)) {
            return reply(response, 400, { error: 'invalid_password' });
          }
        } else if (method === 'POST') {
          if (!collector.connect(owner)) return reply(response, 503, { error: 'archive_capacity' });
        } else if (method === 'DELETE') {
          await collector.disconnect(owner);
        }
        return reply(response, 200, collector.status(owner));
      }
      if (isAppearanceSave) {
        const packet = await readBytes(request, packetLimit);
        if (!validAppearance(packet)) return reply(response, 400, { error: 'invalid_appearance' });
        store.saveAppearance(owner, packet);
        return reply(response, 200, { saved: true });
      }
      if (appearancePart) {
        const [, peer, part, mediaId] = appearancePart;
        const prefix = store.appearancePrefix(peer);
        if (!prefix) return reply(response, 404, { error: 'profile_not_found' });
        const offset = Buffer.from(prefix.buffer, prefix.byteOffset, prefix.byteLength).readUInt32BE(0) + 4;
        const header = prefix.subarray(4, offset);
        if (part === 'metadata') {
          const etag = `"${createHash('sha256').update(header).digest('hex')}"`;
          return cached(request, response, etag, 'application/json', 'private, max-age=30', header);
        }
        const { profile } = JSON.parse(Buffer.from(header));
        if (profile.media?.id !== mediaId) return reply(response, 404, { error: 'banner_not_found' });
        const bytes = store.appearanceMedia(peer, offset);
        return cached(request, response, `"${mediaId}"`, 'application/octet-stream', 'private, max-age=31536000, immutable', bytes);
      }
      if (appearancePeer) {
        const packet = store.appearance(appearancePeer[1]);
        if (!packet) return reply(response, 404, { error: 'profile_not_found' });
        response.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Cache-Control': 'no-store' });
        return response.end(packet);
      }
      if (isSave) {
        const { banner, gifts } = await readBody(request) ?? {};
        if ((banner !== null && !bannerIds.has(banner)) || !Array.isArray(gifts) ||
            gifts.length > 6 || new Set(gifts).size !== gifts.length || gifts.some((id) => !giftIds.has(id))) {
          return reply(response, 400, { error: 'invalid_decorations' });
        }
        const profile = { banner, gifts };
        store.saveProfile(owner, profile);
        return reply(response, 200, profile);
      }
      return reply(response, 200, store.getProfile(peerRoute[1]));
    } catch {
      if (!response.headersSent && !response.destroyed) reply(response, 500, { error: 'server_error' });
    }
  };
  return tls ? createSecureServer({ ...options, ...tls, minVersion: 'TLSv1.2' }, handle) : createServer(options, handle);
}

async function telegram(token, method, body = {}) {
  const response = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(35_000)
  });
  if (!response.ok) throw new Error(`Bot API ${method}: HTTP ${response.status}`);
  const result = await response.json();
  if (!result.ok) throw new Error(`Bot API ${method}: invalid response`);
  return result.result;
}

async function pollBot(token, store) {
  let offset = 0;
  for (;;) {
    try {
      const updates = await telegram(token, 'getUpdates', { offset, timeout: 25, allowed_updates: ['message'] });
      for (const update of updates) {
        const message = update.message;
        if (message?.chat.type === 'private' && message.from?.id === message.chat.id &&
            /^\/(start|code)$/.test(message.text ?? '')) {
          const code = store.issueCode(String(message.from.id));
          if (code) {
            await telegram(token, 'sendMessage', {
              chat_id: message.chat.id,
              text: `Ваш код для общего профиля VeilGram — ${code}\nВведите его в приложении. Код действует 5 минут.`,
              protect_content: true
            });
          }
        }
        offset = update.update_id + 1;
      }
    } catch {
      console.error('Bot API request failed. Retrying in five seconds.');
      await delay(5000);
    }
  }
}

async function main() {
  if (existsSync('.env')) process.loadEnvFile();
  const [command, peer] = process.argv.slice(2);
  if (command && (command !== 'invite' || !validPeer(peer) || process.argv.length !== 4)) {
    throw new Error('Usage: node index.mjs [invite TELEGRAM_ID]');
  }
  const database = resolve(process.env.PROFILE_DATABASE ?? 'data/profiles.sqlite');
  mkdirSync(dirname(database), { recursive: true });
  const archiveKey = process.env.ARCHIVE_KEY;
  if (archiveKey && !/^[a-f0-9]{64}$/i.test(archiveKey)) throw new Error('Invalid archive key.');
  const store = createStore(database, archiveKey ? Buffer.from(archiveKey, 'hex') : undefined);
  if (command === 'invite') {
    try {
      const code = store.issueCode(peer);
      if (!code) throw new Error('A code was issued recently. Wait 30 seconds before replacing it.');
      console.log(code);
    } finally {
      store.close();
    }
    return;
  }
  const token = process.env.TELEGRAM_BOT_TOKEN;
  if (token && !/^\d+:[\w-]+$/.test(token)) throw new Error('Invalid bot token.');
  const bot = token ? await telegram(token, 'getMe') : undefined;
  if (token && !bot?.username) throw new Error('Bot username is unavailable.');
  const port = Number(process.env.PORT ?? process.env.SERVER_PORT ?? 8080);
  const tls = process.env.TLS_CERT && process.env.TLS_KEY
    ? { cert: readFileSync(process.env.TLS_CERT), key: readFileSync(process.env.TLS_KEY) }
    : undefined;
  const archiveConfigured = archiveKey && process.env.TELEGRAM_API_ID && process.env.TELEGRAM_API_HASH;
  const collector = archiveConfigured ? await import('./collector.mjs').then(({ createCollector }) => createCollector(store, dirname(database))) : undefined;
  profileServer(store, bot?.username, { tls, collector }).listen(port, process.env.HOST ?? '127.0.0.1', () => {
    console.log(`Profile service listening on port ${port}.`);
  });
  if (token) await pollBot(token, store);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch((error) => {
    console.error(process.argv[2] ? error.message : 'Could not start the profile service. Check the database path and optional bot configuration.');
    process.exitCode = 1;
  });
}
