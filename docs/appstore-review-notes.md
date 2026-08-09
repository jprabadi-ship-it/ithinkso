# App Review Notes (English — paste into App Store Connect "Notes" field)

## What this app does

"I think so" is a menu bar utility for Japanese users who type with two
input modes (Japanese IME and English). When the user types in the wrong
mode (e.g., Japanese romaji while still in English mode), the text comes
out garbled. The app lets the user press the JIS kana key twice to have
the mistyped text deleted and retyped in the correct input mode.

This is the app's single, entire function. It has no network capability,
no data persistence, and no UI beyond a menu bar item.

## Why the app requests Input Monitoring and Accessibility

The core feature is technically impossible without two TCC permissions:

1. **Input Monitoring (ListenEvent)** — the app uses a CGEventTap to
   (a) detect the kana-key double-press that triggers the retype, and
   (b) remember the most recent run of typed characters so it knows what
   to retype. The buffer is kept only in memory, is cleared on every
   Space/Return/Escape/modifier shortcut, and is never written to disk
   or transmitted anywhere. The app contains no networking code.

2. **Accessibility (PostEvent only)** — to perform the retype, the app
   posts keyboard events with CGEvent.post: Backspace events to remove
   the mistyped text and key events to re-enter it through the Japanese
   IME. Note that this permission appears as "Accessibility" in System
   Settings, but the app only uses the event-posting capability gated by
   it; it does not use AXUIElement or read any UI content of other apps.

Regarding Guideline 2.4.5: the app does not use accessibility features
for any purpose other than its stated, user-visible function. Posting
keyboard events IS the product — identical in spirit to text-expansion
utilities. Every event the app posts is the direct, immediate result of
an explicit user gesture (the kana-key double-press); the app never
posts events on its own initiative.

## How to test

Requirements: a Mac with Japanese – Romaji input source enabled and a
JIS keyboard layout (or any keyboard that can send the kana key,
keycode 104).

1. Launch the app (menu bar icon appears; grant Input Monitoring and
   Accessibility when prompted, then relaunch if needed).
2. In TextEdit, with the ABC input source active, type:
   `sonocheckma-kuhadokomadegahannidesuka`
3. Press the kana key twice quickly (within 0.35 s).
4. The ASCII text is deleted and retyped through the Japanese IME,
   producing 「そのcheckマークはどこまでが範囲ですか」 (the English word
   "check" is preserved; the rest becomes Japanese).
5. Reverse direction: with the Japanese input source active, type
   `gitcommit` (it appears as kana composition), then press the kana key
   twice. The composition is converted back to the literal romaji
   "gitcommit" and the input source switches to ABC.

## App Sandbox

The app is fully sandboxed (com.apple.security.app-sandbox = true).
Both required permissions are compatible with the App Sandbox.
