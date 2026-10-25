import { formatCommands } from './text-format.mjs';
const $ = id => document.getElementById(id);
const api = window.dictation;
let state = {}, busy = false, undoText = null;
function count() { $('count').textContent = `${$('draft').value.trim().split(/\s+/).filter(Boolean).length} words`; }
function showError(message) { $('error').hidden = !message; $('error').textContent = message || ''; }
function render(next) {
  state = next;
  $('status').textContent = state.status;
  $('pair').disabled = !state.ready || state.listening || busy || !state.addresses.length;
  $('model').disabled = state.listening || busy;
  $('load').disabled = state.listening || busy;
  $('download').disabled = state.listening || busy;
  $('disconnect').hidden = !state.listening;
  $('pairing').hidden = !state.qr;
  $('qr').src = state.qr || '';
  $('pairLink').value = state.pairingLink;
  $('connected').hidden = !state.paired;
}
async function run(action) {
  showError('');
  try { const result = await action(); if (!result.ok) throw new Error(result.error); return result.value; }
  catch (error) { showError(error.message); return null; }
}
const addresses = await run(() => api.state());
if (addresses) {
  for (const address of addresses.addresses) { const option = document.createElement('option'); option.value = address; option.textContent = address; $('address').append(option); }
  if (!addresses.addresses.length) showError('No network address found. Connect Wi-Fi or a VPN, then reopen the app.');
  render(addresses);
}
api.subscribe(event => {
  if (event.type === 'state') render(event.state);
  if (event.type === 'progress') { $('progress').hidden = false; $('progress').value = event.progress.progress || 0; }
  if (event.type === 'transcript') {
    if (event.text) {
      const combined = $('draft').value + ($('draft').value ? '\n\n' : '') + event.text;
      if (combined.length > 100000) { showError('Draft is full. The new transcription remains on the iPhone. Copy and clear this draft before continuing.'); return; }
      $('draft').value = combined;
    }
    else showError('No speech detected. Try again closer to the microphone.');
    undoText = null; $('undo').disabled = true; count();
  }
  if (event.type === 'clear') { $('draft').value = ''; undoText = null; $('undo').disabled = true; count(); }
});
for (const [button, download] of [['download', true], ['load', false]]) $(button).onclick = async () => {
  busy = true; render(state);
  await run(() => api.loadModel($('model').value, download));
  busy = false; $('progress').hidden = true; render(state);
};
$('pair').onclick = async () => { busy = true; render(state); await run(() => api.startSession($('address').value)); busy = false; render(state); };
$('disconnect').onclick = () => { if (!$('draft').value || confirm('End pairing and clear this draft?')) run(() => api.stopSession()); };
$('copy').onclick = async () => { if (!$('draft').value.trim()) return; const result = await run(() => api.copy($('draft').value)); if (result) $('status').textContent = 'Copied for 2 minutes. Paste into the intended chart and verify the patient.'; };
$('clear').onclick = async () => { if (!$('draft').value || confirm('Clear the current draft and its app-owned clipboard copy?')) { $('draft').value = ''; undoText = null; $('undo').disabled = true; count(); await run(() => api.clear()); } };
$('format').onclick = () => {
  undoText = $('draft').value;
  $('draft').value = formatCommands(undoText);
  $('undo').disabled = false; count();
};
$('undo').onclick = () => { if (undoText !== null) $('draft').value = undoText; undoText = null; $('undo').disabled = true; count(); };
$('draft').addEventListener('input', () => { undoText = null; $('undo').disabled = true; count(); });
