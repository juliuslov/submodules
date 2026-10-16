#!/bin/sh
# Termux/Android bootstrap for hikari + WeiWei.
#
# This script is deliberately pure POSIX shell with no dependencies beyond what
# Termux already ships, because it is the step that installs everything else
# (including Node). It never uses sudo, never edits shell startup files and never
# runs anything from the network: `pkg` is Termux's own package manager, and the
# only script it executes afterwards is this repository's installer.
#
#   sh scripts/install/termux.sh --check     # report only, changes nothing
#   sh scripts/install/termux.sh             # install missing packages, then build
#   sh scripts/install/termux.sh --all       # + optional packages and storage access
#   sh scripts/install/termux.sh --test      # build, then run the test suites
#   sh scripts/install/termux.sh --packages  # only the `pkg install` step
#   sh scripts/install/termux.sh --storage   # only termux-setup-storage
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PACKAGES="$ROOT/scripts/install/termux-packages.txt"

CHECK_ONLY=0
INSTALL_PACKAGES=0
INSTALL_OPTIONAL=0
SETUP_STORAGE=0
BUILD=1
INSTALLER_ARGS=''
FORCE=0

say() { printf '%s\n' "hikari/termux: $*"; }
die() { printf '%s\n' "hikari/termux: $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
hikari + WeiWei Termux bootstrap.

  --check        report what is installed and what is missing, then stop
  --packages     install the missing required packages with `pkg install`
  --optional     also install the optional packages (termux-api, rust, ripgrep)
  --storage      run termux-setup-storage so ~/storage/... becomes readable
  --all          --packages --optional --storage
  --no-build     do not run the Node installer afterwards
  --test         pass --test to the installer (native/Python/Node/Lua suites)
  --offline      pass --offline to the installer (requires a warm npm cache)
  --force        run even when Termux is not detected
  --help         this text

Run it from anywhere; it locates the checkout from its own path.
USAGE
}

for argument in "$@"; do
  case "$argument" in
    --check) CHECK_ONLY=1 ;;
    --packages) INSTALL_PACKAGES=1 ;;
    --optional) INSTALL_OPTIONAL=1 ;;
    --storage) SETUP_STORAGE=1 ;;
    --all) INSTALL_PACKAGES=1; INSTALL_OPTIONAL=1; SETUP_STORAGE=1 ;;
    --no-build) BUILD=0 ;;
    --test) INSTALLER_ARGS="$INSTALLER_ARGS --test" ;;
    --offline) INSTALLER_ARGS="$INSTALLER_ARGS --offline" ;;
    --force) FORCE=1 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $argument (try --help)" ;;
  esac
done

# --- detection ---------------------------------------------------------------
PREFIX_VALUE=${PREFIX:-}
is_termux=0
if [ -n "${TERMUX_VERSION:-}" ]; then is_termux=1; fi
case "$PREFIX_VALUE" in
  *com.termux*) is_termux=1 ;;
esac
if [ "$is_termux" = 0 ] && [ "$FORCE" = 0 ]; then
  die "this does not look like Termux (PREFIX=${PREFIX_VALUE:-unset}, TERMUX_VERSION=${TERMUX_VERSION:-unset}).
Re-run with --force to check the package list anyway, or see docs/INSTALL.md for a
normal Linux/macOS build."
fi
if [ "$is_termux" = 1 ]; then
  say "Termux detected (PREFIX=$PREFIX_VALUE)"
else
  say "Termux not detected; continuing because --force was given"
fi

command -v pkg >/dev/null 2>&1 || say "warning: 'pkg' is not on PATH; install steps will be printed, not run"

# --- package list ------------------------------------------------------------
[ -f "$PACKAGES" ] || die "the package list is missing: $PACKAGES"

missing_required=''
missing_optional=''
while read -r package binary requirement; do
  case "$package" in ''|'#'*) continue ;; esac
  [ -n "$binary" ] || binary=$package
  if command -v "$binary" >/dev/null 2>&1; then
    state=present
  elif [ "$requirement" = optional ]; then
    state=optional
    missing_optional="$missing_optional $package"
  else
    state=missing
    missing_required="$missing_required $package"
  fi
  printf '  %-9s %-16s (%s)\n' "$state" "$package" "$binary"
done < "$PACKAGES"

# --- optional package install ------------------------------------------------
if [ "$INSTALL_OPTIONAL" = 1 ] && [ -n "$missing_optional" ]; then
  if [ "$CHECK_ONLY" = 1 ]; then
    say "would install optional:$missing_optional"
  elif command -v pkg >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    say "installing optional:$missing_optional"
    pkg install -y $missing_optional
    missing_optional=''
  fi
fi

# --- required package install ------------------------------------------------
if [ -n "$missing_required" ]; then
  say "missing required:$missing_required"
  say "install with: pkg install -y$missing_required"
  if [ "$INSTALL_PACKAGES" = 1 ] && [ "$CHECK_ONLY" = 0 ]; then
    command -v pkg >/dev/null 2>&1 || die "cannot install packages: 'pkg' is not available"
    # shellcheck disable=SC2086
    pkg install -y $missing_required
    missing_required=''
  fi
fi

# --- shared storage ----------------------------------------------------------
STORAGE="$HOME/storage"
if [ -d "$STORAGE" ]; then
  say "shared storage is set up ($STORAGE)"
  for directory in "$STORAGE/music" "$STORAGE/shared/Music" "$HOME/Music"; do
    [ -d "$directory" ] && say "music directory: $directory"
  done
else
  say "shared storage is not set up: run 'termux-setup-storage' (Android will ask for permission)"
  if [ "$SETUP_STORAGE" = 1 ] && [ "$CHECK_ONLY" = 0 ]; then
    if command -v termux-setup-storage >/dev/null 2>&1; then
      # shellcheck disable=SC2086
      say "requesting storage access (a system dialog appears; accept it)"
      termux-setup-storage || say "termux-setup-storage did not complete; run it manually"
    else
      say "termux-setup-storage is unavailable; it ships with termux-tools"
    fi
  fi
fi

if [ "$CHECK_ONLY" = 1 ]; then
  say "check complete"
  [ -z "$missing_required" ] || exit 1
  exit 0
fi

# --- build -------------------------------------------------------------------
if [ "$BUILD" = 0 ]; then
  say "skipping the build (--no-build)"
  exit 0
fi
if ! command -v node >/dev/null 2>&1; then
  die "node is not installed yet. Install it and rerun:
  pkg install -y nodejs-lts
  sh scripts/install/termux.sh"
fi

NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || printf '0')
if [ "$NODE_MAJOR" -lt 22 ]; then
  say "warning: Node $NODE_MAJOR is below 22.12; install 'nodejs-lts' or 'nodejs'"
fi

say "running the hikari installer (npm ci + make)"
# `clang` and `llvm-ar` are Termux's C toolchain names; the installer resolves
# them itself, but passing them here keeps `make` honest if something differs.
: "${CC:=clang}"
: "${AR:=llvm-ar}"
export CC AR
# shellcheck disable=SC2086
exec node "$ROOT/scripts/install/main.mjs" $INSTALLER_ARGS
