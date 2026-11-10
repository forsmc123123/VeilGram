import { mkdirSync, readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { createStore } from './store.mjs';

const catalog = JSON.parse(readFileSync(new URL('./catalog.json', import.meta.url), 'utf8'));
const bannerIds = new Set(catalog.banners.map(({ id }) => id));
const giftIds = new Set(catalog.gifts.map(({ id }) => id));
const validPeer = (peer) => typeof peer === 'string' && /^[1-9][0-9]{0,15}$/.test(peer);
const mediaLimit = 8 * 1024 * 1024;
const contentTypes = { photo: 'image/jpeg', gif: 'image/gif', video: 'video/mp4' };
const validMediaId = (value) => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);

function reply(response, status, value) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(value));
}

async function readBytes(request, limit) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request.iterator({ destroyOnReturn: false })) {
    size += chunk.length;
    if (size > limit) {
      request.resume();
      return null;
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

async function readBody(request) {
  try {
    const bytes = await readBytes(request, 2048);
    return bytes && JSON.parse(bytes.toString('utf8'));
  } catch {
    return null;
  }
}

function readStyle(input) {
  const { banner = null, media = null, color = null, status = null } = input ?? {};
  if (banner !== null && !bannerIds.has(banner)) return;
  if (media !== null && (!validMediaId(media?.id) || !Object.hasOwn(contentTypes, media?.kind))) return;
  if (color !== null && (typeof color !== 'string' || !/^[A-F0-9]{6}$/.test(color))) return;
  if (status !== null && (typeof status !== 'string' || Array.from(status).length > 32 ||
      /[\p{Cc}\u202a-\u202e\u2066-\u2069]/u.test(status))) return;
  return { banner: media ? null : banner, media: media && { id: media.id, kind: media.kind }, color, status };
}

function validMedia(kind, data) {
  if (!data || data.length < 12) return false;
  if (kind === 'photo') return data[0] === 0xff && data[1] === 0xd8 && data[2] === 0xff;
  if (kind === 'gif') return ['GIF89a', 'GIF87a'].includes(data.toString('ascii', 0, 6));
  return data.toString('ascii', 4, 8) === 'ftyp';
}

function giftCost(item) {
  if (typeof item !== 'string') return;
  if (/^gift:[1-9][0-9]{0,18}$/.test(item)) return 25;
  if (/^nft:[A-Za-z0-9]{1,60}-[1-9][0-9]{0,11}$/.test(item)) return 100;
}

export function profileServer(store, botUsername) {
  return createServer({ requestTimeout: 60_000, headersTimeout: 5_000 }, async (request, response) => {
    const { method, url } = request;
    try {
      if (method === 'GET' && url === '/v1/catalog') {
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
      if (!(method === 'GET' && peerRoute) && !isSave && !url.startsWith('/v2/')) {
        return reply(response, 404, { error: 'not_found' });
      }
      const bearer = /^Bearer ([\w-]{43})$/.exec(request.headers.authorization ?? '');
      const owner = bearer && store.authenticatedPeer(bearer[1]);
      if (!owner) return reply(response, 401, { error: 'authentication_required' });
      if (url.startsWith('/v2/')) {
        const profileRoute = /^\/v2\/profiles\/([1-9][0-9]{0,15})$/.exec(url);
        const mediaRoute = /^\/v2\/media\/([1-9][0-9]{0,15})\/([a-f0-9]{64})$/.exec(url);
        const uploadRoute = /^\/v2\/me\/media\/(photo|gif|video)$/.exec(url);
        if (method === 'GET' && profileRoute) {
          return reply(response, 200, store.getSharedProfile(profileRoute[1], owner));
        }
        if (method === 'PUT' && url === '/v2/me') {
          const input = await readBody(request);
          const style = input && typeof input === 'object' && !Array.isArray(input) && readStyle(input);
          if (!style || !store.saveStyle(owner, style)) return reply(response, 400, { error: 'invalid_style' });
          return reply(response, 200, store.getSharedProfile(owner, owner));
        }
        if (method === 'POST' && uploadRoute) {
          const kind = uploadRoute[1];
          if (request.headers['content-type'] !== contentTypes[kind] ||
              Number(request.headers['content-length'] ?? 0) > mediaLimit) {
            return reply(response, 400, { error: 'invalid_media' });
          }
          const bytes = await readBytes(request, mediaLimit);
          if (!validMedia(kind, bytes)) return reply(response, 400, { error: 'invalid_media' });
          return reply(response, 200, store.uploadMedia(owner, kind, bytes));
        }
        if (method === 'GET' && mediaRoute) {
          const media = store.getMedia(mediaRoute[1], mediaRoute[2], owner);
          if (!media) return reply(response, 404, { error: 'not_found' });
          response.writeHead(200, {
            'Content-Type': contentTypes[media.kind], 'Content-Length': media.data.byteLength,
            'X-Content-Type-Options': 'nosniff', 'Cache-Control': 'private, no-store'
          });
          return response.end(media.data);
        }
        if (method === 'POST' && url === '/v2/gifts') {
          const { recipient, nonce, item } = await readBody(request) ?? {};
          const cost = giftCost(item);
          if (!cost || !validPeer(recipient) || recipient === owner ||
              typeof nonce !== 'string' || !/^[a-f0-9-]{36}$/.test(nonce)) {
            return reply(response, 400, { error: 'invalid_gift' });
          }
          const result = store.sendGift(owner, recipient, nonce, item, cost);
          return reply(response, result.error ? 409 : 200, result);
        }
        return reply(response, 404, { error: 'not_found' });
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
  });
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
  const token = process.env.TELEGRAM_BOT_TOKEN;
  if (!token || !/^\d+:[\w-]+$/.test(token)) throw new Error('Set TELEGRAM_BOT_TOKEN before starting.');
  const bot = await telegram(token, 'getMe');
  if (!bot.username) throw new Error('Bot username is unavailable.');
  const database = resolve(process.env.PROFILE_DATABASE ?? 'data/profiles.sqlite');
  mkdirSync(dirname(database), { recursive: true });
  const store = createStore(database);
  const port = Number(process.env.PORT ?? 8080);
  profileServer(store, bot.username).listen(port, process.env.HOST ?? '127.0.0.1', () => {
    console.log(`Profile service listening on port ${port}.`);
  });
  await pollBot(token, store);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(() => {
    console.error('Could not start the profile service. Check the bot token, Telegram connection and database path.');
    process.exitCode = 1;
  });
}
