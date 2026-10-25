// Runs the real Electron app on Mac/Windows CI, including its custom scheme,
// sandboxed preload, IPC sender checks, editor and clipboard.
const { app, clipboard } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const timer = setTimeout(() => { console.error('Electron UI smoke timed out'); app.exit(1); }, 30000);
app.on('browser-window-created', (_event, window) => {
  window.webContents.on('did-fail-load', (_e, code, description) => { console.error('UI load failed:', code, description); app.exit(1); });
  window.webContents.once('did-finish-load', async () => {
    try {
      const result = await window.webContents.executeJavaScript(`(async () => {
        if (typeof require !== 'undefined') throw new Error('Renderer Node access must be disabled');
        if (!window.dictation) throw new Error('Preload bridge missing');
        const status = await window.dictation.state();
        if (!status.ok || status.value.ready) throw new Error('IPC state check failed');
        const copied = await window.dictation.copy('Synthetic smoke test: no melena.');
        if (!copied.ok) throw new Error('Copy IPC failed');
        document.getElementById('draft').value = 'Synthetic smoke test: no melena.';
        document.getElementById('draft').dispatchEvent(new Event('input'));
        if (document.getElementById('count').textContent !== '5 words') throw new Error('Editor JavaScript not active');
        return { title: document.title, controls: document.querySelectorAll('button').length };
      })()`);
      if (await clipboard.readText() !== 'Synthetic smoke test: no melena.') throw new Error('Native clipboard mismatch');
      await window.webContents.executeJavaScript('window.dictation.clear()');
      if (await clipboard.readText()) throw new Error('Clipboard not cleared');
      if (result.controls < 8) throw new Error('Missing UI controls');
      const image = await window.webContents.capturePage();
      fs.writeFileSync(path.resolve('smoke.png'), image.toPNG());
      clearTimeout(timer);
      console.log('Native Electron UI, IPC isolation and clipboard smoke passed:', result.title);
      app.exit(0);
    } catch (error) { console.error(error.message); clearTimeout(timer); app.exit(1); }
  });
});
require('../src/main.cjs');
