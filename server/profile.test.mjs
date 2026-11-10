import assert from 'node:assert/strict';
import { once } from 'node:events';
import { test } from 'node:test';
import { profileServer } from './index.mjs';
import { createStore } from './store.mjs';

test('profile sharing requires account verification and only the owner can change a profile', async (t) => {
  const store = createStore(':memory:');
  const server = profileServer(store, 'PolusExampleBot').listen(0, '127.0.0.1');
  t.after(async () => {
    server.close();
    await once(server, 'close');
    store.close();
  });
  await once(server, 'listening');
  const origin = `http://127.0.0.1:${server.address().port}`;
  const call = (path, { method = 'GET', token, body } = {}) => fetch(origin + path, {
    method,
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body ? { 'Content-Type': 'application/json' } : {})
    },
    body: body && JSON.stringify(body)
  });
  const login = (peer, code) => call('/v1/session', { method: 'POST', body: { peer, code } });

  const first = '987654321012';
  const second = '987654321013';
  const firstCode = store.issueCode(first);
  assert.equal((await login(second, firstCode)).status, 401);
  const { token: firstToken } = await (await login(first, firstCode)).json();
  assert.equal((await login(first, firstCode)).status, 401);
  const { token: secondToken } = await (await login(second, store.issueCode(second))).json();
  assert.equal((await call(`/v1/profiles/${first}`)).status, 401);

  const selection = { banner: 'aurora', gifts: ['crystal', 'moon'] };
  const save = (token, body) => call('/v1/me', { method: 'PUT', token, body });
  assert.equal((await save(firstToken, { banner: 'fake', gifts: [] })).status, 400);
  assert.equal((await save(firstToken, { banner: null, gifts: ['moon', 'moon'] })).status, 400);
  assert.deepEqual(await (await save(firstToken, selection)).json(), selection);
  assert.deepEqual(await (await call(`/v1/profiles/${first}`, { token: secondToken })).json(), selection);
  assert.equal((await call(`/v1/profiles/${first}`, { method: 'PUT', token: secondToken, body: { banner: null, gifts: [] } })).status, 404);

  const empty = { banner: null, gifts: [] };
  assert.deepEqual(await (await save(firstToken, empty)).json(), empty);
  assert.deepEqual(await (await call(`/v1/profiles/${first}`, { token: secondToken })).json(), empty);
});

test('expired codes and codes that run out of attempts cannot start sessions', (t) => {
  const store = createStore(':memory:');
  t.after(() => store.close());
  const code = store.issueCode('123', 0);
  assert.equal(store.redeemCode('123', code, 300_000), undefined);
  const fresh = store.issueCode('123', 300_000);
  const wrong = fresh === 'FFFFFFFF' ? 'EEEEEEEE' : 'FFFFFFFF';
  for (let attempt = 0; attempt < 6; attempt++) {
    assert.equal(store.redeemCode('123', wrong, 300_001), undefined);
  }
  assert.equal(store.redeemCode('123', fresh, 300_002), undefined);
});

test('verified profiles share uploaded frames and spend visual stars exactly once per gift', async (t) => {
  const store = createStore(':memory:');
  const server = profileServer(store, 'PolusExampleBot').listen(0, '127.0.0.1');
  t.after(() => {
    server.close();
    store.close();
  });
  await once(server, 'listening');
  const origin = `http://127.0.0.1:${server.address().port}`;
  const sender = '421001';
  const recipient = '421002';
  const token = store.redeemCode(sender, store.issueCode(sender));
  const call = (path, { method = 'GET', bearer = token, payload, media } = {}) => fetch(origin + path, {
    method,
    headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': media ? 'image/gif' : 'application/json' },
    body: media ?? (payload === undefined ? undefined : JSON.stringify(payload))
  });
  const gift = { recipient, item: 'nft:PlushPepe-42', nonce: '71ca0e60-6a2e-48be-8687-3cc4f0918089' };
  assert.deepEqual(await (await call(`/v2/profiles/${recipient}`)).json(), { member: false });
  assert.equal((await call('/v2/gifts', { method: 'POST', payload: gift })).status, 409);
  assert.equal((await (await call(`/v2/profiles/${sender}`)).json()).balance, 1000);

  const recipientToken = store.redeemCode(recipient, store.issueCode(recipient));
  const gif = Buffer.from('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7', 'base64');
  const upload = await call('/v2/me/media/gif', { method: 'POST', media: gif });
  assert.equal(upload.status, 200);
  const frame = await upload.json();
  const framePath = `/v2/media/${sender}/${frame.id}`;
  assert.equal((await call(framePath, { bearer: recipientToken })).status, 404);
  assert.equal((await call('/v2/me', { method: 'PUT', bearer: recipientToken, payload: { media: frame } })).status, 400);
  assert.equal((await call('/v2/me', { method: 'PUT', payload: { media: frame, color: 'C4A7FF', status: '👻 Привет' } })).status, 200);
  assert.deepEqual(Buffer.from(await (await call(framePath, { bearer: recipientToken })).arrayBuffer()), gif);
  const visible = await (await call(`/v2/profiles/${sender}`, { bearer: recipientToken })).json();
  assert.equal(visible.member, true);
  assert.equal(visible.color, 'C4A7FF');
  assert.equal(visible.balance, undefined);

  const send = (payload) => call('/v2/gifts', { method: 'POST', payload });
  const responses = await Promise.all([send(gift), send(gift)]);
  for (const response of responses) assert.deepEqual(await response.json(), { balance: 900 });
  assert.equal((await send({ ...gift, item: 'gift:400' })).status, 409);
  const received = await (await call(`/v2/profiles/${recipient}`, { bearer: recipientToken })).json();
  assert.deepEqual(received.received, [gift.item]);
  assert.equal(received.balance, 1000);
  assert.equal((await call('/v2/me', { method: 'PUT', payload: { banner: 'aurora' } })).status, 200);
  assert.equal((await call(framePath, { bearer: recipientToken })).status, 404);
});
