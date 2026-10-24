# The emacspeak stack for Windows: neomacs and OmniVox

`scripts/build-emacspeak-stack-windows.ps1` builds an audio desktop on
[neomacs](https://github.com/eval-exec/neomacs), with
[OmniVox](https://github.com/robertmeta/omnivox) speech, in one portable
folder. neomacs replaces GNU Emacs's C core with Rust; OmniVox, a Rust
speech server, replaces emacspeak's Tcl servers. Nothing is installed,
nothing needs administrator rights, and nothing outside the folder
changes.

The audio desktop is [EmacsVox](https://github.com/robertmeta/emacsvox) by
default: a fork of emacspeak modernized for Emacs 31 by the OmniVox
author. `-EmacspeakRepo tvraman/emacspeak` builds upstream emacspeak.

Status in October 2026: **upstream emacspeak works on neomacs 0.0.19**,
every silent self-test passes, a console start included. **EmacsVox does
not work yet**, for reasons in EmacsVox itself (see "EmacsVox" below):
its `master` branch asks a question while it loads, and its newer
`safe-elisp-modernization` branch builds and loads but stops its
interactive start with an error. Until EmacsVox is fixed, build with
`-EmacspeakRepo tvraman/emacspeak`.

For emacspeak on GNU Emacs, the proven route, use
`scripts/install-emacspeak-windows.ps1` instead.

## Quick start

In PowerShell, as your normal user:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-emacspeak-stack-windows.ps1 -EmacspeakRepo tvraman/emacspeak
```

Later runs keep that choice. The folder is `%USERPROFILE%\emacspeak-stack`
by default. Your own settings go in `home\.emacs.d\local.el`; the script
never changes that file. `update.cmd` refreshes everything later.

## The two launchers, and screen readers

- `emacspeak.cmd`, the default, starts neomacs in its own window, the GUI,
  through `runneomacs.exe`.
- `emacspeak-console.cmd` starts `neomacs.exe -nw` in the console window.

neomacs's window has no accessibility tree yet: AccessKit support
(neomacs issue 466) is planned for neomacs 0.0.21, with no date. Until
then NVDA, JAWS and a Braille display get nothing from that window, and
the audio desktop's speech is the whole interface there. The console
launcher draws neomacs as text in the console, which screen readers and
Braille displays read like any console; use it when the screen must be
readable by the screen reader or on Braille. Windows Terminal is a good
host for it.

NVDA and JAWS also speak over the audio desktop unless paused: NVDA+Shift+S
(NVDA+Shift+Z on the laptop layout) toggles NVDA's sleep mode for the
focused program, and JAWS has INSERT+SPACEBAR, then Z.

## Options

- `-Prefix DIR`: the stack folder. Default `%USERPROFILE%\emacspeak-stack`.
- `-NeomacsVersion VER`, `-OmnivoxVersion VER`: pin a release, such as
  `0.0.19` or `1.3.0`. Default: the latest release on the first run, and
  the installed one on a rerun.
- `-EmacspeakRepo REPO`: the GitHub repository of the audio desktop, as
  `owner/name` or its URL. Default `robertmeta/emacsvox` on a first run,
  and the installed one on a rerun; `tvraman/emacspeak` is upstream.
- `-EmacspeakRef REF`: its branch, tag or commit. Default `master`.
- `-SetupFile FILE`: the setup file in the snapshot's `lisp` folder.
  Default: `emacsvox-setup.el` when the snapshot has it, otherwise
  `emacspeak-setup.el`. Its name without `-setup.el` is the prefix of the
  other core files (`emacsvox-preamble.el`, `emacsvox-autoload.el`).
- `-Update`: move to the latest neomacs and OmniVox releases and the
  current snapshot. The home folder, with `local.el`, is kept.
- `-QuietDisplay`: turn off neomacs's cursor, scroll, buffer-switch and
  window animations. Later runs keep it until `-AnimatedDisplay`.
- `-NoDump`: do not build the fast-start dump. Later runs keep it until
  `-Dump`.
- `-NoTest`: skip the self-tests and the startup timing.
- `-NoSound`: skip only the two self-tests that make sound.
- `-Help`: a short usage text; nothing is touched.

The opposite switches exist because `powershell -File` cannot pass
`-QuietDisplay:$false` in Windows PowerShell 5.1: it hands the switch
the string `$false`, which it refuses.

A rerun without `-Update` repairs and re-verifies: every download is
checked against its checksum again, every unpacked file against the
archive's list of names and sizes (a missing or changed file is written
again), the byte-compiled files against their sources, and the dump
against its inputs.

## The folder

- `emacspeak.cmd`, `emacspeak-console.cmd`: the launchers. They set
  `HOME` to `home`, `DTK_PROGRAM=omnivox` and `OMNIVOX_ENGINE=native`
  unless already set, clear GNU Emacs's `EMACSLOADPATH`, `EMACSDATA`,
  `EMACSDOC` and `EMACSPATH`, and add `--dump-file` when the fast-start
  dump was built for this folder.
- `update.cmd`: reruns the kept copy of the script with `-Update`;
  options are passed on.
- `neomacs\<version>`, `omnivox\<version>`, and `emacsvox\<commit>` or
  `emacspeak\<commit>`: one folder per version. An update unpacks into a
  new folder, so a running session never blocks it and the old version
  stays as a fallback; the summary lists older folders, which you delete
  by hand.
- `home`: `HOME` while the stack runs. `home\.emacs.d\init.el` is
  rewritten on every run; `home\.emacs.d\local.el` is yours.
- `dump`: the fast-start dump and its stamp.
- `downloads`: the verified downloads, which let a rerun repair the
  folder without the network.
- `tools`: the copy of the script that `update.cmd` runs; its Lisp
  helpers (`selftest.el`, `dump.el`); `compat\emacspeak-preamble.el` on
  EmacsVox (below); `silent-omnivox.exe` and `console-test.txt`, the
  console self-test's stand-in server and report.
- `manifest.txt`: every version, commit and SHA-256, the audio desktop
  and its setup file, the count of old-style advice, the dump's key, the
  startup times, and the self-test result. A rerun reads it back.
- `build.log`: the full output of the last run.
- `README.txt`: the same facts in plain text, with the accessibility and
  Windows security notes.

`init.el` finds every folder from its own location, and the launchers
use `%~dp0`, so the folder can move as a whole. Only the dump is tied to
its folder: after a move the launchers skip it and say so, and the next
run builds it again. Tested by moving a built folder: the rerun rebuilt
the dump and passed every test.

The script deletes nothing. Archives are unpacked straight into their
final folders, and damaged downloads are renamed with `.bad` added.

## Sources and checksums

- neomacs: the release asset `neomacs-<version>-x86_64-pc-windows-msvc.zip`
  (or `aarch64-pc-windows-msvc`), checked against the release's
  `SHA256SUMS`, whose lines read `hash  ./name` (the release workflow runs
  `sha256sum ./*`). The zip holds one folder,
  `neomacs-<version>-<target>/`, with `neomacs.exe`, `runneomacs.exe`,
  `neomacsclient.exe`, `cmdproxy.exe`, `neomacs.pdump`, `lisp/` (with
  `.elc` files), `etc/` and `COPYING`. There are no DLLs. The x64 zip of
  0.0.19 is 70.9 MB.
- OmniVox: `omnivox-<version>-windows-x64.zip` (or `arm64`), checked
  against `sha256sums.txt` (`hash  name`). The zip holds `omnivox.exe` and
  `omnivox-voices.el` at the top level. 1.3.0 is its only release, and its
  main branch has not moved since March 11, 2026.
- The audio desktop: a GitHub zip snapshot, no git needed. The script asks
  the GitHub API which commit the branch names, then downloads
  `https://github.com/<repo>/archive/<commit>.zip`, so the recorded commit
  is exactly what was downloaded. GitHub also writes the commit into the
  zip's comment, which the script reads to confirm it, and uses on its own
  when the API cannot be reached (then the download is
  `archive/<ref>.zip`). Neither project publishes a checksum, so the
  SHA-256 is recorded in the manifest and checked on reruns.

The API calls send `GH_TOKEN` or `GITHUB_TOKEN` as a bearer token when
one is set, which raises the rate limit; downloads never carry it. When
the rate limit is used up, the warning says so and names the token. When
the API cannot be reached, a rerun keeps the installed versions and a
first run falls back to neomacs 0.0.19 and OmniVox 1.3.0.

Only the parts of the snapshot read at run time are unpacked: `lisp`,
`servers`, `sounds`, `etc`, `xsl`, `info` and `media/radio`. The rest
(130 MB of soundscapes for Boodler, 38 MB of recorded talks, the blog
archive and web pages) stays in the downloaded zip. A zip snapshot has
no `.git`, which also spares every start a `git show` that the preamble
runs in a git clone to name its revision.

Upstream emacspeak's GitHub master was last pushed on August 26, 2024
(commit 7482f8e2713b).

## Build steps

1. Check Windows 10 or 11 and the architecture (x64 or ARM64).
2. Ask GitHub for the versions, download, verify, and unpack neomacs,
   OmniVox and the audio desktop, and find its setup file.
3. Copy `omnivox.exe` into the snapshot's `servers` folder as `omnivox.exe`
   and `log-omnivox.exe`, and list both in `servers\.servers`.
4. On EmacsVox, write `tools\compat\emacspeak-preamble.el` (below).
5. Check that neomacs runs: `--version`, and `--batch` printing
   `emacs-version`, 29.1 or newer for emacspeak and 31.1 for EmacsVox.
6. Generate `<base>-loaddefs.el` with neomacs, as `lisp/Makefile` does.
7. Byte-compile the Lisp with neomacs, each file in its own neomacs as the
   Makefile does, up to eight at a time, in the Makefile's `OBJECTS` order.
   EmacsVox's master Makefile still lists the old `emacspeak-*.elc` names;
   the script compiles the `emacsvox-*` file of each, in the same order.
   Then byte-compile `omnivox-voices.el`.
8. Write `init.el`, `local.el` (only when missing) and the Lisp helpers.
9. Check that neomacs loads the audio desktop and omnivox-voices through
   `init.el` in batch mode, where it loads without speaking.
10. Build the fast-start dump, and check that it loads.
11. Write the launchers, `update.cmd`, `README.txt` and `manifest.txt`.
12. Run the self-tests, then time startup.

If neomacs cannot run, cannot generate the autoloads, cannot load the
audio desktop, cannot start `servers/omnivox`, or the console start
stalls, the script stops, says which of these failed, and names the
alternatives. When a file of the snapshot asks a question while it loads
("Error reading from stdin" in batch mode), the stop says that the
snapshot is at fault, not neomacs. Files that fail to byte-compile only
produce a warning: they load from source.

## The init file

`home\.emacs.d\init.el` does, in order:

- finds the stack folder from its own location;
- sets `load-prefer-newer`, requires `cl-lib` (the compiled preamble
  calls `cl-proclaim` while it loads, which fails when nothing loaded
  `cl-lib` first), puts the snapshot's `lisp`, OmniVox's Lisp and, on
  EmacsVox, `tools\compat` on `load-path`, and the snapshot's `servers`
  on `exec-path`;
- sets `dtk-program` from `DTK_PROGRAM`, or `omnivox`, and
  `<base>-play-program` to nil, since OmniVox plays auditory icons;
- arms a watchdog for the console self-test, only when its variable is
  set;
- ends every subprocess from `kill-emacs-hook` (below);
- works around the missing clipboard function (below);
- turns on the startup program-lookup cache (below);
- sets the process settings that matter for speech latency;
- fixes and defers OmniVox's voice list (below), then requires
  `omnivox-voices`;
- applies `-QuietDisplay`;
- loads `local.el`, then the setup file.

### Startup program-lookup cache

While it loads, emacspeak calls `executable-find` about 25 times (curl,
git, mpv, sox, xsltproc and others). On Windows each call tries six
suffixes in every folder on PATH; on the test machine, with 57 PATH
entries, each call took about 34 ms, 0.9 s in all, 80 percent of
emacspeak's load time. Until `emacs-startup-hook` runs, `init.el`
answers these lookups from one directory listing of each folder on
`exec-path` (made again whenever `exec-path` changes) and then removes
itself. The answers are the same as `executable-find`'s: a sample of
programs present and absent gave identical results.
`EMACSPEAK_STACK_NO_EXEC_CACHE=1` turns it off.

### OmniVox's voice list

`omnivox-voices.el` asks for the voices with
`(shell-command-to-string "omnivox --list-voices-alist 2>/dev/null")`.
On Windows that goes through cmd.exe, which refuses the redirection
("The system cannot find the path specified"), so the list is always
empty and `M-x omnivox-select-voice` has nothing to offer. This affects
GNU Emacs on Windows the same way, it is still in OmniVox's main branch,
and EmacsVox ships no OmniVox Lisp of its own that could fix it.
`init.el` replaces the query with a direct `call-process` of
`omnivox.exe`, with no shell, and skips it while speech starts: asking
costs 0.5 to 0.7 s of WinRT start-up. The list is read the first time a
command needs it. `(setq emacspeak-stack-query-voices-at-startup t)` in
`local.el` asks at startup again.

### Speech servers on exit

After an interactive session, neomacs 0.0.19 left the notification
server running when it exited; the speaker server ended. Found with the
console self-test's stand-in server, and every time. Simple tests with
one or two subprocesses, in batch and `-nw` mode, left nothing behind,
so it depends on something in an emacspeak session. GNU Emacs ends its
subprocesses on exit; `init.el` deletes every process from
`kill-emacs-hook`, last of the exit hooks, and the console self-test
checks that no server outlives neomacs. With OmniVox, a leftover server
would keep the audio device open.

### The clipboard

neomacs 0.0.19 on Windows has no `w32-set-clipboard-data` or
`w32-get-clipboard-data`. In the console and in batch mode, every kill
(`C-k`, `C-w`, `M-w`) deletes the text and puts it in the kill ring,
then signals `(void-function w32-set-clipboard-data)`, so the command
stops before emacspeak's after-advice speaks. Yank works. While the
function is missing, `init.el` makes `gui-select-text` ignore exactly
that error, so kills stay inside Emacs. The GUI was not tested.

### Speech latency

OmniVox 1.3.0 has no latency settings to expose: its queue depths
(speech 100, tones 10, sounds 10) and its 15-word synthesis chunks are
compile-time constants in `omnivox-cli`, and the only environment
variables it reads are `OMNIVOX_ENGINE`, `OMNIVOX_AUDIO_TARGET` and
`OMNIVOX_PIPER_MODEL`. `ENV-VARS.md` lists the CLI flags (rate, pitch,
volumes, channel), which the Emacs side sets through protocol commands
from the `omnivox-*` customizations. A silence trimmer already cuts the
leading and trailing silence of every utterance.

On the Emacs side, neomacs 0.0.19 already uses the low-latency process
settings: `process-adaptive-read-buffering` nil, `w32-pipe-read-delay`
0 and `read-process-output-max` 64 KB. `init.el` sets them anyway, so a
later neomacs that follows GNU's defaults (adaptive buffering on, a
50 ms pipe delay) keeps them. neomacs ran no garbage collection at all
while loading emacspeak, so `gc-cons-threshold` tweaks were left out.

The speed of speech is `omnivox-speech-rate`: 60 by default, faster than
normal, and 50 is normal speed with the Windows voices.

Messages, such as the greeting, are spoken through `dtk-notify`, by the
second OmniVox process (the notification server). Upstream emacspeak's
`dtk-notify-initialize` sets `ALSA_DEFAULT`, `SWIFTMAC_AUDIO_TARGET`,
`SHARPWIN_AUDIO_TARGET` and `PULSE_SINK` for it, not
`OMNIVOX_AUDIO_TARGET`, although `omnivox-voices.el` says it does, so
the notification server plays on both channels rather than only the
left one.

### Display

neomacs 0.0.19 animates the cursor (`neomacs-cursor-motion-enabled`, on)
and window layout changes (the `neomacs-window-open`, `-resize` and
`-movement` slots, on); buffer-switch and scroll transitions ship
turned off. `-QuietDisplay` sets `neomacs-cursor-motion-enabled`,
`neomacs-cursor-size-transition-enabled`,
`neomacs-buffer-transition-enabled` and
`neomacs-scroll-transition-enabled` to nil and
`neomacs-window-animations-off` to t with `customize-set-variable`, so
their `:set` functions reach the renderer, and again from
`window-setup-hook` in case the renderer did not exist yet. It does so
only with a GUI renderer: the console has no animations, and loading
`neomacs-effects.el` without one cost about half a second in batch
mode. The settings live in `neomacs-effects.el`; `docs/animations.md` on
neomacs's main branch describes a newer `neomacs-effects-apply` profile
function, which `init.el` also calls when it exists.

## EmacsVox

Read from GitHub, then built and tested here, in October 2026:

- **Renamed throughout.** The core files are `emacsvox-preamble.el`,
  `emacsvox-autoload.el`, `emacsvox-setup.el` and `emacsvox.el`; the
  feature, the variables (`emacsvox-directory`,
  `emacsvox-servers-directory`, `emacsvox-play-program`), the loaddefs
  (`emacsvox-loaddefs.el`) and the entry point (`(emacsvox)`) follow.
  `dtk-speak.el`, `voice-setup.el` and `dtk-program` keep their names;
  `dtk-program` is still a `defvar` that `DTK_PROGRAM` sets, as upstream.
- **No OmniVox Lisp of its own**, on either branch. OmniVox's
  `omnivox-voices.el` requires `emacspeak-preamble` and uses
  `emacspeak-servers-directory` and `emacspeak-play-program`, so on
  EmacsVox the script writes `tools\compat\emacspeak-preamble.el`: it
  requires `emacsvox-preamble`, makes the two old variable names aliases
  of the new ones, and provides `emacspeak-preamble`. With it, OmniVox
  loads, registers in `tts-multi-engines`, and lists its voices.
- **`servers/.servers`** is the same file as upstream's, without OmniVox;
  the script adds `omnivox` and `log-omnivox` as for upstream.
- **`lisp/Makefile`** on master still lists `emacspeak-*.elc` and
  `emacspeak-preamble.el`; the script maps each name to the snapshot's
  own. The newer branch completes the rename.
- **master does not load.** The formatting commit "Apply consistent
  formatting to all lisp files" closed `emacsvox-submit-bug` in
  `lisp/emacsvox-speak.el` right after `(interactive)`, so its body runs
  at load time: it asks "Are you sure you want to submit a bug report?
  (yes or no)", and a stray parenthesis follows. In batch mode the
  question reads standard input and fails; an interactive start would
  ask it every time, on GNU Emacs too. The script stops with that
  explanation.
- **The `safe-elisp-modernization` branch** (commit 8f151ad7393d, April
  8, 2026, seven commits ahead of master) fixes that, completes the
  Makefile rename, removes 21 dead modules and the `cl-declaim` lines,
  and adds byte-compile CI. On neomacs it generates its autoloads,
  compiles 231 of 232 files (`lisp/emacsvox-wizards.el` line 2389:
  "`let' bindings can have only one value-form"), loads in batch with
  OmniVox, and builds a dump. But its interactive start fails:
  - Converted `advice-add` functions call `ems-interactive-p`, whose
    global definition always signals "Unexpected call!"; only inside a
    `defadvice` body does `ems--generate-interactive-check` rewrite it.
    In the batch advice test, `delete-horizontal-space` signals "From
    delete-horizontal-space: Unexpected call!".
  - In the console start, the init file stops with "From nil: Unexpected
    call!" after `emacsvox-prepare-emacs: done`; displaying that warning
    signals the same error from `delayed-warnings-hook`, startup never
    processes the rest of the command line, and the session sits idle.
  - The `show-paren-function` timer signals `(void-function ad-get-arg)`
    every time it runs: a converted advice still uses a `defadvice`-only
    macro.
  These come from EmacsVox's Lisp, not from neomacs: the same code
  behaves the same way on GNU Emacs. (No GNU Emacs was available here to
  run it.)
- **`defadvice` is not gone.** The branch still has 439 `(defadvice`
  forms in 127 files, many generated in `cl-loop`/`eval` forms; after its
  advice file loads, 254 functions carry old-style advice. Upstream
  emacspeak has 1,969 forms in 193 files: 435 functions carry advice
  after its advice file loads in batch, and 539 after a full console
  start. `defadvice` itself works on neomacs: upstream's advice speaks
  after every tested command.

## The fast-start dump

neomacs supports `dump-emacs-portable`. After the build, the script runs
neomacs in batch mode with `init.el` (without `local.el`) and
`tools\dump.el`, which loads the autoloads and writes
`dump\emacspeak.pdump`: neomacs's own image with the audio desktop and
omnivox-voices preloaded, 24.1 MB for upstream emacspeak and 23.4 MB for
EmacsVox. The launchers pass it with `--dump-file`. `init.el` runs as
usual on top of it: `require` finds everything loaded, and the setup
file starts speech.

The dump bakes in absolute paths and the programs found at build time,
so its stamp, `dump\emacspeak-dump-stamp.txt`, records the folder and a
key made of the neomacs version, the commit, the OmniVox version and a
hash of `init.el`. The launchers use the dump only when the stamp
matches their own folder and key; otherwise they start without it and
say so. Every run rebuilds the dump when its key changed, and checks
that it loads before using it. `EMACSPEAK_STACK_NO_DUMP=1` skips it for
one start, and `-NoDump` turns it off.

With the dump, the audio desktop is loaded before `local.el` runs, so a
setting it reads while it loads only takes effect with `-NoDump`.

## Startup times

The script times neomacs in batch mode with `init.el`, which loads the
audio desktop and OmniVox's Lisp without speaking: the closest proxy for
a real start that needs no window and no speech. It runs the variants in
turn, one round at a time: a first round to warm the file cache, then
five; the manifest records each median.

Measured on the x64 test machine (12 logical processors, Windows 11,
neomacs 0.0.19, OmniVox 1.3.0) with 10 interleaved rounds per build, run
back to back while the machine was quiet. Fastest run, then median:

- neomacs alone, no init file: 133 and 164 ms (upstream build's run),
  131 and 146 ms (EmacsVox build's run).
- With the fast-start dump, as the launchers start it: upstream emacspeak
  155 and 188 ms; EmacsVox 153 and 157 ms.
- Byte-compiled, without the dump: upstream 263 and 370 ms; EmacsVox 234
  and 266 ms.
- Without the program-lookup cache: upstream 593 and 727 ms; EmacsVox
  512 and 576 ms.
- Everything from source: upstream 1,202 and 1,860 ms; EmacsVox 771 and
  849 ms.

So with the dump, loading the audio desktop adds about 20 ms to neomacs's
own start. Without it, byte-compiling saves about 1 s for upstream, and
the lookup cache about 0.3 s more on a quiet machine. Earlier runs,
while other work loaded the machine, gave the same order with larger
numbers: neomacs alone 272 ms at best, upstream with the dump 239 ms,
without it 497 ms, without the cache 1,294 ms, from source 3,062 ms.

The console start of upstream emacspeak with the silent stand-in
server took about 1 s from launch to its report, two inline
`make-thread` calls included.

## Self-tests

Silent first, numbered as the script prints them:

1. `neomacs.exe --version` names neomacs.
2. `neomacs.exe --batch` prints `emacs-version`, new enough.
3. The autoloads exist, and the Lisp is byte-compiled.
4. neomacs loads the audio desktop and omnivox-voices through `init.el`,
   from this folder, and finds `omnivox.exe`.
5. `omnivox.exe --version`.
6. `omnivox.exe --list-voices` finds Windows voices (silent).
7. neomacs's `start-process` starts `servers/omnivox`, without `.exe`,
   the way `dtk-make-process` starts the speech server, and it prints
   its version (silent).
8. The voice list reaches neomacs through `init.el`'s fixed query.
9. The speech advice: the advice file loads as a start would load it,
   and `next-line`, `forward-word`, `end-of-line`, `kill-line` and
   `delete-horizontal-space` each produce speech or an auditory icon,
   counted instead of sent, without an error. The count of old-style
   advised functions goes into the manifest.
10. A console start: `neomacs.exe -nw` with the init file and the dump,
    input at end of file, and `tools\silent-omnivox.exe` as the speech
    server: a copy of Windows's `sort.exe`, which reads everything, says
    nothing, and prints the sorted lines when its input closes. Its name
    holds "omnivox", so the OmniVox setup runs against it. The test
    checks that the start finished with its speech advice, the speaker
    and notification servers running, that `dtk-speak` and `next-line`
    sent speech to the stand-in, and that no server outlived neomacs.
    A start that stalls is stopped after 60 s by a watchdog in `init.el`,
    which reports the errors from `*Messages*`.
11. The launchers, `update.cmd`, `README.txt`, `manifest.txt`, `init.el`
    and `local.el` are in place and name this build.
12. The fast-start dump starts neomacs with the audio desktop preloaded
    from this folder (only when the dump is built).
13. `omnivox.exe --check` plays a tone and speech. Sound.
14. The OmniVox server speaks its version, started from neomacs as
    emacspeak starts it. Sound.

`-NoSound` skips the last two. Without a sound output device, test 13
warns and test 14 is skipped, which is what GitHub's runners report.

## What neomacs says about itself, and what the tests found

From its README, `docs/faq.md`, `docs/ARCHITECTURE.md`, `docs/daemon.md`,
`docs/animations.md`, the release workflow and its issues, read in
October 2026 for release 0.0.19 (September 20, 2026):

- A hard fork of GNU Emacs, its Lisp tree synced to the `emacs-31.1` tag,
  with the C core fully replaced by Rust and a GPU display engine (wgpu;
  DX12 on Windows). GPL-3.0. Compatibility with GNU Emacs is the stated
  contract, measured at about 95 percent by its oracle test suites; it
  calls itself a work in progress.
- Windows is marked experimental. `runneomacs.exe` re-runs `neomacs.exe`
  beside it with the same arguments and environment, in a hidden console.
  `neomacs.exe` is for `-nw`, `--batch`, redirected output and exit
  status. The release zip is portable; the installers are per-user.
- The executables are not code-signed. Downloaded by the script, they
  carry no mark of the web, so SmartScreen should not stop them; Smart
  App Control on Windows 11 blocks unsigned programs. `README.txt` says
  so.
- Generational garbage collection (GEN1) is on by default;
  `NEOVM_GC_GENERATIONAL=0` opts out.
- `make-thread` in 0.0.19 runs its function at once, in the caller;
  emacspeak calls it twice in `(emacspeak)`, to load its advice and to
  run `emacspeak-prepare-emacs`. Both ran inline in the console test and
  finished; nothing blocked on them.
- Tested here and working: `HOME` decides where `~/.emacs.d/init.el` and
  `early-init.el` are found, as in GNU Emacs; batch mode generates the
  autoloads and byte-compiles all of upstream emacspeak (242 files)
  without a failure; `start-process` finds `servers\omnivox.exe` from the
  bare name; `defadvice` and the `funcall-interactively` advice that
  emacspeak's interactive check relies on work through `command-execute`;
  the interactive console start runs to the end.
- In batch and `-nw` mode its logs go nowhere unless `NEOMACS_LOG_FILE`
  names a file; in the GUI they go to standard output. `RUST_LOG` sets
  the level (default warn).
- The portable dump: the release ships `neomacs.pdump`, loaded in about
  50 ms; `dump-emacs-portable` and `--dump-file` work. Issue #578
  reports that dumps built under Nix embedded the build environment.
- The headless daemon uses Unix sockets and is not available on Windows.
- Without `HOME`, neomacs on Windows sets it from `APPDATA`, as GNU Emacs
  does. `data-directory` and `shell-file-name` come back as `\\?\` paths,
  which worked everywhere this script uses them.
- Accessibility: issue #466 (open, October 2026) plans a native
  accessibility tree through AccessKit, with UI Automation for NVDA on
  Windows, for 0.0.21, and lists EmacsVox compatibility as a target. The
  issue says the TUI, `neomacs -nw`, already reads fine under screen
  readers.
- Windows issues open in October 2026 include #395 (a new frame does not
  take keyboard focus), #384 (slow mouse selection), #402 (no fallback for
  computers without a usable GPU) and #109 (no suitable GPU adapter
  found). On a computer without a working GPU, `emacspeak-console.cmd` is
  the way in.
- Found by the tests, not in the issues: the missing
  `w32-set-clipboard-data`, and the notification server left running
  after an interactive session (both above).

## What only GitHub's runners can verify

The workflow `.github/workflows/stack-windows.yml` runs on `windows-latest`
(x64) and `windows-11-arm`, once for upstream emacspeak, which must pass,
and once for EmacsVox, the default, which may fail until EmacsVox is
fixed:

- the arm64 builds of neomacs and OmniVox, which the test machine (x64)
  cannot run;
- PowerShell 7 (`-Update` runs under `pwsh`), which is not installed on
  the test machine;
- the default folder in a clean profile, and that nothing appears in the
  profile;
- the sound self-tests on a machine without speakers (a warning and a
  skip);
- `update.cmd` itself.

Neither the runners nor the script can open the neomacs window, so the
GUI start, speech from the GUI, the dump in the GUI, the clipboard in the
GUI and `-QuietDisplay`'s effect on the renderer need a person at the
computer.

## Checks for a person at the computer

With NVDA or JAWS paused in the neomacs window:

- `emacspeak.cmd` opens neomacs and emacspeak speaks its greeting.
- `C-x C-f` and a file name: emacspeak speaks the prompt and the file.
- `C-k`, then `C-y`: the line is killed and yanked back, and both speak.
- `M-x omnivox-select-voice` offers the Windows voices.
- `emacspeak-console.cmd` speaks the same in the console window, and the
  screen reader and Braille display can read the console.
- After quitting, Task Manager shows no `omnivox.exe` left running.
- After `update.cmd`, emacspeak still starts, and `local.el` is unchanged.
- With `-QuietDisplay`, the cursor jumps instead of sliding (ask a
  sighted helper, or trust the manifest's `quiet-display: yes`).
