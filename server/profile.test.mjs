import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { test } from 'node:test';
import { profileServer } from './index.mjs';
import { createStore } from './store.mjs';

test('profile sharing and deleted messages respect the verified account', async (t) => {
  const store = createStore(':memory:', Buffer.alloc(32, 7));
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

  const appearance = (path, method, token, body) => fetch(origin + path, {
    method,
    headers: token ? { Authorization: `Bearer ${token}` } : {},
    body
  });
  const media = Buffer.from('test banner');
  const id = createHash('sha256').update('gif').update(media).digest('hex');
  const header = Buffer.from(JSON.stringify({
    version: 2, profile: { status: 'VeilGram', media: { kind: 'gif', id }, received: ['gift:123'] }
  }));
  const length = Buffer.alloc(4);
  length.writeUInt32BE(header.length);
  const packet = Buffer.concat([length, header, media]);
  const firstAppearance = `/v1/appearance/${first}`;
  assert.equal((await appearance(firstAppearance, 'GET', secondToken)).status, 404);
  assert.equal((await appearance('/v1/appearance/me', 'PUT', undefined, packet)).status, 401);
  assert.equal((await appearance('/v1/appearance/me', 'PUT', firstToken, packet.subarray(0, -1))).status, 400);
  assert.equal((await appearance('/v1/appearance/me', 'PUT', firstToken, packet)).status, 200);
  assert.equal((await appearance(firstAppearance, 'GET')).status, 401);
  assert.equal((await appearance(firstAppearance, 'PUT', secondToken, packet)).status, 404);
  const saved = await appearance(firstAppearance, 'GET', secondToken);
  assert.deepEqual(Buffer.from(await saved.arrayBuffer()), packet);

  const record = { chatId: '808', messageId: '333', chat: 'Test chat', timestamp: 4, text: 'before editing' };
  store.stageMessage(first, '808', '333', record);
  assert.deepEqual(await (await call('/v1/deleted', { token: firstToken })).json(), []);
  store.editStagedMessage(first, '808', '333', 'after editing');
  store.archiveDeletions(first, '808', ['333', '999']);
  store.archiveDeletions(first, '808', ['333']);
  assert.deepEqual(await (await call('/v1/deleted', { token: firstToken })).json(), [{ ...record, text: 'after editing' }]);
  assert.deepEqual(await (await call('/v1/deleted', { token: secondToken })).json(), []);
  assert.equal((await call('/v1/deleted')).status, 401);
  assert.equal((await call('/v1/deleted/connection', { token: firstToken })).status, 503);
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
