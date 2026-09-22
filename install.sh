#!/usr/bin/env bash
#
# wslc-remote installer.
#
#   curl -fsSL https://raw.githubusercontent.com/craigloewen-msft/WSLc-remote/main/install.sh | bash
#
# Installs the `wslc` script into ~/.local/bin and, where the distro packages it,
# the one external dependency: `unfsd` (UNFS3 userspace NFSv3 server). This script
# never builds anything from source — if unfsd cannot be installed from a package,
# it tells you exactly what is missing and how to build it yourself.
#
# Options (also settable via env):
#   --dir DIR        install directory        (WSLC_REMOTE_INSTALL_DIR, default ~/.local/bin)
#   --ref REF        git ref to download from (WSLC_REMOTE_REF, default main)
#   --skip-deps      do not touch unfsd       (WSLC_REMOTE_SKIP_DEPS=1)
#   --help
#
set -euo pipefail

REPO_SLUG="${WSLC_REMOTE_REPO:-craigloewen-msft/WSLc-remote}"
REF="${WSLC_REMOTE_REF:-main}"
INSTALL_DIR="${WSLC_REMOTE_INSTALL_DIR:-$HOME/.local/bin}"
SKIP_DEPS="${WSLC_REMOTE_SKIP_DEPS:-0}"
BIN_NAME="wslc"

# The installer is normally piped into bash, so its own source arrives on stdin.
# Nothing below may read stdin.
info() { printf '\033[36m[wslc-remote]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[wslc-remote] warning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[wslc-remote] error:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
wslc-remote installer — installs the `wslc` command into ~/.local/bin.

  curl -fsSL https://raw.githubusercontent.com/craigloewen-msft/WSLc-remote/main/install.sh | bash

Options (also settable via env):
  --dir DIR     install directory        (WSLC_REMOTE_INSTALL_DIR, default ~/.local/bin)
  --ref REF     git ref to download from (WSLC_REMOTE_REF, default main)
  --skip-deps   do not touch unfsd       (WSLC_REMOTE_SKIP_DEPS=1)
  -h, --help    show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)        shift; [[ $# -gt 0 ]] || die "--dir requires an argument"; INSTALL_DIR="$1" ;;
    --dir=*)      INSTALL_DIR="${1#*=}" ;;
    --ref)        shift; [[ $# -gt 0 ]] || die "--ref requires an argument"; REF="$1" ;;
    --ref=*)      REF="${1#*=}" ;;
    --skip-deps)  SKIP_DEPS=1 ;;
    -h|--help)    usage ;;
    *)            die "unknown option '$1' (try --help)" ;;
  esac
  shift
done

RAW_URL="https://raw.githubusercontent.com/$REPO_SLUG/$REF/$BIN_NAME"
# Where the wslc script looks for a distro-installed unfsd that is not on PATH.
SBIN_CANDIDATES=(/usr/sbin /usr/local/sbin /sbin "$HOME/.local/sbin" "$HOME/.local/bin")

# ---------------------------------------------------------------------------
# Preflight

if [[ -z "${BASH_VERSINFO:-}" || ${BASH_VERSINFO[0]} -lt 4 ]]; then
  die "bash 4 or newer is required (run this with bash, not sh)"
fi

DOWNLOADER=""
if command -v curl >/dev/null 2>&1; then DOWNLOADER=curl
elif command -v wget >/dev/null 2>&1; then DOWNLOADER=wget
fi

if ! grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
  warn "this does not look like a WSL distro; wslc-remote only makes sense inside WSL"
fi

if ! command -v wslc.exe >/dev/null 2>&1 && [[ ! -x "/mnt/c/Program Files/WSL/wslc.exe" ]]; then
  warn "could not find wslc.exe — install WSL container support, or set \$WSLC to its path"
fi

# ---------------------------------------------------------------------------
# Install the script

fetch_to() {
  local url="$1" dest="$2"
  case "$DOWNLOADER" in
    curl) curl -fsSL "$url" -o "$dest" ;;
    wget) wget -qO "$dest" "$url" ;;
    *)    die "need curl or wget to download $url" ;;
  esac
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

staged="$TMP_DIR/$BIN_NAME"
# Run from a clone (or any directory holding the script) and we use that copy,
# so the repo is testable before it is ever pushed.
self_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [[ -n "$self_dir" && -f "$self_dir/$BIN_NAME" ]]; then
  info "installing from local checkout: $self_dir/$BIN_NAME"
  cp "$self_dir/$BIN_NAME" "$staged"
else
  info "downloading $BIN_NAME from $REPO_SLUG@$REF"
  fetch_to "$RAW_URL" "$staged" || die "download failed: $RAW_URL"
fi

[[ -s "$staged" ]] || die "downloaded file is empty: $RAW_URL"
head -n1 "$staged" | grep -q '^#!' || die "downloaded file is not a script (got HTML?): $RAW_URL"
grep -q 'wslc-remote' "$staged" || die "downloaded file does not look like wslc-remote: $RAW_URL"

mkdir -p "$INSTALL_DIR" || die "cannot create install directory: $INSTALL_DIR"
[[ -w "$INSTALL_DIR" ]] || die "install directory is not writable: $INSTALL_DIR"

target="$INSTALL_DIR/$BIN_NAME"
chmod +x "$staged"
mv -f "$staged" "$target"
info "installed $target"

# ---------------------------------------------------------------------------
# unfsd — package manager only. Never built from source here.

have_unfsd() {
  if command -v unfsd >/dev/null 2>&1; then UNFSD_PATH="$(command -v unfsd)"; return 0; fi
  if [[ -n "${WSLC_REMOTE_UNFSD:-}" && -x "${WSLC_REMOTE_UNFSD}" ]]; then UNFSD_PATH="$WSLC_REMOTE_UNFSD"; return 0; fi
  local d
  for d in "${SBIN_CANDIDATES[@]}"; do
    if [[ -x "$d/unfsd" ]]; then UNFSD_PATH="$d/unfsd"; return 0; fi
  done
  return 1
}

# Distros vary: unfsd often lands in /usr/sbin, which is not on every user's PATH.
# Symlink it next to the wslc script so the tool finds it with no extra setup.
link_unfsd_onto_path() {
  [[ -n "${UNFSD_PATH:-}" ]] || return 0
  command -v unfsd >/dev/null 2>&1 && return 0
  ln -sf "$UNFSD_PATH" "$INSTALL_DIR/unfsd" \
    && info "linked $INSTALL_DIR/unfsd -> $UNFSD_PATH"
}

manual_unfsd_instructions() {
  local reason="$1"
  cat >&2 <<EOF

$(printf '\033[33m')wslc-remote is installed, but its one dependency is missing.$(printf '\033[0m')

  Missing: unfsd — the UNFS3 userspace NFSv3 server.
  Why:     wslc-remote serves each host bind mount over a loopback NFS export,
           which is what makes it faster than the default virtiofs share.
  Reason:  $reason

  Build it from source (takes about a minute):

    # build deps: autoconf automake libtool make gcc flex bison
    #   Fedora/RHEL:  sudo dnf install autoconf automake libtool make gcc flex bison
    #   Arch:         sudo pacman -S --needed base-devel flex bison
    #   Debian/Ubuntu: sudo apt-get install build-essential autoconf automake libtool flex bison
    # on modern glibc you may also need libtirpc + rpcsvc-proto headers

    git clone https://github.com/unfs3/unfs3
    cd unfs3
    ./bootstrap && ./configure && make && sudo make install

  Already have an unfsd binary somewhere? Point wslc-remote at it instead:

    export WSLC_REMOTE_UNFSD=/path/to/unfsd

  Then verify everything with:

    $BIN_NAME _check

EOF
}

install_unfsd() {
  local sudo_cmd=""
  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then sudo_cmd="sudo"; else
      manual_unfsd_instructions "not running as root and no sudo available to install a package"
      return 1
    fi
  fi

  # unfs3 is packaged on Debian/Ubuntu and openSUSE; on Arch it is AUR-only, so
  # plain pacman cannot help. Fedora has no package at all.
  if command -v apt-get >/dev/null 2>&1; then
    info "installing unfs3 with apt-get"
    $sudo_cmd apt-get update -qq || true
    $sudo_cmd apt-get install -y unfs3 && return 0
    manual_unfsd_instructions "'apt-get install unfs3' failed"; return 1
  fi

  if command -v zypper >/dev/null 2>&1; then
    info "installing unfs3 with zypper"
    $sudo_cmd zypper --non-interactive install unfs3 && return 0
    manual_unfsd_instructions "'zypper install unfs3' failed"; return 1
  fi

  if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    local pm; pm="$(command -v dnf || command -v yum)"
    info "trying to install unfs3 with $(basename "$pm")"
    $sudo_cmd "$pm" install -y unfs3 && return 0
    manual_unfsd_instructions "no unfs3 package is available for this distro"; return 1
  fi

  if command -v pacman >/dev/null 2>&1; then
    local helper=""
    command -v yay  >/dev/null 2>&1 && helper=yay
    command -v paru >/dev/null 2>&1 && helper=paru
    if [[ -n "$helper" ]]; then
      info "installing unfs3 from the AUR with $helper"
      "$helper" -S --needed --noconfirm unfs3 && return 0
      manual_unfsd_instructions "'$helper -S unfs3' failed"; return 1
    fi
    manual_unfsd_instructions "unfs3 is AUR-only on Arch and no AUR helper (yay/paru) is installed"
    return 1
  fi

  manual_unfsd_instructions "no supported package manager found (apt-get, dnf, zypper, pacman+AUR helper)"
  return 1
}

UNFSD_OK=1
if [[ "$SKIP_DEPS" == 1 ]]; then
  info "skipping dependency check (--skip-deps)"
elif have_unfsd; then
  info "found unfsd: $UNFSD_PATH"
  link_unfsd_onto_path
elif install_unfsd; then
  if have_unfsd; then
    info "found unfsd: $UNFSD_PATH"
    link_unfsd_onto_path
  else
    UNFSD_OK=0
    manual_unfsd_instructions "the package installed but no 'unfsd' binary was found afterwards"
  fi
else
  # install_unfsd already explained why it could not install the package.
  UNFSD_OK=0
fi

# ---------------------------------------------------------------------------
# PATH and collisions

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    warn "$INSTALL_DIR is not on your PATH. Add it:

    echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.bashrc   # or ~/.zshrc
    export PATH=\"$INSTALL_DIR:\$PATH\"
"
    ;;
esac

# wslc-remote installs itself as `wslc`, shadowing anything else with that name.
existing="$(command -v "$BIN_NAME" 2>/dev/null || true)"
if [[ -n "$existing" && "$existing" != "$target" ]]; then
  warn "another '$BIN_NAME' is earlier on your PATH and will win: $existing
  (wslc-remote was installed at $target)"
fi

echo
if [[ "$UNFSD_OK" == 1 ]]; then
  info "done. Verify with:  $BIN_NAME _check"
else
  info "done — install unfsd (see above), then verify with:  $BIN_NAME _check"
fi
