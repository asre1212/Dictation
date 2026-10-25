const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('dictation', {
  state: () => ipcRenderer.invoke('state'),
  loadModel: (model, download) => ipcRenderer.invoke('load-model', { model, download }),
  startSession: address => ipcRenderer.invoke('start-session', address),
  stopSession: () => ipcRenderer.invoke('stop-session'),
  copy: text => ipcRenderer.invoke('copy', text),
  clear: () => ipcRenderer.invoke('clear'),
  subscribe: callback => { const listener = (_event, value) => callback(value); ipcRenderer.on('dictation:event', listener); return () => ipcRenderer.removeListener('dictation:event', listener); }
});
