# Dictation proxy

The service the iOS app talks to. It holds the provider API keys so the app does
not have to — a key shipped in an app binary is extractable by anyone who
downloads it, and re-plumbing authentication later is far more work than putting
this in front from the start.

Roughly 300 lines and a few dollars a month at personal volume.

## What it does

1. Takes 16 kHz mono PCM from the app.
2. Wraps it in a WAV container and sends it to a speech recogniser.
3. Runs the transcript through a cleanup pass that strips filler and adds
   punctuation.
4. Returns the cleaned text, plus the raw transcript so the app can show you what
   cleanup changed.

## Deploying

```bash
cd server
npm install

# Secrets. None of these belong in wrangler.toml.
wrangler secret put GROQ_API_KEY        # speech recognition
wrangler secret put ANTHROPIC_API_KEY   # cleanup pass
wrangler secret put AUTH_TOKEN          # what the app sends as its bearer token

npm run deploy
```

Generate the auth token with something like `openssl rand -hex 32`, then put the
worker's URL and that token into the app's Settings screen. The app requires
https and refuses anything else.

## Endpoints

Both require `Authorization: Bearer <AUTH_TOKEN>`.

### `POST /v1/dictate`

`multipart/form-data`:

| Field | Type | |
|---|---|---|
| `audio` | binary | headerless 16-bit little-endian mono PCM |
| `sample_rate` | text | e.g. `16000` |
| `encoding` | text | `pcm_s16le` |
| `options` | JSON | `{style, vocabulary, context, locale}` |

Returns `{"text": "...", "raw_text": "..."}`.

### `GET /v1/stream` (WebSocket)

```
→ {"type":"start","sample_rate":16000,"encoding":"pcm_s16le","options":{…}}
→ binary frames of PCM, sent while the user is still speaking
→ {"type":"stop"}
← {"type":"final","text":"…","raw_text":"…"}
← {"type":"error","message":"…"}          on failure
```

**What this does and does not buy you.** The upload finishes while you are still
speaking instead of after you stop, which is real latency removed. But
recognition here still starts at `stop` — the socket accumulates audio rather
than feeding a live recogniser. To close the rest of the gap, replace the
`stop` handler with a provider that accepts a streaming socket of its own
(Deepgram, AssemblyAI) and emit `{"type":"partial","text":"…"}` frames as
interim results arrive. The app already renders those.

## Configuration

| Binding | Kind | Default | |
|---|---|---|---|
| `GROQ_API_KEY` | secret | — | speech recognition |
| `ANTHROPIC_API_KEY` | secret | — | cleanup pass |
| `AUTH_TOKEN` | secret | — | shared secret with the app |
| `ASR_MODEL` | var | `whisper-large-v3-turbo` | |
| `CLEANUP_MODEL` | var | `claude-haiku-4-5` | on the latency path for every utterance |
| `CLEANUP_ALWAYS` | var | unset | run cleanup even in verbatim mode |

## The cleanup prompt

The one thing worth being careful about. Its job is to reformat, never to
respond: dictating *"what should I have for lunch"* has to produce that
sentence, not a lunch suggestion. That is the classic failure of naive LLM
cleanup, and the prompt defends against it explicitly — the transcript arrives
inside delimiters, labelled as data rather than instruction.

If cleanup returns nothing, or returns something wildly longer than the input,
the raw transcript is used instead. A worse transcript beats a hallucinated one.

Before trusting the prompt, build the eval set from Phase 1 of
`docs/iphone-dictation-feasibility.md`: 30–50 recorded utterances with
hand-written target output, including adversarial ones — questions and commands
— to check the model reformats rather than answers.

## Costs

Around **$5/month** at roughly 30 minutes of dictation a day. Recognition
dominates; the cleanup pass is a fraction of a cent per utterance.
