import https from 'node:https';
import { randomBytes, X509Certificate, createHash } from 'node:crypto';
import { networkInterfaces } from 'node:os';
import selfsigned from 'selfsigned';
import { MAX_AUDIO_BYTES, ID_PATTERN, validToken, createPairingLink } from './protocol.mjs';

export function localAddresses() {
  return [...new Set(Object.values(networkInterfaces()).flat().filter(x => x && x.family === 'IPv4' && !x.internal).map(x => x.address))];
}
export async function makeIdentity() {
  const pems = await selfsigned.generate([{ name: 'commonName', value: 'Dictation Desktop' }], {
    notAfterDate: new Date(Date.now() + 86400000), keySize: 2048, algorithm: 'sha256',
    extensions: [{ name: 'basicConstraints', cA: false }, { name: 'keyUsage', digitalSignature: true, keyEncipherment: true }, { name: 'extKeyUsage', serverAuth: true }]
  });
  return { key: pems.private, cert: pems.cert, fingerprint: new X509Certificate(pems.cert).fingerprint256.replaceAll(':', '').toLowerCase() };
}
export async function startReceiver({ transcribe, onEvent = () => {}, identity, host = '0.0.0.0', port = 0, now = Date.now }) {
  const tls = identity || await makeIdentity();
  const token = randomBytes(32).toString('hex');
  const started = now(); let lastActivity = started; let deviceId = null; let closed = false;
  let busy = false; let activeRequests = 0;
  const recent = new Map(); const failures = new Map();
  const send = (res, status, data) => { if (!res.destroyed) { res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }); res.end(JSON.stringify(data)); } };
  async function readBody(req, max) {
    if (Number(req.headers['content-length']) > max) throw new Error('size');
    const chunks = []; let length = 0;
    for await (const chunk of req) { length += chunk.length; if (length > max) throw new Error('size'); chunks.push(chunk); }
    return Buffer.concat(chunks);
  }
  const server = https.createServer({ key: tls.key, cert: tls.cert, minVersion: 'TLSv1.2', requestTimeout: 20000, headersTimeout: 10000, maxHeaderSize: 4096 }, async (req, res) => {
    if (closed || now() - started > 8 * 3600000 || now() - lastActivity > 30 * 60000) return send(res, 410, { error: 'Session expired. Pair again.' });
    if (activeRequests >= 8) return send(res, 429, { error: 'Receiver busy.' });
    activeRequests++;
    res.once('close', () => activeRequests--);
    const ip = req.socket.remoteAddress;
    const failure = failures.get(ip);
    if (failure && failure.until > now() && failure.count >= 12) return send(res, 429, { error: 'Too many failed attempts.' });
    if (req.headers.origin || !validToken(req.headers.authorization, `Bearer ${token}`)) {
      if (failures.size > 200) failures.clear();
      failures.set(ip, { until: now() + 60000, count: (failure?.until > now() ? failure.count : 0) + 1 });
      return send(res, 401, { error: 'Pairing required.' });
    }
    if (req.method !== 'POST') return send(res, 405, { error: 'POST required.' });
    try {
      if (req.url === '/v1/pair') {
        if (!deviceId && now() - started > 10 * 60000) return send(res, 410, { error: 'QR expired. Start a new session.' });
        const data = JSON.parse((await readBody(req, 512)).toString());
        if (!ID_PATTERN.test(data.deviceId || '')) return send(res, 400, { error: 'Invalid device.' });
        if (deviceId && deviceId !== data.deviceId) return send(res, 409, { error: 'Another iPhone is paired. Start a new session.' });
        deviceId = data.deviceId; lastActivity = now();
        onEvent({ type: 'paired' });
        return send(res, 200, { paired: true, protocol: 1, sampleRate: 16000, maximumSeconds: 60 });
      }
      if (!deviceId || req.headers['x-device-id'] !== deviceId) return send(res, 403, { error: 'Device not paired.' });
      if (req.url !== '/v1/audio') return send(res, 404, { error: 'Not found.' });
      const id = req.headers['x-dictation-id'];
      if (!ID_PATTERN.test(id || '') || req.headers['content-type'] !== 'audio/pcm') return send(res, 400, { error: 'Invalid audio headers.' });
      // One audio upload/inference at a time bounds memory and prevents request floods.
      if (busy) return send(res, 429, { error: 'Still transcribing. Retry shortly.' });
      busy = true;
      let pcm;
      try {
        pcm = await readBody(req, MAX_AUDIO_BYTES);
        if (!pcm.length || pcm.length % 2) return send(res, 400, { error: 'Expected mono 16 kHz Int16 PCM.' });
        const hash = createHash('sha256').update(pcm).digest('hex');
        for (const [key, entry] of recent) if (now() - entry.time > 300000) entry.result = { id: key, text: '', alreadyDelivered: true, reviewRequired: true };
        const previous = recent.get(id);
        if (previous) return send(res, previous.hash === hash ? 200 : 409, previous.hash === hash ? previous.result : { error: 'Request ID conflict.' });
        onEvent({ type: 'transcribing' }); lastActivity = now();
        const text = await transcribe(pcm);
        if (closed) return send(res, 410, { error: 'Session ended.' });
        const result = { id, text: String(text).slice(0, 30000), reviewRequired: true };
        recent.set(id, { hash, result, time: now() });
        // Keep delivery IDs for the full session so late retries never duplicate drafts.
        if (recent.size >= 1000) { close(); onEvent({ type: 'expired' }); }
        lastActivity = now(); onEvent({ type: 'transcript', ...result });
        return send(res, 200, result);
      } finally { pcm?.fill(0); busy = false; }
    } catch (error) {
      onEvent({ type: 'request-error' });
      return send(res, error.message === 'size' ? 413 : error instanceof SyntaxError ? 400 : 503, { error: error.message === 'size' ? 'Maximum recording: 60 seconds.' : 'Unable to transcribe. Check the desktop model and retry.' });
    }
  });
  server.maxConnections = 16;
  server.on('tlsClientError', () => {}); // No peer data or credentials in logs.
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, host, resolve); });
  const actualPort = server.address().port;
  const close = () => { closed = true; recent.clear(); failures.clear(); server.closeAllConnections(); server.close(); clearInterval(expiry); };
  const expiry = setInterval(() => { if (now() - started > 8 * 3600000 || now() - lastActivity > 30 * 60000) { close(); onEvent({ type: 'expired' }); } }, 10000);
  expiry.unref();
  return { port: actualPort, token, fingerprint: tls.fingerprint, pairingLink: address => createPairingLink(address, actualPort, token, tls.fingerprint), close };
}
