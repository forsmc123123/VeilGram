import assert from 'node:assert/strict';
import { once } from 'node:events';
import { test } from 'node:test';
import { profileServer } from './index.mjs';

test('installer manifest resolves only to the per-install IPA on the iPhone', async (t) => {
  const server = profileServer().listen(0, '127.0.0.1');
  t.after(async () => {
    server.close();
    await once(server, 'close');
  });
  await once(server, 'listening');
  const origin = `http://127.0.0.1:${server.address().port}`;
  const path = origin + '/install/manifest.plist';
  const token = '3011bc45-c4e9-4e72-936d-2fe2528db860';
  const query = new URLSearchParams({ bundle: 'me.example.veilgram', version: '100101', token });
  const response = await fetch(`${path}?${query}`);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.match(response.headers.get('content-type'), /^application\/xml/);
  const plist = await response.text();
  assert.ok(plist.includes(`http://127.0.0.1:47557/${token}/VeilGram.ipa`));
  assert.ok(plist.includes('<string>me.example.veilgram</string>'));
  assert.ok(plist.includes('<string>100101</string>'));
  const head = await fetch(`${path}?${query}`, { method: 'HEAD' });
  assert.equal(head.status, 200);
  assert.equal(await head.text(), '');
  assert.equal((await fetch(`${path}?${query}`, { method: 'POST' })).status, 405);
  query.set('bundle', 'me.example.<bad>');
  assert.equal((await fetch(`${path}?${query}`)).status, 400);
  query.set('bundle', 'me.example.veilgram');
  query.set('token', 'https://example.com/');
  assert.equal((await fetch(`${path}?${query}`)).status, 400);
});
