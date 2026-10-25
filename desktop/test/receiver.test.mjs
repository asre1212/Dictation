import test from 'node:test';
import assert from 'node:assert/strict';
import https from 'node:https';
import { randomUUID, X509Certificate } from 'node:crypto';
import { startReceiver, makeIdentity } from '../src/receiver.mjs';
import { MAX_AUDIO_BYTES, pcmToFloat32, hasSpeechEnergy, validToken } from '../src/protocol.mjs';
import { formatCommands } from '../src/text-format.mjs';
const identity = await makeIdentity();
const audio = Buffer.alloc(3200, 12);
async function setup(t, transcribe = async () => 'No melena. Hemoglobin 12.4 g/dL.', now) {
  const events = [];
  const server = await startReceiver({ identity, host: '127.0.0.1', transcribe, onEvent: e => events.push(e), now });
  t.after(() => server.close());
  const deviceId = randomUUID();
  function request(path, body = Buffer.from('{}'), headers = {}) {
    return new Promise((resolve, reject) => {
      const req = https.request({ hostname: '127.0.0.1', port: server.port, path, method: 'POST', ca: identity.cert,
        checkServerIdentity: (_host, cert) => { if (new X509Certificate(cert.raw).fingerprint256.replaceAll(':', '').toLowerCase() !== server.fingerprint) return new Error('Certificate mismatch'); },
        headers: { Authorization: `Bearer ${server.token}`, 'Content-Type': 'audio/pcm', 'X-Device-Id': deviceId, 'X-Dictation-Id': randomUUID(), ...headers }
      }, res => { const parts = []; res.on('data', c => parts.push(c)); res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(Buffer.concat(parts)) })); });
      req.on('error', reject); req.end(body);
    });
  }
  async function pair(id = deviceId) { return request('/v1/pair', Buffer.from(JSON.stringify({ deviceId: id })), { 'Content-Type': 'application/json' }); }
  return { server, events, request, pair };
}
test('certificate-pinned HTTPS, pairing, delivery and identical retry', async t => {
  let calls = 0;
  const s = await setup(t, async () => { calls++; return 'No melena. Hemoglobin 12.4 g/dL.'; });
  assert.equal((await s.pair()).status, 200);
  const id = randomUUID();
  const result = await s.request('/v1/audio', audio, { 'X-Dictation-Id': id });
  assert.equal(result.body.text, 'No melena. Hemoglobin 12.4 g/dL.');
  assert.deepEqual(await s.request('/v1/audio', audio, { 'X-Dictation-Id': id }), result);
  assert.equal(calls, 1); assert.equal(s.events.filter(e => e.type === 'transcript').length, 1);
  assert.equal((await s.request('/v1/audio', Buffer.alloc(3200, 3), { 'X-Dictation-Id': id })).status, 409);
});
test('rejects unauthenticated, browser-origin and unpaired devices', async t => {
  const s = await setup(t);
  assert.equal((await s.request('/v1/audio', audio, { Authorization: 'Bearer incorrect' })).status, 401);
  assert.equal((await s.request('/v1/audio', audio, { Origin: 'https://evil.example' })).status, 401);
  assert.equal((await s.request('/v1/audio', audio)).status, 403);
  await s.pair(); assert.equal((await s.pair(randomUUID())).status, 409);
  assert.equal((await s.request('/v1/audio', audio, { 'X-Device-Id': randomUUID() })).status, 403);
});
test('bounds payloads and rejects malformed audio', async t => {
  const s = await setup(t); await s.pair();
  assert.equal((await s.request('/v1/audio', Buffer.alloc(3))).status, 400);
  assert.equal((await s.request('/v1/audio', audio, { 'Content-Length': MAX_AUDIO_BYTES + 2 })).status, 413);
  assert.equal((await s.request('/v1/audio', audio, { 'Content-Type': 'audio/wav' })).status, 400);
});
test('one in-flight transcription and closing suppresses late drafts', async t => {
  let complete; const s = await setup(t, () => new Promise(resolve => { complete = resolve; })); await s.pair();
  const first = s.request('/v1/audio', audio).catch(() => null);
  while (!complete) await new Promise(resolve => setTimeout(resolve, 5));
  assert.equal((await s.request('/v1/audio', audio)).status, 429);
  s.server.close(); complete('late draft'); await first;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(s.events.filter(e => e.type === 'transcript').length, 0);
});
test('expired QR and session idle timeout', async t => {
  let clock = 1000; const s = await setup(t, undefined, () => clock);
  clock += 11 * 60000; assert.equal((await s.pair()).status, 410);
  clock += 20 * 60000; assert.equal((await s.request('/v1/audio', audio)).status, 410);
});
test('late retry acknowledges earlier delivery without duplicating it', async t => {
  let clock = 1000; let calls = 0;
  const s = await setup(t, async () => { calls++; return 'original'; }, () => clock); await s.pair();
  const id = randomUUID(); await s.request('/v1/audio', audio, { 'X-Dictation-Id': id });
  clock += 6 * 60000;
  const result = await s.request('/v1/audio', audio, { 'X-Dictation-Id': id });
  assert.equal(result.body.alreadyDelivered, true); assert.equal(calls, 1);
});
test('PCM conversion preserves signed little-endian amplitudes and screens silence', () => {
  assert.deepEqual([...pcmToFloat32(Buffer.from([0, 128, 0, 0, 255, 127]))], [-1, 0, 32767 / 32768]);
  assert.equal(hasSpeechEnergy(new Float32Array(16000)), false);
  assert.throws(() => pcmToFloat32(Buffer.alloc(MAX_AUDIO_BYTES + 2)));
  assert.equal(validToken('x', 'y'), false);
});
test('explicit formatting preserves dose, negation and clinical terminology', () => {
  assert.equal(formatCommands('No melena. New paragraph Continue omeprazole 20 mg. New line No change.'), 'No melena.\n\nContinue omeprazole 20 mg.\nNo change.');
});
