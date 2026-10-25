import { parentPort, workerData } from 'node:worker_threads';
import { pipeline, env } from '@huggingface/transformers';
import { pcmToFloat32, hasSpeechEnergy } from './protocol.mjs';
import { MODELS } from './models.mjs';
env.cacheDir = workerData.cacheDir;
env.allowLocalModels = true;
// local_files_only forbids network access while loading cached model assets.
let recognizer; let activeModel;
parentPort.on('message', async ({ id, action, model, pcm, download = false }) => {
  try {
    if (action === 'load') {
      const selected = MODELS[model];
      if (!selected) throw new Error('Unknown model');
      if (recognizer && activeModel !== model) { await recognizer.dispose(); recognizer = null; }
      if (!recognizer) recognizer = await pipeline('automatic-speech-recognition', selected.id, {
        dtype: 'q8', device: 'cpu', revision: selected.revision,
        local_files_only: !download,
        progress_callback: progress => parentPort.postMessage({ type: 'progress', progress: { status: progress.status, progress: progress.progress } })
      });
      activeModel = model;
      parentPort.postMessage({ id, ok: true });
    } else {
      if (!recognizer) throw new Error('Load a model first');
      const samples = pcmToFloat32(pcm);
      try {
        if (!hasSpeechEnergy(samples)) parentPort.postMessage({ id, text: '' });
        else {
          const result = await recognizer(samples, { chunk_length_s: 30, stride_length_s: 5, return_timestamps: false, do_sample: false });
          parentPort.postMessage({ id, text: result.text.trim() });
        }
      } finally { samples.fill(0); pcm.fill(0); }
    }
  } catch { parentPort.postMessage({ id, error: action === 'load' ? 'Model load failed. Use Download model while online, then try again.' : 'Local transcription failed. Try a shorter recording.' }); }
});
