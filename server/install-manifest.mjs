const bundleID = /^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/;
const buildVersion = /^[0-9]+(?:\.[0-9]+){0,2}$/;
const installToken = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/;

export function serveInstallManifest(request, response) {
  const url = new URL(request.url, 'http://localhost');
  if (url.pathname !== '/install/manifest.plist') return false;
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    response.writeHead(405, { Allow: 'GET, HEAD' });
    response.end();
    return true;
  }
  const bundle = url.searchParams.get('bundle') ?? '';
  const version = url.searchParams.get('version') ?? '';
  const token = url.searchParams.get('token') ?? '';
  if (bundle.length > 155 || version.length > 32 ||
      !bundleID.test(bundle) || !buildVersion.test(version) || !installToken.test(token)) {
    response.writeHead(400, { 'Cache-Control': 'no-store' });
    response.end();
    return true;
  }
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array><dict>
    <key>assets</key>
    <array><dict>
      <key>kind</key><string>software-package</string>
      <key>url</key><string>http://127.0.0.1:47557/${token}/VeilGram.ipa</string>
    </dict></array>
    <key>metadata</key>
    <dict>
      <key>bundle-identifier</key><string>${bundle}</string>
      <key>bundle-version</key><string>${version}</string>
      <key>kind</key><string>software</string>
      <key>title</key><string>VeilGram</string>
    </dict>
  </dict></array>
</dict>
</plist>
`;
  response.writeHead(200, {
    'Content-Type': 'application/xml; charset=utf-8',
    'Content-Length': Buffer.byteLength(plist),
    'Cache-Control': 'no-store'
  });
  response.end(request.method === 'HEAD' ? undefined : plist);
  return true;
}
