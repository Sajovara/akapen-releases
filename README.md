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
| Debian / Ubuntu | `akapen_<version>_amd64.deb` – `sudo apt install ./akapen_<version>_amd64.deb` |

macOS is not available yet.

## Install on your own server without giving the app your password

The desktop app can set up a server for you (Proxmox or a Debian/Ubuntu machine) – it then needs the server's root password.
If you'd rather not hand that over, run the installer yourself. The app shows you these same lines ("Rather do it yourself?") and checks the result.

**Proxmox** – in the Proxmox web interface click your node (e.g. `pve`) → **Shell** and paste:

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sajovara/akapen-releases/v0.1.20/install/proxmox.sh)"
```

It asks a few questions (Anki via AnkiWeb login or none, VOICEVOX voices, Tailscale for your phone), creates a new container for Akapen (Debian, unprivileged, 4 cores, 6–8 GB RAM, 24 GB disk, starts with the host) and installs everything inside. Other containers and VMs are not touched.

**Debian 12+ / Ubuntu 22.04+ machine** – in a terminal on it:

```sh
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sajovara/akapen-releases/v0.1.20/install/server.sh)"
```

At the end both print the address to enter in the app, e.g. `http://192.168.1.50:4750`.

**Updating** – on the server, or on the Proxmox host's shell (it finds the Akapen container):

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sajovara/akapen-releases/v0.1.20/install/update.sh)"
```

Your learning data stays. Then press "Check" in the app.

Good to know:

- The scripts are short and readable – download one first (`curl -fsSLO <url>`), read it, then run it with `bash`.
- Each script is pinned to its release: it downloads that release's `akapen-server-<version>.tar.gz` and refuses to continue if it doesn't match the SHA-256 checksum written into the script. Nothing is changed before that check.
- Your AnkiWeb password is typed hidden, goes only to the server's Anki and is deleted after logging in. Passwords are never printed or logged.
- Running a script again is safe: it picks up where it stopped, your progress stays.
- No questions (for automation): set the answers as variables, e.g. `AKAPEN_YES=1 AKAPEN_ANKI=none AKAPEN_VOICEVOX=0 AKAPEN_TAILSCALE=1`; Proxmox also takes `AKAPEN_VMID`, `AKAPEN_HOSTNAME`, `AKAPEN_STORAGE`, `AKAPEN_BRIDGE`. The top of each script lists them all.

## System requirements

- 64-bit Windows 10/11 or Linux (x64)
- About 1 GB of disk space, more if you use offline speech recognition (the model is downloaded on demand)
- Optional: [Anki](https://apps.ankiweb.net/) with the AnkiConnect add-on, [Ollama](https://ollama.com/) for a free local AI, [VOICEVOX](https://voicevox.hiroshiba.jp/) for natural Japanese voices

The installers are not code-signed yet, so Windows SmartScreen may warn you – choose "More info" → "Run anyway".

## Source code

Akapen's source code is not public. This repository only hosts the installers and release notes.
If you find a bug or have an idea, feel free to open an issue here.
