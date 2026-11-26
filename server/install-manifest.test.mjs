import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { profileServer } from './index.mjs';

test('patcher API serves the exact catalog, base and patch files', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'veilgram-patcher-'));
  const payload = new Map([
    ['latest.json', '{"base":{},"patch":{}}'],
    ['Telegram.ipa', 'test base'],
    ['VeilGram-patch.zip', 'test patch']
  ]);
  await Promise.all([...payload].map(([name, bytes]) => writeFile(join(directory, name), bytes)));
  const archived = join(directory, 'versions', '100008');
  await mkdir(archived, { recursive: true });
  await writeFile(join(archived, 'latest.json'), '{"version":"3","telegramVersion":"12.2","notes":"Previous build"}');
  await writeFile(join(archived, 'Telegram.ipa'), 'old base');
  const server = profileServer(undefined, undefined, { patchDirectory: directory }).listen(0, '127.0.0.1');
  t.after(async () => {
    server.close();
    await once(server, 'close');
    await rm(directory, { recursive: true, force: true });
  });
  await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}/patcher/`;
  for (const [name, expected] of payload) {
    const response = await fetch(base + name);
    assert.equal(response.status, 200);
    assert.equal(await response.text(), expected);
  }
  assert.equal((await fetch(base + 'other.ipa')).status, 404);
  assert.equal((await fetch(base + 'Telegram.ipa', { method: 'POST' })).status, 405);
  const versions = await (await fetch(base + 'versions.json')).json();
  assert.deepEqual(versions.map(({ id }) => id), ['latest', '100008']);
  assert.equal(versions[1].telegramVersion, '12.2');
  assert.equal(await (await fetch(base + 'versions/100008/Telegram.ipa')).text(), 'old base');
  assert.equal((await fetch(base + 'versions/100008/unknown.zip')).status, 404);
});

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
