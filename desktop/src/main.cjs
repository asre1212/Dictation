const { app, BrowserWindow, ipcMain, protocol, net, clipboard, powerMonitor, session: electronSession } = require('electron');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { Worker } = require('node:worker_threads');
protocol.registerSchemesAsPrivileged([{ scheme: 'dictation', privileges: { standard: true, secure: true, supportFetchAPI: true } }]);
let win, worker, receiver, loading = false, ready = false, stopping = false, sequence = 0, copiedText = '', clipboardTimer;
const pending = new Map();
const state = { model: 'base', ready: false, listening: false, paired: false, addresses: [], port: null, qr: null, pairingLink: '', status: 'Download a speech model to begin.' };
const emit = event => { if (win && !win.isDestroyed()) win.webContents.send('dictation:event', event); };
const publish = () => emit({ type: 'state', state: { ...state } });
function stopSession() {
  receiver?.close(); receiver = null;
  Object.assign(state, { listening: false, paired: false, qr: null, pairingLink: '', port: null, status: ready ? 'Session ended. Start a new session to pair.' : 'Load a model to begin.' });
  clearClipboard(); emit({ type: 'clear' }); publish();
}
function clearClipboard() { clearTimeout(clipboardTimer); if (copiedText && clipboard.readText() === copiedText) clipboard.clear(); copiedText = ''; }
function stopWorker() {
  const old = worker; worker = null; ready = false; state.ready = false;
  for (const item of pending.values()) { clearTimeout(item.timer); item.reject(new Error('Speech engine stopped. Load the model again.')); }
  pending.clear(); old?.terminate();
}
function ensureWorker() {
  if (worker) return;
  worker = new Worker(path.join(__dirname, 'asr-worker.mjs'), { workerData: { cacheDir: path.join(app.getPath('userData'), 'models') } });
  const current = worker;
  current.on('message', event => {
    if (current !== worker) return;
    if (event.type === 'progress') return emit(event);
    const item = pending.get(event.id); if (!item) return;
    pending.delete(event.id); clearTimeout(item.timer);
    event.error ? item.reject(new Error(event.error)) : item.resolve(event);
  });
  const failed = () => { if (current !== worker) return; stopWorker(); stopSession(); state.status = 'Speech engine stopped. Load the model again.'; publish(); };
  current.on('error', failed); current.on('exit', code => { if (code !== 0) failed(); });
}
function requestWorker(message, timeout = 180000) {
  ensureWorker(); const id = ++sequence;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { stopWorker(); stopSession(); reject(new Error('Speech engine timed out. Load it again.')); }, timeout);
    pending.set(id, { resolve, reject, timer }); worker.postMessage({ ...message, id });
  });
}
function trusted(event) { return event.sender === win.webContents && event.senderFrame === win.webContents.mainFrame && new URL(event.senderFrame.url).protocol === 'dictation:' && new URL(event.senderFrame.url).host === 'app'; }
function handle(channel, fn) {
  ipcMain.handle(channel, async (event, input) => {
    if (!trusted(event)) throw new Error('Unauthorized');
    try { return { ok: true, value: await fn(input) }; }
    catch (error) { return { ok: false, error: error.message }; }
  });
}
app.whenReady().then(async () => {
  const { startReceiver, localAddresses } = await import('./receiver.mjs');
  const QRCode = require('qrcode');
  electronSession.fromPartition('dictation-memory').protocol.handle('dictation', request => {
    const url = new URL(request.url);
    const allowed = new Set(['/index.html', '/app.js', '/styles.css', '/text-format.mjs']);
    if (url.hostname !== 'app' || !allowed.has(url.pathname)) return new Response('Not found', { status: 404 });
    return net.fetch(pathToFileURL(path.join(__dirname, url.pathname === '/text-format.mjs' ? 'text-format.mjs' : '../ui/' + url.pathname.slice(1))).toString());
  });
  win = new BrowserWindow({ width: 1160, height: 820, minWidth: 850, minHeight: 640, title: 'Dictation Desktop', backgroundColor: '#f4f6f8', webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, sandbox: true, nodeIntegration: false, webSecurity: true, partition: 'dictation-memory' } });
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', event => event.preventDefault());
  win.webContents.session.setPermissionRequestHandler((_wc, _permission, callback) => callback(false));
  win.webContents.session.setPermissionCheckHandler(() => false);
  win.webContents.session.on('will-download', event => event.preventDefault());
  handle('state', () => { state.addresses = localAddresses(); return { ...state }; });
  handle('load-model', async ({ model, download } = {}) => {
    if (loading || state.listening) throw new Error('End the session before changing the model.');
    if (!['base', 'small'].includes(model)) throw new Error('Unknown model.');
    loading = true; ready = false; Object.assign(state, { model, ready: false, status: download ? 'Downloading model files from Hugging Face…' : 'Loading cached model…' }); publish();
    try { await requestWorker({ action: 'load', model, download: download === true }, 15 * 60000); ready = true; Object.assign(state, { ready: true, status: 'Local speech model ready.' }); }
    finally { loading = false; publish(); }
  });
  handle('start-session', async address => {
    if (!ready || loading || stopping) throw new Error('Load a model first.');
    if (state.listening) throw new Error('A session is already running.');
    if (!localAddresses().includes(address)) throw new Error('Choose a current network address.');
    stopping = true;
    try {
      receiver = await startReceiver({ host: address, transcribe: async pcm => (await requestWorker({ action: 'transcribe', pcm })).text, onEvent: event => {
        if (event.type === 'paired') { state.paired = true; state.qr = null; state.pairingLink = ''; state.status = 'iPhone connected. Ready for dictation.'; }
        if (event.type === 'transcribing') state.status = 'Transcribing on this computer…';
        if (event.type === 'transcript') state.status = 'Draft received. Review before copying.';
        if (event.type === 'request-error') state.status = 'Request failed. Retry from the iPhone.';
        if (event.type === 'expired') { stopSession(); state.status = 'Session expired. Pair again.'; }
        emit(event); publish();
      } });
      const link = receiver.pairingLink(address);
      Object.assign(state, { listening: true, paired: false, port: receiver.port, pairingLink: link, qr: await QRCode.toDataURL(link, { width: 280, margin: 2 }), status: 'Scan this code with the iPhone app. Code expires in 10 minutes.' }); publish();
    } finally { stopping = false; }
  });
  handle('stop-session', () => { stopSession(); stopWorker(); publish(); });
  handle('copy', text => { if (typeof text !== 'string' || text.length > 100000) throw new Error('Invalid text.'); clipboard.writeText(text); copiedText = text; clearTimeout(clipboardTimer); clipboardTimer = setTimeout(clearClipboard, 120000); return true; });
  handle('clear', () => { clearClipboard(); return true; });
  await win.loadURL('dictation://app/index.html');
  const lock = () => { stopSession(); stopWorker(); publish(); };
  powerMonitor.on('lock-screen', lock); powerMonitor.on('suspend', lock);
});
app.on('before-quit', () => { stopSession(); stopWorker(); });
app.on('window-all-closed', () => app.quit());
