# Wispr Flow–style Dictation App for iPhone — Feasibility & Build Plan

## Context

The goal: hold a button, speak, and have cleaned-up text — filler words removed,
punctuation added — land in whatever app you are currently typing in. Essentially
Wispr Flow, on iPhone.

This document answers three questions: is it possible on iOS at all, what are the hard
limits, and should it be a native Xcode app or a PWA.

Decisions taken up front:

- **Audience:** personal use first, but no architectural choices that would block a later
  App Store release.
- **Transcription:** cloud ASR + LLM cleanup (the Wispr Flow approach).
- **Deliverable:** this document. No code yet.

> **Note on this document.** It was researched and written in a Linux container with no
> Xcode, no macOS and no iPhone. Nothing described here has been compiled, run or tested.
> Every verification step is something you perform on a Mac. Claims about Apple's behaviour
> are sourced at the bottom; the microphone question in particular is inferred from public
> evidence, not from a device.

---

## Verdict: native Xcode, not a PWA

**A PWA cannot build this product.**

There is no web API — on any browser, on any platform — that lets a web app install a system
keyboard. The entire value proposition is "text appears in the app you're already in", and
the only iOS mechanism for that is a custom keyboard extension. That is native-only.

The best a PWA can do is: open the web app, record, transcribe, copy to clipboard, then you
switch apps and paste. That is strictly worse than the dictation already built into iOS, so
it is not a viable v1.

Secondary PWA problems, for completeness:

- Microphone capture in an installed iOS PWA works but is historically flaky — including a
  well-known standalone-mode bug that uploads a 44-byte empty WAV instead of real audio.
- The microphone is muted shortly after the app backgrounds; iOS heavily restricts
  background activity for PWAs.
- No Action Button integration, no Shortcuts, no App Store presence.

**The one legitimate use for a web build** is as a throwaway quality harness — a page that
records and runs the ASR + cleanup pipeline, so transcription quality can be tuned before
any Swift is written. That is Phase 1 below. It is genuinely worth doing, but it is a test
rig, not the product.

---

## The critical unknown: can a keyboard extension use the microphone?

This single question determines whether the product exists. The public evidence is
contradictory, so it is worth laying out both sides.

**Evidence against.** Apple's App Extension Programming Guide states that custom keyboards
have no access to the device microphone, so dictation input is not possible. Developers on
the Apple forums report the system refusing to start recording:

```
CMSUtility_IsAllowedToStartRecording: Client sid:0x2205e, ...
was NOT allowed to start recording because it is an extension
and doesn't have entitlements to record audio.
```

along with `AVAudioSession.setActive` failures (errors `561015905`, `561145187`). Several of
these threads have zero replies, and the common community recommendation is to give up and
have the containing app do the recording.

**Evidence for.** Wispr Flow ships exactly this on the App Store, rated 4.8 across 8,500+
reviews. Their own help documentation states the requirements plainly:

- Full Access must be enabled: *Settings → General → Keyboard → Keyboards → Flow → Allow
  Full Access.*
- **Microphone permission must be granted from the main app — it cannot be granted from the
  keyboard.**
- *"Missing Full Access can look like a microphone failure — check it first if dictation
  doesn't start."*

That last line is telling: it describes precisely the symptom the failing forum posts report.

**Reading.** It works, but only with the exact combination of:

1. `RequestsOpenAccess = true` in the extension's `Info.plist`,
2. Full Access enabled by the user in Settings, and
3. microphone permission already granted via the containing app.

The forum posters hitting the entitlement error were most likely missing (2) or (3). This is
under-documented and Apple could tighten it at any point, so it is a genuine platform risk
rather than a settled fact.

**Phase 0 exists to prove this on a real device before any other work happens.**

---

## Hard limitations

These do not go away with better engineering.

### Platform shape

1. **No global push-to-talk.** iOS has no equivalent of the macOS hold-a-key-anywhere
   trigger. Dictation only happens through the keyboard, which means tapping the globe key
   to switch keyboards first, every single time. This is the biggest UX gap versus the
   desktop version and it is not solvable.
2. **No background or always-on listening, and no wake word.**
3. **Secure text fields disable third-party keyboards.** iOS forcibly swaps in the system
   keyboard for password fields. You cannot dictate passwords. This is correct behaviour but
   will read as a bug to users.
4. **Some apps and MDM-managed devices block third-party keyboards outright.**

### Keyboard extension sandbox

5. **~48MB memory cap.** Exceed it and the keyboard is killed mid-use. This rules out
   running Whisper locally inside the keyboard — a quantised tiny model plus audio buffers
   does not fit. Cloud ASR is not merely a preference here, it is close to forced.
6. **Truncated surrounding context.** `documentContextBeforeInput` is limited and unreliable
   in some host apps (notably Chrome and web-view-based apps), so context-aware formatting
   is meaningfully weaker than on desktop.
7. **Editing is fragile.** "Delete that last sentence" means looping `deleteBackward()`;
   there is no reliable text-selection API across host apps.
8. **Network round-trip latency floor.** Cloud ASR means you cannot beat roughly 600–900ms
   without streaming. See Phase 4.

### App Store rules (Guideline 4.4.1)

These bite even though the plan starts with personal use, because the stated goal is to keep
the App Store path open. Verbatim, a keyboard extension must:

> - Provide keyboard input functionality (e.g. typed characters);
> - Provide a method for progressing to the next keyboard;
> - Remain functional without full network access and without requiring full access;
> - Collect user activity only to enhance the functionality of the user's keyboard extension
>   on the iOS device.

and must not:

> - Launch other apps besides Settings; or
> - Repurpose keyboard buttons for other behaviors.

Consequences:

9. **A mic-only keyboard is rejected.** You must build a real QWERTY layout — a genuinely
   non-trivial work item that is routinely forgotten when budgeting this project.
10. **The keyboard must work with Full Access off and with no network.** The typing layout
    has to stand alone, with the mic button degrading into a "turn on Full Access"
    affordance.
11. **"Must not launch other apps besides Settings" kills the common workaround.** The
    architecture the Apple forums recommend — keyboard triggers the main app to record, text
    comes back via an App Group — is *not* App Store legal. It stays available for personal
    sideloaded use, but adopting it forecloses the App Store option.
12. A next-keyboard (globe) control is mandatory.
13. Sending audio off-device requires a privacy policy and accurate privacy nutrition labels,
    and keyboards requesting Full Access attract extra review scrutiny.

---

## Architecture

```
┌──────────────────────┐     ┌──────────────────────────┐
│  Container app       │     │  Keyboard extension      │
│  (SwiftUI)           │     │  (UIInputViewController) │
│                      │     │                          │
│  • mic permission    │     │  • QWERTY layout         │
│  • Full Access       │     │  • mic button            │
│    onboarding        │     │  • AVAudioEngine tap     │
│  • settings, history │     │  • streams audio out     │
│  • custom vocabulary │     │  • insertText() result   │
└──────────┬───────────┘     └────────────┬─────────────┘
           │                              │
           └────── App Group + ───────────┘
                  Keychain sharing
             (auth token, settings, vocab)
                              │
                              ▼
                  ┌───────────────────────┐
                  │  Thin proxy server    │
                  │  • holds API keys     │
                  │  • streaming ASR      │
                  │  • LLM cleanup pass   │
                  └───────────────────────┘
```

**Why a proxy server rather than calling the ASR provider directly from the device.** An API
key shipped in an app binary is extractable. Personal-only use could skip this, but adding
it later means re-plumbing authentication throughout. A single Cloudflare Worker or small
Fly.io service is a few hours of work and keeps the App Store path viable.

**Shared state** lives in an App Group container (settings, custom vocabulary, history), with
the auth token in a shared Keychain access group. The keyboard extension cannot read the
container app's private storage any other way.

**The cleanup prompt** is what decides whether this feels magic or annoying. It must strip
filler and false starts, add punctuation and paragraph breaks, and respect a user dictionary
of names and jargon. Critically, it must **never answer or act on the dictated content**,
only reformat it — dictating *"what should I have for lunch"* must produce that sentence,
not a lunch suggestion. This is the classic failure mode of naive LLM cleanup and needs
explicit prompt defence plus eval coverage.

---

## Phases

### Phase 0 — De-risk spike (first, ~1–2 days on a Mac)

Nothing else is worth building until this passes.

Build a minimal Xcode project: container app plus keyboard extension, App Group configured,
`NSMicrophoneUsageDescription` in the container, `RequestsOpenAccess = true` in the
extension's `Info.plist`.

Then, **on a physical device** — the simulator is not trustworthy for this:

1. Grant microphone permission in the container app.
2. Enable Full Access in Settings.
3. From the keyboard, attempt `AVAudioSession` `.record` plus an `AVAudioEngine` input tap.

- **Pass condition:** you receive non-silent PCM buffers.
- **Test across hosts:** Messages, Notes, Mail, Safari, Chrome, Slack — behaviour varies by
  host app.
- **Also measure:** peak memory in Instruments against the ~48MB ceiling.
- **If it fails:** stop and reassess. The fallback — recording in the container app — costs
  an app-switch per dictation and gives up App Store eligibility per limitation 11.

### Phase 1 — Backend and quality harness

Stand up the proxy service with streaming ASR plus LLM cleanup. Build a plain web page
against it for recording and evaluation; this is where the throwaway web build earns its
keep, since transcription quality can be iterated without Xcode in the loop.

Assemble 30–50 recorded utterances covering fast speech, accents, domain jargon and
background noise, each with a hand-written target output. Track word error rate, cleanup
quality, and p50/p95 latency. Include adversarial cases — questions and commands — to verify
the model reformats rather than responds.

### Phase 2 — Container app

Onboarding that walks through microphone permission and Full Access (deep-linking into
Settings is permitted), authentication, settings, custom vocabulary, and dictation history.
Add an App Intent so the Action Button and Shortcuts can capture a quick note — a
disproportionate win for the effort.

### Phase 3 — Keyboard extension

Full QWERTY layout (mandatory, and the single biggest work item), globe key, mic button
supporting both hold-to-talk and tap-to-toggle, live waveform, streaming partial results,
`insertText()` on completion, and undo-last-dictation. Graceful degradation when Full Access
is off. Strict memory discipline throughout: stream audio out, retain no buffers, no local
model.

### Phase 4 — Latency

Begin streaming on the first audio frame rather than on button release — this is most of why
Wispr feels instant. Encode to Opus or AAC to cut upload size. Target p50 under ~1.2s from
release to inserted text. Add an offline queue.

### Phase 5 — App Store prep (only if pursued)

Privacy nutrition labels, privacy policy, subscription billing, and review notes explaining
why Full Access is required. Re-audit against every 4.4.1 rule above.

---

## Running cost

Cheap enough to be a non-issue for personal use.

| Component | Approximate rate |
|---|---|
| Groq `whisper-large-v3-turbo` | ~$0.04 / hour of audio |
| Deepgram Nova-3 | ~$0.0043 / min |
| OpenAI Whisper | ~$0.006 / min |
| LLM cleanup (Haiku-class) | ~$0.001 / utterance |

Heavy personal use at ~30 minutes of dictation per day lands around **$5/month**. That
recurring cost floor is why Wispr Flow charges a $12/month subscription rather than selling
the app outright — worth knowing if this ever stops being personal.

---

## Next steps

1. Review the Xcode-vs-PWA reasoning above and confirm it matches intent.
2. On a Mac, execute **Phase 0** exactly as specified. That spike either confirms the product
   is buildable or forces the fallback architecture; everything downstream depends on it.
3. Report the spike result, then proceed to the Phase 1 backend and cleanup prompt — which,
   unlike the iOS work, is testable without a Mac.

---

## Sources

- [App Extension Programming Guide: Custom Keyboard](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html) — states extensions have no microphone access
- [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) — section 4.4.1, keyboard extension rules
- [Recording audio in keyboard extension](https://developer.apple.com/forums/thread/742601) — entitlement error report
- [Error 561145187 — Recording audio from keyboard extension](https://developer.apple.com/forums/thread/775077)
- [Record microphone in a Keyboard app](https://developer.apple.com/forums/thread/800500) — the app-group workaround pattern
- [Set up the Flow keyboard on iPhone — Wispr Flow](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone) — Full Access + container-app mic permission requirements
- [Wispr Flow: AI Voice Keyboard — App Store](https://apps.apple.com/us/app/wispr-flow-ai-voice-keyboard/id6497229487)
- [Limitations of custom iOS keyboards](https://medium.com/@inFullMobile/limitations-of-custom-ios-keyboards-3be88dfb694)
- [React Native iOS custom keyboard 48MB memory limit](https://github.com/facebook/react-native/issues/31910)
- [PWA iOS Limitations and Safari Support (2026)](https://www.magicbell.com/blog/pwa-ios-limitations-safari-support-complete-guide)
- [Audio Recorder in iOS in PWA standalone mode](https://forum.zeroqode.com/t/audio-recorder-in-ios-in-pwa-standalone-mode/4029) — 44-byte WAV bug
- [WKWebView getUserMedia microphone gets muted in background](https://developer.apple.com/forums/thread/689182)
