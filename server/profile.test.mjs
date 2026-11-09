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
