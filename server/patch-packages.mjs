import { open } from 'node:fs/promises';
import { join } from 'node:path';
import { pipeline } from 'node:stream/promises';

const files = new Map([
  ['/patcher/latest.json', ['latest.json', 'application/json']],
  ['/patcher/Telegram.ipa', ['Telegram.ipa', 'application/octet-stream']],
  ['/patcher/VeilGram-patch.zip', ['VeilGram-patch.zip', 'application/zip']]
]);

export async function servePatchPackage(request, response, directory) {
  const file = files.get(request.url);
  if (!file || !directory) return false;
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    response.writeHead(405, { Allow: 'GET, HEAD' }).end();
    return true;
  }
  let input;
  try {
    input = await open(join(directory, file[0]), 'r');
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
