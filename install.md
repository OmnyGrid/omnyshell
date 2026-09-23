# Installing OmnyShell

One command installs the `omnyshell` CLI together with everything it needs:
the Dart SDK (when it is missing or too old), the tools OmnyShell uses, and your
`PATH`. The installer asks no questions; it only needs your password (sudo) or a
UAC confirmation when a system package has to be installed.

## Install

**Linux, macOS, WSL**

```sh
curl -fsSL https://raw.githubusercontent.com/OmnyGrid/omnyshell/master/install.sh | sh
```

or, without curl:

```sh
wget -qO- https://raw.githubusercontent.com/OmnyGrid/omnyshell/master/install.sh | sh
```

**Windows (PowerShell)**

```powershell
irm https://raw.githubusercontent.com/OmnyGrid/omnyshell/master/install.ps1 | iex
```

**Windows (cmd.exe)**

```bat
curl -fsSLo %TEMP%\omnyshell-install.bat https://raw.githubusercontent.com/OmnyGrid/omnyshell/master/install.bat && %TEMP%\omnyshell-install.bat
```

Then open a new terminal and check it:

```sh
omnyshell --version
```

To update OmnyShell later, run the same command again.

## What the installer does

1. **Dart SDK (3.10.9 or newer).** OmnyShell is a Dart program, installed with
   `dart pub global activate`.
   - If Dart is already installed and new enough, it is used as is.
   - If it is too old, it is upgraded **the way it was installed**: Homebrew,
     apt, dnf/yum/zypper, pacman, snap, asdf, mise, Flutter (`flutter upgrade`),
     FVM, winget, Chocolatey, Scoop, or the installer's own download. A Dart the
     installer cannot identify is left alone; a separate SDK is downloaded and
     put ahead of it on `PATH`.
   - If Dart is missing, it is installed the way the system usually installs
     software:

     | System | Dart comes from |
     |---|---|
     | macOS with Homebrew | `brew install dart-lang/dart/dart` (falls back to the core `dart-sdk` formula) |
     | Debian, Ubuntu and derivatives | Google's official apt repository |
     | Arch, Manjaro | `pacman -S dart` |
     | Windows | winget (`Google.DartSDK`), else Chocolatey (`dart-sdk`), else Scoop (`dart`) |
     | Anything else, or no admin rights | The official SDK zip, checksum-verified, unpacked into `~/.omnyshell/dart-sdk` (`%LOCALAPPDATA%\omnyshell\dart-sdk` on Windows) |

2. **Tools OmnyShell uses**, installed with the system package manager when
   missing (skip with `--no-tools`):

   | Tool | Used for |
   |---|---|
   | `script` (Linux: `bsdutils`/`util-linux`; built into macOS) | Real terminals on a Node, so `vim`, `htop` and other full-screen programs work |
   | Git for Windows (Windows) | Git Bash and winpty for real terminals on a Windows Node; also `git` |
   | `git` | Drive git mounts |
   | `openssl` | `omnyshell cert gen` (Hub certificates) |

3. **OmnyShell**: `dart pub global activate omnyshell`.
4. **PATH**: the pub-cache `bin` directory (and the Dart SDK, when the installer
   downloaded it) is added to your shell profile, inside a block marked
   `# >>> omnyshell >>>` (`~/.zshrc`, `~/.bashrc`, `~/.bash_profile`,
   `~/.profile`, fish's `conf.d/omnyshell.fish`), or to the user `PATH` on
   Windows.
5. **Services**: if a Hub or Node service is installed, the installer tells you
   to run `omnyshell service reinstall <hub|node>` so it picks up the new
   version (or does it for you with `--reinstall-services`).

## Options

Pass options after `sh -s --` when piping:

```sh
curl -fsSL https://raw.githubusercontent.com/OmnyGrid/omnyshell/master/install.sh | sh -s -- --version 1.60.0 --no-tools
```

With `irm … | iex`, which cannot take arguments, set the matching environment
variable instead:

```powershell
$env:OMNYSHELL_VERSION = '1.60.0'; irm https://raw.githubusercontent.com/OmnyGrid/omnyshell/master/install.ps1 | iex
```

`install.sh`, `install.ps1` and `install.bat` take the same options:

| Option | Environment variable | Effect |
|---|---|---|
| `--version <v>` | `OMNYSHELL_VERSION` | Install that OmnyShell version instead of the latest |
| `--source <path>` | `OMNYSHELL_SOURCE` | Install from a local checkout |
| `--git <url>` | `OMNYSHELL_GIT` | Install from a git repository |
| `--git-ref <ref>` | `OMNYSHELL_GIT_REF` | Branch, tag or commit for `--git` |
| `--no-tools` | `OMNYSHELL_NO_TOOLS=1` | Don't install git, openssl, `script` or Git for Windows (the installer still lists what is missing) |
| `--no-modify-path` | `OMNYSHELL_NO_MODIFY_PATH=1` | Don't change your shell profile or user `PATH`; print what to add instead |
| `--no-sudo` | `OMNYSHELL_NO_SUDO=1` | Never use sudo/doas or ask for administrator rights: Dart is downloaded instead, missing tools are only reported |
| `--dart-method <m>` | `OMNYSHELL_DART_METHOD` | `auto` (default), `system` (package manager only, fail otherwise) or `zip` (always the downloaded SDK) |
| `--dart-dir <dir>` | `OMNYSHELL_DART_DIR` | Where the downloaded SDK goes |
| `--no-dart-upgrade` | `OMNYSHELL_NO_DART_UPGRADE=1` | Never upgrade an existing Dart (nor run `flutter upgrade`); fail if it is too old |
| `--reinstall-services` | `OMNYSHELL_REINSTALL_SERVICES=1` | Reinstall installed Hub/Node services on the new version (restarts them) |
| `--print-env` | `OMNYSHELL_PRINT_ENV=1` | Print only the `PATH` setup on stdout, for the calling shell to evaluate (see below) |
| `--shell` | `OMNYSHELL_SHELL=1` | Once installed, start a shell that already has the updated `PATH` (see below) |
| `--shell-cmd <cmd>` | `OMNYSHELL_SHELL_CMD` | Run `<cmd>` in that shell first (implies `--shell`); without a terminal, run only `<cmd>` and exit with its status |
| `--dry-run` | `OMNYSHELL_DRY_RUN=1` | Show what would be done and change nothing |
| `--uninstall` | `OMNYSHELL_UNINSTALL=1` | Remove OmnyShell (see below) |
| `--quiet` | `OMNYSHELL_QUIET=1` | Only print errors and the summary |
| `--verbose` | `OMNYSHELL_VERBOSE=1` | Also print every command run |
| `--help` | | Show the options |

Example: try an unreleased branch

```sh
curl -fsSL https://raw.githubusercontent.com/OmnyGrid/omnyshell/master/install.sh | sh -s -- --git https://github.com/OmnyGrid/omnyshell.git --git-ref my-branch
```

## Using omnyshell right after installing

The installer updates your shell profile, so **new** terminals find
`omnyshell`. It cannot change the terminal it was started from: the installer
is a child process, and no child process can change its parent shell's
environment. On Windows, `irm … | iex` runs inside your PowerShell session, so
that session is updated as well. Elsewhere, pick one of these:

**Evaluate the PATH setup in the current shell** (scripts, CI, terminals).
With `--print-env`, the installer prints only the `PATH` lines on stdout
(everything else goes to stderr), so the calling shell can apply them:

```sh
eval "$(curl -fsSL https://raw.githubusercontent.com/OmnyGrid/omnyshell/master/install.sh | sh -s -- --print-env)"
```

`omnyshell` then works on the next line of the same script. From PowerShell,
where `install.ps1` prints PowerShell syntax:

```powershell
powershell -NoProfile -File install.ps1 --print-env | Out-String | Invoke-Expression
```

**Continue in a new shell that has the PATH.** With `--shell`, the installer
ends by starting your shell (`$SHELL`; `cmd.exe` when launched from
`install.bat`, otherwise PowerShell). Exit it to return to the original one:

```sh
curl -fsSL https://raw.githubusercontent.com/OmnyGrid/omnyshell/master/install.sh | sh -s -- --shell
```

**Run a first command in that shell** with `--shell-cmd`. In a terminal, the
command runs and the shell stays open. Without a terminal (automation), only
the command runs, and the installer exits with the command's exit status:

```sh
curl -fsSL https://raw.githubusercontent.com/OmnyGrid/omnyshell/master/install.sh | sh -s -- --shell-cmd 'omnyshell node start --hub wss://hub.example.com:8443 --id web-01'
```

Without a terminal, plain `--shell` has nothing to attach to: it prints a
warning and starts no shell.

## Supported platforms

| Platform | Architectures | Notes |
|---|---|---|
| macOS | Apple silicon, Intel | Homebrew is used when installed; otherwise Dart is downloaded |
| Linux (glibc: Debian, Ubuntu, Fedora, RHEL, openSUSE, Arch, …) | x64, arm64, armv7, riscv64 | |
| WSL | as Linux | Use the Linux command inside WSL |
| Windows 10/11, Windows Server | x64, arm64 | Windows PowerShell 5.1 or PowerShell 7 |
| Alpine and other musl systems | | Not supported: the Dart SDK needs glibc |

## Uninstall

Remove any Hub/Node service first, while `omnyshell` still exists:

```sh
omnyshell service uninstall node   # and/or hub
```

Then:

```sh
curl -fsSL https://raw.githubusercontent.com/OmnyGrid/omnyshell/master/install.sh | sh -s -- --uninstall
```

```powershell
$env:OMNYSHELL_UNINSTALL = '1'; irm https://raw.githubusercontent.com/OmnyGrid/omnyshell/master/install.ps1 | iex
```

This deactivates OmnyShell, removes the installer's `PATH` changes and deletes
the Dart SDK if the installer downloaded it. It keeps a Dart installed by a
package manager, the tools, and `~/.omnyshell` (your configuration and
credentials; delete it yourself to remove those).

## Manual install

With Dart 3.10.9 or newer already installed:

```sh
dart pub global activate omnyshell
```

and add the pub-cache `bin` directory to your `PATH` (`~/.pub-cache/bin`, or
`%LOCALAPPDATA%\Pub\Cache\bin` on Windows).

## Troubleshooting

- **`omnyshell: command not found` right after installing**: open a new
  terminal, or run the `export PATH=…` line the installer printed.
- **No sudo / not an administrator**: use `--no-sudo`. Dart is downloaded into
  your home directory; the installer lists any tools you need to ask an
  administrator for.
- **Behind a proxy**: set `HTTPS_PROXY` (and `HTTP_PROXY`) before running the
  installer; curl, wget, Dart and PowerShell all honour them.
- **Flutter users**: when Flutter's Dart is too old, the installer runs
  `flutter upgrade`. Use `--no-dart-upgrade` to prevent that.
- **See what it would do**: `--dry-run --verbose`.
