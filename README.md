# emacspeak installers

One script per platform that installs [emacspeak](https://github.com/tvraman/emacspeak),
T. V. Raman's audio desktop for Emacs, with a working speech server on
today's systems. Clone, run one script, type `emacspeak`.

No Docker here. These are the bare-metal installers from
[emacspeak-docker](https://github.com/leavesofgrass/emacspeak-docker), kept
in both places for people who want only the scripts.

Why a script at all: emacspeak's speech servers are Tcl scripts that need
Tcl 8.6 and the TclX extension, plus a small C or C++ glue library per
synthesizer. Fedora ships Tcl 9 as its default, Arch does not package TclX,
and macOS and Windows have no sensible Tcl route, so a plain `make` fails
on each of them for a different reason. Each script knows its platform's way
around that, checks its own work, and says plainly what it did. The scripts
are written for screen reader users: one plain line per step, the key fact
first, no spinners, no progress bars.

## Quick start

```bash
git clone https://github.com/leavesofgrass/emacspeak-installer
cd emacspeak-installer
```

Then the script for your system. Every script has the same options
(`--help` lists them), self-tests, and a rerun that updates emacspeak and
rebuilds.

- **Fedora 43, 44 or 45:** `sudo bash scripts/install-emacspeak-fedora.sh`.
  Fedora's default `tcl` is Tcl 9, which emacspeak cannot use. The script
  installs Fedora's own `tcl8`, `tcl8-devel` and `tclx` packages and points
  the speech servers at `tclsh8.6`. Fedora's packaged `emacspeak` (60.0)
  does not do that: as shipped on Fedora 44 its servers start Tcl 9 and die
  with "can't find package Tclx".
- **Debian 13, Ubuntu 24.04, and relatives such as Linux Mint 22:**
  `sudo bash scripts/install-emacspeak-debian.sh`. Stock Tcl 8.6 and
  `tclx8.4`. On Debian 12 and Ubuntu 22.04 it stops early, because their
  Emacs is older than 29.1, and names the backports route on Debian.
- **Arch, CachyOS, EndeavourOS, Manjaro:**
  `sudo bash scripts/install-emacspeak-arch.sh`. Arch's `tcl` is still 8.6.
  TclX is not packaged, so the script builds it from source into
  `/usr/lib/tclx8.6`. The pacman step is a full system upgrade, as Arch
  requires.
- **macOS 13 or newer:** `bash scripts/install-emacspeak-macos.sh` as your
  normal user, with Homebrew installed. The default speech server is
  OmniVox, a Rust server by the swiftmac author that speaks with the macOS
  system voices; the script installs its checksum-verified release, or
  builds it with `--omnivox-source`, installs Homebrew's terminal `emacs`
  when none is 29.1 or newer (`--emacs-plus` installs emacs-plus@30 with
  Emacs.app instead), and writes an `emacspeak` launcher into Homebrew's
  bin. Verified on GitHub's Apple silicon and Intel runners, where the
  system voice gives no audio, so the speech self-tests report a warning
  and a skip there.
- **Windows 10 or 11:** in PowerShell, as your normal user,
  `powershell -ExecutionPolicy Bypass -File scripts\install-emacspeak-windows.ps1`.
  The default speech server is OmniVox with the Windows system voices. The
  script installs GNU Emacs with winget when none is 29.1 or newer, clones
  and byte-compiles emacspeak into `.emacspeak` in your profile folder, and
  writes an `emacspeak.cmd` launcher that starts GUI Emacs. It changes
  nothing outside that folder unless you pass `-AddToPath`, `-SetHome` or
  `-StartMenuShortcut`. NVDA and JAWS speak over emacspeak unless you pause
  them; the summary says how. `-NoSound` keeps the self-tests silent.
  Verified on GitHub's x64 and arm64 runners.

## Choosing speech engines

Every script takes `--speech LIST` (`-Speech LIST` on Windows): engine
names in order of preference, the first one the launcher's default.
`--speech list` shows the platform's choices. A run in a terminal without
`--speech` asks with a numbered menu; a run without a terminal takes the
default and says so. The choice is recorded, so reruns do not ask again.

- Linux: `espeak` (the default), `omnivox` (built from source), `dectalk`
  (the community software DECtalk, built from source) and `voxin`
  (Eloquence, from your paid Voxin archive given with
  `--voxin-archive FILE`).
- macOS: `omnivox` (the default), `espeak` (OmniVox's built-in eSpeak NG
  engine), `swiftmac` (emacspeak's Swift server) and `tclespeak` (emacspeak's
  Tcl espeak server, the heavy route).
- Windows: `omnivox` (the default), `espeak` (OmniVox's eSpeak NG engine,
  which needs eSpeak NG's voice data) and `sharpwin` (the C# server, built
  with the .NET 8 SDK).

Details, including how to switch servers later and the notes from building
OmniVox on Linux, are in [docs/speech-engines.md](docs/speech-engines.md).

## The full Linux installer

`scripts/install-emacspeak-voxin.sh` is the older all-in-one installer for
the Debian, Arch and Fedora families with the Eloquence (Voxin) and
software DECtalk voices:

```bash
sudo ./scripts/install-emacspeak-voxin.sh ~/voxin-enu-v3.x.tar.gz --with-dectalk
```

The per-distribution scripts above now cover the same engines through
`--speech`; the full installer stays for the people already using it.

## What the scripts do not do

They never run as root on macOS or Windows, never delete anything, and
change nothing outside their install folder except what each summary
lists. Nothing proprietary is downloaded on your behalf: Voxin comes from
your own archive, and OmniVox's prebuilt releases are verified against the
checksums its author publishes.

## Testing

The macOS and Windows scripts run on GitHub's runners through the
workflows in `.github/workflows/` on every change to them. The Linux
scripts are tested in Fedora, Debian, Ubuntu and Arch containers before
each change lands. The Docker image, the long guide to the moving parts,
and the gotchas live in
[emacspeak-docker](https://github.com/leavesofgrass/emacspeak-docker).

## Keeping the two repositories in sync

The same scripts live in emacspeak-docker. `tools/sync-from-emacspeak-docker.ps1`
reports which of the shared files differ between a local clone of
emacspeak-docker and this repository, and copies them with `-Apply`
(or `-Reverse` for the other direction). It never deletes anything.

## License

GPL-2.0-or-later, the same as emacspeak and emacspeak-docker. See
[LICENSE](LICENSE).
