#!/bin/sh
# OmnyShell installer for Linux, macOS and WSL.
#
#   curl -fsSL https://raw.githubusercontent.com/OmnyGrid/omnyshell/master/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/OmnyGrid/omnyshell/master/install.sh | sh -s -- --no-tools
#
# Installs the Dart SDK when it is missing or too old (upgrading an existing one
# the way it was installed), runs `dart pub global activate omnyshell`, installs
# the tools OmnyShell uses (git, openssl, script) and puts everything on PATH.
# It never asks questions; sudo/doas may ask for a password when a system
# package has to be installed. Run with --help for the options, and see
# install.md for details.

set -eu

MIN_DART_VERSION=3.10.9
DART_ARCHIVE=https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk
DART_APT_REPO=https://storage.googleapis.com/download.dartlang.org/linux/debian
DART_APT_KEY=https://dl-ssl.google.com/linux/linux_signing_key.pub
REPO_RAW=https://raw.githubusercontent.com/OmnyGrid/omnyshell/master
BLOCK_BEGIN='# >>> omnyshell >>>'
BLOCK_END='# <<< omnyshell <<<'
# Written inside a Dart SDK this installer unpacked, so --uninstall and upgrades
# only ever delete a directory the installer created.
ZIP_MARKER=.omnyshell-installer

# --- options (flags override the OMNYSHELL_* environment) --------------------

truthy() {
  case "${1:-}" in 1 | true | TRUE | yes | YES | on | ON) return 0 ;; *) return 1 ;; esac
}
flag_env() { if truthy "${1:-}"; then echo 1; else echo 0; fi; }

opt_version=${OMNYSHELL_VERSION:-}
opt_source=${OMNYSHELL_SOURCE:-}
opt_git=${OMNYSHELL_GIT:-}
opt_git_ref=${OMNYSHELL_GIT_REF:-}
opt_no_tools=$(flag_env "${OMNYSHELL_NO_TOOLS:-}")
opt_no_modify_path=$(flag_env "${OMNYSHELL_NO_MODIFY_PATH:-}")
opt_no_sudo=$(flag_env "${OMNYSHELL_NO_SUDO:-}")
opt_dart_method=${OMNYSHELL_DART_METHOD:-auto}
opt_dart_dir=${OMNYSHELL_DART_DIR:-}
opt_no_dart_upgrade=$(flag_env "${OMNYSHELL_NO_DART_UPGRADE:-}")
opt_reinstall_services=$(flag_env "${OMNYSHELL_REINSTALL_SERVICES:-}")
opt_dry_run=$(flag_env "${OMNYSHELL_DRY_RUN:-}")
opt_quiet=$(flag_env "${OMNYSHELL_QUIET:-}")
opt_verbose=$(flag_env "${OMNYSHELL_VERBOSE:-}")
opt_uninstall=$(flag_env "${OMNYSHELL_UNINSTALL:-}")

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Installs OmnyShell (the Dart SDK if needed, the omnyshell CLI, its tools, PATH).

Options (each also reads the OMNYSHELL_* variable shown):
  --version <v>           Install this omnyshell version (OMNYSHELL_VERSION)
  --source <path>         Install from a local checkout (OMNYSHELL_SOURCE)
  --git <url>             Install from a git repository (OMNYSHELL_GIT)
  --git-ref <ref>         Branch, tag or commit for --git (OMNYSHELL_GIT_REF)
  --no-tools              Don't install git, openssl, script (OMNYSHELL_NO_TOOLS=1)
  --no-modify-path        Don't edit shell rc files (OMNYSHELL_NO_MODIFY_PATH=1)
  --no-sudo               Never use sudo/doas (OMNYSHELL_NO_SUDO=1)
  --dart-method <m>       auto | system | zip (OMNYSHELL_DART_METHOD)
  --dart-dir <dir>        Where a downloaded Dart SDK goes (OMNYSHELL_DART_DIR)
  --no-dart-upgrade       Never upgrade an existing Dart (OMNYSHELL_NO_DART_UPGRADE=1)
  --reinstall-services    Reinstall installed Hub/Node services after upgrading
                          (OMNYSHELL_REINSTALL_SERVICES=1)
  --dry-run               Print what would be done, change nothing (OMNYSHELL_DRY_RUN=1)
  --uninstall             Remove omnyshell, its PATH block and a downloaded Dart SDK
                          (OMNYSHELL_UNINSTALL=1)
  --quiet                 Only print errors and the summary (OMNYSHELL_QUIET=1)
  --verbose               Also print every command run (OMNYSHELL_VERBOSE=1)
  -h, --help              Show this help
EOF
}

die() {
  printf 'omnyshell-install: error: %s\n' "$*" >&2
  exit 1
}

need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then die "$1 needs a value (see --help)"; fi
}

while [ $# -gt 0 ]; do
  case $1 in
    --version) need_value "$@"; opt_version=$2; shift ;;
    --version=*) opt_version=${1#*=} ;;
    --source) need_value "$@"; opt_source=$2; shift ;;
    --source=*) opt_source=${1#*=} ;;
    --git) need_value "$@"; opt_git=$2; shift ;;
    --git=*) opt_git=${1#*=} ;;
    --git-ref) need_value "$@"; opt_git_ref=$2; shift ;;
    --git-ref=*) opt_git_ref=${1#*=} ;;
    --no-tools) opt_no_tools=1 ;;
    --no-modify-path) opt_no_modify_path=1 ;;
    --no-sudo) opt_no_sudo=1 ;;
    --dart-method) need_value "$@"; opt_dart_method=$2; shift ;;
    --dart-method=*) opt_dart_method=${1#*=} ;;
    --dart-dir) need_value "$@"; opt_dart_dir=$2; shift ;;
    --dart-dir=*) opt_dart_dir=${1#*=} ;;
    --no-dart-upgrade) opt_no_dart_upgrade=1 ;;
    --reinstall-services) opt_reinstall_services=1 ;;
    --dry-run) opt_dry_run=1 ;;
    --uninstall) opt_uninstall=1 ;;
    --quiet) opt_quiet=1 ;;
    --verbose) opt_verbose=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

case $opt_dart_method in
  auto | system | zip) ;;
  *) die "--dart-method must be auto, system or zip (got '$opt_dart_method')" ;;
esac
if [ -n "$opt_source" ] && [ -n "$opt_git" ]; then
  die '--source and --git cannot be combined'
fi
if [ -n "$opt_version" ] && { [ -n "$opt_source" ] || [ -n "$opt_git" ]; }; then
  die '--version cannot be combined with --source or --git'
fi
if [ -n "$opt_git_ref" ] && [ -z "$opt_git" ]; then
  die '--git-ref needs --git'
fi

# --- output -----------------------------------------------------------------

say() { [ "$opt_quiet" = 1 ] || printf '%s\n' "$*" >&2; }
step() { say "==> $*"; }
info() { say "    $*"; }
warn() { printf 'omnyshell-install: warning: %s\n' "$*" >&2; }

# Runs a command, echoing it with --verbose/--dry-run; --dry-run skips it.
run() {
  if [ "$opt_verbose" = 1 ] || [ "$opt_dry_run" = 1 ]; then
    printf '    $ %s\n' "$*" >&2
  fi
  [ "$opt_dry_run" = 1 ] && return 0
  if [ "$opt_quiet" = 1 ]; then
    "$@" >/dev/null
  else
    "$@"
  fi
}

# --- environment --------------------------------------------------------------

[ -n "${HOME:-}" ] || die 'HOME is not set'

os=$(uname -s)
case $os in
  Linux) os_tag=linux ;;
  Darwin) os_tag=macos ;;
  MINGW* | MSYS* | CYGWIN*)
    die "this is Windows; in PowerShell run: irm $REPO_RAW/install.ps1 | iex"
    ;;
  *) die "unsupported operating system: $os" ;;
esac

case $(uname -m) in
  x86_64 | amd64) arch_tag=x64 ;;
  aarch64 | arm64) arch_tag=arm64 ;;
  armv7* | armv8l | armhf) arch_tag=arm ;;
  riscv64) arch_tag=riscv64 ;;
  *) die "unsupported CPU architecture: $(uname -m)" ;;
esac
# A Rosetta-translated shell on Apple silicon reports x86_64; use the native SDK.
if [ "$os_tag" = macos ] && [ "$arch_tag" = x64 ] &&
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then
  arch_tag=arm64
fi

distro_id=''
if [ -r /etc/os-release ]; then
  # shellcheck source=/dev/null # only exists on the target machine
  distro_id=$(. /etc/os-release && echo "${ID:-}")
fi

is_musl=0
if [ "$os_tag" = linux ]; then
  for f in /lib/ld-musl-*; do [ -e "$f" ] && is_musl=1; done
fi

dart_dir=${opt_dart_dir:-$HOME/.omnyshell/dart-sdk}
pub_bin=${PUB_CACHE:-$HOME/.pub-cache}/bin
orig_path=$PATH

tmp_dir=$(mktemp -d 2>/dev/null || mktemp -d -t omnyshell-install)
trap 'rm -rf "$tmp_dir"' EXIT
trap 'exit 130' INT TERM

# --- privileges and package managers -----------------------------------------

is_root=0
[ "$(id -u)" = 0 ] && is_root=1

# sudo/doas are used only when they can work: without a password, or with a
# terminal to ask for one on (a piped `curl | sh` still has /dev/tty).
root_cmd=''
if [ "$is_root" = 0 ] && [ "$opt_no_sudo" = 0 ]; then
  has_tty=0
  if (: </dev/tty) 2>/dev/null; then has_tty=1; fi
  if command -v sudo >/dev/null 2>&1; then
    if sudo -n true 2>/dev/null || [ "$has_tty" = 1 ]; then root_cmd=sudo; fi
  elif command -v doas >/dev/null 2>&1; then
    if doas -n true 2>/dev/null || [ "$has_tty" = 1 ]; then root_cmd=doas; fi
  fi
fi

can_root() { [ "$is_root" = 1 ] || [ -n "$root_cmd" ]; }

root_notice_shown=0
as_root() {
  if [ "$is_root" = 1 ]; then
    run "$@"
  elif [ -n "$root_cmd" ]; then
    if [ "$root_notice_shown" = 0 ] && ! $root_cmd -n true 2>/dev/null; then
      say "    Administrator rights are needed; $root_cmd may ask for your password."
      root_notice_shown=1
    fi
    run $root_cmd "$@"
  else
    return 1
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

pm=''
if [ "$os_tag" = macos ]; then
  have brew && pm=brew
else
  for candidate in apt-get dnf yum zypper pacman apk; do
    if have "$candidate"; then pm=$candidate; break; fi
  done
fi

# Homebrew refuses to run as root.
brew_usable() { have brew && [ "$is_root" = 0 ]; }

apt_updated=0
# Installs system packages with the detected package manager. Returns non-zero
# when that is impossible (no manager, no root) or the install fails.
pkg_install() {
  [ $# -gt 0 ] || return 0
  case $pm in
    brew)
      brew_usable || return 1
      run brew install "$@"
      ;;
    apt-get)
      can_root || return 1
      if [ "$apt_updated" = 0 ]; then
        as_root apt-get update -qq || return 1
        apt_updated=1
      fi
      as_root env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -qq --no-install-recommends "$@"
      ;;
    dnf | yum)
      can_root || return 1
      as_root "$pm" install -y -q "$@"
      ;;
    zypper)
      can_root || return 1
      as_root zypper --non-interactive --quiet install "$@"
      ;;
    pacman)
      can_root || return 1
      as_root pacman -S --needed --noconfirm "$@"
      ;;
    apk)
      can_root || return 1
      as_root apk add --no-cache "$@"
      ;;
    *) return 1 ;;
  esac
}

# The package that provides [tool] for the detected package manager.
package_for() {
  case $1:$pm in
    script:apt-get) echo bsdutils ;;
    # dnf/yum/zypper resolve a file path to whichever package provides it.
    script:dnf | script:yum | script:zypper) echo /usr/bin/script ;;
    script:*) echo util-linux ;;
    gpg:apt-get) echo gpg ;;
    *) echo "$1" ;;
  esac
}

# The command a user would run to install [packages] themselves.
manual_install_hint() {
  case $pm in
    brew) echo "brew install $*" ;;
    apt-get) echo "sudo apt-get install $*" ;;
    dnf | yum | zypper) echo "sudo $pm install $*" ;;
    pacman) echo "sudo pacman -S $*" ;;
    apk) echo "apk add $*" ;;
    *) echo "install $* with your package manager" ;;
  esac
}

# --- downloads --------------------------------------------------------------

ensure_downloader() {
  have curl || have wget && return 0
  step 'Installing curl (needed to download)'
  pkg_install curl ca-certificates ||
    die "neither curl nor wget is available; $(manual_install_hint curl)"
}

download() {
  if have curl; then
    run curl -fsSL --retry 3 -o "$2" "$1"
  else
    run wget -q -O "$2" "$1"
  fi
}

sha256_of() {
  if have sha256sum; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# --- versions and paths -------------------------------------------------------

# Succeeds when version $1 >= $2 (numeric major.minor.patch; pre-release
# suffixes such as `-12.0.dev` are ignored).
version_ge() {
  _a=${1%%-*} _b=${2%%-*} _i=1
  while [ "$_i" -le 3 ]; do
    _x=$(echo "$_a" | cut -d. -f"$_i") _y=$(echo "$_b" | cut -d. -f"$_i")
    _x=${_x:-0} _y=${_y:-0}
    [ "$_x" -gt "$_y" ] && return 0
    [ "$_x" -lt "$_y" ] && return 1
    _i=$((_i + 1))
  done
  return 0
}

dart_version_of() {
  "$1" --version 2>&1 | sed -n 's/.*Dart SDK version: \([0-9][0-9.]*[^ ]*\).*/\1/p' | head -n1
}

resolve_path() {
  realpath "$1" 2>/dev/null || readlink -f "$1" 2>/dev/null || echo "$1"
}

on_path() {
  case ":$orig_path:" in *":$1:"*) return 0 ;; *) return 1 ;; esac
}

# Prints the first Dart found on PATH or in a common install location.
find_dart() {
  if have dart; then
    command -v dart
    return 0
  fi
  for c in "$dart_dir/bin/dart" /usr/lib/dart/bin/dart /opt/homebrew/bin/dart \
    /usr/local/bin/dart "$HOME/flutter/bin/dart" \
    "$HOME/development/flutter/bin/dart" "$HOME/fvm/default/bin/dart" \
    /snap/bin/dart; do
    if [ -x "$c" ]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

# How the Dart at $1 was installed: sets dart_kind (zip, flutter, fvm, brew,
# asdf, mise, snap, apt, rpm, pacman, unmanaged) and dart_pkg / flutter_bin.
classify_dart() {
  _bin=$1
  _real=$(resolve_path "$_bin")
  dart_pkg='' flutter_bin=''
  case $_real in
    "$dart_dir"/*) dart_kind=zip; return ;;
  esac
  case $_bin:$_real in
    */fvm/*) dart_kind=fvm; return ;;
  esac
  if [ -x "$(dirname "$_bin")/flutter" ]; then
    flutter_bin=$(dirname "$_bin")/flutter
  else
    case $_real in
      */bin/cache/dart-sdk/bin/dart)
        _root=${_real%/bin/cache/dart-sdk/bin/dart}
        [ -x "$_root/bin/flutter" ] && flutter_bin=$_root/bin/flutter
        ;;
    esac
  fi
  if [ -n "$flutter_bin" ]; then dart_kind=flutter; return; fi
  case $_bin:$_real in
    */.asdf/* | "${ASDF_DATA_DIR:-/nonexistent}"/*) dart_kind=asdf; return ;;
    */mise/* | */rtx/*) dart_kind=mise; return ;;
    /snap/*) dart_kind=snap; return ;;
  esac
  if have brew; then
    _prefix=$(brew --prefix 2>/dev/null || true)
    case $_real in
      "$_prefix"/* | */Cellar/*)
        dart_kind=brew
        if brew list --formula dart >/dev/null 2>&1; then
          dart_pkg=dart
        else
          dart_pkg=dart-sdk
        fi
        return
        ;;
    esac
  fi
  if have dpkg && _owner=$(dpkg -S "$_real" 2>/dev/null); then
    dart_kind=apt dart_pkg=${_owner%%:*}
    return
  fi
  if have rpm && _owner=$(rpm -qf --qf '%{NAME}' "$_real" 2>/dev/null); then
    dart_kind=rpm dart_pkg=$_owner
    return
  fi
  if have pacman && _owner=$(pacman -Qqo "$_real" 2>/dev/null); then
    dart_kind=pacman dart_pkg=$_owner
    return
  fi
  dart_kind=unmanaged
}

# --- Dart installation ------------------------------------------------------

dart_bin=''
dart_prefer_path=0  # 1: put the Dart bin dir first on PATH (downloaded SDK)

install_dart_zip() {
  step "Downloading the Dart SDK into $dart_dir"
  [ "$is_musl" = 0 ] || die 'the Dart SDK does not run on musl-based systems (e.g. Alpine); use a glibc distribution'
  ensure_downloader
  have unzip || pkg_install unzip || die "unzip is needed; $(manual_install_hint unzip)"
  if [ -e "$dart_dir" ] && [ ! -e "$dart_dir/$ZIP_MARKER" ] &&
    [ -n "$(ls -A "$dart_dir" 2>/dev/null)" ]; then
    die "$dart_dir exists and was not created by this installer; choose another --dart-dir"
  fi
  _zip=dartsdk-$os_tag-$arch_tag-release.zip
  download "$DART_ARCHIVE/$_zip" "$tmp_dir/$_zip"
  download "$DART_ARCHIVE/$_zip.sha256sum" "$tmp_dir/$_zip.sha256sum"
  if [ "$opt_dry_run" = 0 ]; then
    _want=$(cut -d' ' -f1 <"$tmp_dir/$_zip.sha256sum")
    _got=$(sha256_of "$tmp_dir/$_zip")
    [ "$_want" = "$_got" ] || die "checksum mismatch for $_zip (expected $_want, got $_got)"
  fi
  run unzip -q "$tmp_dir/$_zip" -d "$tmp_dir/unzipped"
  run rm -rf "$dart_dir"
  run mkdir -p "$(dirname "$dart_dir")"
  run mv "$tmp_dir/unzipped/dart-sdk" "$dart_dir"
  [ "$opt_dry_run" = 1 ] || : >"$dart_dir/$ZIP_MARKER"
  dart_bin=$dart_dir/bin/dart
  dart_prefer_path=1
}

install_dart_apt() {
  _arch=$(dpkg --print-architecture)
  case $_arch in amd64 | armhf | arm64 | riscv64) ;; *) return 1 ;; esac
  step 'Installing the Dart SDK from the official apt repository'
  ensure_downloader
  have gpg || pkg_install gpg || return 1
  download "$DART_APT_KEY" "$tmp_dir/dart.pub" || return 1
  if [ "$opt_dry_run" = 0 ]; then
    gpg --dearmor <"$tmp_dir/dart.pub" >"$tmp_dir/dart.gpg" || return 1
  fi
  as_root install -m 644 "$tmp_dir/dart.gpg" /usr/share/keyrings/dart.gpg || return 1
  echo "deb [signed-by=/usr/share/keyrings/dart.gpg arch=$_arch] $DART_APT_REPO stable main" \
    >"$tmp_dir/dart_stable.list"
  as_root install -m 644 "$tmp_dir/dart_stable.list" \
    /etc/apt/sources.list.d/dart_stable.list || return 1
  apt_updated=0
  pkg_install dart || return 1
  dart_bin=/usr/lib/dart/bin/dart
}

install_dart_brew() {
  step 'Installing the Dart SDK with Homebrew'
  if run brew tap dart-lang/dart; then
    # Newer Homebrew requires third-party taps to be trusted.
    if brew help trust >/dev/null 2>&1; then run brew trust dart-lang/dart || true; fi
    if run brew install dart-lang/dart/dart; then
      dart_bin=$(brew --prefix)/bin/dart
      return 0
    fi
  fi
  info 'The dart-lang tap failed; trying the core dart-sdk formula'
  run brew install dart-sdk || return 1
  dart_bin=$(brew --prefix)/bin/dart
}

# Installs Dart the way this OS usually installs software.
install_dart_system() {
  case $os_tag:$pm in
    macos:brew) brew_usable && install_dart_brew ;;
    linux:apt-get) can_root && install_dart_apt ;;
    linux:pacman)
      can_root || return 1
      step 'Installing the Dart SDK with pacman'
      as_root pacman -Syu --needed --noconfirm dart || return 1
      dart_bin=/usr/bin/dart
      ;;
    *) return 1 ;;
  esac
}

install_dart_fresh() {
  if [ "$opt_dart_method" = zip ]; then
    install_dart_zip
    return
  fi
  if install_dart_system; then return; fi
  [ "$opt_dart_method" = system ] &&
    die 'no system package manager could install Dart here (try --dart-method zip)'
  info 'No usable package manager for Dart here; using the official SDK download'
  install_dart_zip
}

upgrade_dart() {
  step "Upgrading the Dart SDK ($dart_kind install)"
  case $dart_kind in
    zip) install_dart_zip ;;
    flutter) run "$flutter_bin" upgrade ;;
    fvm) run fvm install stable && run fvm global stable ;;
    brew) run brew upgrade "$dart_pkg" ;;
    apt)
      can_root || return 1
      as_root apt-get update -qq && apt_updated=1 &&
        as_root env DEBIAN_FRONTEND=noninteractive \
          apt-get install -y -qq --only-upgrade "$dart_pkg"
      ;;
    rpm)
      can_root || return 1
      case $pm in
        zypper) as_root zypper --non-interactive update "$dart_pkg" ;;
        *) as_root "$pm" upgrade -y -q "$dart_pkg" ;;
      esac
      ;;
    pacman) can_root && as_root pacman -Syu --needed --noconfirm "$dart_pkg" ;;
    snap) can_root && as_root snap refresh "$(basename "$(resolve_path "$dart_bin")")" ;;
    asdf)
      run asdf plugin add dart >/dev/null 2>&1 || true
      run asdf install dart latest &&
        { run asdf set -u dart latest 2>/dev/null || run asdf global dart latest; }
      ;;
    mise) run mise use -g dart@latest ;;
    *) return 1 ;;
  esac
}

ensure_dart() {
  if [ "$opt_dart_method" != zip ] && found=$(find_dart); then
    dart_bin=$found
    version=$(dart_version_of "$dart_bin")
    classify_dart "$dart_bin"
    if [ -n "$version" ] && version_ge "$version" "$MIN_DART_VERSION"; then
      step "Using Dart $version ($dart_bin)"
      if [ "$dart_kind" = zip ]; then dart_prefer_path=1; fi
      return 0
    fi
    info "Found Dart ${version:-of unknown version} at $dart_bin ($dart_kind); omnyshell needs >= $MIN_DART_VERSION"
    [ "$opt_no_dart_upgrade" = 0 ] ||
      die "Dart is too old and --no-dart-upgrade was given; upgrade it to $MIN_DART_VERSION or newer and re-run"
    if [ "$dart_kind" != unmanaged ] && upgrade_dart; then
      [ "$opt_dry_run" = 1 ] && return
      if found=$(find_dart); then dart_bin=$found; fi
      version=$(dart_version_of "$dart_bin")
      if [ -n "$version" ] && version_ge "$version" "$MIN_DART_VERSION"; then
        step "Dart upgraded to $version"
        return
      fi
      warn "Dart is still ${version:-unknown} after upgrading it with $dart_kind"
    fi
    [ "$opt_dart_method" = system ] &&
      die "could not upgrade Dart at $dart_bin; upgrade it to $MIN_DART_VERSION or newer and re-run"
    warn "installing a separate Dart SDK in $dart_dir, placed ahead of $dart_bin on PATH"
    install_dart_zip
    return
  fi
  install_dart_fresh
}

# --- tools -----------------------------------------------------------------

has_script() { [ -x /usr/bin/script ] || [ -x /bin/script ]; }

# macOS ships a `git` stub that opens an installer dialog; only the Command
# Line Tools (or Homebrew's git) make it real.
has_git() {
  if [ "$os_tag" = macos ]; then
    xcode-select -p >/dev/null 2>&1 || [ -x "$(brew --prefix 2>/dev/null)/bin/git" ]
  else
    have git
  fi
}

ensure_tools() {
  missing=''
  has_git || missing="$missing git"
  have openssl || missing="$missing openssl"
  [ "$os_tag" = macos ] || has_script || missing="$missing script"
  [ -n "$missing" ] || { step 'Tools: git, openssl and script are present'; return; }

  if [ "$opt_no_tools" = 1 ]; then
    warn "--no-tools: not installing${missing} (git: drive git mounts; openssl: omnyshell cert gen; script: full-screen programs on a Node)"
    return
  fi
  packages=''
  for tool in $missing; do packages="$packages $(package_for "$tool")"; done
  step "Installing tools:${missing}"
  # shellcheck disable=SC2086 # word-splitting the package list is intended
  if ! pkg_install $packages; then
    # shellcheck disable=SC2086
    warn "could not install${missing}; install them with: $(manual_install_hint $packages)"
    if [ "$os_tag" = macos ]; then
      case $missing in *git*) warn 'or get git from the Command Line Tools: xcode-select --install' ;; esac
    fi
  fi
}

# --- PATH -----------------------------------------------------------------

# The rc files a login or interactive shell of this user reads.
rc_files() {
  _shell=$(basename "${SHELL:-sh}")
  case $_shell in
    zsh) echo "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash)
      echo "$HOME/.bashrc"
      if [ "$os_tag" = macos ] || [ -e "$HOME/.bash_profile" ]; then
        echo "$HOME/.bash_profile"
      fi
      ;;
  esac
  echo "$HOME/.profile"
}

# Every rc file a previous run may have written to (for --uninstall).
all_rc_files() {
  echo "${ZDOTDIR:-$HOME}/.zshrc"
  echo "$HOME/.bashrc"
  echo "$HOME/.bash_profile"
  echo "$HOME/.profile"
}

fish_conf() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/omnyshell.fish"; }

# Writes $HOME-relative paths as "$HOME/..." so the block survives a moved home.
home_rel() {
  case $1 in
    "$HOME"/*) printf '%s' "\$HOME/${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

remove_block() {
  [ -f "$1" ] && grep -qxF "$BLOCK_BEGIN" "$1" || return 0
  sed "/^$BLOCK_BEGIN\$/,/^$BLOCK_END\$/d" "$1" >"$tmp_dir/rc.new"
  # Rewrite in place so permissions, ownership and symlinks are kept.
  cat "$tmp_dir/rc.new" >"$1"
}

path_block() {
  echo "$BLOCK_BEGIN"
  echo '# Added by the omnyshell installer; delete this block to undo.'
  if [ -n "$dart_path_dir" ]; then
    _d=$(home_rel "$dart_path_dir")
    if [ "$dart_prefer_path" = 1 ]; then
      echo "case \":\$PATH:\" in *\":$_d:\"*) ;; *) export PATH=\"$_d:\$PATH\" ;; esac"
    else
      echo "case \":\$PATH:\" in *\":$_d:\"*) ;; *) export PATH=\"\$PATH:$_d\" ;; esac"
    fi
  fi
  _p=$(home_rel "$pub_bin")
  echo "case \":\$PATH:\" in *\":$_p:\"*) ;; *) export PATH=\"\$PATH:$_p\" ;; esac"
  echo "$BLOCK_END"
}

fish_block() {
  echo "$BLOCK_BEGIN"
  echo '# Added by the omnyshell installer; delete this file to undo.'
  if [ -n "$dart_path_dir" ]; then
    if [ "$dart_prefer_path" = 1 ]; then
      echo "fish_add_path --global --move --path '$dart_path_dir'"
    else
      echo "fish_add_path --global --append --path '$dart_path_dir'"
    fi
  fi
  echo "fish_add_path --global --append --path '$pub_bin'"
  echo "$BLOCK_END"
}

configure_path() {
  dart_path_dir=''
  if [ -n "$dart_bin" ]; then
    _dir=$(dirname "$dart_bin")
    if [ "$dart_prefer_path" = 1 ] || ! on_path "$_dir"; then dart_path_dir=$_dir; fi
  fi
  # This process needs them too, to verify the install.
  [ -n "$dart_path_dir" ] && PATH=$dart_path_dir:$PATH
  PATH=$PATH:$pub_bin
  export PATH

  if [ "$opt_no_modify_path" = 1 ]; then
    step 'Not changing PATH (--no-modify-path); add this to your shell profile:'
    path_block | sed 's/^/    /' >&2
    return
  fi
  step 'Adding omnyshell to PATH'
  for rc in $(rc_files); do
    info "$rc"
    [ "$opt_dry_run" = 1 ] && continue
    remove_block "$rc"
    # Separate the block from existing content with a blank line.
    if [ -s "$rc" ]; then echo >>"$rc"; fi
    path_block >>"$rc"
  done
  if [ "$(basename "${SHELL:-}")" = fish ] || [ -d "${XDG_CONFIG_HOME:-$HOME/.config}/fish" ]; then
    _conf=$(fish_conf)
    info "$_conf"
    if [ "$opt_dry_run" = 0 ]; then
      mkdir -p "$(dirname "$_conf")"
      fish_block >"$_conf"
    fi
  fi
}

# --- omnyshell ------------------------------------------------------------

activate_omnyshell() {
  if [ -n "$opt_source" ]; then
    step "Installing omnyshell from $opt_source"
    run "$dart_bin" pub global activate --source path "$opt_source"
  elif [ -n "$opt_git" ]; then
    step "Installing omnyshell from $opt_git${opt_git_ref:+ ($opt_git_ref)}"
    if [ -n "$opt_git_ref" ]; then
      run "$dart_bin" pub global activate --source git "$opt_git" --git-ref "$opt_git_ref"
    else
      run "$dart_bin" pub global activate --source git "$opt_git"
    fi
  else
    step "Installing omnyshell${opt_version:+ $opt_version} from pub.dev"
    if [ -n "$opt_version" ]; then
      run "$dart_bin" pub global activate omnyshell "$opt_version"
    else
      run "$dart_bin" pub global activate omnyshell
    fi
  fi
}

handle_services() {
  _omny=$1
  for role in hub node; do
    _info=$("$_omny" service info "$role" 2>/dev/null || true)
    case $_info in 'Service "'*) ;; *) continue ;; esac
    if [ "$opt_reinstall_services" = 1 ]; then
      step "Reinstalling the $role service on the new version"
      run "$_omny" service reinstall "$role" ||
        warn "could not reinstall the $role service; run: omnyshell service reinstall $role"
    else
      info "A $role service is installed; it keeps running the previous version until you run: omnyshell service reinstall $role"
    fi
  done
}

# --- uninstall ------------------------------------------------------------

uninstall() {
  step 'Uninstalling omnyshell'
  if found=$(find_dart); then
    run "$found" pub global deactivate omnyshell || info 'omnyshell was not activated'
  fi
  for rc in $(all_rc_files) ; do
    if [ -f "$rc" ] && grep -qxF "$BLOCK_BEGIN" "$rc"; then
      info "Removing the PATH block from $rc"
      [ "$opt_dry_run" = 1 ] || remove_block "$rc"
    fi
  done
  _conf=$(fish_conf)
  if [ -f "$_conf" ]; then
    info "Removing $_conf"
    run rm -f "$_conf"
  fi
  if [ -e "$dart_dir/$ZIP_MARKER" ]; then
    info "Removing the Dart SDK this installer downloaded ($dart_dir)"
    run rm -rf "$dart_dir"
  fi
  say ''
  say 'omnyshell is uninstalled. Kept: a Dart SDK installed by a package manager,'
  say 'git/openssl/script, and ~/.omnyshell (configuration and credentials).'
  say 'Services, if any, are removed with: omnyshell service uninstall <hub|node>'
  say '(run that before uninstalling, while the omnyshell command still exists).'
}

# --- main -----------------------------------------------------------------

main() {
  if [ "$opt_uninstall" = 1 ]; then
    uninstall
    return
  fi
  [ "$opt_dry_run" = 0 ] || step 'Dry run: nothing will be changed'
  step "Installing omnyshell on $os_tag-$arch_tag${distro_id:+ ($distro_id)}"
  [ "$is_musl" = 0 ] || die 'musl-based systems (e.g. Alpine) are not supported: the Dart SDK needs glibc'
  [ -n "$pm" ] || info 'No supported package manager found; tools cannot be installed automatically'

  ensure_dart
  ensure_tools
  activate_omnyshell
  configure_path

  if [ "$opt_dry_run" = 1 ]; then
    step 'Dry run finished'
    return
  fi
  omny=$pub_bin/omnyshell
  [ -x "$omny" ] || die "omnyshell was not found at $omny after installing it"
  # A source-activated wrapper prints pub's resolution output first.
  installed=$("$omny" --version 2>/dev/null | tail -n1) || die "$omny --version failed"
  case $installed in omnyshell\ *) ;; *) die "$omny --version failed" ;; esac
  handle_services "$omny"

  opt_quiet=0
  say ''
  say "Installed: $installed"
  say "Dart:      $("$dart_bin" --version 2>&1 | head -n1)"
  if [ "$opt_no_modify_path" = 0 ]; then
    say 'Open a new terminal, or run this to use omnyshell in the current one:'
    say "  export PATH=\"${dart_path_dir:+$dart_path_dir:}\$PATH:$pub_bin\""
  fi
  say 'Get started: omnyshell --help   (docs: https://github.com/OmnyGrid/omnyshell)'
}

main
