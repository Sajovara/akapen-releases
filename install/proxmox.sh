#!/usr/bin/env bash
# Akapen on Proxmox – run it yourself instead of giving the desktop app the
# root password. In the Proxmox web interface: your node (e.g. "pve") →
# Shell, then paste:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sajovara/akapen-releases/v<version>/install/proxmox.sh)"
#
# Asks a few questions (Anki, voices, Tailscale), makes a new container for
# Akapen (Debian, unprivileged, 4 cores, 6–8 GB RAM, 24 GB disk, starts with
# the host, Tailscale-ready), downloads the server code of this release
# (checked against its SHA-256), installs it inside with server.sh and prints
# the address to enter in the app. Other containers and VMs are left alone.
#
# Without questions (all optional, the defaults in brackets):
#   AKAPEN_ANKI=none|ankiweb          [none]; ankiweb asks for e-mail and password
#   AKAPEN_ANKIWEB_FILE=<file>        or the AnkiWeb login as {"user": …, "password": …} (deleted after use)
#   AKAPEN_VOICEVOX=0|1               natural voices, ~2 GB [0]
#   AKAPEN_TAILSCALE=0|1              phone / on the road [0]
#   AKAPEN_VMID=<id>                  container ID [the next free one]; an existing
#                                     Akapen container with this ID is installed again
#   AKAPEN_HOSTNAME=<name>            [akapen, akapen-2, … whichever is free]
#   AKAPEN_STORAGE / AKAPEN_BRIDGE    [the storage with the most free space / vmbr0]
#   AKAPEN_YES=1                      take the defaults, ask nothing
#   AKAPEN_VERSION=<x.y.z|latest>     another release than this script's
#   AKAPEN_TARBALL=<file>             use this server code instead of downloading it
set -euo pipefail

REPO=Sajovara/akapen-releases
RELEASE="0.1.2"   # filled in when published (scripts/release.mjs)
SHA256="ab5947fb33a3d868fefbba8e5b311fe312dae42d477d2b3dd7dfc80321678cd9"
DESC="Akapen (Japanese trainer) + headless Anki"
case "$RELEASE" in @*) RELEASE= ;; esac
case "$SHA256" in @*) SHA256= ;; esac

if [ -t 1 ]; then B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; D=$'\e[2m'; N=$'\e[0m'; else B= R= G= D= N=; fi
say() { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
die() { printf '\n%sStopped: %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
TTY=
if [ -z "${AKAPEN_YES:-}" ] && { : </dev/tty; } 2>/dev/null; then TTY=/dev/tty; fi
ask() { REPLY="$2"; [ -n "$TTY" ] || return 0; read -r -p "$1 " REPLY <"$TTY" || true; REPLY="${REPLY:-$2}"; }
yes_no() { local hint="[y/N]"; [ "$2" = y ] && hint="[Y/n]"; ask "$1 $hint" "$2"; case "$REPLY" in [yYjJ]*) return 0 ;; *) return 1 ;; esac; }
secret() { REPLY=; [ -n "$TTY" ] || die "$1 is needed, but there is no terminal to ask in."; read -r -s -p "$1 " REPLY <"$TTY" || true; printf '\n'; }
flag() { case "${1:-}" in 1|y|yes|true) echo 1 ;; 0|n|no|false) echo 0 ;; *) echo "" ;; esac; }

# ---------- is this a Proxmox host? ----------
say "${B}Akapen – installation on Proxmox${N}${RELEASE:+ (release $RELEASE)}"
[ "$(id -u)" = 0 ] || die "please run this as root, in the Proxmox host's shell."
[ -d /etc/pve ] && command -v pct >/dev/null && command -v pvesm >/dev/null \
  || die "this isn't a Proxmox host. Run it in the Proxmox web interface: your node → Shell. (For a plain Debian/Ubuntu server, use install/server.sh.)"
[ "$(uname -m)" = x86_64 ] || die "this host is $(uname -m); Akapen's server needs x86_64."
say "${D}$(pveversion 2>/dev/null | head -1), $(nproc) cores, $(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo) GB RAM${N}"

# ---------- the facts: container ID, name, storage, bridge, template ----------
is_akapen() { pct config "$1" 2>/dev/null | grep -qi '^description:.*akapen'; }
taken_id() { pct status "$1" >/dev/null 2>&1 || [ -e "/etc/pve/qemu-server/$1.conf" ] || [ -n "$(find /etc/pve/nodes -name "$1.conf" 2>/dev/null | head -1)" ]; }
REUSE=
if [ -n "${AKAPEN_VMID:-}" ]; then
  [[ "$AKAPEN_VMID" =~ ^[0-9]+$ ]] && [ "$AKAPEN_VMID" -ge 100 ] || die "AKAPEN_VMID must be a number ≥ 100."
  VMID="$AKAPEN_VMID"
  if taken_id "$VMID"; then
    is_akapen "$VMID" || die "ID $VMID is already taken by something else on this host."
    REUSE=1
  fi
else
  VMID="$(pvesh get /cluster/nextid 2>/dev/null || true)"
  [[ "$VMID" =~ ^[0-9]+$ ]] || die "couldn't get a free container ID (pvesh get /cluster/nextid)."
fi
existing="$(for id in $(pct list 2>/dev/null | awk 'NR>1{print $1}'); do is_akapen "$id" && printf '%s (%s) ' "$id" "$(pct config "$id" | sed -n 's/^hostname: //p')"; done || true)"
if [ -z "$REUSE" ] && [ -n "$existing" ]; then
  say "Note: Akapen already has a container here: ${existing}– this makes another one. To update that one instead, use install/update.sh."
  [ -z "$TTY" ] || yes_no "Make another container anyway?" n || exit 0
fi
NAMES=" $(pct list 2>/dev/null | awk 'NR>1{print $NF}' | tr '\n' ' ') "
if [ -n "$REUSE" ]; then
  HOSTNAME_="$(pct config "$VMID" | sed -n 's/^hostname: //p')"
else
  HOSTNAME_="${AKAPEN_HOSTNAME:-}"
  if [ -z "$HOSTNAME_" ]; then HOSTNAME_=akapen; n=2; while [[ "$NAMES" == *" $HOSTNAME_ "* ]]; do HOSTNAME_="akapen-$n"; n=$((n+1)); done; fi
  [[ "$HOSTNAME_" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "AKAPEN_HOSTNAME may only have a–z, 0–9 and -."
fi

# ---------- questions ----------
ANKI="${AKAPEN_ANKI:-}"
if [ -z "$ANKI" ]; then
  if [ -n "$TTY" ]; then
    say ""
    say "${B}Anki in the container?${N} Akapen can show your Anki reviews and use the words you know."
    [ -n "$REUSE" ] && say "  0) keep what the container has"
    say "  1) log in to AnkiWeb (downloads your collection)"
    say "  2) no Anki"
    ask "Choose [${REUSE:+0}${REUSE:-2}]:" "${REUSE:+0}${REUSE:-2}"
    case "$REPLY" in 0) ANKI=auto ;; 1) ANKI=ankiweb ;; *) ANKI=none ;; esac
  else ANKI="${REUSE:+auto}"; ANKI="${ANKI:-none}"; fi
fi
# auto (an existing container): server.sh keeps an Anki profile that is there
case "$ANKI" in none|ankiweb) ;; keep|auto) [ -n "$REUSE" ] || die "AKAPEN_ANKI=$ANKI only works for an existing container."; [ "$ANKI" = keep ] || ANKI= ;; *) die "AKAPEN_ANKI must be none or ankiweb." ;; esac
CREDS=
TMPD="$(mktemp -d)"
cleanup() { [ -n "$CREDS" ] && rm -f "$CREDS"; rm -rf "$TMPD"; return 0; }
trap cleanup EXIT
if [ "$ANKI" = ankiweb ]; then
  CREDS="$(umask 077; mktemp /root/.akapen-ankiweb.XXXXXX)"
  if [ -n "${AKAPEN_ANKIWEB_FILE:-}" ]; then
    [ -f "$AKAPEN_ANKIWEB_FILE" ] || die "AKAPEN_ANKIWEB_FILE ($AKAPEN_ANKIWEB_FILE) doesn't exist."
    cat "$AKAPEN_ANKIWEB_FILE" >"$CREDS"; rm -f "$AKAPEN_ANKIWEB_FILE"
  else
    say "Your AnkiWeb login (the same as in Anki → Sync). It goes only to the new container's Anki and is deleted after the login."
    ask "AnkiWeb e-mail:" ""; AW_USER="$REPLY"; [ -n "$AW_USER" ] || die "no AnkiWeb e-mail given."
    secret "AnkiWeb password (not shown):"; AW_PASS="$REPLY"; [ -n "$AW_PASS" ] || die "no AnkiWeb password given."
    printf '%s\n%s' "$AW_USER" "$AW_PASS" | python3 -c 'import json,sys; u,p=sys.stdin.read().split("\n",1); json.dump({"user":u,"password":p}, open(sys.argv[1],"w"))' "$CREDS" || die "couldn't store the login."
    unset AW_PASS REPLY
  fi
fi
VOICEVOX="$(flag "${AKAPEN_VOICEVOX:-}")"
if [ -z "$VOICEVOX" ]; then VOICEVOX=0; yes_no "Install VOICEVOX (natural Japanese voices, ~2 GB download, 2 GB more RAM)?" n && VOICEVOX=1; fi
TAILSCALE="$(flag "${AKAPEN_TAILSCALE:-}")"
if [ -z "$TAILSCALE" ]; then TAILSCALE=0; yes_no "Set up Tailscale (use Akapen on your phone away from home)?" n && TAILSCALE=1; fi

# ---------- the server code (checked before anything is created) ----------
step "Server code"
if [ -n "${AKAPEN_TARBALL:-}" ]; then
  [ -f "$AKAPEN_TARBALL" ] || die "AKAPEN_TARBALL ($AKAPEN_TARBALL) doesn't exist."
  cp "$AKAPEN_TARBALL" "$TMPD/code.tar.gz"; say "from $AKAPEN_TARBALL"
else
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
fi
tar -xzf "$TMPD/code.tar.gz" -C "$TMPD" deploy/selfhost/server.sh || die "the server code has no deploy/selfhost/server.sh."

# ---------- the container ----------
if [ -n "$REUSE" ]; then
  step "Container $VMID ($HOSTNAME_) – already there, installing again"
  pct status "$VMID" | grep -q running || pct start "$VMID"
else
  STORAGE="${AKAPEN_STORAGE:-$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && $3=="active"{print $6, $1}' | sort -rn | head -1 | cut -d' ' -f2)}"
  [ -n "$STORAGE" ] || die "no storage on this host can hold containers."
  [[ "$STORAGE" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid storage name."
  BRIDGES="$(for b in /sys/class/net/*/bridge; do [ -e "$b" ] && basename "$(dirname "$b")"; done || true)"
  BRIDGE="${AKAPEN_BRIDGE:-$(printf '%s\n' $BRIDGES | grep -x vmbr0 || printf '%s\n' $BRIDGES | head -1)}"
  [ -n "$BRIDGE" ] || die "no network bridge (vmbr0) on this host."
  [[ "$BRIDGE" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid bridge name."
  CORES=$(( $(nproc) < 4 ? $(nproc) : 4 ))
  WANT_MB=$([ "$VOICEVOX" = 1 ] && echo 8192 || echo 6144)
  TOTAL_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  MEM=$(( (TOTAL_MB - 1024) / 512 * 512 )); [ "$MEM" -gt "$WANT_MB" ] && MEM=$WANT_MB; [ "$MEM" -lt 2048 ] && MEM=2048

  step "Debian template"
  TEMPLATE=
  for v in 13 12; do
    TEMPLATE="$(for s in $(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1{print $1}'); do pveam list "$s" 2>/dev/null | awk 'NR>1{print $1}'; done | grep -E "debian-$v-standard_.*amd64" | sort | tail -1 || true)"
    [ -n "$TEMPLATE" ] && break
  done
  if [ -z "$TEMPLATE" ]; then
    TSTORE="$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1{print $1}' | grep -x local || pvesm status --content vztmpl 2>/dev/null | awk 'NR>1{print $1}' | head -1)"
    [ -n "$TSTORE" ] || die "no storage on this host can hold container templates."
    pveam update >/dev/null 2>&1 || true
    for v in 13 12; do NAME="$(pveam available --section system | awk '{print $2}' | grep -E "^debian-$v-standard_.*amd64" | sort | tail -1 || true)"; [ -n "$NAME" ] && break; done
    [ -n "$NAME" ] || die "no Debian template available for download."
    say "Downloading $NAME …"
    pveam download "$TSTORE" "$NAME" >/dev/null
    TEMPLATE="$TSTORE:vztmpl/$NAME"
  fi
  say "$TEMPLATE"

  step "Creating container $VMID \"$HOSTNAME_\" ($CORES cores, $MEM MB, 24 GB on $STORAGE, $BRIDGE)"
  pct create "$VMID" "$TEMPLATE" --hostname "$HOSTNAME_" --description "$DESC" \
    --cores "$CORES" --memory "$MEM" --swap 1024 --rootfs "$STORAGE:24" \
    --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp,type=veth" --unprivileged 1 --features nesting=1,keyctl=1 \
    --onboot 1 --ostype debian --timezone host >/dev/null
  # Tailscale needs the tun device
  cat >>"/etc/pve/lxc/$VMID.conf" <<'EOF'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
  pct start "$VMID"
fi

say "Waiting for its network …"
IP=
for _ in $(seq 1 60); do
  IP="$(pct exec "$VMID" -- ip -4 -o addr show dev eth0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1 || true)"
  [ -n "$IP" ] && break; sleep 2
done
[ -n "$IP" ] || die "container $VMID got no network address (DHCP). Fix it and run this again with AKAPEN_VMID=$VMID."
for i in $(seq 1 30); do pct exec "$VMID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break; [ "$i" = 30 ] && die "container $VMID ($IP) can't reach the internet. Fix it and run this again with AKAPEN_VMID=$VMID."; sleep 2; done
say "Container $VMID is up at ${B}$IP${N}"

# ---------- install inside ----------
pct push "$VMID" "$TMPD/code.tar.gz" /root/akapen-server.tar.gz --perms 600
pct push "$VMID" "$TMPD/deploy/selfhost/server.sh" /root/akapen-server.sh --perms 700
CRED_ENV=
if [ -n "$CREDS" ]; then
  pct push "$VMID" "$CREDS" /root/.akapen-ankiweb.json --perms 600
  rm -f "$CREDS"; CREDS=
  CRED_ENV=AKAPEN_ANKIWEB_FILE=/root/.akapen-ankiweb.json
fi
step "Installing Akapen inside container $VMID"
set +e
pct exec "$VMID" -- env LANG=C.UTF-8 LC_ALL=C.UTF-8 AKAPEN_FROM_PROXMOX=1 AKAPEN_YES=1 AKAPEN_ANKI="$ANKI" $CRED_ENV AKAPEN_VOICEVOX="$VOICEVOX" AKAPEN_TAILSCALE=0 \
  AKAPEN_TARBALL=/root/akapen-server.tar.gz bash /root/akapen-server.sh
code=$?
set -e
pct exec "$VMID" -- rm -f /root/akapen-server.tar.gz /root/akapen-server.sh /root/.akapen-ankiweb.json || true
[ "$code" = 0 ] || die "the installation inside container $VMID failed (see above). Fix the cause and run this again with AKAPEN_VMID=$VMID – it picks up the same container."

# ---------- Tailscale ----------
TAILNET=
S=/opt/akapen/deploy/selfhost/server.sh
if [ "$TAILSCALE" = 1 ]; then
  step "Tailscale"
  r="$(pct exec "$VMID" -- env LANG=C.UTF-8 LC_ALL=C.UTF-8 bash "$S" --tailscale-start)" || die "Tailscale setup failed: $r"
  printf '%s\n' "$r" | grep -v '^AKAPEN_' || true
  url="$(printf '%s\n' "$r" | sed -n 's/^AKAPEN_LOGIN_URL=//p')"
  if [ -n "$url" ]; then
    say "Open this link and log in – with the account you'll also use on your phone:"
    say "  ${B}$url${N}"
    if [ -n "$TTY" ]; then ask "Press Enter after logging in …" ""; else say "Then run here:  pct exec $VMID -- bash $S --tailscale-serve"; fi
  fi
  if [ -z "$url" ] || [ -n "$TTY" ]; then
    for try in 1 2 3; do
      r="$(pct exec "$VMID" -- env LANG=C.UTF-8 LC_ALL=C.UTF-8 bash "$S" --tailscale-serve || true)"
      TAILNET="$(printf '%s\n' "$r" | sed -n 's/^AKAPEN_TAILNET_URL=//p')"
      [ -n "$TAILNET" ] && break
      https="$(printf '%s\n' "$r" | sed -n 's/^AKAPEN_ENABLE_HTTPS_URL=//p')"
      if [ -n "$https" ]; then say "One more thing: turn on HTTPS for your Tailscale network – open $https and press “Enable”."
      elif printf '%s' "$r" | grep -q not-logged-in; then say "Not logged in yet${url:+ – open $url first}."
      else printf '%s\n' "$r"; fi
      [ -n "$TTY" ] && [ "$try" -lt 3 ] || { say "Later, here:  pct exec $VMID -- bash $S --tailscale-serve"; break; }
      ask "Press Enter to check again …" ""
    done
  fi
fi

say ""
say "${G}${B}Done – Akapen runs in container $VMID (\"$HOSTNAME_\").${N}"
say "Enter this address in the Akapen app (\"Rather do it yourself?\" → Check):"
say "  ${B}http://$IP:4750${N}"
[ -n "$TAILNET" ] && say "Anywhere (Tailscale on): ${B}$TAILNET${N}"
say "${D}Update later: install/update.sh, here in the host's shell.${N}"
exit 0
