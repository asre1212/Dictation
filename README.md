# Dictation

Hold a key, speak, and get cleaned-up text — filler words removed, punctuation
added — inserted into whatever app you are typing in. An iOS custom keyboard
plus the container app that configures it.

**Status: written, never compiled.** All of this was written on Linux with no
Xcode, no macOS and no device. It has not been built or run. Treat the first
build as part of the work, and read
[the feasibility document](docs/iphone-dictation-feasibility.md) before starting
— the whole product rests on one unproven assumption.

## The assumption

A custom keyboard extension is the only mechanism iOS gives you for putting text
into another app. Whether such an extension can open the microphone is genuinely
unsettled: Apple's own documentation says it cannot, and the developer forums
are full of people failing at it, but keyboards doing exactly this ship on the
App Store today.

The evidence points to it working with Full Access enabled *and* microphone
permission already granted by the container app. **Phase 0 of the plan exists to
prove that on a physical device before anything else is built on top of it.**

## Layout

```
Dictation.xcodeproj      two targets: the app and the keyboard
Dictation/               container app (SwiftUI) — setup, settings, history, capture
DictationKeyboard/       keyboard extension (UIKit) — QWERTY, mic, waveform
Shared/                  compiled into both targets
server/                  the proxy the app talks to (Cloudflare Worker)
docs/                    feasibility and build plan
project.yml              XcodeGen spec the .xcodeproj is generated from
scripts/build-check.sh   compile both targets without needing a signing identity
```

`Shared/` is compiled into both targets rather than being a framework: it is ten
small files, and a framework would mean a third signed binary and a dynamic-link
cost paid on every keyboard launch.

## Getting it running

### 1. Compile it

```bash
scripts/build-check.sh
```

Builds both targets for the simulator with signing switched off, so it works
before any of the signing setup below. Since none of this has been through a
compiler, do this first and fix what it reports.

### 2. Signing

Open `Dictation.xcodeproj` and set your team on **both** targets under Signing &
Capabilities. Or from the command line:

```bash
scripts/build-check.sh DEVELOPMENT_TEAM=XXXXXXXXXX
```

Your team ID is the ten-character string in
[developer.apple.com/account](https://developer.apple.com/account) under
Membership.

### 3. App Group

Both targets need `group.com.asre1212.dictation`. If you change the identifier,
change it in `Shared/AppGroup.swift` and both `.entitlements` files too. The
app's Settings screen reports whether the group is actually working — a
misconfiguration here shows up as "the keyboard ignores my settings" and is
otherwise very hard to spot.

The same identifier doubles as the Keychain access group, which avoids
hard-coding a team-prefixed string that changes with the signing identity.

### 4. Server

Deploy `server/` and note its URL and auth token. See
[server/README.md](server/README.md).

### 5. On the device

Run the app and allow the microphone, then
Settings › General › Keyboard › Keyboards › Add New Keyboard › Dictation, and
turn on **Allow Full Access**. Both are required, and neither can be done from
the keyboard itself — that is the whole reason the container app exists.

## How it fits together

```
┌──────────────────────┐     ┌──────────────────────────┐
│  Container app       │     │  Keyboard extension      │
│  (SwiftUI)           │     │  (UIInputViewController) │
│                      │     │                          │
│  • mic permission    │     │  • QWERTY layout         │
│  • Full Access       │     │  • mic key               │
│    onboarding        │     │  • AVAudioEngine tap     │
│  • settings, history │     │  • streams audio out     │
│  • custom vocabulary │     │  • insertText() result   │
└──────────┬───────────┘     └────────────┬─────────────┘
           │                              │
           └────── App Group + ───────────┘
                  Keychain sharing
                              │
                              ▼
                  ┌───────────────────────┐
                  │  Proxy (server/)      │
                  │  • holds API keys     │
                  │  • speech recognition │
                  │  • LLM cleanup pass   │
                  └───────────────────────┘
```

## Constraints worth knowing before you read the code

These are platform facts, not implementation gaps.

- **No global push-to-talk.** Dictation only happens through the keyboard, so you
  tap the globe key to switch to it first, every time. There is no way around
  this on iOS. The Action Button intent is the partial workaround.
- **~48 MB memory ceiling** in the extension, enforced by killing it. That rules
  out running a speech model locally and is why recognition is a network call.
- **Secure text fields** force the system keyboard. You cannot dictate passwords.
- **A real QWERTY layout is mandatory.** App Store guideline 4.4.1 requires the
  keyboard to type, and to keep working with Full Access off and no network. A
  microphone-only keyboard is rejected. It is also the largest single piece of
  code here.
- **The keyboard must not launch other apps.** That forecloses the workaround the
  Apple forums recommend — keyboard wakes the container app to record — so the
  microphone is opened inside the extension or not at all.

## Next

Phase 0 in [the plan](docs/iphone-dictation-feasibility.md): build to a device,
grant the microphone, enable Full Access, and confirm the keyboard receives
non-silent audio buffers across several host apps. Everything downstream depends
on the answer.
