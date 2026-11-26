import { open, readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pipeline } from 'node:stream/promises';

const files = new Map([
  ['/patcher/latest.json', ['latest.json', 'application/json']],
  ['/patcher/Telegram.ipa', ['Telegram.ipa', 'application/octet-stream']],
  ['/patcher/VeilGram-patch.zip', ['VeilGram-patch.zip', 'application/zip']]
]);
const historic = /^\/patcher\/versions\/([0-9]{1,12})\/([^/]+)$/;

export async function servePatchPackage(request, response, directory) {
  const route = historic.exec(request.url);
  const file = files.get(route ? '/patcher/' + route[2] : request.url);
  const versions = request.url === '/patcher/versions.json';
  if ((!file && !versions) || !directory) return false;
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    response.writeHead(405, { Allow: 'GET, HEAD' }).end();
    return true;
  }
  let input;
  try {
    if (versions) {
      const history = await readdir(join(directory, 'versions'), { withFileTypes: true }).catch(error => {
        if (error.code === 'ENOENT') return [];
        throw error;
      });
      const ids = history.filter(entry => entry.isDirectory() && /^[0-9]{1,12}$/.test(entry.name))
        .map(entry => entry.name).sort((a, b) => Number(b) - Number(a)).slice(0, 6);
      const releases = await Promise.all(['latest', ...ids].map(async id => {
        const folder = id === 'latest' ? directory : join(directory, 'versions', id);
        try {
          const catalog = JSON.parse(await readFile(join(folder, 'latest.json'), 'utf8'));
          return { id, version: String(catalog.version ?? 'VeilGram').slice(0, 48),
            build: String(catalog.build ?? '').slice(0, 32), telegramVersion: String(catalog.telegramVersion ?? '').slice(0, 48),
            notes: String(catalog.notes ?? '').slice(0, 2000) };
        } catch {
          return null;
        }
      }));
      const body = JSON.stringify(releases.filter(Boolean));
      response.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store',
        'Content-Length': Buffer.byteLength(body) }).end(request.method === 'HEAD' ? undefined : body);
      return true;
    }
    input = await open(join(directory, ...(route ? ['versions', route[1]] : []), file[0]), 'r');
    const stat = await input.stat();
    if (!stat.isFile()) {
      response.writeHead(404).end();
      return true;
    }
    response.writeHead(200, {
      'Content-Type': file[1],
      'Content-Length': stat.size,
      'Cache-Control': 'no-store'
    });
    if (request.method === 'HEAD') response.end();
    else await pipeline(input.createReadStream({ autoClose: false }), response);
  } catch (error) {
    if (response.headersSent) response.destroy();
    else response.writeHead(error.code === 'ENOENT' ? 404 : 503).end();
  } finally {
    await input?.close();
  }
  return true;
}
