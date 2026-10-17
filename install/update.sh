#!/usr/bin/env bash
# Updates Akapen on your server – run it yourself instead of giving the
# desktop app your password. Either on the server itself (Debian/Ubuntu, as
# root or with sudo) or, for a Proxmox container, in the Proxmox host's shell
# (your node → Shell):
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sajovara/akapen-releases/v<version>/install/update.sh)"
#
# Downloads the server code of this release (checked against its SHA-256),
# replaces the code in /opt/akapen and restarts the app. Your progress
# (/opt/akapen/data), Anki, voices and Tailscale stay as they are.
#
#   AKAPEN_VERSION=<x.y.z|latest>   another release than this script's
#   AKAPEN_VMID=<id>                on Proxmox: the container [the one with Akapen; asked if several]
#   AKAPEN_YES=1                    ask nothing
#   AKAPEN_TARBALL=<file>           use this server code instead of downloading it
set -euo pipefail

REPO=Sajovara/akapen-releases
RELEASE="0.1.12"   # filled in when published (scripts/release.mjs)
SHA256="8bd2e873a7d857763a5fcd37e381c36036f807ee3e8c0b1fe833344eacc2c71b"
APP=/opt/akapen
case "$RELEASE" in @*) RELEASE= ;; esac
case "$SHA256" in @*) SHA256= ;; esac

if [ -t 1 ]; then B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; D=$'\e[2m'; N=$'\e[0m'; else B= R= G= D= N=; fi
say() { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
die() { printf '\n%sStopped: %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
TTY=
if [ -z "${AKAPEN_YES:-}" ] && { : </dev/tty; } 2>/dev/null; then TTY=/dev/tty; fi
ask() { REPLY="$2"; [ -n "$TTY" ] || return 0; read -r -p "$1 " REPLY <"$TTY" || true; REPLY="${REPLY:-$2}"; }

say "${B}Akapen – update${N}${RELEASE:+ (release $RELEASE)}"
[ "$(id -u)" = 0 ] || die "please run this as root (or put sudo in front)."

# ---------- where: this machine, or a container on this Proxmox host ----------
VMID=
if [ -d /etc/pve ] && command -v pct >/dev/null; then
  is_akapen() { pct config "$1" 2>/dev/null | grep -qi '^description:.*akapen'; }
  if [ -n "${AKAPEN_VMID:-}" ]; then
    [[ "$AKAPEN_VMID" =~ ^[0-9]+$ ]] || die "AKAPEN_VMID must be a number."
    pct status "$AKAPEN_VMID" >/dev/null 2>&1 || die "there is no container $AKAPEN_VMID."
    pct exec "$AKAPEN_VMID" -- test -f $APP/server/index.js 2>/dev/null || die "container $AKAPEN_VMID has no Akapen in $APP (is it running?)."
    VMID="$AKAPEN_VMID"
  else
    found=()
    for id in $(pct list 2>/dev/null | awk 'NR>1{print $1}'); do is_akapen "$id" && found+=("$id"); done
    [ "${#found[@]}" -gt 0 ] || die "no Akapen container on this host (none has \"Akapen\" in its description). Give it with AKAPEN_VMID=<id>."
    if [ "${#found[@]}" = 1 ]; then VMID="${found[0]}"
    else
      [ -n "$TTY" ] || die "several Akapen containers (${found[*]}) – choose one with AKAPEN_VMID=<id>."
      say "Akapen containers on this host:"
      for id in "${found[@]}"; do say "  $id  $(pct config "$id" | sed -n 's/^hostname: //p')  ($(pct status "$id" | cut -d' ' -f2))"; done
      ask "Which one? [${found[0]}]" "${found[0]}"; VMID="$REPLY"
      [[ " ${found[*]} " == *" $VMID "* ]] || die "$VMID isn't one of them."
    fi
  fi
  pct status "$VMID" | grep -q running || { say "Starting container $VMID …"; pct start "$VMID"; sleep 3; }
  say "Container $VMID ($(pct config "$VMID" | sed -n 's/^hostname: //p'))"
  run() { pct exec "$VMID" -- env LANG=C.UTF-8 LC_ALL=C.UTF-8 PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash -c "$1"; }
else
  [ -f "$APP/server/index.js" ] || die "Akapen isn't installed here ($APP is missing). To install it, use install/server.sh – or, on Proxmox, run this in the host's shell."
  run() { LANG=C.UTF-8 LC_ALL=C.UTF-8 bash -c "$1"; }
fi
OLD="$(run "cd $APP && node -p 'require(\"./package.json\").version'" 2>/dev/null || echo "?")"

# ---------- the code ----------
step "Server code"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
if [ -n "${AKAPEN_TARBALL:-}" ]; then
  [ -f "$AKAPEN_TARBALL" ] || die "AKAPEN_TARBALL ($AKAPEN_TARBALL) doesn't exist."
  cp "$AKAPEN_TARBALL" "$TMPD/code.tar.gz"; say "from $AKAPEN_TARBALL"
else
  command -v curl >/dev/null || die "curl is missing (apt-get install curl)."
  WANT="${AKAPEN_VERSION:-${RELEASE:-latest}}"
  if [ "$WANT" = latest ]; then
    WANT="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" | sed -n 's#.*/tag/v##p')"
    [ -n "$WANT" ] || die "couldn't find the latest release on GitHub."
  fi
  WANT="${WANT#v}"
  URL="https://github.com/$REPO/releases/download/v$WANT/akapen-server-$WANT.tar.gz"
  say "Akapen $OLD → $WANT"
  curl -fsSL --retry 3 -o "$TMPD/code.tar.gz" "$URL" || die "couldn't download $URL"
  SUM="$SHA256"
  [ "$WANT" = "$RELEASE" ] && [ -n "$SUM" ] || SUM="$(curl -fsSL --retry 3 "$URL.sha256" | cut -d' ' -f1)"
  [ -n "$SUM" ] || die "no checksum for $URL"
  [ "$(sha256sum "$TMPD/code.tar.gz" | cut -d' ' -f1)" = "$SUM" ] || die "the download doesn't match its checksum – nothing was changed."
  say "${G}checksum ok${N} ${D}(sha256 $SUM)${N}"
fi
tar -tzf "$TMPD/code.tar.gz" server/index.js deploy/update.sh >/dev/null 2>&1 || die "the server code is incomplete."
if [ -n "$VMID" ]; then
  pct push "$VMID" "$TMPD/code.tar.gz" /root/akapen-server.tar.gz --perms 600
  CODE=/root/akapen-server.tar.gz
else
  CODE="$TMPD/code.tar.gz"
fi

# ---------- replace, update, restart ----------
step "Updating"
# unpacked next to the app first; then the code folders are swapped
# (removed files go), data/ and node_modules/ stay
run "set -e; t=\$(mktemp -d $APP.new.XXXXXX); tar -xzf $CODE -C \$t --no-same-owner
for d in server public content vendor deploy; do rm -rf $APP/\$d; done
cp -a \$t/. $APP/; rm -rf \$t
[ '$CODE' = /root/akapen-server.tar.gz ] && rm -f $CODE || true
bash $APP/deploy/update.sh" || die "the update failed (see above). Your progress is untouched; run this again once the cause is fixed."

ok=
for _ in $(seq 1 60); do run "curl -fs -m 3 -o /dev/null http://127.0.0.1:4747/api/settings" 2>/dev/null && { ok=1; break; }; sleep 2; done
[ -n "$ok" ] || { run "journalctl -u akapen -n 30 --no-pager" || true; die "the app didn't come back after the update."; }
NEW="$(run "curl -fs -m 5 http://127.0.0.1:4747/api/version" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')"
say ""
say "${G}${B}Done – Akapen ${NEW:-?} is running${VMID:+ in container $VMID}.${N} ${D}(was $OLD)${N}"
say "In the app, press “Check” to see it."
exit 0
