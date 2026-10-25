import { timingSafeEqual } from 'node:crypto';
export const MAX_AUDIO_BYTES = 16000 * 2 * 60;
export const ID_PATTERN = /^[a-f0-9-]{36}$/i;
export function validToken(actual, expected) {
  const a = Buffer.from(actual || ''); const b = Buffer.from(expected || '');
  return a.length === b.length && a.length > 0 && timingSafeEqual(a, b);
}
export function pcmToFloat32(bytes) {
  if (!bytes.length || bytes.length % 2 || bytes.length > MAX_AUDIO_BYTES) throw new Error('Invalid PCM length');
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const samples = new Float32Array(bytes.length / 2);
  for (let i = 0; i < samples.length; i++) samples[i] = view.getInt16(i * 2, true) / 32768;
  return samples;
}
export function hasSpeechEnergy(samples) {
  let energy = 0;
  for (const value of samples) energy += value * value;
  return samples.length >= 1600 && Math.sqrt(energy / samples.length) >= 0.001;
}
export function createPairingLink(address, port, token, fingerprint) {
  return 'dictation://desktop?' + new URLSearchParams({ endpoint: `https://${address}:${port}`, token, fingerprint }).toString();
}
