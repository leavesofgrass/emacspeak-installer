#!/usr/bin/env bash
# install-emacspeak-macos.sh: emacspeak with real speech on macOS.
#
# It installs one or more speech engines, chosen with --speech or a menu:
#   omnivox    the macOS system voices through OmniVox, an emacspeak speech
#              server written in Rust (https://github.com/robertmeta/omnivox),
#              from its prebuilt release (checksum verified) or from source;
#   espeak     the espeak-ng voices through OmniVox's built-in espeak-ng
#              engine, with the voice data from Homebrew's espeak-ng;
#   swiftmac   the macOS system voices through emacspeak's own Swift server,
#              built with the Swift that Xcode and its Command Line Tools ship;
#   tclespeak  espeak-ng through emacspeak's own Tcl espeak server, on
#              Homebrew's Tcl 8.6, with TclX built from source.
# It clones and byte-compiles emacspeak, registers OmniVox as a speech
# server, writes an init file and an emacspeak launcher, and tests each
# chosen engine.
#
# Run it as your normal user, never with sudo: Homebrew refuses to run as
# root, and everything goes into your home folder and Homebrew's folder.
# It runs with the bash 3.2 that macOS ships.
# For Linux, use the other installers in this folder.

set -euo pipefail

# OmniVox's documentation expects emacspeak in ~/.emacspeak, with its
# speech servers in ~/.emacspeak/servers, so that is the default here.
# emacspeak keeps your own files there too; git updates leave them alone.
PREFIX=$HOME/.emacspeak
REPO=https://github.com/tvraman/emacspeak.git
REF=master
SKIP_DEPS=no
RUN_TESTS=yes
SPEECH=""
OMNIVOX_ROUTE=prebuilt
OMNIVOX_VERSION=""
OMNIVOX_REPO=robertmeta/omnivox
# Used only when GitHub cannot be asked for the latest release and no
# OmniVox is installed yet: the release this script was written against.
OMNIVOX_FALLBACK=1.3.0
# Without Emacs 29.1 or newer, install Homebrew's own emacs formula: a
# terminal Emacs, which is what the launcher runs, prebuilt for Apple silicon.
EMACS_ROUTE=core
EMACS_FORMULA=emacs
# --emacs-plus installs this instead, for people who also want Emacs.app.
EMACS_PLUS_TAP=d12frosted/emacs-plus
EMACS_PLUS_FORMULA=emacs-plus@30
# emacspeak's Tcl servers need Tcl 8.6, and Homebrew's tcl-tk is Tcl 9, so
# the Tcl espeak server runs on tcl-tk@8. Homebrew has no TclX, so it is
# built from this release tag, which ships its configure script.
TCL_FORMULA=tcl-tk@8
TCLX_URL=https://github.com/flightaware/tclx.git
TCLX_REF=v8.6.3
# The speech engines, in menu order. The default is the one used when
# nothing else says which engines to install.
ENGINES="omnivox espeak swiftmac tclespeak"
DEFAULT_ENGINE=omnivox
LOG=$HOME/Library/Logs/install-emacspeak-macos.log
MARKER="Written by install-emacspeak-macos.sh"

usage() {
    cat <<USAGE
Usage: bash install-emacspeak-macos.sh [options]

Installs emacspeak with real speech on macOS 13 or newer.
Run it as your normal user, not with sudo. It needs Homebrew.
Run it again later to update emacspeak and its speech engines.

Options:
  --speech LIST          speech engines, comma-separated, in order of
                         preference: omnivox, espeak, swiftmac, tclespeak,
                         or all. The first one is the launcher's default.
                         --speech list describes each engine.
                         Without it, the script reuses the engines chosen
                         last time, or asks with a menu, or takes omnivox
                         when there is no terminal to ask on.
  --prefix DIR           where emacspeak is cloned and built
                         (default $PREFIX)
  --repo URL             emacspeak git repository (default $REPO)
  --ref REF              branch or tag to build (default $REF)
  --omnivox-version VER  OmniVox release to install, such as 1.3.0
                         (default: the latest release)
  --omnivox-source       build OmniVox from source with cargo
                         instead of using the prebuilt release
  --emacs-plus           use $EMACS_PLUS_FORMULA, which includes Emacs.app,
                         from the $EMACS_PLUS_TAP tap, instead of
                         Homebrew's emacs. This trusts that whole tap.
  --skip-deps            do not run brew; you installed Emacs, and what
                         the chosen engines need, yourself
  --no-test              skip the self-tests at the end
  --help                 show this help

Without Emacs 29.1 or newer, it installs Homebrew's emacs formula, a
terminal Emacs. --omnivox-source also needs cmake and Rust, which it
installs with Homebrew if they are missing. espeak installs Homebrew's
espeak-ng; tclespeak installs $TCL_FORMULA, espeak-ng and sox; swiftmac
needs Swift 5.9 or newer, from Xcode or its Command Line Tools.
Build output goes to $LOG.
USAGE
}

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'Warning: %s\n' "$*"; }

# Run a noisy command with its output in $LOG. If it fails, show the end of
# the log, then the error, so the last line on screen names the problem.
# HINT, set by each section, says what to do about a failure there.
HINT=""
fail_with_log() { # $1 = what failed
    printf '\nLast lines of %s:\n' "$LOG" >&2
    tail -n 20 "$LOG" >&2
    die "$1 failed. ${HINT:+$HINT }The full output is in $LOG"
}
logged() {
    local what=$1; shift
    "$@" >>"$LOG" 2>&1 || fail_with_log "$what"
}

# emacspeak's Makefile runs its sub-makes as "$(MAKE) $(MAKEFLAGS)", so any
# flag make puts into MAKEFLAGS (make -C adds -w) becomes a bogus target.
# So never use make -C or make options here: change into the folder in a
# subshell and run make with the inherited flag variables cleared.
make_in() { # $1 = folder, the rest = make arguments
    local dir=$1; shift
    (cd "$dir" && unset MAKEFLAGS MFLAGS MAKELEVEL && make "$@")
}
in_dir() { # $1 = folder, the rest = a command to run there
    local dir=$1; shift
    (cd "$dir" && "$@")
}

# macOS has no timeout command. Run a command with INPUT on its standard
# input, stop it after SECONDS, and return its exit status (143 if stopped).
# The watcher stops its own sleep when it is stopped, so nothing lingers.
limited() { # $1 = seconds, $2 = input, the rest = the command
    local secs=$1 input=$2 pid watcher rc=0
    shift 2
    "$@" <<<"$input" &
    pid=$!
    (
        sleep "$secs" & nap=$!
        trap 'kill "$nap"; exit 0' TERM
        wait "$nap" && kill "$pid"
    ) >/dev/null 2>&1 &
    watcher=$!
    wait "$pid" || rc=$?
    kill "$watcher" 2>/dev/null || true
    # Reap the stopped watcher quietly, or bash prints "Terminated".
    wait "$watcher" 2>/dev/null || true
    return "$rc"
}

emacs_new_enough() { # $1 = an emacs program
    "$1" -Q --batch --eval '(kill-emacs (if (version<= "29.1" emacs-version) 0 1))' \
        2>>"$LOG"
}
emacs_version() { # $1 = an emacs program
    "$1" -Q --batch --eval '(princ emacs-version)' 2>>"$LOG"
}

# Sets EMACS_BIN to the first Emacs 29.1 or newer: the one on PATH, then
# Homebrew's emacs and emacs-plus@30, which may be installed but not linked.
# With --emacs-plus, only emacs-plus@30 counts.
find_emacs() {
    local candidate
    EMACS_BIN=""
    if [ "$EMACS_ROUTE" = plus ]; then
        set -- "$BREW_PREFIX/opt/$EMACS_PLUS_FORMULA/bin/emacs"
    else
        set -- "$(command -v emacs || true)" \
               "$BREW_PREFIX/opt/$EMACS_FORMULA/bin/emacs" \
               "$BREW_PREFIX/opt/$EMACS_PLUS_FORMULA/bin/emacs"
    fi
    for candidate in "$@"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ] &&
           emacs_new_enough "$candidate"; then
            EMACS_BIN=$candidate
            return 0
        fi
    done
    return 1
}

# cargo from rustup lives in ~/.cargo/bin, which a script's PATH may lack.
find_cargo() {
    if ! command -v cargo >/dev/null && [ -x "$HOME/.cargo/bin/cargo" ]; then
        PATH="$HOME/.cargo/bin:$PATH"
    fi
    command -v cargo >/dev/null && command -v rustc >/dev/null
}

valid_version() {
    case "$1" in
        *[!0-9A-Za-z.-]*) return 1 ;;
        [0-9]*.[0-9]*)    return 0 ;;
        *)                return 1 ;;
    esac
}

# The Swift version, such as 6.1, from swift --version.
swift_version() {
    swift --version 2>>"$LOG" |
        sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | sed -n 1p
}
swift_new_enough() { # $1 = a version such as 5.9 or 6.1; swiftmac needs 5.9
    local major=${1%%.*} minor=${1#*.}
    minor=${minor%%.*}
    [ "$major" -gt 5 ] || { [ "$major" -eq 5 ] && [ "$minor" -ge 9 ]; }
}

# Prints the latest OmniVox release, such as 1.3.0, from the GitHub API.
# GitHub limits API calls without a token, which hits shared machines such
# as CI runners, so a GH_TOKEN or GITHUB_TOKEN already in the environment
# is sent to api.github.com. It goes in on curl's standard input, not its
# command line, so other users cannot read it in the process list.
latest_omnivox_version() {
    local url="https://api.github.com/repos/$OMNIVOX_REPO/releases/latest"
    local token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
    if [ -n "$token" ]; then
        printf 'Authorization: Bearer %s\n' "$token" |
            curl -fsS --retry 2 --max-time 30 -H @- "$url" 2>>"$LOG"
    else
        curl -fsS --retry 2 --max-time 30 "$url" 2>>"$LOG"
    fi | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p'
}

# --------------------------------------------------------------------------
# The speech engines.
engine_title() { # the engine's name in messages, such as OmniVox
    case "$1" in
        omnivox) echo OmniVox ;;
        *)       echo "$1" ;;
    esac
}
engine_server() { # the emacspeak speech server the engine runs as
    case "$1" in
        omnivox|espeak) echo omnivox ;;
        swiftmac)       echo swiftmac ;;
        tclespeak)      echo espeak ;;
    esac
}
engine_server_text() { # the server, as the summary names it
    case "$1" in
        espeak) echo "omnivox, with OMNIVOX_ENGINE=espeak" ;;
        *)      engine_server "$1" ;;
    esac
}
engine_about() {
    case "$1" in
        omnivox)   echo "the macOS system voices through OmniVox" ;;
        espeak)    echo "espeak-ng voices through OmniVox's espeak-ng engine" ;;
        swiftmac)  echo "the macOS system voices through emacspeak's swiftmac server" ;;
        tclespeak) echo "espeak-ng through emacspeak's Tcl espeak server, the heavy route" ;;
    esac
}
engine_needs() {
    case "$1" in
        omnivox)   echo "OmniVox's prebuilt release, or Rust and cmake with --omnivox-source" ;;
        espeak)    echo "OmniVox, and Homebrew's espeak-ng for the voice data" ;;
        swiftmac)  echo "Swift 5.9 or newer, from Xcode or its Command Line Tools; a few minutes to build" ;;
        tclespeak) echo "Homebrew's $TCL_FORMULA, espeak-ng and sox, and TclX built from source; the slowest to install" ;;
    esac
}
print_engines() {
    local e
    for e in $ENGINES; do
        echo "$e: $(engine_about "$e"). Server: $(engine_server_text "$e"). Needs: $(engine_needs "$e")."
    done
}

# The chosen engines live in SELECTED, space-separated, in order.
SELECTED=""
is_selected() { case " $SELECTED " in *" $1 "*) return 0 ;; esac; return 1; }
add_engine() { is_selected "$1" || SELECTED="${SELECTED:+$SELECTED }$1"; }
selected_titles() { # such as "OmniVox, swiftmac"
    local e out=""
    for e in $SELECTED; do out="${out:+$out, }$(engine_title "$e")"; done
    printf '%s' "$out"
}
chosen_servers() { # the servers of the chosen engines, in order, each once
    local e s out=""
    for e in $SELECTED; do
        s=$(engine_server "$e")
        case " $out " in *" $s "*) ;; *) out="${out:+$out }$s" ;; esac
    done
    printf '%s' "$out"
}
commas() { printf '%s' "$1" | sed 's/ /, /g'; } # "a b" becomes "a, b"

# Adds the engines named in $1 (separated by commas, spaces or newlines,
# in any case) to SELECTED. On an unknown name, sets BAD and returns 1.
BAD=""
parse_engines() {
    local rest word lower e
    rest=$(printf '%s' "$1" | tr ',\t\n\r' '    ')
    while :; do
        rest=${rest#"${rest%%[! ]*}"}
        [ -n "$rest" ] || break
        word=${rest%% *}
        rest=${rest#"$word"}
        lower=$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')
        case "$lower" in
            omnivox|espeak|swiftmac|tclespeak) add_engine "$lower" ;;
            all) for e in $ENGINES; do add_engine "$e"; done ;;
            *) BAD=$word; return 1 ;;
        esac
    done
}

# The menu, shown when nothing else says which engines to install.
ask_engines() {
    local e i answer n picked bad
    echo "Which speech engines should emacspeak get?"
    i=0
    for e in $ENGINES; do
        i=$((i + 1))
        if [ "$e" = "$DEFAULT_ENGINE" ]; then
            echo "$i) $e: $(engine_about "$e") (default)"
        else
            echo "$i) $e: $(engine_about "$e")"
        fi
    done
    while :; do
        printf '%s' "Numbers separated by spaces, or Enter for the default [1]: "
        if ! IFS= read -r answer; then
            echo
            die "no answer was given. Run the script again, or choose with --speech."
        fi
        answer=$(printf '%s' "$answer" | tr ',\t\r' '   ')
        picked=""
        bad=no
        case "$answer" in *[!0-9\ ]*) bad=yes ;; esac
        if [ "$bad" = no ]; then
            # Only digits and spaces are left, so the words cannot glob.
            for n in $answer; do
                case "$n" in
                    1) e=omnivox ;;
                    2) e=espeak ;;
                    3) e=swiftmac ;;
                    4) e=tclespeak ;;
                    *) bad=yes; break ;;
                esac
                case " $picked " in *" $e "*) ;; *) picked="${picked:+$picked }$e" ;; esac
            done
        fi
        if [ "$bad" = yes ]; then
            echo "Please answer with numbers from 1 to 4, such as: 1 3"
            continue
        fi
        SELECTED=${picked:-$DEFAULT_ENGINE}
        return 0
    done
}

# --------------------------------------------------------------------------
install_core_emacs() {
    log "No Emacs 29.1 or newer found: installing Homebrew's emacs formula"
    echo "It is a terminal Emacs, which is what the launcher runs."
    if [ "$ARCH" = x64 ] || [ "$MACOS_MAJOR" -lt 15 ]; then
        warn "Homebrew may have no prebuilt emacs for $ARCH_NAME Macs on \
macOS $MACOS_MAJOR, so it may compile Emacs, which can take an hour or more."
        echo "Progress goes to the build log. To follow it: tail -f $LOG"
    fi
    logged "brew install $EMACS_FORMULA" "$BREW" install "$EMACS_FORMULA"
}

install_emacs_plus() {
    local brew_major
    log "Installing $EMACS_PLUS_FORMULA, with Emacs.app, from the $EMACS_PLUS_TAP tap"
    brew_major=$("$BREW" --version 2>>"$LOG" | sed -n 's/^Homebrew \([0-9][0-9]*\).*/\1/p')
    if [ "${brew_major:-0}" -ge 6 ]; then
        echo "This trusts the whole $EMACS_PLUS_TAP tap."
        echo "Homebrew 6 runs code only from taps you trust."
        echo "$EMACS_PLUS_FORMULA loads other formulas from its tap"
        echo "while it installs, so trusting one formula fails."
        echo "To undo it later: brew untrust $EMACS_PLUS_TAP"
        # The tap's README trusts before tapping; Homebrew's own guide taps
        # first. Try trust first, and tap first if Homebrew wants that.
        if ! "$BREW" trust "$EMACS_PLUS_TAP" >>"$LOG" 2>&1; then
            logged "brew tap $EMACS_PLUS_TAP" "$BREW" tap "$EMACS_PLUS_TAP"
            logged "brew trust $EMACS_PLUS_TAP" "$BREW" trust "$EMACS_PLUS_TAP"
        fi
    fi
    logged "brew tap $EMACS_PLUS_TAP" "$BREW" tap "$EMACS_PLUS_TAP"
    echo "Homebrew compiles emacs-plus from source: a few minutes to half an hour."
    if [ "$ARCH" = x64 ] || [ "$MACOS_MAJOR" -lt 15 ]; then
        warn "Homebrew no longer has prebuilt packages for $ARCH_NAME Macs on \
macOS $MACOS_MAJOR, so Emacs's libraries compile too, which can take hours."
    fi
    echo "Progress goes to the build log. To follow it: tail -f $LOG"
    if ! "$BREW" install "$EMACS_PLUS_TAP/$EMACS_PLUS_FORMULA" >>"$LOG" 2>&1; then
        # Homebrew reports an error when it cannot link emacs-plus because
        # another Emacs is linked as emacs. The keg itself still works.
        find_emacs || fail_with_log "brew install $EMACS_PLUS_TAP/$EMACS_PLUS_FORMULA"
        warn "Homebrew reported an error (see $LOG), but $EMACS_PLUS_FORMULA \
is installed and runs, so the script goes on. If the error says another Emacs \
is linked as emacs: the launcher runs $EMACS_PLUS_FORMULA by its full path, \
and brew unlink emacs, then brew link $EMACS_PLUS_FORMULA, makes the emacs \
command run it too."
    fi
}

brew_install() { # $1 = formula, $2 = what it is for
    [ ! -d "$BREW_PREFIX/opt/$1" ] || return 0
    log "Installing $1 with Homebrew ($2)"
    logged "brew install $1" "$BREW" install "$1"
}

# servers/.servers is part of emacspeak's git tree. M-x dtk-select-server
# offers the names listed there, and OmniVox's README asks for both names.
# swiftmac and espeak are listed there already.
register_omnivox() {
    local name
    [ -f "$SERVERS_LIST" ] || die "$SERVERS_LIST is missing; is $PREFIX an emacspeak clone?"
    # Add a final newline if the file lacks one, so each name gets its own line.
    [ -z "$(tail -c 1 "$SERVERS_LIST")" ] || printf '\n' >>"$SERVERS_LIST"
    for name in omnivox log-omnivox; do
        grep -qx "$name" "$SERVERS_LIST" || printf '%s\n' "$name" >>"$SERVERS_LIST"
    done
}
# Takes this script's two lines out again, so git sees the file unchanged.
unregister_omnivox() {
    [ -f "$SERVERS_LIST" ] || return 0
    grep -qx -e omnivox -e log-omnivox "$SERVERS_LIST" || return 0
    grep -vx -e omnivox -e log-omnivox "$SERVERS_LIST" >"$SERVERS_LIST.new" || true
    mv -f "$SERVERS_LIST.new" "$SERVERS_LIST"
}

# Keeps the files this script adds to the clone out of git status.
exclude_own_files() {
    local file=$PREFIX/.git/info/exclude pattern
    mkdir -p "$PREFIX/.git/info"
    touch "$file"
    [ -z "$(tail -c 1 "$file")" ] || printf '\n' >>"$file"
    for pattern in /speech-engines /emacspeak-init.el /omnivox-init.el \
                   /omnivox/ /tclx/ /servers/omnivox /servers/log-omnivox \
                   /servers/ogg.framework/ /servers/vorbis.framework/ \
                   /servers/native-espeak/tclespeak.dylib \
                   /servers/native-espeak/tclespeak.o; do
        grep -qxF "$pattern" "$file" || printf '%s\n' "$pattern" >>"$file"
    done
}

# Replaces the first line of a file, keeping its mode and all other bytes.
set_first_line() { # $1 = file, $2 = the new first line
    cp -p "$1" "$1.new"
    { printf '%s\n' "$2"; tail -n +2 "$1"; } >"$1.new"
    mv -f "$1.new" "$1"
}
# emacspeak's Tcl servers start with #!/usr/bin/tclsh, Apple's old Tcl
# without TclX. These point them at Homebrew's tclsh8.6, and back again
# around a git update, so git sees unmodified files.
point_tcl_servers() {
    local f
    TCL_SERVERS=""
    for f in "$PREFIX"/servers/*; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        case "$(head -n 1 "$f")" in
            "#!$TCLSH") ;;
            '#!'*tclsh*) set_first_line "$f" "#!$TCLSH" ;;
            *) continue ;;
        esac
        TCL_SERVERS="$TCL_SERVERS ${f##*/}"
    done
}
restore_tcl_servers() {
    local f original
    RESTORED_TCL=no
    for f in "$PREFIX"/servers/*; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        [ "$(head -n 1 "$f")" = "#!$TCLSH" ] || continue
        original=$(git -C "$PREFIX" show "HEAD:servers/${f##*/}" 2>>"$LOG" | sed -n 1p) ||
            continue
        [ -n "$original" ] || continue
        set_first_line "$f" "$original"
        RESTORED_TCL=yes
    done
}

# tclsh reading a script from its input exits 0 even after an error, so
# these Tcl checks exit 1 themselves when something fails.
tclx_version() {
    limited 30 'if {[catch {puts [package require Tclx]}]} {exit 1}' "$TCLSH"
}
espeak_glue_check() { # $1 = path of tclespeak.dylib
    limited 30 "if {[catch {load {$1}} err]} {puts stderr \$err; exit 1}
if {[info commands say] ne \"say\"} {puts stderr \"no say command\"; exit 1}
puts \"eSpeak NG [ttsVersion], voice data in [ttsDataPath]\"" "$TCLSH"
}

# Builds TclX from its release tag against Homebrew's Tcl 8.6, into
# $TCLX_DIR. Tcl finds it there through TCLLIBPATH, which the launcher and
# the init file set, so Homebrew's own folders stay untouched, and a brew
# upgrade or reinstall of tcl-tk@8 cannot remove it.
build_tclx() {
    local src=$TCLX_DIR/src
    HINT="Check the internet connection and the Xcode Command Line Tools, then rerun."
    if [ -d "$src/.git" ]; then
        log "Updating the TclX source in $src to $TCLX_REF"
        logged "fetching TclX $TCLX_REF" git -C "$src" fetch -q --depth 1 origin \
            "refs/tags/$TCLX_REF:refs/tags/$TCLX_REF"
        logged "checking out TclX $TCLX_REF" git -C "$src" -c advice.detachedHead=false \
            checkout -q "$TCLX_REF"
    else
        log "Cloning TclX ${TCLX_REF#v} into $src"
        logged "cloning TclX" git -c advice.detachedHead=false clone -q --depth 1 \
            --branch "$TCLX_REF" "$TCLX_URL" "$src"
    fi
    log "Building TclX ${TCLX_REF#v} against Homebrew's Tcl 8.6 (a minute or two)"
    # --with-tclinclude names the 8.6 headers, with the private ones TclX
    # needs. Without it, configure may take a Tcl 9 tcl.h in /usr/local.
    logged "configuring TclX" in_dir "$src" ./configure \
        --with-tcl="$TCL_KEG/lib" --with-tclinclude="$TCL_INCLUDE" \
        --prefix="$TCLX_DIR" --exec-prefix="$TCLX_DIR" --libdir="$TCLX_DIR/lib"
    logged "building TclX" make_in "$src"
    logged "installing TclX into $TCLX_DIR" make_in "$src" install
}

# Installs an omnivox binary and omnivox-voices.el, then records the version.
place_omnivox() { # $1 = omnivox binary, $2 = omnivox-voices.el
    local out
    mkdir -p "$OMNIVOX_DIR/elisp"
    cp "$2" "$OMNIVOX_DIR/elisp/omnivox-voices.el"
    # Copy, then rename over the old binary, so a running server keeps its file.
    cp "$1" "$PREFIX/servers/omnivox.new"
    chmod 0755 "$PREFIX/servers/omnivox.new"
    mv -f "$PREFIX/servers/omnivox.new" "$PREFIX/servers/omnivox"
    # OmniVox's README registers the same binary under the name log-omnivox.
    ln -sfn omnivox "$PREFIX/servers/log-omnivox"
    out=$(limited 30 "" "$PREFIX/servers/omnivox" --version 2>>"$LOG") ||
        die "$PREFIX/servers/omnivox does not run on this Mac. Rerun with \
--omnivox-source to build it here. See $LOG"
    printf '%s\n' "$WANT" >"$OMNIVOX_DIR/installed-version"
    echo "Installed $PREFIX/servers/omnivox ($out), and log-omnivox beside it."
}

install_prebuilt_omnivox() { # $1 = version
    local v=$1 base tarball sums dir want got
    base=https://github.com/$OMNIVOX_REPO/releases/download/v$v
    tarball=omnivox-$v-macos-$ARCH.tar.gz
    sums=$OMNIVOX_DIR/downloads/sha256sums-$v.txt
    dir=$OMNIVOX_DIR/release-$v-$ARCH
    mkdir -p "$OMNIVOX_DIR/downloads" "$dir"
    log "Downloading OmniVox $v for $ARCH_NAME ($tarball)"
    HINT="Check the internet connection. If release $v lacks this file, pick \
another with --omnivox-version, or use --omnivox-source."
    logged "downloading $base/$tarball" curl -fsSL --retry 2 \
        -o "$OMNIVOX_DIR/downloads/$tarball" "$base/$tarball"
    logged "downloading $base/sha256sums.txt" curl -fsSL --retry 2 \
        -o "$sums" "$base/sha256sums.txt"
    want=$(awk -v f="$tarball" '$2 == f || $2 == "*" f { print $1; exit }' "$sums")
    [ -n "$want" ] || die "sha256sums.txt of OmniVox $v has no line for $tarball, \
so it cannot be checked. Pick a release with --omnivox-version, or use --omnivox-source."
    got=$(shasum -a 256 "$OMNIVOX_DIR/downloads/$tarball" | awk '{ print $1 }')
    [ "$got" = "$want" ] || die "checksum mismatch for $tarball: expected $want, \
got $got. The download is damaged or was changed. Run the script again; if it \
fails again, use --omnivox-source."
    echo "Checksum verified: SHA-256 $got"
    HINT="Run the script again to download it afresh, or use --omnivox-source."
    logged "unpacking $tarball" tar -xzf "$OMNIVOX_DIR/downloads/$tarball" -C "$dir"
    [ -f "$dir/omnivox" ] && [ -f "$dir/omnivox-voices.el" ] ||
        die "$tarball does not hold omnivox and omnivox-voices.el; the release \
layout may have changed. Try --omnivox-source."
    place_omnivox "$dir/omnivox" "$dir/omnivox-voices.el"
}

build_omnivox_from_source() { # $1 = version
    local v=$1 tag=v$1 src=$OMNIVOX_DIR/src
    HINT="Check the internet connection, and that OmniVox has a release $tag."
    if [ -d "$src/.git" ]; then
        log "Updating the OmniVox source in $src to $tag"
        logged "fetching OmniVox $tag" git -C "$src" fetch -q --depth 1 origin \
            "refs/tags/$tag:refs/tags/$tag"
        logged "checking out OmniVox $tag" git -C "$src" checkout -q "$tag"
    else
        log "Cloning OmniVox $tag into $src"
        logged "cloning OmniVox" git clone -q --depth 1 --branch "$tag" \
            "https://github.com/$OMNIVOX_REPO.git" "$src"
    fi
    log "Building OmniVox $v with cargo (a few minutes; it compiles espeak-ng too)"
    HINT="Update Rust (rustup update, or brew upgrade rust) and rerun, or leave \
out --omnivox-source to use the prebuilt release."
    logged "cargo build" cargo build --release --manifest-path "$src/Cargo.toml"
    place_omnivox "$src/target/release/omnivox" "$src/elisp/omnivox-voices.el"
}

# The status line under [synthesis] in OmniVox's --check report, such as
# "OK - 9000 samples, ..." or "WARNING - synthesized empty buffer".
synth_status() { # $1 = the report
    awk '/^\[synthesis\]/ { getline; sub(/^[[:space:]]*Status:[[:space:]]*/, "");
                            print; exit }' <<<"$1"
}
voice_count() { # $1 = the output of omnivox --list-voices
    sed -n 's/^Found \([0-9][0-9]*\) voices.*/\1/p' <<<"$1"
}

# --------------------------------------------------------------------------
need_value() { [ $# -ge 2 ] || die "$1 needs a value (try --help)"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --speech)          need_value "$@"; SPEECH=$2; shift ;;
        --prefix)          need_value "$@"; PREFIX=$2; shift ;;
        --repo)            need_value "$@"; REPO=$2; shift ;;
        --ref)             need_value "$@"; REF=$2; shift ;;
        --omnivox-version) need_value "$@"; OMNIVOX_VERSION=${2#v}; shift ;;
        --omnivox-source)  OMNIVOX_ROUTE=source ;;
        --emacs-plus)      EMACS_ROUTE=plus ;;
        --skip-deps)       SKIP_DEPS=yes ;;
        --no-test)         RUN_TESTS=no ;;
        --help|-h)         usage; exit 0 ;;
        *)                 die "unknown option $1 (try --help)" ;;
    esac
    shift
done
if [ "$(printf '%s' "$SPEECH" | tr '[:upper:]' '[:lower:]')" = list ]; then
    print_engines
    exit 0
fi
if [ -n "$SPEECH" ]; then
    if ! parse_engines "$SPEECH"; then
        echo "The speech engines on macOS are:" >&2
        print_engines >&2
        die "unknown speech engine \"$BAD\". Use one or more of \
$(echo "$ENGINES" | tr ' ' ','), separated by commas, or all, or list."
    fi
    [ -n "$SELECTED" ] || die "--speech needs at least one engine name (try --speech list)"
fi
[ -z "$OMNIVOX_VERSION" ] || valid_version "$OMNIVOX_VERSION" ||
    die "--omnivox-version needs a release number such as 1.3.0"
# macOS realpath has no -m, so make the prefix absolute by hand.
case "$PREFIX" in /*) ;; *) PREFIX=$PWD/$PREFIX ;; esac
while [ "$PREFIX" != / ] && [ "${PREFIX%/}" != "$PREFIX" ]; do PREFIX=${PREFIX%/}; done
case "$PREFIX" in
    *'"'*|*\\*) die "--prefix must not contain quotes or backslashes" ;;
esac
SERVERS_LIST=$PREFIX/servers/.servers
OMNIVOX_DIR=$PREFIX/omnivox
TCLX_DIR=$PREFIX/tclx
GLUE=$PREFIX/servers/native-espeak/tclespeak.dylib
RECORD=$PREFIX/speech-engines
INIT=$PREFIX/emacspeak-init.el
# The init file's name before the engine choice. Earlier runs wrote it, and
# init files load it, so it now loads the new one.
OLD_INIT=$PREFIX/omnivox-init.el

# --------------------------------------------------------------------------
log "Checking the system"
[ "$(uname -s)" = Darwin ] ||
    die "this script is for macOS. For Linux, use the other installers in this folder."
[ "$EUID" -ne 0 ] ||
    die "do not run this as root or with sudo. Run it as your normal user: bash $0"
MACOS_VERSION=$(sw_vers -productVersion)
MACOS_MAJOR=${MACOS_VERSION%%.*}
case "$MACOS_MAJOR" in
    ''|*[!0-9]*) die "could not read the macOS version (sw_vers said: $MACOS_VERSION)" ;;
esac
[ "$MACOS_MAJOR" -ge 13 ] ||
    die "this needs macOS 13 or newer, and this is macOS $MACOS_VERSION"
# hw.optional.arm64 is 1 on Apple silicon, even in a shell under Rosetta.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then
    ARCH=arm64; ARCH_NAME="Apple silicon"
else
    ARCH=x64; ARCH_NAME=Intel
fi
echo "macOS $MACOS_VERSION on $ARCH_NAME: supported."
xcode-select -p >/dev/null 2>&1 ||
    die "the Xcode Command Line Tools are missing; they provide git, make and \
the C compiler. Install them with: xcode-select --install, then rerun this script."
if ! BREW=$(command -v brew); then
    BREW=""
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$candidate" ]; then BREW=$candidate; break; fi
    done
fi
[ -n "$BREW" ] ||
    die "Homebrew is not installed. Install it by following https://brew.sh, then rerun this script."
BREW_PREFIX=$("$BREW" --prefix)
BREW_ON_PATH=yes
case ":$PATH:" in *":$BREW_PREFIX/bin:"*) ;; *) BREW_ON_PATH=no ;; esac
PATH="$BREW_PREFIX/bin:$BREW_PREFIX/sbin:$PATH"
# Homebrew's bin folder belongs to you and is on PATH for Homebrew users,
# so the launcher goes there and needs no sudo.
LAUNCHER=$BREW_PREFIX/bin/emacspeak
# tcl-tk@8 is keg-only: its tclsh8.6 is not linked into Homebrew's bin.
TCL_KEG=$BREW_PREFIX/opt/$TCL_FORMULA
TCLSH=$TCL_KEG/bin/tclsh8.6
TCL_INCLUDE=$TCL_KEG/include/tcl-tk
echo "Homebrew: $BREW_PREFIX"
mkdir -p "${LOG%/*}"
: >"$LOG"
echo "Build log: $LOG"

# --------------------------------------------------------------------------
log "Choosing the speech engines"
if [ -n "$SPEECH" ]; then
    echo "Chosen with --speech."
elif [ -f "$RECORD" ]; then
    parse_engines "$(cat "$RECORD")" ||
        die "$RECORD lists an unknown engine, \"$BAD\". Choose again with --speech."
    [ -n "$SELECTED" ] || die "$RECORD is empty. Choose the engines with --speech."
    echo "Reusing the engines chosen last time, from $RECORD."
    echo "To choose others, run the script with --speech."
elif [ -f "$OLD_INIT" ] && grep -q "$MARKER" "$OLD_INIT"; then
    # Installed before there was a choice of engines: that was OmniVox.
    SELECTED=omnivox
    echo "Keeping OmniVox, which an earlier run of this script installed."
    echo "To choose others, run the script with --speech."
elif [ -t 0 ] && [ -t 1 ]; then
    ask_engines
else
    SELECTED=$DEFAULT_ENGINE
    echo "No terminal to ask on, so the default is used: $DEFAULT_ENGINE. Choose others with --speech."
fi
echo "Selected: $(selected_titles)."
FIRST=${SELECTED%% *}
DEFAULT_SERVER=$(engine_server "$FIRST")
case "$FIRST" in
    espeak)    echo "The launcher's default server: omnivox, with its espeak-ng engine." ;;
    tclespeak) echo "The launcher's default server: espeak, emacspeak's Tcl espeak server." ;;
    *)         echo "The launcher's default server: $DEFAULT_SERVER" ;;
esac
WANT_OMNIVOX=no
if is_selected omnivox || is_selected espeak; then WANT_OMNIVOX=yes; fi
if [ "$WANT_OMNIVOX" = no ] &&
   { [ "$OMNIVOX_ROUTE" = source ] || [ -n "$OMNIVOX_VERSION" ]; }; then
    warn "--omnivox-source and --omnivox-version apply to omnivox and espeak, \
and neither is selected, so they change nothing."
fi
if is_selected tclespeak; then
    case "$PREFIX" in
        *' '*|*'{'*|*'}'*)
            die "tclespeak needs a --prefix without spaces or braces: TclX's \
build and Tcl's package path cannot use them. Choose another --prefix." ;;
    esac
fi

# --------------------------------------------------------------------------
if [ "$SKIP_DEPS" = no ]; then
    HINT="Run brew doctor, fix what it reports, then rerun this script."
    if find_emacs; then
        :
    elif [ "$EMACS_ROUTE" = plus ]; then
        install_emacs_plus
    else
        install_core_emacs
    fi
    if [ "$WANT_OMNIVOX" = yes ] && [ "$OMNIVOX_ROUTE" = source ]; then
        if ! command -v cmake >/dev/null; then
            log "Installing cmake with Homebrew (OmniVox's source build needs it)"
            logged "brew install cmake" "$BREW" install cmake
        fi
        # Homebrew's rust formula installs without running a remote script.
        if ! find_cargo; then
            log "Installing Rust with Homebrew (OmniVox's source build needs it)"
            logged "brew install rust" "$BREW" install rust
        fi
    fi
    if is_selected espeak || is_selected tclespeak; then
        brew_install espeak-ng "the espeak-ng voices and their data"
    fi
    if is_selected tclespeak; then
        if [ ! -d "$TCL_KEG" ]; then
            log "Installing $TCL_FORMULA with Homebrew (Tcl 8.6 for the Tcl espeak server)"
            echo "Homebrew marks $TCL_FORMULA deprecated: Tcl 8.6 has reached its end of life."
            echo "Homebrew plans to disable it on January 1, 2028; until then it installs."
            HINT="If Homebrew says $TCL_FORMULA is disabled, it no longer offers \
Tcl 8.6, which the Tcl espeak server needs. Leave tclespeak out of --speech."
            logged "brew install $TCL_FORMULA" "$BREW" install "$TCL_FORMULA"
            HINT="Run brew doctor, fix what it reports, then rerun this script."
        fi
        if [ ! -d "$BREW_PREFIX/opt/sox" ]; then
            log "Installing sox with Homebrew (it plays the Tcl espeak server's auditory icons)"
            if [ "$ARCH" = x64 ]; then
                warn "Homebrew may have no prebuilt sox for Intel Macs, so it \
may compile sox and its libraries, which can take a while."
            fi
            # Icons are a nicety: the server speaks without them.
            if ! "$BREW" install sox >>"$LOG" 2>&1; then
                warn "brew install sox failed (see $LOG), so the Tcl espeak \
server's auditory icons stay silent. To add them later: brew install sox, then rerun."
            fi
        fi
    fi
fi

log "Checking Emacs and the build tools"
if ! find_emacs; then
    if [ "$EMACS_ROUTE" = plus ]; then
        die "$EMACS_PLUS_FORMULA is not installed in $BREW_PREFIX/opt. Rerun \
without --skip-deps, or install it: brew tap $EMACS_PLUS_TAP, then brew trust \
$EMACS_PLUS_TAP, then brew install $EMACS_PLUS_FORMULA"
    fi
    if command -v emacs >/dev/null; then
        die "emacspeak needs Emacs 29.1 or newer, and $(command -v emacs) is \
Emacs $(emacs_version emacs || echo unknown). Install a newer one: brew install $EMACS_FORMULA"
    fi
    die "emacs not found. Install it: brew install $EMACS_FORMULA, or rerun without --skip-deps"
fi
EMACS_VERSION=$(emacs_version "$EMACS_BIN") ||
    die "$EMACS_BIN is installed but does not run in batch mode. Reinstall \
that Emacs (for Homebrew's: brew reinstall $EMACS_FORMULA), then rerun."
echo "Emacs $EMACS_VERSION: new enough. Using $EMACS_BIN"
# emacspeak's lisp/Makefile runs plain "emacs", so put this one first.
PATH="${EMACS_BIN%/*}:$PATH"
# Apple's make (GNU make 3.81) is enough: emacspeak's Makefiles use only
# pattern rules and $(shell ...), nothing from newer GNU make.
for tool in git make curl shasum tar; do
    command -v "$tool" >/dev/null ||
        die "$tool not found. Install the Xcode Command Line Tools: xcode-select --install"
done
if [ "$WANT_OMNIVOX" = yes ] && [ "$OMNIVOX_ROUTE" = source ]; then
    command -v cmake >/dev/null || die "cmake not found. Install it: brew install cmake"
    find_cargo ||
        die "Rust (cargo) not found. Install it from https://rustup.rs or with: brew install rust"
    RUSTC_VERSION=$(rustc --version | awk '{ print $2 }')
    rust_minor=${RUSTC_VERSION#1.}
    rust_minor=${rust_minor%%.*}
    case "$rust_minor" in ''|*[!0-9]*) rust_minor=0 ;; esac
    [ "$rust_minor" -ge 70 ] ||
        die "OmniVox needs Rust 1.70 or newer, and this is $RUSTC_VERSION. \
Update it: rustup update, or brew upgrade rust"
    echo "Rust $RUSTC_VERSION and cmake found."
fi
if is_selected espeak || is_selected tclespeak; then
    [ -f "$BREW_PREFIX/share/espeak-ng-data/phontab" ] ||
        die "espeak-ng's voice data is missing from $BREW_PREFIX/share/espeak-ng-data. \
Install it: brew install espeak-ng, or rerun without --skip-deps"
    echo "espeak-ng voice data found in $BREW_PREFIX/share/espeak-ng-data."
fi
SWIFT_VERSION=""
if is_selected swiftmac; then
    command -v swift >/dev/null ||
        die "Swift not found, and swiftmac needs Swift 5.9 or newer. The Xcode \
Command Line Tools include it: install them with xcode-select --install, or \
install Xcode, then rerun. Or leave swiftmac out of --speech."
    SWIFT_VERSION=$(swift_version) || SWIFT_VERSION=""
    [ -n "$SWIFT_VERSION" ] ||
        die "swift --version did not say which Swift this is. Reinstall the \
Command Line Tools (xcode-select --install), then rerun. See $LOG"
    swift_new_enough "$SWIFT_VERSION" ||
        die "swiftmac needs Swift 5.9 or newer, and this is Swift $SWIFT_VERSION. \
Update Xcode or its Command Line Tools with Software Update, then rerun."
    echo "Swift $SWIFT_VERSION: new enough for swiftmac."
fi
if is_selected tclespeak; then
    [ -x "$TCLSH" ] ||
        die "$TCL_FORMULA is not installed: $TCLSH is missing. Install it: brew \
install $TCL_FORMULA, or rerun without --skip-deps"
    [ -f "$TCL_KEG/lib/tclConfig.sh" ] ||
        die "$TCL_KEG/lib/tclConfig.sh is missing. Reinstall Tcl 8.6: brew reinstall $TCL_FORMULA"
    grep -q 'define TCL_VERSION[[:space:]]*"8.6"' "$TCL_INCLUDE/tcl.h" 2>/dev/null ||
        die "$TCL_INCLUDE/tcl.h is missing or is not Tcl 8.6. Reinstall it: brew \
reinstall $TCL_FORMULA"
    [ -r "$BREW_PREFIX/include/espeak-ng/speak_lib.h" ] ||
        die "espeak-ng's headers are missing from $BREW_PREFIX/include. Install \
it: brew install espeak-ng"
    echo "Tcl 8.6 from $TCL_FORMULA, and the espeak-ng headers, found."
fi

# --------------------------------------------------------------------------
OLD_HEAD=""
RESTORED_TCL=no
HINT="Check the internet connection and the --repo and --ref values. For an \
update, also undo your own changes in $PREFIX (git -C $PREFIX status)."
if [ -d "$PREFIX/.git" ]; then
    log "Updating emacspeak in $PREFIX from $REPO ($REF)"
    # Undo this script's changes first, so git sees unmodified files:
    # OmniVox's two names in servers/.servers, and the Tcl servers' first
    # lines. Both come back after the update.
    unregister_omnivox
    restore_tcl_servers
    OLD_HEAD=$(git -C "$PREFIX" rev-parse HEAD)
    logged "updating the clone in $PREFIX" \
        git -C "$PREFIX" pull -q --ff-only "$REPO" "$REF"
    # What earlier runs installed stays usable, chosen this time or not.
    if [ -x "$PREFIX/servers/omnivox" ]; then register_omnivox; fi
    if [ "$RESTORED_TCL" = yes ] && [ -x "$TCLSH" ]; then point_tcl_servers; fi
elif [ -e "$PREFIX" ] && [ -n "$(ls -A "$PREFIX")" ]; then
    die "$PREFIX exists but is not a git clone of emacspeak. Move it away or use --prefix."
else
    log "Cloning emacspeak ($REF) from $REPO into $PREFIX"
    logged "git clone" git clone -q --depth 1 --branch "$REF" "$REPO" "$PREFIX"
fi
exclude_own_files
echo "Emacspeak source: $(git -C "$PREFIX" log -1 --format='commit %h of %cd' --date=short)"

log "Configuring emacspeak (make config)"
HINT="The lines above name the Lisp file that failed. Make sure $EMACS_BIN \
starts, then rerun; if it still fails, ask on the emacspeak mailing list."
logged "make config" make_in "$PREFIX" config
# make config only writes emacspeak-loaddefs.el when it is missing, so
# rebuild it when the update brought new commits.
if [ -n "$OLD_HEAD" ] && [ "$OLD_HEAD" != "$(git -C "$PREFIX" rev-parse HEAD)" ]; then
    log "Regenerating emacspeak's autoloads for the new commits"
    logged "regenerating emacspeak-loaddefs.el" \
        make_in "$PREFIX/lisp" -B emacspeak-loaddefs.el
fi

log "Byte-compiling emacspeak's Lisp (make emacspeak, a few minutes)"
logged "make emacspeak" make_in "$PREFIX" emacspeak

# --------------------------------------------------------------------------
# OmniVox, for the omnivox and espeak engines.
INSTALLED=$(cat "$OMNIVOX_DIR/installed-version" 2>/dev/null || true)
ROUTE_TEXT=""
if [ "$WANT_OMNIVOX" = yes ]; then
    mkdir -p "$OMNIVOX_DIR"
    log "Choosing the OmniVox release"
    # Latest by default, so rerunning this script also updates OmniVox. The
    # checksum file comes from the same release: it catches a damaged download.
    if [ -n "$OMNIVOX_VERSION" ]; then
        echo "OmniVox $OMNIVOX_VERSION, as asked with --omnivox-version."
    elif OMNIVOX_VERSION=$(latest_omnivox_version) && valid_version "$OMNIVOX_VERSION"; then
        echo "Latest OmniVox release: $OMNIVOX_VERSION"
    elif [ -n "$INSTALLED" ]; then
        OMNIVOX_VERSION=${INSTALLED%% *}
        warn "could not ask GitHub for the latest OmniVox release; keeping $OMNIVOX_VERSION."
    else
        OMNIVOX_VERSION=$OMNIVOX_FALLBACK
        warn "could not ask GitHub for the latest OmniVox release; using $OMNIVOX_VERSION."
    fi
    if [ "$OMNIVOX_ROUTE" = source ]; then
        WANT="$OMNIVOX_VERSION source"
        ROUTE_TEXT="built from source"
    else
        WANT="$OMNIVOX_VERSION macos-$ARCH"
        ROUTE_TEXT="prebuilt for $ARCH_NAME, checksum verified"
    fi
    if [ "$INSTALLED" = "$WANT" ] && [ -x "$PREFIX/servers/omnivox" ] &&
       [ -f "$OMNIVOX_DIR/elisp/omnivox-voices.el" ]; then
        echo "OmniVox $OMNIVOX_VERSION ($ROUTE_TEXT) is already installed; keeping it."
    elif [ "$OMNIVOX_ROUTE" = source ]; then
        build_omnivox_from_source "$OMNIVOX_VERSION"
    else
        install_prebuilt_omnivox "$OMNIVOX_VERSION"
    fi
    INSTALLED=$WANT

    log "Registering OmniVox in $SERVERS_LIST"
    register_omnivox
    echo "Listed: omnivox, log-omnivox."
elif [ -n "$INSTALLED" ]; then
    OMNIVOX_VERSION=${INSTALLED%% *}
    case "$INSTALLED" in
        *" source") ROUTE_TEXT="built from source" ;;
        *)          ROUTE_TEXT="prebuilt for $ARCH_NAME, checksum verified" ;;
    esac
fi
HAVE_OMNIVOX=no
if [ -x "$PREFIX/servers/omnivox" ] && [ -f "$OMNIVOX_DIR/elisp/omnivox-voices.el" ]; then
    HAVE_OMNIVOX=yes
fi
# The prebuilt OmniVox looks for espeak-ng's voice data in /opt/homebrew and
# /usr/local only (a source build carries its own), so a Homebrew elsewhere
# needs ESPEAK_NG_DATA, which OmniVox reads first.
SET_ESPEAK_DATA=no
case "$BREW_PREFIX" in
    /opt/homebrew|/usr/local) ;;
    *) if [ "$HAVE_OMNIVOX" = yes ] && [ -f "$BREW_PREFIX/share/espeak-ng-data/phontab" ]; then
           SET_ESPEAK_DATA=yes
       fi ;;
esac

if is_selected espeak; then
    log "Setting up OmniVox's espeak-ng engine"
    echo "Voice data: $BREW_PREFIX/share/espeak-ng-data, from Homebrew's espeak-ng."
    if [ "$SET_ESPEAK_DATA" = yes ]; then
        echo "OmniVox does not look in $BREW_PREFIX, so the launcher and the init file set ESPEAK_NG_DATA."
    elif [ "$OMNIVOX_ROUTE" = source ]; then
        echo "OmniVox built from source reads the copy of the data its build made."
    else
        echo "OmniVox finds the data there itself. OMNIVOX_ENGINE=espeak picks the engine."
    fi
fi

# --------------------------------------------------------------------------
if is_selected swiftmac; then
    log "Building swiftmac with Swift $SWIFT_VERSION (make swiftmac, a few minutes)"
    echo "It fetches one Swift package, OggDecoder, from GitHub."
    HINT="swiftmac needs Swift 5.9 or newer, and the internet for its OggDecoder \
package. Update Xcode or its Command Line Tools, then rerun, or leave swiftmac \
out of --speech."
    logged "make swiftmac" make_in "$PREFIX" swiftmac
    # emacspeak's swiftmac target reports a failed build only with an echo,
    # so check that servers/swiftmac is the binary this build just made.
    cmp -s "$PREFIX/servers/mac-swiftmac/.build/release/swiftmac" "$PREFIX/servers/swiftmac" ||
        fail_with_log "make swiftmac"
    echo "Built $PREFIX/servers/swiftmac"
fi

# --------------------------------------------------------------------------
if is_selected tclespeak; then
    export TCLLIBPATH="{$TCLX_DIR/lib}${TCLLIBPATH:+ $TCLLIBPATH}"
    log "Checking TclX in Homebrew's Tcl 8.6"
    if TCLX=$(tclx_version 2>>"$LOG"); then
        echo "TclX $TCLX loads in $TCLSH; keeping it."
    else
        build_tclx
        TCLX=$(tclx_version 2>>"$LOG") ||
            die "TclX was built, but it does not load in $TCLSH. See $LOG"
        echo "TclX $TCLX is installed in $TCLX_DIR"
    fi

    log "Building tclespeak.dylib, the espeak glue, against Homebrew's Tcl 8.6"
    # The Makefile's macOS branch links Apple's Tcl framework, so name
    # Homebrew's Tcl 8.6 and espeak-ng here instead.
    HINT="Check that $TCL_FORMULA and espeak-ng are installed (brew list \
$TCL_FORMULA espeak-ng), then rerun."
    logged "building tclespeak.dylib" make_in "$PREFIX/servers/native-espeak" -B \
        CXXFLAGS="-g -O2 -fPIC -DPIC -Wall -Wno-long-long -std=c++11 -I$TCL_INCLUDE -I$BREW_PREFIX/include" \
        LIBS="-L$TCL_KEG/lib -ltcl8.6 -L$BREW_PREFIX/lib -lespeak-ng"
    [ -f "$GLUE" ] || die "the build finished but $GLUE is missing"
    echo "Built $GLUE"

    log "Pointing the Tcl speech servers at $TCLSH"
    point_tcl_servers
    [ -n "$TCL_SERVERS" ] || die "no Tcl speech servers found in $PREFIX/servers"
    echo "Changed:$TCL_SERVERS"
fi
HAVE_SWIFTMAC=no
if [ -x "$PREFIX/servers/swiftmac" ]; then HAVE_SWIFTMAC=yes; fi
HAVE_TCLESPEAK=no
if [ -f "$GLUE" ] && [ -x "$TCLSH" ] && [ -f "$PREFIX/servers/espeak" ] &&
   [ "$(head -n 1 "$PREFIX/servers/espeak")" = "#!$TCLSH" ]; then
    HAVE_TCLESPEAK=yes
fi
# The Tcl espeak server's auditory icons are Ogg Vorbis files. SoX's play
# reads them; macOS's afplay does not, but it at least runs without errors.
ICON_PLAYER=/usr/bin/afplay
if [ -x "$BREW_PREFIX/bin/play" ]; then ICON_PLAYER=$BREW_PREFIX/bin/play; fi
if is_selected tclespeak; then
    if [ "$ICON_PLAYER" = /usr/bin/afplay ]; then
        echo "Auditory icons: SoX is missing, so the Tcl espeak server's icons are silent."
    else
        echo "Auditory icons: the Tcl espeak server plays them with $ICON_PLAYER"
    fi
fi

# --------------------------------------------------------------------------
log "Writing $INIT"
{
    cat <<INIT
;;; emacspeak-init.el --- emacspeak with real speech on macOS  -*- lexical-binding: t; -*-
;; $MARKER, which rewrites it on every run.
;; Load it from your own init file, or copy these settings there.

;; Emacspeak's Lisp, and the speech server: DTK_PROGRAM when it is set,
;; otherwise $DEFAULT_SERVER, the default chosen when this was installed.
(add-to-list 'load-path "$PREFIX/lisp")
(setq dtk-program (or (getenv "DTK_PROGRAM") "$DEFAULT_SERVER"))
INIT
    if [ "$HAVE_OMNIVOX" = yes ]; then
        cat <<INIT

;; OmniVox's voice module loads before emacspeak, for the omnivox server.
;; From another server, M-x omnivox switches to OmniVox.
(add-to-list 'load-path "$OMNIVOX_DIR/elisp")
(when (string-match-p "omnivox" dtk-program)
  (require 'omnivox-voices))
(autoload 'omnivox "omnivox-voices" "Switch emacspeak to the OmniVox server." t)
;; Optional: M-x customize-group RET omnivox RET lists every OmniVox setting.
;; (setq omnivox-voice-id "en-US:Samantha")
;; (setq omnivox-speech-rate 60)   ; 0 to 100, 50 is normal
INIT
        if [ "$FIRST" = espeak ]; then
            cat <<'INIT'
;; OmniVox speaks with its espeak-ng engine unless OMNIVOX_ENGINE is set;
;; OMNIVOX_ENGINE=native picks the macOS system voices instead.
(unless (getenv "OMNIVOX_ENGINE")
  (setenv "OMNIVOX_ENGINE" "espeak"))
INIT
        fi
        if [ "$SET_ESPEAK_DATA" = yes ]; then
            cat <<INIT
;; OmniVox's espeak-ng engine reads its voice data from Homebrew.
(unless (getenv "ESPEAK_NG_DATA")
  (setenv "ESPEAK_NG_DATA" "$BREW_PREFIX/share"))
INIT
        fi
    fi
    if [ "$HAVE_TCLESPEAK" = yes ]; then
        cat <<INIT

;; The Tcl espeak server: Tcl finds TclX through TCLLIBPATH, and the
;; server plays auditory icons with EMACSPEAK_PLAY.
(let ((tclx "{$TCLX_DIR/lib}")
      (old (getenv "TCLLIBPATH")))
  (unless (and old (string-search tclx old))
    (setenv "TCLLIBPATH" (if old (concat tclx " " old) tclx))))
(unless (getenv "EMACSPEAK_PLAY")
  (setenv "EMACSPEAK_PLAY" "$ICON_PLAYER"))
INIT
    fi
    cat <<INIT

;; Keep macOS accessibility prompts from interrupting speech.
(when (eq system-type 'darwin)
  (setq mac-ignore-accessibility t))
;; OmniVox and swiftmac play the auditory icons themselves, so their sound
;; volume applies. The Tcl espeak server keeps emacspeak's own player.
(when (string-match-p "omnivox\\\\|swiftmac" dtk-program)
  (setq emacspeak-play-program nil))
;; Native compilation runs in the background; do not pop up its warnings.
(setq native-comp-async-report-warnings-errors 'silent)

(load-file "$PREFIX/lisp/emacspeak-setup.el")
INIT
} >"$INIT"
echo "Written."
if [ -f "$OLD_INIT" ] && grep -q "$MARKER" "$OLD_INIT"; then
    cat >"$OLD_INIT" <<OLD
;;; omnivox-init.el --- loads emacspeak-init.el  -*- lexical-binding: t; -*-
;; $MARKER, which rewrites it on every run.
;; The settings moved to emacspeak-init.el. This file loads it, so an init
;; file that loads omnivox-init.el keeps working. Better, load the new one:
;; (load-file "$INIT")
(load-file "$INIT")
OLD
    echo "The old init file now loads it: $OLD_INIT"
fi

log "Writing the launcher $LAUNCHER"
[ -w "${LAUNCHER%/*}" ] ||
    die "${LAUNCHER%/*} is not writable by you. Fix Homebrew's permissions (brew doctor), then rerun."
if [ -L "$LAUNCHER" ] || { [ -e "$LAUNCHER" ] && ! grep -q "$MARKER" "$LAUNCHER"; }; then
    die "$LAUNCHER exists and was not written by this script. Move it away, then rerun."
fi
{
    cat <<LAUNCHER
#!/bin/sh
# Console Emacs with emacspeak. The default speech server is $DEFAULT_SERVER.
# $MARKER. DTK_PROGRAM picks the speech server.
# -q skips your own init file, so emacspeak always starts the same way.
export DTK_PROGRAM="\${DTK_PROGRAM:-$DEFAULT_SERVER}"
LAUNCHER
    if [ "$FIRST" = espeak ]; then
        cat <<'LAUNCHER'
# OmniVox speaks with its espeak-ng engine; OMNIVOX_ENGINE=native picks
# the macOS system voices instead.
export OMNIVOX_ENGINE="${OMNIVOX_ENGINE:-espeak}"
LAUNCHER
    fi
    if [ "$SET_ESPEAK_DATA" = yes ]; then
        cat <<LAUNCHER
export ESPEAK_NG_DATA="\${ESPEAK_NG_DATA:-$BREW_PREFIX/share}"
LAUNCHER
    fi
    if [ "$HAVE_TCLESPEAK" = yes ]; then
        cat <<LAUNCHER
# The Tcl espeak server finds TclX through TCLLIBPATH, and plays its
# auditory icons with EMACSPEAK_PLAY.
export TCLLIBPATH="{$TCLX_DIR/lib}\${TCLLIBPATH:+ \$TCLLIBPATH}"
export EMACSPEAK_PLAY="\${EMACSPEAK_PLAY:-$ICON_PLAYER}"
LAUNCHER
    fi
    cat <<LAUNCHER
exec "$EMACS_BIN" -nw -q -l "$INIT" "\$@"
LAUNCHER
} >"$LAUNCHER"
chmod 0755 "$LAUNCHER"
echo "Launcher written."

# --------------------------------------------------------------------------
# Self-tests, numbered across the chosen engines: each engine's own checks,
# then the shared ones, then each server started the way Emacs starts it.
# Only the OmniVox server tests need sound: each is skipped when OmniVox
# finds no sound output device, or when the voice gives no audio, which
# happens in sessions without a logged-in user (its check then warns).
OMNIVOX=$PREFIX/servers/omnivox
SWIFTMAC=$PREFIX/servers/swiftmac
TCL_SERVER=$PREFIX/servers/espeak
TEST_N=0
TEST_TOTAL=0
TEST_ENGINE=""
PASS_COUNT=0
PASSED=""
WARN_COUNT=0
WARNED=""
SKIP_COUNT=0
SKIPPED=""
ENGINES_PASSED=""
ENGINES_WARNED=""
count_tests() {
    local n=3   # shared: Emacs, the init file, the servers and launcher
    if is_selected omnivox; then n=$((n + 4)); fi
    if is_selected espeak; then
        n=$((n + 3))
        if ! is_selected omnivox; then n=$((n + 1)); fi
    fi
    if is_selected swiftmac; then n=$((n + 2)); fi
    if is_selected tclespeak; then n=$((n + 4)); fi
    echo "$n"
}
begin_test() { # $1 = the engine it tests, or "" for a shared test; $2 = what
    TEST_N=$((TEST_N + 1))
    TEST_ENGINE=$1
    log "Self-test $TEST_N of $TEST_TOTAL: $2"
}
passed() { # $1 = what passed
    PASSED="${PASSED:+$PASSED, }$TEST_N"
    PASS_COUNT=$((PASS_COUNT + 1))
    ENGINES_PASSED="$ENGINES_PASSED $TEST_ENGINE"
    echo "Pass: $1"
}
warned() { # $1 = the warning, as the summary gives it
    WARNED="${WARNED:+$WARNED; }test $TEST_N, $1"
    WARN_COUNT=$((WARN_COUNT + 1))
    ENGINES_WARNED="$ENGINES_WARNED $TEST_ENGINE"
}
skipped() { # $1 = why
    SKIPPED="${SKIPPED:+$SKIPPED; }test $TEST_N, $1"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    echo "Skipped: $1."
}
engine_status() { # $1 = engine: Pass, Warning or Skipped
    if [ "$RUN_TESTS" = no ]; then echo "Skipped (--no-test)"; return 0; fi
    case " $ENGINES_WARNED " in *" $1 "*) echo Warning; return 0 ;; esac
    case " $ENGINES_PASSED " in *" $1 "*) echo Pass; return 0 ;; esac
    echo Skipped
}
test_omnivox_version() { # $1 = the engine this counts for
    begin_test "$1" "OmniVox reports its version"
    OUT=$(limited 30 "" "$OMNIVOX" --version 2>>"$LOG") ||
        die "Self-test $TEST_N failed: $OMNIVOX --version did not run. Rerun with \
--omnivox-source to build it here. See $LOG"
    case "$OUT" in
        "omnivox "*) passed "$OUT." ;;
        *) die "Self-test $TEST_N failed: $OMNIVOX --version printed: $OUT. Rerun \
with --omnivox-source to build it here." ;;
    esac
}
# Speech synthesis needs your logged-in session on the Mac.
SPEECH_FIX="If you ran this over ssh, run it in Terminal on the Mac itself."
# Emacs loads the init file with DTK_PROGRAM set to a server, and checks
# that emacspeak loaded and finds that server. $1 = extra checks.
load_check() {
    printf '%s' "(kill-emacs (if (and (featurep (quote emacspeak))
                                  (file-executable-p
                                   (expand-file-name dtk-program emacspeak-servers-directory))
                                  $1)
                             0 1))"
}

if [ "$RUN_TESTS" = yes ]; then
    TEST_TOTAL=$(count_tests)
    # The tests set these themselves; values from your shell would change them.
    unset OMNIVOX_ENGINE OMNIVOX_AUDIO_TARGET SWIFTMAC_AUDIO_TARGET
    if [ "$SET_ESPEAK_DATA" = yes ] && [ -z "${ESPEAK_NG_DATA:-}" ]; then
        export ESPEAK_NG_DATA=$BREW_PREFIX/share
    fi
    if is_selected tclespeak; then export EMACSPEAK_PLAY="${EMACSPEAK_PLAY:-$ICON_PLAYER}"; fi
    SOUND=no
    SKIP_WHY=""
    ESPEAK_SOUND=no
    ESPEAK_SKIP_WHY=""

    if is_selected omnivox; then
        test_omnivox_version omnivox

        begin_test omnivox "OmniVox lists the system voices"
        OUT=$(limited 60 "" "$OMNIVOX" --list-voices 2>>"$LOG") ||
            die "Self-test $TEST_N failed: $OMNIVOX --list-voices did not finish. $SPEECH_FIX See $LOG"
        printf '%s\n' "$OUT" >>"$LOG"
        VOICES=$(voice_count "$OUT")
        [ "${VOICES:-0}" -ge 1 ] ||
            die "Self-test $TEST_N failed: OmniVox found no voices. Check System \
Settings, Accessibility, Spoken Content."
        passed "$VOICES voices."

        begin_test omnivox "OmniVox's own check synthesizes speech"
        echo "With a sound device, you may hear a tone and: Omnivox is ready."
        OUT=$(limited 120 "" "$OMNIVOX" --check 2>>"$LOG") ||
            die "Self-test $TEST_N failed: $OMNIVOX --check did not run to the end. \
$SPEECH_FIX See $LOG"
        printf '%s\n' "$OUT" >>"$LOG"
        SYNTH=$(synth_status "$OUT")
        if grep -q 'Audio device: OK' <<<"$OUT"; then SOUND=yes; fi
        case "$SYNTH" in
            OK*)
                if [ "$SOUND" = yes ]; then
                    passed "speech synthesized, and a sound output device was found."
                else
                    passed "speech synthesized. No sound output device was found."
                    SKIP_WHY="no sound output device was found"
                fi ;;
            *)
                SOUND=no
                warned "the system voice produced no audio"
                SKIP_WHY="the system voice produced no audio in test $TEST_N"
                warn "the system voice produced no audio."
                echo "OmniVox said: ${SYNTH:-no synthesis status}"
                echo "This happens in sessions without a logged-in user."
                echo "On your Mac, run the script again in Terminal,"
                echo "or try M-x omnivox-select-voice in emacspeak." ;;
        esac
    fi

    if is_selected espeak; then
        is_selected omnivox || test_omnivox_version espeak

        begin_test espeak "OmniVox's espeak-ng engine finds its voices"
        OUT=$(limited 60 "" "$OMNIVOX" --engine espeak --list-voices 2>>"$LOG") ||
            die "Self-test $TEST_N failed: OmniVox's espeak-ng engine did not \
start; its voice data may be missing. Reinstall it: brew reinstall espeak-ng, \
then rerun. See $LOG"
        printf '%s\n' "$OUT" >>"$LOG"
        VOICES=$(voice_count "$OUT")
        [ "${VOICES:-0}" -ge 1 ] ||
            die "Self-test $TEST_N failed: OmniVox's espeak-ng engine found no \
voices. Reinstall espeak-ng: brew reinstall espeak-ng, then rerun."
        passed "$VOICES espeak-ng voices."

        begin_test espeak "OmniVox's espeak-ng engine synthesizes speech"
        echo "With a sound device, you may hear a tone and, in an espeak-ng voice: Omnivox is ready."
        OUT=$(limited 120 "" "$OMNIVOX" --engine espeak --check 2>>"$LOG") ||
            die "Self-test $TEST_N failed: $OMNIVOX --engine espeak --check did \
not run to the end. See $LOG"
        printf '%s\n' "$OUT" >>"$LOG"
        SYNTH=$(synth_status "$OUT")
        if grep -q 'Audio device: OK' <<<"$OUT"; then ESPEAK_SOUND=yes; fi
        case "$SYNTH" in
            OK*)
                if [ "$ESPEAK_SOUND" = yes ]; then
                    passed "espeak-ng synthesized speech, and a sound output device was found."
                else
                    passed "espeak-ng synthesized speech. No sound output device was found."
                    ESPEAK_SKIP_WHY="no sound output device was found"
                fi ;;
            *)
                ESPEAK_SOUND=no
                warned "espeak-ng produced no audio"
                ESPEAK_SKIP_WHY="espeak-ng produced no audio in test $TEST_N"
                warn "espeak-ng produced no audio."
                echo "OmniVox said: ${SYNTH:-no synthesis status}"
                echo "Reinstall espeak-ng (brew reinstall espeak-ng), then rerun." ;;
        esac
    fi

    if is_selected swiftmac; then
        begin_test swiftmac "swiftmac is built, with its two frameworks beside it"
        [ -x "$SWIFTMAC" ] ||
            die "Self-test $TEST_N failed: $SWIFTMAC is missing. Rerun the script to build it."
        if [ -d "$PREFIX/servers/ogg.framework" ] && [ -d "$PREFIX/servers/vorbis.framework" ]; then
            passed "swiftmac, ogg.framework and vorbis.framework are in $PREFIX/servers."
        else
            warned "ogg.framework or vorbis.framework is missing beside swiftmac"
            warn "ogg.framework or vorbis.framework is missing from $PREFIX/servers, \
so swiftmac may not start. Rerun the script to rebuild it."
        fi
    fi

    if is_selected tclespeak; then
        begin_test tclespeak "TclX loads in $TCLSH"
        TCLX=$(tclx_version 2>>"$LOG") ||
            die "Self-test $TEST_N failed: TclX does not load in $TCLSH. Rerun the \
script to rebuild it. See $LOG"
        passed "TclX $TCLX."

        begin_test tclespeak "tclespeak.dylib loads in $TCLSH and provides say"
        INFO=$(espeak_glue_check "$GLUE" 2>>"$LOG") ||
            die "Self-test $TEST_N failed: $GLUE does not load. See $LOG"
        passed "$INFO."

        begin_test tclespeak "SoX reads emacspeak's auditory icons (no sound)"
        if [ ! -x "$BREW_PREFIX/bin/sox" ]; then
            warned "SoX is missing, so the Tcl espeak server's auditory icons are silent"
            warn "SoX is not installed, so the Tcl espeak server cannot play auditory icons."
            echo "To add them: brew install sox, then rerun."
        elif "$BREW_PREFIX/bin/sox" "$PREFIX/sounds/chimes/button.ogg" -n >>"$LOG" 2>&1; then
            passed "SoX decodes the Ogg Vorbis icons, so the server can play them."
        else
            warned "SoX could not read the auditory icons"
            warn "SoX could not decode $PREFIX/sounds/chimes/button.ogg, so the Tcl \
espeak server's auditory icons may be silent. See $LOG"
        fi
    fi

    begin_test "" "Emacs is 29.1 or newer"
    emacs_new_enough "$EMACS_BIN" ||
        die "Self-test $TEST_N failed: Emacs $EMACS_VERSION is too old. Install a \
newer one: brew install $EMACS_FORMULA"
    passed "Emacs $EMACS_VERSION."

    begin_test "" "Emacs loads the init file and finds each chosen server (no speech)"
    for server in $(chosen_servers); do
        case "$server" in
            omnivox)
                extra="(featurep (quote omnivox-voices))"
                if [ "$FIRST" = espeak ]; then
                    extra="$extra (equal (getenv \"OMNIVOX_ENGINE\") \"espeak\")"
                fi ;;
            espeak)
                extra="(string-search \"$TCLX_DIR/lib\" (or (getenv \"TCLLIBPATH\") \"\"))
                       (getenv \"EMACSPEAK_PLAY\")" ;;
            *) extra="t" ;;
        esac
        # Without the variables the init file sets, to see that it sets them.
        env -u TCLLIBPATH -u EMACSPEAK_PLAY DTK_PROGRAM="$server" \
            "$EMACS_BIN" -Q --batch -l "$INIT" --eval "$(load_check "$extra")" >>"$LOG" 2>&1 ||
            die "Self-test $TEST_N failed: Emacs could not load $INIT with the \
$server server, or emacspeak does not find $PREFIX/servers/$server. Rerun the \
script to rebuild both. See $LOG"
    done
    if is_selected omnivox || is_selected espeak; then
        passed "emacspeak and omnivox-voices load, and emacspeak finds the servers: $(commas "$(chosen_servers)")."
    else
        passed "emacspeak loads, and finds the servers: $(commas "$(chosen_servers)")."
    fi

    begin_test "" "the servers are registered and the launcher is in place"
    names=""
    if [ "$WANT_OMNIVOX" = yes ]; then names="omnivox log-omnivox"; fi
    if is_selected swiftmac; then names="$names swiftmac"; fi
    if is_selected tclespeak; then names="$names espeak"; fi
    for name in $names; do
        grep -qx "$name" "$SERVERS_LIST" ||
            die "Self-test $TEST_N failed: $SERVERS_LIST does not list $name. Rerun the script."
    done
    if [ "$WANT_OMNIVOX" = yes ]; then
        [ -x "$PREFIX/servers/log-omnivox" ] ||
            die "Self-test $TEST_N failed: $PREFIX/servers/log-omnivox is missing. Rerun the script."
    fi
    [ -x "$LAUNCHER" ] || die "Self-test $TEST_N failed: $LAUNCHER is missing. Rerun the script."
    grep -q "DTK_PROGRAM:-$DEFAULT_SERVER}" "$LAUNCHER" ||
        die "Self-test $TEST_N failed: $LAUNCHER does not default to $DEFAULT_SERVER. Rerun the script."
    passed "$SERVERS_LIST lists every chosen server, and the launcher defaults to $DEFAULT_SERVER."

    if is_selected omnivox; then
        begin_test omnivox "the OmniVox server starts the way Emacs starts it"
        if [ "$SOUND" = yes ]; then
            echo "You should hear: Omnivox version $OMNIVOX_VERSION."
            limited 60 version "$OMNIVOX" >>"$LOG" 2>&1 ||
                die "Self-test $TEST_N failed: the server did not start or exit \
cleanly. Check the output device in System Settings, Sound, then rerun. See $LOG"
            passed "the server spoke its version and exited cleanly."
        else
            skipped "$SKIP_WHY"
            echo "The server needs a working voice and a sound output device."
            if [ -z "$WARNED" ]; then
                echo "Connect speakers or headphones, then rerun."
            fi
        fi
    fi

    if is_selected espeak; then
        begin_test espeak "the OmniVox server starts with its espeak-ng engine"
        if [ "$ESPEAK_SOUND" = yes ]; then
            echo "You should hear, in an espeak-ng voice: Omnivox version $OMNIVOX_VERSION."
            limited 60 version env OMNIVOX_ENGINE=espeak "$OMNIVOX" >>"$LOG" 2>&1 ||
                die "Self-test $TEST_N failed: the server did not start or exit \
cleanly with OMNIVOX_ENGINE=espeak. Check the output device in System Settings, \
Sound, then rerun. See $LOG"
            passed "the server spoke its version with espeak-ng and exited cleanly."
        else
            skipped "$ESPEAK_SKIP_WHY"
            echo "The server needs a sound output device."
        fi
    fi

    if is_selected swiftmac; then
        begin_test swiftmac "the swiftmac server starts the way Emacs starts it"
        echo "With a sound device, you may hear: swiftmac, and its version."
        limited 60 version "$SWIFTMAC" >>"$LOG" 2>&1 ||
            die "Self-test $TEST_N failed: $SWIFTMAC did not start, or did not \
exit at the end of its input. $SPEECH_FIX See $LOG"
        passed "the server started, read its input and exited cleanly."
    fi

    if is_selected tclespeak; then
        begin_test tclespeak "the Tcl espeak server starts the way Emacs starts it"
        echo "With a sound device, you may hear: eSpeak, and its version."
        rc=0
        OUT=$(limited 60 "" "$TCL_SERVER" 2>&1) || rc=$?
        printf '%s\n' "$OUT" >>"$LOG"
        if [ "$rc" -eq 0 ]; then
            passed "the server started and exited cleanly at the end of its input."
        elif grep -q 'Could not synthesize' <<<"$OUT"; then
            warned "the Tcl espeak server could not play speech"
            warn "the Tcl espeak server started, but espeak-ng could not play speech."
            echo "This happens without a sound output device. Connect one, then rerun."
        else
            die "Self-test $TEST_N failed: $TCL_SERVER did not start, or did not \
exit at the end of its input. See $LOG"
        fi
    fi

    TESTS="$PASS_COUNT of $TEST_TOTAL passed"
    if [ "$WARN_COUNT" -eq 1 ]; then TESTS="$TESTS, 1 warning"; fi
    if [ "$WARN_COUNT" -gt 1 ]; then TESTS="$TESTS, $WARN_COUNT warnings"; fi
    if [ "$SKIP_COUNT" -gt 0 ]; then TESTS="$TESTS, $SKIP_COUNT skipped"; fi
    if [ "$PASS_COUNT" -eq "$TEST_TOTAL" ]; then TESTS="all $TEST_TOTAL passed"; fi
else
    TESTS="skipped (--no-test)"
fi

# The record of this choice, which the next run without --speech reuses.
for e in $SELECTED; do printf '%s\n' "$e"; done >"$RECORD"

# --------------------------------------------------------------------------
log "Done: emacspeak is installed"
echo "Self-tests: $TESTS"
if [ "$RUN_TESTS" = yes ]; then
    if [ -n "$PASSED" ]; then echo "Passed: tests $PASSED"; fi
    if [ -n "$WARNED" ]; then echo "Warning: $WARNED"; fi
    if [ -n "$SKIPPED" ]; then echo "Skipped: $SKIPPED"; fi
fi
echo "Speech engines, in order of preference:"
for e in $SELECTED; do
    echo "  $e: $(engine_status "$e"). Server: $(engine_server_text "$e")."
done
EARLIER=""
if [ "$HAVE_OMNIVOX" = yes ] && [ "$WANT_OMNIVOX" = no ]; then EARLIER="OmniVox"; fi
if [ "$HAVE_SWIFTMAC" = yes ] && ! is_selected swiftmac; then
    EARLIER="${EARLIER:+$EARLIER, }swiftmac"
fi
if [ "$HAVE_TCLESPEAK" = yes ] && ! is_selected tclespeak; then
    EARLIER="${EARLIER:+$EARLIER, }the Tcl espeak server"
fi
if [ -n "$EARLIER" ]; then
    echo "Still installed from an earlier run, not updated: $EARLIER."
fi
SERVERS=""
if [ "$HAVE_OMNIVOX" = yes ]; then SERVERS="omnivox"; fi
if [ "$HAVE_SWIFTMAC" = yes ]; then SERVERS="${SERVERS:+$SERVERS, }swiftmac"; fi
if [ "$HAVE_TCLESPEAK" = yes ]; then SERVERS="${SERVERS:+$SERVERS, }espeak"; fi
case "$FIRST" in
    omnivox)   LAUNCHER_SETS="DTK_PROGRAM=omnivox, which picks the OmniVox server." ;;
    espeak)    LAUNCHER_SETS="DTK_PROGRAM=omnivox and OMNIVOX_ENGINE=espeak, which pick OmniVox's espeak-ng engine." ;;
    swiftmac)  LAUNCHER_SETS="DTK_PROGRAM=swiftmac, which picks the swiftmac server." ;;
    tclespeak) LAUNCHER_SETS="DTK_PROGRAM=espeak, which picks emacspeak's Tcl espeak server." ;;
esac
if [ "$EMACS_ROUTE" = plus ]; then
    EMACS_NOTE="Emacs.app is in $BREW_PREFIX/opt/$EMACS_PLUS_FORMULA; the launcher runs Emacs in the terminal."
else
    EMACS_NOTE="For Emacs.app as well, rerun with --emacs-plus."
fi
echo "Emacspeak is in $PREFIX"
if [ "$HAVE_OMNIVOX" = yes ]; then
    echo "OmniVox: $OMNIVOX_VERSION, $ROUTE_TEXT, in $PREFIX/servers"
fi
if is_selected swiftmac; then
    echo "swiftmac: built with Swift $SWIFT_VERSION, in $PREFIX/servers"
fi
if [ "$HAVE_TCLESPEAK" = yes ]; then
    echo "Tcl espeak server: runs on $TCLSH, with TclX in $TCLX_DIR"
fi
cat <<DONE
Emacs $EMACS_VERSION: $EMACS_BIN
$EMACS_NOTE
Launcher: $LAUNCHER
Init file: $INIT
Engines recorded in: $RECORD
Build log: $LOG

To start it, run this in Terminal:
  emacspeak

The launcher starts console Emacs without your own init file (-q),
and sets $LAUNCHER_SETS
Servers installed: $SERVERS.
To start with another server: DTK_PROGRAM=<server> emacspeak
Inside Emacs, M-x dtk-select-server switches to another server.
DONE
if is_selected omnivox && is_selected espeak; then
    cat <<'DONE'
OmniVox has two engines, and OMNIVOX_ENGINE picks one at start:
  OMNIVOX_ENGINE=espeak emacspeak, for espeak-ng
  OMNIVOX_ENGINE=native emacspeak, for the macOS system voices
Inside Emacs: M-x setenv RET OMNIVOX_ENGINE RET espeak RET,
then M-x dtk-select-server RET omnivox RET.
DONE
fi
cat <<DONE

To load emacspeak from your own Emacs init file instead, put this
line at the very top of ~/.emacs or ~/.emacs.d/init.el:
  (load-file "$INIT")

If VoiceOver is on, you hear both it and emacspeak.
Command-F5 turns VoiceOver off and on.
DONE
if [ "$HAVE_OMNIVOX" = yes ]; then
    echo "To choose an OmniVox voice in Emacs: M-x omnivox-select-voice"
    echo "From another server, M-x omnivox switches to OmniVox."
    echo "Known OmniVox issue: text after two semicolons may not be spoken."
fi
if [ "$HAVE_TCLESPEAK" = yes ]; then
    echo "Tones: not available with the Tcl espeak server on macOS;"
    echo "its library looks for SoX only in /usr/bin."
    if [ "$ICON_PLAYER" = /usr/bin/afplay ]; then
        echo "Its auditory icons need SoX: brew install sox, then rerun."
    else
        echo "Its auditory icons play with SoX: $ICON_PLAYER"
    fi
    echo "Homebrew marks $TCL_FORMULA deprecated and plans to disable it"
    echo "on January 1, 2028; the Tcl espeak server needs it."
fi
echo
echo "To update emacspeak and the speech engines later, run this script again."
if [ "$BREW_ON_PATH" = no ]; then
    printf '%s\n' "" \
        "Homebrew is not on your PATH yet, so the emacspeak command is not found." \
        "Add Homebrew to your shell, then open a new Terminal window:" \
        "  echo 'eval \"\$($BREW shellenv)\"' >> ~/.zprofile"
fi
