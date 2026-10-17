#!/usr/bin/env bash
# Akapen on this Debian/Ubuntu machine – run it yourself instead of giving
# the desktop app your password. As root (or with sudo), e.g.:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sajovara/akapen-releases/v<version>/install/server.sh)"
#
# Asks a few questions (Anki, voices, Tailscale), downloads the server code
# of this release (checked against its SHA-256), installs everything and
# prints the address to enter in the app. Safe to run again: your progress
# in /opt/akapen/data stays.
#
# Without questions (all optional, the defaults in brackets):
#   AKAPEN_ANKI=none|ankiweb|keep     Anki on the server [none; keep if there is a profile]
#   AKAPEN_ANKIWEB_FILE=<file>        AnkiWeb login as {"user": …, "password": …} (deleted after use);
#                                     otherwise AKAPEN_ANKI=ankiweb asks for e-mail and password
#   AKAPEN_VOICEVOX=0|1               natural voices, ~2 GB [0]
#   AKAPEN_TAILSCALE=0|1              phone / on the road [0]
#   AKAPEN_YES=1                      take the defaults, ask nothing
#   AKAPEN_VERSION=<x.y.z|latest>     another release than this script's
#   AKAPEN_TARBALL=<file>             use this server code instead of downloading it
# Also: server.sh --tailscale-start | --tailscale-serve   (used by proxmox.sh)
set -euo pipefail

REPO=Sajovara/akapen-releases
RELEASE="0.1.10"   # filled in when published (scripts/release.mjs)
SHA256="48e0a00820bba741de8d9af591f905ab11925cca6494acf5b42a6bd16086a2ae"
APP=/opt/akapen
LAN_PORT=4750
# a fresh container has no locales: the terminal's would make apt and perl complain
export LANG=C.UTF-8 LC_ALL=C.UTF-8 LANGUAGE=
case "$RELEASE" in @*) RELEASE= ;; esac
case "$SHA256" in @*) SHA256= ;; esac

# ---------- output and questions ----------
if [ -t 1 ]; then B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; D=$'\e[2m'; N=$'\e[0m'; else B= R= G= D= N=; fi
say() { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
die() { printf '\n%sStopped: %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
TTY=
if [ -z "${AKAPEN_YES:-}" ] && { : </dev/tty; } 2>/dev/null; then TTY=/dev/tty; fi
# ask <prompt> <default> → $REPLY (the default without a terminal)
ask() {
  REPLY="$2"
  [ -n "$TTY" ] || return 0
  read -r -p "$1 " REPLY <"$TTY" || true
  REPLY="${REPLY:-$2}"
}
yes_no() { # yes_no <question> <y|n> → 0 for yes
  local hint="[y/N]"; [ "$2" = y ] && hint="[Y/n]"
  ask "$1 $hint" "$2"
  case "$REPLY" in [yYjJ]*) return 0 ;; *) return 1 ;; esac
}
secret() { # secret <prompt> → $REPLY, not shown
  REPLY=
  [ -n "$TTY" ] || die "$1 is needed, but there is no terminal to ask in."
  read -r -s -p "$1 " REPLY <"$TTY" || true
  printf '\n'
}
flag() { case "${1:-}" in 1|y|yes|true) echo 1 ;; 0|n|no|false) echo 0 ;; *) echo "" ;; esac; }

# ---------- Tailscale (also called by proxmox.sh inside the container) ----------
ts_status() { tailscale status --json 2>/dev/null || true; }
ts_field() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" | head -1; }
tailscale_start() { # installs, starts the login; prints AKAPEN_LOGIN_URL=… or AKAPEN_TAILSCALE=running
  if ! command -v tailscale >/dev/null; then
    say "Installing Tailscale …"
    curl -fsSL https://tailscale.com/install.sh | sh >/root/tailscale-install.log 2>&1 || { tail -20 /root/tailscale-install.log; die "installing Tailscale failed."; }
  fi
  systemctl enable --now tailscaled >/dev/null 2>&1 || true
  [ -e /dev/net/tun ] || die "Tailscale needs the tun device (/dev/net/tun), and this machine has none."
  if [ "$(ts_status | ts_field BackendState)" = Running ]; then echo "AKAPEN_TAILSCALE=running"; return; fi
  # `tailscale up` waits for the login: it runs on as a transient service
  systemctl stop akapen-tailscale-up >/dev/null 2>&1 || true
  systemctl reset-failed akapen-tailscale-up >/dev/null 2>&1 || true
  rm -f /root/tailscale-up.log
  systemd-run --quiet --unit=akapen-tailscale-up --collect sh -c "exec tailscale up --hostname=$(hostname -s) >/root/tailscale-up.log 2>&1"
  local url
  for _ in $(seq 1 30); do
    sleep 1
    [ "$(ts_status | ts_field BackendState)" = Running ] && { echo "AKAPEN_TAILSCALE=running"; return; }
    url="$(ts_status | ts_field AuthURL)"
    [ -n "$url" ] || url="$(grep -o 'https://login.tailscale.com/[^ ]*' /root/tailscale-up.log 2>/dev/null | head -1 || true)"
    [ -n "$url" ] && { echo "AKAPEN_LOGIN_URL=$url"; return; }
  done
  cat /root/tailscale-up.log 2>/dev/null || true
  die "Tailscale didn't give a login address."
}
tailscale_serve() { # after the login: https for the phone; prints AKAPEN_TAILNET_URL=… or what is missing
  local st
  for _ in 1 2 3 4 5 6; do st="$(ts_status)"; [ "$(printf '%s' "$st" | ts_field BackendState)" = Running ] && break; sleep 1.5; done
  if [ "$(printf '%s' "$st" | ts_field BackendState)" != Running ]; then echo "AKAPEN_TAILSCALE=not-logged-in"; return; fi
  local out
  out="$(timeout 25 tailscale serve --bg 4748 2>&1)" || {
    local enable; enable="$(printf '%s' "$out" | grep -o 'https://login.tailscale.com/f/serve[^ ]*' | head -1 || true)"
    if [ -n "$enable" ]; then echo "AKAPEN_ENABLE_HTTPS_URL=$enable"; return; fi
    printf '%s\n' "$out"; echo "AKAPEN_TAILSCALE=serve-failed"; return
  }
  # the app lets in the tailnet's owner, read at start
  curl -fs -m 5 http://127.0.0.1:4747/api/settings | grep -q '"allowedLogins":\[[^]]*@' || systemctl restart akapen
  local name; name="$(printf '%s' "$st" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true)"
  echo "AKAPEN_TAILNET_URL=https://$name"
}
case "${1:-}" in
  --tailscale-start) tailscale_start; exit 0 ;;
  --tailscale-serve) tailscale_serve; exit 0 ;;
  "") ;;
  *) die "unknown option $1" ;;
esac

# ---------- is this a machine for it? ----------
say "${B}Akapen – server installation${N}${RELEASE:+ (release $RELEASE)}"
[ "$(id -u)" = 0 ] || die "please run this as root (or put sudo in front)."
[ "$(uname -m)" = x86_64 ] || die "this machine is $(uname -m); Akapen's server needs a normal 64-bit PC processor (x86_64)."
[ -d /etc/pve ] && die "this is a Proxmox host. Akapen doesn't go onto the host itself – run install/proxmox.sh instead, it makes a container for it."
. /etc/os-release 2>/dev/null || true
case "${ID:-}" in
  debian) [ "${VERSION_ID%%.*}" -ge 12 ] 2>/dev/null || die "Debian ${VERSION_ID:-?} is too old – Debian 12 or newer is needed." ;;
  ubuntu) [ "${VERSION_ID%%.*}" -ge 22 ] 2>/dev/null || die "Ubuntu ${VERSION_ID:-?} is too old – Ubuntu 22.04 or newer is needed." ;;
  *) die "this is ${PRETTY_NAME:-an unknown system}. Akapen's server installs on Debian (12+) or Ubuntu (22.04+) only." ;;
esac
[ -d /run/systemd/system ] || die "this system doesn't run systemd, which Akapen's services need."
say "${D}${PRETTY_NAME}, $(nproc) cores, $(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo) GB RAM${N}"
if [ -f "$APP/server/index.js" ]; then say "Akapen is already installed here – this installs it again. Your progress ($APP/data) stays."; fi

# ---------- questions ----------
ANKI="${AKAPEN_ANKI:-}"
HAVE_PROFILE=; [ -f /home/dojo/.local/share/Anki2/prefs21.db ] && HAVE_PROFILE=1
if [ -z "$ANKI" ]; then
  if [ -n "$TTY" ]; then
    say ""
    say "${B}Anki on the server?${N} Akapen can show your Anki reviews and use the words you know."
    [ -n "$HAVE_PROFILE" ] && say "  0) keep the Anki profile that is already here"
    say "  1) log in to AnkiWeb (downloads your collection)"
    say "  2) no Anki"
    ask "Choose${HAVE_PROFILE:+ [0]}${HAVE_PROFILE:- [2]}:" "${HAVE_PROFILE:+0}${HAVE_PROFILE:-2}"
    case "$REPLY" in 0) ANKI=keep ;; 1) ANKI=ankiweb ;; *) ANKI=none ;; esac
  else
    ANKI="${HAVE_PROFILE:+keep}"; ANKI="${ANKI:-none}"
  fi
fi
case "$ANKI" in none|ankiweb|keep) ;; *) die "AKAPEN_ANKI must be none, ankiweb or keep." ;; esac
[ "$ANKI" = keep ] && [ -z "$HAVE_PROFILE" ] && die "there is no Anki profile here to keep (AKAPEN_ANKI=keep)."
CREDS=
cleanup() { [ -n "$CREDS" ] && rm -f "$CREDS"; [ -n "${TMPD:-}" ] && rm -rf "$TMPD"; return 0; }
trap cleanup EXIT
if [ "$ANKI" = ankiweb ]; then
  CREDS="$(umask 077; mktemp /root/.akapen-ankiweb.XXXXXX)"
  if [ -n "${AKAPEN_ANKIWEB_FILE:-}" ]; then
    [ -f "$AKAPEN_ANKIWEB_FILE" ] || die "AKAPEN_ANKIWEB_FILE ($AKAPEN_ANKIWEB_FILE) doesn't exist."
    cat "$AKAPEN_ANKIWEB_FILE" >"$CREDS"; rm -f "$AKAPEN_ANKIWEB_FILE"
  else
    say "Your AnkiWeb login (the same as in Anki → Sync). It goes only to this machine's Anki and is deleted after the login."
    ask "AnkiWeb e-mail:" ""; AW_USER="$REPLY"
    [ -n "$AW_USER" ] || die "no AnkiWeb e-mail given."
    secret "AnkiWeb password (not shown):"; AW_PASS="$REPLY"
    [ -n "$AW_PASS" ] || die "no AnkiWeb password given."
    # JSON without the password ever being a command argument
    printf '%s\n%s' "$AW_USER" "$AW_PASS" | python3 -c 'import json,sys; u,p=sys.stdin.read().split("\n",1); json.dump({"user":u,"password":p}, open(sys.argv[1],"w"))' "$CREDS" 2>/dev/null \
      || { command -v python3 >/dev/null || die "python3 is missing (apt-get install python3)."; die "couldn't store the login."; }
    unset AW_PASS REPLY
  fi
fi
VOICEVOX="$(flag "${AKAPEN_VOICEVOX:-}")"
if [ -z "$VOICEVOX" ]; then VOICEVOX=0; yes_no "Install VOICEVOX (natural Japanese voices, ~2 GB download, ~2 GB RAM)?" n && VOICEVOX=1; fi
TAILSCALE="$(flag "${AKAPEN_TAILSCALE:-}")"
if [ -z "$TAILSCALE" ]; then TAILSCALE=0; yes_no "Set up Tailscale (use Akapen on your phone away from home)?" n && TAILSCALE=1; fi

# ---------- the code ----------
step "Server code"
TMPD="$(mktemp -d)"
need() { command -v "$1" >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${@:2}" >/dev/null; }; }
need tar tar
if [ -n "${AKAPEN_TARBALL:-}" ]; then
  [ -f "$AKAPEN_TARBALL" ] || die "AKAPEN_TARBALL ($AKAPEN_TARBALL) doesn't exist."
  CODE="$AKAPEN_TARBALL"
  say "from $CODE"
else
  need curl curl ca-certificates
  WANT="${AKAPEN_VERSION:-${RELEASE:-latest}}"
  if [ "$WANT" = latest ]; then
    WANT="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" | sed -n 's#.*/tag/v##p')"
    [ -n "$WANT" ] || die "couldn't find the latest release on GitHub."
  fi
  WANT="${WANT#v}"
  URL="https://github.com/$REPO/releases/download/v$WANT/akapen-server-$WANT.tar.gz"
  say "Akapen $WANT"
  curl -fsSL --retry 3 -o "$TMPD/code.tar.gz" "$URL" || die "couldn't download $URL"
  SUM="$SHA256"
  [ "$WANT" = "$RELEASE" ] && [ -n "$SUM" ] || SUM="$(curl -fsSL --retry 3 "$URL.sha256" | cut -d' ' -f1)"
  [ -n "$SUM" ] || die "no checksum for $URL"
  [ "$(sha256sum "$TMPD/code.tar.gz" | cut -d' ' -f1)" = "$SUM" ] || die "the download doesn't match its checksum – nothing was changed."
  say "${G}checksum ok${N} ${D}(sha256 $SUM)${N}"
  CODE="$TMPD/code.tar.gz"
fi
mkdir -p "$TMPD/x"
tar -xzf "$CODE" -C "$TMPD/x" --no-same-owner
[ -f "$TMPD/x/server/index.js" ] && [ -f "$TMPD/x/deploy/install.sh" ] || die "the server code is incomplete."
mkdir -p "$APP"
# code folders are replaced (removed files go), data/ and node_modules/ stay
for d in server public content vendor deploy; do rm -rf "${APP:?}/$d"; done
cp -a "$TMPD/x/." "$APP/"
say "in $APP"

# ---------- system, app ----------
step "System, Node.js$([ "$ANKI" = none ] || echo ", Anki") and the app (takes a few minutes)"
AKAPEN_ANKI="$([ "$ANKI" = none ] && echo 0 || echo 1)" bash "$APP/deploy/install.sh"

wait_app() {
  for _ in $(seq 1 60); do curl -fs -m 3 -o /dev/null http://127.0.0.1:4747/api/settings && return 0; sleep 2; done
  journalctl -u akapen -n 30 --no-pager; die "the app didn't start."
}

if [ "$ANKI" != none ]; then
  step "Anki"
  if [ "$ANKI" = ankiweb ]; then
    systemctl stop anki-headless 2>/dev/null || true
    install -o dojo -m 600 "$CREDS" /home/dojo/.akapen-ankiweb.json; rm -f "$CREDS"
    if ! out="$(runuser -u dojo -- env HOME=/home/dojo /opt/anki/bin/python "$APP/deploy/anki-profile.py" /home/dojo/.akapen-ankiweb.json 2>&1)"; then
      rm -f /home/dojo/.akapen-ankiweb.json
      printf '%s\n' "$out" | grep -v '^ERROR:' | tail -5
      die "$(printf '%s\n' "$out" | sed -n 's/^ERROR: //p' | head -1) Run this script again to retry."
    fi
    rm -f /home/dojo/.akapen-ankiweb.json
    printf '%s\n' "$out"
  fi
  bash "$APP/deploy/ankiconnect.sh"
  systemctl enable anki-headless >/dev/null 2>&1; systemctl restart anki-headless
  say "Waiting for Anki …"
  ok=
  for _ in $(seq 1 45); do curl -fs -m 3 -d '{"action":"version","version":6}' http://127.0.0.1:8765 | grep -q '"result"' && { ok=1; break; }; sleep 2; done
  [ -n "$ok" ] || { journalctl -u anki-headless -n 30 --no-pager; die "Anki started, but AnkiConnect doesn't answer."; }
  curl -fs -m 300 -o /dev/null -d '{"action":"sync","version":6}' http://127.0.0.1:8765 && say "synced with AnkiWeb" || say "first sync didn't finish – the app syncs again later"
fi

if [ "$VOICEVOX" = 1 ]; then
  step "VOICEVOX voices (large download)"
  bash "$APP/deploy/voicevox.sh"
fi

step "Starting Akapen"
wait_app
curl -fsS -m 10 -o /dev/null -X POST -H 'Content-Type: application/json' --data "{\"anki\":{\"enabled\":$([ "$ANKI" = none ] && echo false || echo true)}}" http://127.0.0.1:4747/api/settings
VERSION_NOW="$(curl -fs -m 5 http://127.0.0.1:4747/api/version | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')"
say "${G}Akapen ${VERSION_NOW} is running${N}"

TAILNET=
if [ "$TAILSCALE" = 1 ]; then
  step "Tailscale"
  r="$(tailscale_start)"; printf '%s\n' "$r" | grep -v '^AKAPEN_' || true
  url="$(printf '%s\n' "$r" | sed -n 's/^AKAPEN_LOGIN_URL=//p')"
  if [ -n "$url" ]; then
    say "Open this link and log in – with the account you'll also use on your phone:"
    say "  ${B}$url${N}"
    if [ -n "$TTY" ]; then ask "Press Enter after logging in …" ""; else say "Then run:  bash $APP/deploy/selfhost/server.sh --tailscale-serve"; fi
  fi
  if [ -z "$url" ] || [ -n "$TTY" ]; then
    for try in 1 2 3; do
      r="$(tailscale_serve)"
      TAILNET="$(printf '%s\n' "$r" | sed -n 's/^AKAPEN_TAILNET_URL=//p')"
      [ -n "$TAILNET" ] && break
      https="$(printf '%s\n' "$r" | sed -n 's/^AKAPEN_ENABLE_HTTPS_URL=//p')"
      if [ -n "$https" ]; then say "One more thing: turn on HTTPS for your Tailscale network – open $https and press “Enable”."
      elif printf '%s' "$r" | grep -q not-logged-in; then say "Not logged in yet${url:+ – open $url first}."
      else printf '%s\n' "$r"; fi
      [ -n "$TTY" ] && [ "$try" -lt 3 ] || { say "Later: bash $APP/deploy/selfhost/server.sh --tailscale-serve"; break; }
      ask "Press Enter to check again …" ""
    done
  fi
fi

# ---------- done ----------
[ -n "${AKAPEN_FROM_PROXMOX:-}" ] && exit 0   # proxmox.sh says it itself
IP="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^100\.' | head -1 || true)"
say ""
say "${G}${B}Done – Akapen runs on this server.${N}"
say "Enter this address in the Akapen app (\"Rather do it yourself?\" → Check):"
say "  ${B}http://${IP:-<this-server>}:$LAN_PORT${N}"
[ -n "$TAILNET" ] && say "Anywhere (Tailscale on): ${B}$TAILNET${N}"
exit 0
