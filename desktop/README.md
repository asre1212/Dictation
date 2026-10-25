# Dictation Desktop — Mac and Windows companion

The native iPhone app's **Desktop** tab records up to 60 seconds and sends 16 kHz mono PCM directly to this companion over pinned HTTPS. Whisper runs locally using Hugging Face Transformers.js. Review/edit the resulting draft, then explicitly copy it into the intended chart.

This is a development build, not a certified or institution-approved clinical product. Use synthetic examples until device testing, clinical accuracy validation and your organization's security review are complete. See [HIPAA deployment requirements](../docs/hipaa-readiness.md).

## Install

Download the platform artifact from the latest successful [Desktop companions workflow](https://github.com/asre1212/Dictation/actions/workflows/desktop.yml):

| Computer | Artifact | Contents |
|---|---|---|
| Apple Silicon Mac | Dictation-Mac-Apple-Silicon | DMG and ZIP |
| Intel Mac | Dictation-Mac-Intel | DMG and ZIP |
| Windows x64 | Dictation-Windows-x64 | Installer and portable EXE |

These initial builds are unsigned and macOS is not notarized. OS or institutional policy may block them. Production distribution needs signing/notarization; do not disable institutional protections. Windows ARM is not a validated target.

For development, install Node.js 22 or newer, then:

```sh
cd desktop
npm ci
npm start
```

## First connection

1. Desktop: choose **Whisper Base English** (faster) or **Whisper Small English** (more capable but slower). Click **Download model** once. This downloads model assets from Hugging Face, without sending dictation. Later use **Load cached** offline.
2. Select the computer's Wi-Fi/Ethernet or private VPN address, then **Start pairing**. Approve the OS firewall prompt only for the intended private network.
3. Build/install the updated iPhone app from the repo's Xcode project with your Apple signing team. In setup choose **Use Desktop mode**. No cloud-server API key or keyboard Full Access is needed for this mode.
4. On iPhone, open **Desktop → Scan pairing QR**. Allow camera/local-network access and authenticate with Face ID/Touch ID/device passcode. Manual pairing links are also supported; treat them as secrets.
5. Start dictation, then **Stop & transcribe**. Keep the app in the foreground. The draft appears on both devices; edit and review on the computer before **Copy reviewed text**.
6. Paste into the intended patient chart. Confirm names, doses, units, dates, numbers, medical terms and negation. End the session when finished.

Speech recognition is after each recording, not live streaming. No automatic typing into another app, direct Epic integration or chart write-back is performed. Citrix clipboard use depends on institutional policy.

## Connectivity and privacy

- Same Wi-Fi/Ethernet works when peer-to-peer traffic is permitted. Guest/hospital networks often isolate devices.
- Different networks/cellular require a reachable **organization-approved private VPN** address. Bluetooth is not used. With no network path between devices, transfer cannot work.
- No public relay or cloud transcription is used by Desktop mode. Do not expose the receiver with router port forwarding.
- TLS 1.2+ and exact SHA-256 certificate pinning from the QR; a random 256-bit pairing token; one paired phone per session; no global certificate/ATS bypass.
- QR codes expire after 10 minutes before pairing. Sessions end after 30 minutes without an authenticated operation or 8 hours total. Sleep/screen lock ends the desktop session; backgrounding/leaving the iPhone screen clears the iPhone side. The desktop must start a new session before that phone reconnects.
- Drafts/audio are not intentionally written to disk. Recent transcript responses are held in memory for at most 5 minutes for reliable retry; delivery IDs survive until the session ends. Raw audio buffers are released after use. Garbage collection, OS swap, crash dumps and clipboard services remain deployment risks—memory-only is not secure erasure.
- Copy is explicit. The app clears its own unchanged clipboard text after 2 minutes or when clearing/ending a session. Clipboard managers, cloud sync and another app's copies cannot be recalled.
- Cached **model files** are stored in the Electron user-data `models/` directory. There is no draft backup/restore or cloud synchronization.
- The original **Dictate** tab/custom keyboard still uses the repo's existing cloud proxy and history. It is a separate path and is not covered by these local-mode assurances.

## Hugging Face choices

| Implemented | Purpose |
|---|---|
| Transformers.js 3.8.1 | Local CPU inference in a separate worker thread |
| `Xenova/whisper-base.en`, Q8 | Lower memory/faster starting point |
| `Xenova/whisper-small.en`, Q8 | Optional larger English model |
| Immutable model revision pins | Avoid silent model changes |
| Basic energy screening | Avoid transcribing fully silent clips; not a full speech-activity detector |

No medical accuracy claim is made for either general-purpose model. The UI provides a GI spelling reference and explicit, undoable “new line/new paragraph” formatting. It does not silently correct medication names, infer diagnoses or use an LLM to rewrite a note.

Future candidates: medically fine-tuned Whisper after license/dataset provenance and held-out GI testing; Silero VAD to segment longer audio; distilled models after benchmarking. A model being on Hugging Face does not establish medical validity or HIPAA suitability. Do not upload patient audio to a public Space or inference service.

## Development checks

```sh
npm test
npm run dist
```

Tests use synthetic PCM and exercise HTTPS pinning, pairing/authentication, device isolation, upload limits, expired sessions, duplicate retries and clinical text preservation. GitHub Actions builds Apple Silicon, Intel Mac and Windows packages. The existing iOS workflow compiles app and keyboard targets.

Physical-device testing remains necessary: QR/camera and Face ID permissions, certificate challenges on iOS, microphone interruptions, network isolation, firewall/VPN connectivity, sleep/lock cleanup, and speech accuracy on actual hardware.

## Sources reviewed

- [Hugging Face Transformers.js](https://huggingface.co/docs/transformers.js/v3.8.1/index)
- [Whisper Small English ONNX model card](https://huggingface.co/Xenova/whisper-small.en)
- [Electron security recommendations](https://www.electronjs.org/docs/latest/tutorial/security)
- [Electron code signing](https://www.electronjs.org/docs/latest/tutorial/code-signing)
- [HHS HIPAA Security Rule](https://www.hhs.gov/hipaa/for-professionals/security/laws-regulations/index.html)
