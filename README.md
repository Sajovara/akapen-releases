# Akapen 赤ペン

**Akapen** ("red pen") is a Japanese grammar trainer – from N5 all the way to N1.
Think spaced repetition like Anki, but for grammar, and with a focus on *output*:
you write the Japanese yourself and get corrections, instead of clicking multiple choice.

- A learning path in short units, one grammar point at a time, with lessons, typed exercises, reading, listening and writing tasks
- Spaced repetition (FSRS) that plans your day: open it once, work through today's steps, done
- Conversation practice and writing feedback with an AI – a local model (e.g. Ollama) or Claude, your choice; works without AI too
- Optional Anki integration: review your vocabulary decks inside the app and get exercises built around words you know
- Runs on your own computer or on your own server (use it from your phone as a web app) – your learning data stays with you
- A guided setup on first start walks you through everything

## Download

Get the latest version from the **[Releases page](https://github.com/Sajovara/akapen-releases/releases/latest)**:

| System | File |
| --- | --- |
| Windows 10/11 (64-bit) | `Akapen-Setup-<version>.exe` – run the installer |
| Linux (64-bit, any distro) | `Akapen-<version>.AppImage` – make it executable (`chmod +x`) and start it |
| Debian / Ubuntu | `akapen-desktop_<version>_amd64.deb` – `sudo apt install ./akapen-desktop_<version>_amd64.deb` |

macOS is not available yet.

## System requirements

- 64-bit Windows 10/11 or Linux (x64)
- About 1 GB of disk space, more if you use offline speech recognition (the model is downloaded on demand)
- Optional: [Anki](https://apps.ankiweb.net/) with the AnkiConnect add-on, [Ollama](https://ollama.com/) for a free local AI, [VOICEVOX](https://voicevox.hiroshiba.jp/) for natural Japanese voices

The installers are not code-signed yet, so Windows SmartScreen may warn you – choose "More info" → "Run anyway".

## Source code

Akapen's source code is not public. This repository only hosts the installers and release notes.
If you find a bug or have an idea, feel free to open an issue here.
