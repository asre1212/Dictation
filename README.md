# Dictation

A Wispr Flow–style dictation app for iPhone: hold a button, speak, and have
cleaned-up text — filler words removed, punctuation added — land in whatever
app you are currently typing in.

## Status

Planning. No code yet.

## Documents

- [iPhone Dictation — Feasibility & Build Plan](docs/iphone-dictation-feasibility.md)
  — whether this is buildable on iOS, the hard platform limits, native-vs-PWA,
  architecture, a six-phase build plan starting with a de-risk spike, and
  running costs.

## Summary of the plan

- **Native Xcode, not a PWA.** No web API on any platform can install a system
  keyboard, and a custom keyboard extension is the only iOS mechanism for
  inserting text into another app.
- **Phase 0 gates everything.** Whether a keyboard extension can actually use
  the microphone must be proven on a physical device before any other work.
- **App Store guideline 4.4.1** forces a real QWERTY layout, operation without
  Full Access, and rules out the "keyboard triggers the main app" workaround.
