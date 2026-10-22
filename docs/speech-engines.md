# Choosing speech engines

The same text is the "Choosing speech engines" section of emacspeak-docker's GUIDE.md.

Every installer in `scripts/` takes the same option, `--speech LIST`
(`-Speech LIST` in the Windows script): a comma-separated list of engine
names, in order of preference. The first one becomes the launcher's default
speech server, `DTK_PROGRAM`. `--speech all` takes every engine the platform
offers, except Voxin, which also needs `--voxin-archive FILE`. `--speech list`
prints the platform's engines, one per line, with what each needs, and exits.

Run without `--speech` in a terminal, an installer asks with a numbered menu:
a title, one line per engine, and a prompt on its own line. Enter takes the
default, and the choice is read back as "Selected: ...". Without a terminal
(a pipe, a script, CI), the default is taken and one line says so. The choice
is recorded in `<prefix>/speech-engines`, so a later rerun updates everything
without asking again. A rerun with a new `--speech` list changes the default
and the record but removes nothing already installed.

The engines, by platform:

- **Linux** (Fedora, Debian family, Arch family): `espeak`, emacspeak's own
  Tcl server with eSpeak NG (the default); `omnivox`, OmniVox built from
  source with cargo, which on Linux also speaks through eSpeak NG but with
  its own audio pipeline; `dectalk`, the community software DECtalk built
  from source into `/opt/dectalk`, with emacspeak's `dtk-soft` server;
  `voxin`, Eloquence from your paid Voxin archive, with emacspeak's `outloud`
  server.
- **macOS:** `omnivox` (the default, the system voices); `espeak`, OmniVox's
  built-in eSpeak NG engine, with voice data from Homebrew's espeak-ng and
  selected with `OMNIVOX_ENGINE=espeak`; `swiftmac`, emacspeak's Swift
  server, which needs Swift 5.9 or newer; and `tclespeak`, the Tcl espeak
  server, the heavy route: Homebrew's deprecated `tcl-tk@8`, TclX built from
  source, and sox for the auditory icons. Tones are unavailable with it,
  because emacspeak looks for sox only at `/usr/bin/sox`.
- **Windows:** `omnivox` (the default, the system voices); `espeak`,
  OmniVox's eSpeak NG engine, which needs eSpeak NG's voice data from the
  eSpeak NG installer (winget id `eSpeak-NG.eSpeak-NG`); and `sharpwin`, the
  C# server, built with the .NET 8 SDK. `-NoSound` skips every self-test that
  would play audio.

Switching later: `DTK_PROGRAM=<server> emacspeak` (on Windows,
`set DTK_PROGRAM=<server>` before `emacspeak.cmd`), or `M-x dtk-select-server`
inside Emacs. The generated init file, `<prefix>/emacspeak-init.el`, loads
each server's own Lisp only when that server is selected, so one init file
serves all of them; your own settings go in `emacspeak-local.el` beside it.

Notes from building OmniVox 1.3.0 on Linux. It ships no `Cargo.lock` and
calls `usize::is_multiple_of`, so as written it needs Rust 1.87 or newer;
the Debian script builds it with Debian 13's Rust 1.85 by pinning cargo's
resolver to the Rust at hand and rewriting that one call, and on Ubuntu 24.04
it installs the `rustc-1.91` and `cargo-1.91` packages. bindgen needs
libclang (`libclang-dev` or `clang`), and the ALSA crate needs the alsa-lib
headers and pkg-config. On Arch, a system espeak-ng brings pcaudiolib and
libsonic headers that make OmniVox's bundled eSpeak NG fail to link; the
script turns both off through a CMake toolchain file. OmniVox finds eSpeak
NG's voice data through `ESPEAK_NG_DATA`, a build-time path, a folder beside
the binary, or the standard shared folders, in that order; the prebuilt
macOS and Windows binaries carry a build-time path from GitHub's runners
that exists nowhere else.

