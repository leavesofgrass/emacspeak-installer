#!/usr/bin/env bash
# install-emacspeak-debian.sh: emacspeak with a choice of speech engines on
# Debian, Ubuntu and Linux Mint.
#
# The speech engines, chosen with --speech or from a menu:
#   espeak   eSpeak NG voices through emacspeak's own espeak server.
#            The default.
#   omnivox  OmniVox (https://github.com/robertmeta/omnivox), a speech
#            server written in Rust. It has no Linux release, so it is
#            built from source. On Linux it speaks with eSpeak NG.
#   dectalk  Software DECtalk (https://github.com/dectalk/dectalk), built
#            from source into /opt/dectalk, for emacspeak's dtk-soft server.
#   voxin    Eloquence (IBM ViaVoice) from Voxin, paid software from
#            https://voxin.oralux.net, for emacspeak's outloud server.
#            Give the archive you bought with --voxin-archive FILE.
#
# Emacspeak's speech servers and their glue only work with Tcl 8.6
# and TclX. Debian and Ubuntu package both (tcl8.6, tcl8.6-dev, tclx8.4),
# and Tcl 8.6 is their default tclsh, so the build works with the stock
# layout. The script still checks which Tcl /usr/bin/tclsh runs, and if it
# is not 8.6, points the servers at tclsh8.6 instead, as the Fedora script
# does. Emacspeak needs Emacs 29.1 or newer: Debian 13 and Ubuntu 24.04 have
# it, Debian 12 and Ubuntu 22.04 do not, and the script stops early there.
#
# OmniVox and Rust. OmniVox 1.3.0 calls usize::is_multiple_of, which is
# stable only since Rust 1.87, and it ships no Cargo.lock, so cargo takes
# the newest crates, and some of those need a newer Rust still. Cargo 1.84
# and newer can pick crate versions that build with the Rust at hand
# instead (CARGO_RESOLVER_INCOMPATIBLE_RUST_VERSIONS=fallback). So the
# script needs Rust 1.85 or newer, and with Rust older than 1.87 it writes
# OmniVox's one Linux call of is_multiple_of with %, which means the same.
# Debian 13 has Rust 1.85. Ubuntu 24.04's rustc is 1.75, too old, but its
# apt also has versioned toolchains (rustc-1.NN with cargo-1.NN), and the
# script installs the newest of those. The build needs cmake (OmniVox
# compiles its own espeak-ng, whose voice data stays in the build folder;
# Debian's espeak-ng-data is the fallback), libclang-dev for bindgen, and
# pkg-config with libasound2-dev for its ALSA sound output.
#
# DECtalk and gcc. The Dockerfile compiles DECtalk on Debian 12 because
# gcc 14 made parts of its 1990s C into errors. DECtalk's develop branch
# now builds with Debian 13's gcc 14.2 and its default flags (checked at
# commit 986ea12). Should a later commit fail, the script builds again with
# -fpermissive -Wno-implicit-function-declaration, as
# install-emacspeak-voxin.sh does.

set -euo pipefail

PREFIX=/opt/emacspeak
REPO=https://github.com/tvraman/emacspeak.git
REF=master
SKIP_DEPS=no
RUN_TESTS=yes
SPEECH=""
SPEECH_GIVEN=no
VOXIN_ARCHIVE=""
TCLSH86=/usr/bin/tclsh8.6
TCL_INCLUDE=/usr/include/tcl8.6
LAUNCHER=/usr/local/bin/emacspeak
LOG=/var/log/install-emacspeak-debian.log
MARKER="Written by install-emacspeak-debian.sh"
# ca-certificates lets git clone over https; apt only recommends it for git.
PACKAGES=(git ca-certificates make gcc g++ tcl8.6 tcl8.6-dev tclx8.4
          sox libsox-fmt-all pulseaudio-utils)
# Emacs is installed only when there is none. The emacs package is the GTK
# build, which also runs in a console. emacs-nox is the console-only build:
# to use it instead, install it yourself before running this script.

# The speech engines, in menu order, and the packages each one adds.
ENGINES=(espeak omnivox dectalk voxin)
ESPEAK_PACKAGES=(espeak-ng libespeak-ng-dev)
# Plus rustc and cargo, or a versioned pair such as rustc-1.91 and cargo-1.91.
OMNIVOX_PACKAGES=(cmake pkg-config libclang-dev libasound2-dev libespeak-ng-dev)
DECTALK_PACKAGES=(build-essential autoconf automake unzip libpulse-dev libasound2-dev)
# Plus libc6:i386 and libstdc++6:i386 on amd64, for Voxin's 32-bit engine.
VOXIN_PACKAGES=(xz-utils libasound2-dev)

OMNIVOX_REPO=https://github.com/robertmeta/omnivox.git
OMNIVOX_VERSION=1.3.0
RUST_MIN=1.85
DECTALK_REPO=https://github.com/dectalk/dectalk.git
DECTALK_REF=develop
DECTALK_HOME=/opt/dectalk
VOXIN_SITE=https://voxin.oralux.net
VOXIN_LIB=/opt/oralux/voxin/lib/libvoxin.so.1
ECI_INI=/var/opt/IBM/ibmtts/cfg/eci.ini
# atcleci.so dlopens "libibmeci.so", which searches the trusted system
# folders; on Debian and Ubuntu /usr/lib is one of them.
SYS_LIBDIR=/usr/lib
VOXIN_NEEDS="the voxin engine needs your Voxin archive. Voxin is paid \
software: buy and download it from $VOXIN_SITE (a file such as \
voxin-enu-v3.x.tar.gz), then rerun with --voxin-archive FILE."
RUST_FIX="Install Rust $RUST_MIN or newer for root with rustup \
(https://rustup.rs), then rerun this script, or leave out omnivox (--speech)."

SELECTED=()
RESULTS=()

usage() {
    cat <<USAGE
Usage: sudo bash install-emacspeak-debian.sh [options]

Installs emacspeak with your choice of speech engines on Debian 13 or
Ubuntu 24.04, and on relatives built on them, such as Linux Mint 22.
Run it again later to update emacspeak and rebuild it.

Options:
  --speech LIST         speech engines, separated by commas, such as
                        espeak,dectalk. The first is the default.
                        all: every engine (voxin only with
                        --voxin-archive). list: what each one needs.
  --voxin-archive FILE  your Voxin archive, such as voxin-enu-v3.x.tar.gz,
                        bought from voxin.oralux.net. Adds voxin.
  --prefix DIR          where emacspeak is cloned and built
                        (default $PREFIX)
  --repo URL            emacspeak git repository (default $REPO)
  --ref REF             branch or tag to build (default $REF)
  --skip-deps           do not run apt-get; you installed the packages yourself
  --no-test             skip the self-tests at the end
  --help                show this help

Speech engines: espeak (the default), omnivox, dectalk, voxin.
Without --speech, a rerun keeps the earlier choice, and a first run
shows a menu at a terminal, or takes espeak.

Packages it always installs: ${PACKAGES[*]},
plus each engine's own (see --speech list), and emacs if no Emacs is
installed. Build output goes to $LOG.
USAGE
}

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'Warning: %s\n' "$*"; }

# Run a noisy command with its output in $LOG. If it fails, show the end of
# the log, then the error, so the last line on screen names the problem.
# HINT, when a step sets it, says what to do about a failure there.
HINT=""
logged() {
    local what=$1; shift
    if ! "$@" >>"$LOG" 2>&1; then
        printf '\nLast lines of %s:\n' "$LOG" >&2
        tail -n 20 "$LOG" >&2
        die "$what failed. ${HINT:+$HINT }The full output is in $LOG"
    fi
}

# No questions from package scripts, and if another package manager (such
# as an automatic update) holds the lock, wait for it up to five minutes.
apt_get() {
    DEBIAN_FRONTEND=noninteractive apt-get -y -q -o DPkg::Lock::Timeout=300 "$@"
}
apt_candidate() { # $1 = package; prints the version apt would install
    apt-cache policy "$1" 2>>"$LOG" |
        awk '$1 == "Candidate:" && $2 != "(none)" { print $2 }'
}
version_ge() { dpkg --compare-versions "$1" ge "$2"; }
upstream_version() { # 1:1.85.1+dfsg1-1 gives 1.85.1
    local v=${1#*:}
    printf '%s\n' "${v%%[-+~]*}"
}

# Emacspeak's Makefiles hand $(MAKEFLAGS) to their sub-makes as plain words.
# GNU make 4.3 (Ubuntu 24.04, Debian 12) writes the -w that "make -C" adds
# as a bare "w", which the sub-make then takes for a target and fails. So
# run make from inside the directory, without flags inherited from outside.
make_in() { # $1 = directory, then the make arguments
    local dir=$1; shift
    ( cd "$dir" && env -u MAKEFLAGS -u MFLAGS make "$@" )
}

# tclsh reading a script from stdin exits 0 even after an error, so these
# Tcl checks exit 1 themselves when something fails.
tcl_patchlevel() { # $1 = the tclsh to ask
    echo 'if {[catch {puts [info patchlevel]}]} {exit 1}' | "$1"
}
tclx_version() {
    echo 'if {[catch {puts [package require Tclx]}]} {exit 1}' | "$TCLSH"
}
espeak_glue_check() { # $1 = path of tclespeak.so
    timeout 30 "$TCLSH" <<TCL
if {[catch {load {$1}} err]} {puts stderr \$err; exit 1}
if {[info commands say] ne "say"} {puts stderr "no say command"; exit 1}
puts "eSpeak NG [ttsVersion], voice data in [ttsDataPath]"
TCL
}
glue_check() { # $1 = path of a Tcl glue library that adds the say command
    timeout 30 "$TCLSH" <<TCL
if {[catch {load {$1}} err]} {puts stderr \$err; exit 1}
if {[info commands say] ne "say"} {puts stderr "no say command"; exit 1}
TCL
}
emacs_new_enough() {
    emacs -Q --batch --eval '(kill-emacs (if (version<= "29.1" emacs-version) 0 1))' \
        2>>"$LOG"
}
check_emacs() { # sets EMACS_VERSION, or stops
    command -v emacs >/dev/null || die "emacs not found. Install it: apt-get install emacs"
    EMACS_VERSION=$(emacs -Q --batch --eval '(princ emacs-version)' 2>>"$LOG") ||
        die "emacs is installed but does not run in batch mode"
    emacs_new_enough ||
        die "emacspeak needs Emacs 29.1 or newer, and $(command -v emacs) is Emacs $EMACS_VERSION"
}

# --------------------------------------------------------------------------
# The speech engines.
engine_server() { # $1 = engine; prints the emacspeak server it runs
    case "$1" in
        espeak)  echo espeak ;;
        omnivox) echo omnivox ;;
        dectalk) echo dtk-soft ;;
        voxin)   echo outloud ;;
    esac
}
engine_title() {
    case "$1" in
        espeak)  echo espeak ;;
        omnivox) echo OmniVox ;;
        dectalk) echo DECtalk ;;
        voxin)   echo Voxin ;;
    esac
}
engine_about() { # the engine's line in the menu
    case "$1" in
        espeak)  echo "free, eSpeak NG voices through emacspeak's own server (default)" ;;
        omnivox) echo "free, the OmniVox server built from source with Rust, eSpeak NG voices" ;;
        dectalk) echo "free, software DECtalk built from source" ;;
        voxin)   echo "paid, Eloquence voices; needs --voxin-archive FILE from voxin.oralux.net" ;;
    esac
}
engine_needs() { # the engine's line for --speech list
    case "$1" in
        espeak)  echo "eSpeak NG from apt, nothing else (the default); server espeak" ;;
        omnivox) echo "builds OmniVox $OMNIVOX_VERSION from source with Rust $RUST_MIN or newer from apt, a few minutes; server omnivox" ;;
        dectalk) echo "builds software DECtalk ($DECTALK_REF branch) from source into $DECTALK_HOME, a few minutes; server dtk-soft" ;;
        voxin)   echo "needs --voxin-archive FILE, your paid Voxin archive from voxin.oralux.net; adds 32-bit (i386) libraries; server outloud" ;;
    esac
}
print_engines() {
    local e
    for e in "${ENGINES[@]}"; do echo "$e: $(engine_needs "$e")"; done
}
is_engine() {
    local e
    for e in "${ENGINES[@]}"; do [ "$e" = "$1" ] && return 0; done
    return 1
}
selected() {
    local e
    for e in "${SELECTED[@]}"; do [ "$e" = "$1" ] && return 0; done
    return 1
}
add_engine() { selected "$1" || SELECTED+=("$1"); }
titles() { # the chosen engines, separated by commas
    local e out=""
    for e in "${SELECTED[@]}"; do out="${out:+$out, }$(engine_title "$e")"; done
    printf '%s\n' "$out"
}
voxin_installed() { [ -e "$VOXIN_LIB" ]; }
installed_engine() { # $1 = engine; true when an earlier run built it here
    case "$1" in
        espeak)  [ -f "$PREFIX/servers/native-espeak/tclespeak.so" ] ;;
        omnivox) [ -x "$PREFIX/servers/omnivox" ] ;;
        dectalk) [ -f "$PREFIX/servers/software-dtk/tcldtk.so" ] &&
                     [ -e "$DECTALK_HOME/lib/libtts.so" ] ;;
        voxin)   [ -f "$PREFIX/servers/linux-outloud/atcleci.so" ] && voxin_installed ;;
    esac
}

parse_speech() { # $1 = the --speech value; sets SELECTED
    local item items
    SELECTED=()
    IFS=, read -r -a items <<<"${1,,}"
    for item in "${items[@]}"; do
        item=${item//[[:space:]]/}
        case "$item" in
            '')   ;;
            all)  add_engine espeak; add_engine omnivox; add_engine dectalk
                  [ -z "$VOXIN_ARCHIVE" ] || add_engine voxin ;;
            list) die "--speech list cannot be combined with engine names" ;;
            *)    if is_engine "$item"; then
                      add_engine "$item"
                  else
                      print_engines >&2
                      die "unknown speech engine \"$item\". Choose from espeak, omnivox, dectalk, voxin, or all."
                  fi ;;
        esac
    done
    [ ${#SELECTED[@]} -gt 0 ] || die "--speech needs at least one engine (try --speech list)"
}

# The record of the chosen engines, one per line, written after a
# successful install. A rerun without --speech uses it again.
read_record() { # sets SELECTED from $RECORD; fails when there is none
    local line
    [ -f "$RECORD" ] || return 1
    SELECTED=()
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line,,}
        line=${line//[[:space:]]/}
        [ -n "$line" ] || continue
        if is_engine "$line"; then
            add_engine "$line"
        else
            warn "ignoring \"$line\" in $RECORD: it is not a speech engine."
        fi
    done <"$RECORD"
    [ ${#SELECTED[@]} -gt 0 ]
}

run_menu() { # sets SELECTED from the answer typed at the terminal
    local default=1 answer word words bad n=0 e
    [ -z "$VOXIN_ARCHIVE" ] || default="1 4"
    echo "Which speech engines should emacspeak get?"
    for e in "${ENGINES[@]}"; do
        n=$((n + 1))
        echo "$n) $e: $(engine_about "$e")"
    done
    while :; do
        printf 'Numbers separated by spaces, or Enter for the default [%s]: ' "$default"
        if ! IFS= read -r answer; then
            echo
            die "no answer. To choose without the menu, rerun with --speech (try --speech list)."
        fi
        answer=${answer//,/ }
        [ -n "${answer//[[:space:]]/}" ] || answer=$default
        read -r -a words <<<"$answer"
        SELECTED=()
        bad=""
        for word in "${words[@]}"; do
            word=${word,,}
            case "$word" in
                [1-9]) if [ "$word" -le ${#ENGINES[@]} ]; then
                           word=${ENGINES[$((word - 1))]}
                       else
                           bad=$word; break
                       fi ;;
                *)     is_engine "$word" || { bad=$word; break; } ;;
            esac
            add_engine "$word"
        done
        if [ -n "$bad" ]; then
            echo "Not a choice: $bad. Type numbers from 1 to ${#ENGINES[@]}."
            continue
        fi
        if selected voxin && [ -z "$VOXIN_ARCHIVE" ] && ! voxin_installed; then
            echo "voxin needs your Voxin archive: choose again, or rerun with --voxin-archive FILE."
            continue
        fi
        break
    done
}

# --------------------------------------------------------------------------
# OmniVox helpers.

# servers/.servers is part of emacspeak's git tree. M-x dtk-select-server
# offers the names listed there, and OmniVox's README asks for both names.
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

# Puts a Rust $RUST_MIN or newer first on PATH: the one on PATH, rustup's
# for root, or the newest versioned toolchain from apt. Sets RUSTC_VERSION
# and RUST_DIR.
find_rust() {
    local dir v candidates=()
    if command -v rustc >/dev/null; then candidates+=("$(dirname "$(command -v rustc)")"); fi
    candidates+=("${HOME:-/root}/.cargo/bin")
    while IFS= read -r dir; do
        candidates+=("$dir")
    done < <(printf '%s\n' /usr/lib/rust-1.*/bin | sort -rV)
    for dir in "${candidates[@]}"; do
        [ -x "$dir/rustc" ] && [ -x "$dir/cargo" ] || continue
        v=$("$dir/rustc" --version 2>>"$LOG" | awk '{ print $2 }') || continue
        if [ -n "$v" ] && version_ge "$v" "$RUST_MIN"; then
            PATH="$dir:$PATH"
            RUSTC_VERSION=$v
            RUST_DIR=$dir
            return 0
        fi
    done
    return 1
}

# Which Rust packages apt should install for OmniVox: rustc and cargo when
# they are new enough, else the newest versioned pair apt offers, else none
# when root already has a new enough Rust. Sets RUST_PACKAGES, or stops.
choose_rust_packages() {
    local v n
    RUST_PACKAGES=(rustc cargo)
    v=$(upstream_version "$(apt_candidate rustc)")
    if [ -n "$v" ] && version_ge "$v" "$RUST_MIN"; then
        echo "Rust $v from apt: new enough for OmniVox."
        return 0
    fi
    for n in $(apt-cache search --names-only '^rustc-1\.[0-9]+$' 2>>"$LOG" |
               awk '{ print substr($1, 7) }' | sort -rV); do
        version_ge "$n" "$RUST_MIN" || break
        [ -n "$(apt_candidate "cargo-$n")" ] || continue
        RUST_PACKAGES=("rustc-$n" "cargo-$n")
        echo "apt's rustc is Rust ${v:-(none)}, too old for OmniVox, which needs $RUST_MIN."
        echo "Using Rust $n from apt instead: rustc-$n and cargo-$n."
        return 0
    done
    if find_rust; then
        RUST_PACKAGES=()
        echo "apt offers no Rust $RUST_MIN or newer; using Rust $RUSTC_VERSION from $RUST_DIR."
        return 0
    fi
    die "OmniVox needs Rust $RUST_MIN or newer, and apt here offers Rust ${v:-none}. $RUST_FIX"
}

build_omnivox() {
    local src=$OMNIVOX_DIR/src tag=v$OMNIVOX_VERSION
    mkdir -p "$OMNIVOX_DIR"
    HINT="Check the internet connection."
    if [ -d "$src/.git" ]; then
        log "Using the OmniVox source in $src"
        if [ "$(git -C "$src" describe --tags --exact-match 2>/dev/null || true)" != "$tag" ]; then
            logged "fetching OmniVox $tag" git -C "$src" fetch -q --depth 1 origin \
                "refs/tags/$tag:refs/tags/$tag"
            HINT="Move $src out of the way, then rerun this script."
            logged "checking out OmniVox $tag" \
                git -C "$src" -c advice.detachedHead=false checkout -q "$tag"
        fi
    elif [ -e "$src" ]; then
        die "$src exists but is not a git clone of OmniVox. Move it away, then rerun."
    else
        log "Cloning OmniVox $tag into $src"
        logged "cloning OmniVox" git -c advice.detachedHead=false clone -q --depth 1 \
            --branch "$tag" "$OMNIVOX_REPO" "$src"
    fi
    if ! version_ge "$RUSTC_VERSION" 1.87; then
        # usize::is_multiple_of is stable from Rust 1.87. OmniVox 1.3.0 calls
        # it once in code built for Linux (once more for Windows only).
        sed -i 's/samples\.len()\.is_multiple_of(CHANNELS as usize)/samples.len() % (CHANNELS as usize) == 0/' \
            "$src/omnivox-audio/src/buffer.rs"
        echo "Rust $RUSTC_VERSION lacks is_multiple_of (Rust 1.87): one call written with %, which means the same."
    fi
    log "Building OmniVox $OMNIVOX_VERSION with cargo and Rust $RUSTC_VERSION (a few minutes)"
    echo "It compiles its own espeak-ng too. Progress goes to the build log."
    HINT="A crate may need a newer Rust than $RUSTC_VERSION. $RUST_FIX"
    logged "cargo build" env CARGO_HOME="$OMNIVOX_DIR/cargo" \
        CARGO_RESOLVER_INCOMPATIBLE_RUST_VERSIONS=fallback \
        CARGO_TERM_COLOR=never CARGO_TERM_PROGRESS_WHEN=never \
        cargo build --release --manifest-path "$src/Cargo.toml"
    HINT=""
    [ -x "$src/target/release/omnivox" ] ||
        die "the build finished but $src/target/release/omnivox is missing"
    [ -f "$src/elisp/omnivox-voices.el" ] ||
        die "$src/elisp/omnivox-voices.el is missing; OmniVox's layout may have changed"
    mkdir -p "$OMNIVOX_DIR/elisp"
    cp "$src/elisp/omnivox-voices.el" "$OMNIVOX_DIR/elisp/omnivox-voices.el"
    # Copy, then rename over the old binary, so a running server keeps its file.
    cp "$src/target/release/omnivox" "$PREFIX/servers/omnivox.new"
    chmod 0755 "$PREFIX/servers/omnivox.new"
    mv -f "$PREFIX/servers/omnivox.new" "$PREFIX/servers/omnivox"
    # OmniVox's README registers the same binary under the name log-omnivox.
    ln -sfn omnivox "$PREFIX/servers/log-omnivox"
    printf '%s\n' "$OMNIVOX_WANT" >"$OMNIVOX_DIR/installed-version"
    echo "Installed $PREFIX/servers/omnivox, and log-omnivox beside it."
}

# --------------------------------------------------------------------------
# DECtalk helpers.
dectalk_build() ( # extra arguments go to configure, such as CFLAGS=...
    cd "$DTK_SRC/src" && ./autogen.sh && ./configure "$@" &&
        env -u MAKEFLAGS -u MFLAGS make -j"$(nproc)"
)

install_dectalk() {
    local commit
    DTK_SRC=$PREFIX/dectalk/src
    mkdir -p "$PREFIX/dectalk"
    HINT="Check the internet connection."
    if [ -d "$DTK_SRC/.git" ]; then
        log "DECtalk: looking for new commits on its $DECTALK_REF branch"
        logged "fetching DECtalk" git -C "$DTK_SRC" fetch -q --depth 1 origin "$DECTALK_REF"
        if [ "$(git -C "$DTK_SRC" rev-parse HEAD)" != "$(git -C "$DTK_SRC" rev-parse FETCH_HEAD)" ]; then
            if git -C "$DTK_SRC" -c advice.detachedHead=false checkout -q FETCH_HEAD >>"$LOG" 2>&1; then
                echo "New DECtalk source: $(git -C "$DTK_SRC" log -1 --format='commit %h of %cd' --date=short)"
            else
                warn "could not move the DECtalk source to the newest commit (see $LOG); building the one already there."
            fi
        else
            echo "No new commits."
        fi
    elif [ -e "$DTK_SRC" ]; then
        die "$DTK_SRC exists but is not a git clone of DECtalk. Move it away, then rerun."
    else
        log "Cloning DECtalk ($DECTALK_REF) from $DECTALK_REPO into $DTK_SRC"
        logged "cloning DECtalk" git clone -q --depth 1 --branch "$DECTALK_REF" \
            "$DECTALK_REPO" "$DTK_SRC"
    fi
    HINT=""
    commit=$(git -C "$DTK_SRC" rev-parse HEAD)
    if [ "$(cat "$PREFIX/dectalk/installed-commit" 2>/dev/null || true)" = "$commit" ] &&
       [ -e "$DECTALK_HOME/lib/libtts.so" ] && [ -x "$DECTALK_HOME/say" ]; then
        echo "DECtalk commit ${commit:0:7} is already installed in $DECTALK_HOME; keeping it."
    else
        log "Building DECtalk, commit ${commit:0:7} (a few minutes)"
        if ! dectalk_build >>"$LOG" 2>&1; then
            echo "The build failed with the default flags; building again with -fpermissive."
            HINT="This gcc rejects DECtalk's old C even with -fpermissive; Debian 12's gcc 12 builds it."
            logged "building DECtalk" dectalk_build \
                CFLAGS="-O2 -fpermissive -Wno-implicit-function-declaration"
            HINT=""
        fi
        [ -e "$DTK_SRC/dist/lib/libtts_us.so" ] || [ -e "$DTK_SRC/dist/lib/libtts.so" ] ||
            die "the DECtalk build finished, but $DTK_SRC/dist/lib has no libtts"
        log "Installing DECtalk into $DECTALK_HOME"
        mkdir -p "$DECTALK_HOME"
        cp -a "$DTK_SRC/dist/." "$DECTALK_HOME/"
        # The dist tree has no C headers, and tcldtk.c includes <dtk/ttsapi.h>.
        mkdir -p "$DECTALK_HOME/include/dtk"
        cp "$DTK_SRC/src/dapi/src/include/"*.h "$DECTALK_HOME/include/dtk/"
        # Some builds make only the per-language library.
        [ -e "$DECTALK_HOME/lib/libtts.so" ] || ln -s libtts_us.so "$DECTALK_HOME/lib/libtts.so"
        printf '%s\n' "$commit" >"$PREFIX/dectalk/installed-commit"
        echo "Installed DECtalk commit ${commit:0:7}, with its headers in $DECTALK_HOME/include/dtk."
    fi
    echo "$DECTALK_HOME/lib" >/etc/ld.so.conf.d/dectalk.conf
    ldconfig
    # libtts falls back to <its prefix>/DECtalk.conf. Emacspeak ships one
    # whose dictionary paths are already absolute /opt/dectalk/dic entries.
    cp "$PREFIX/servers/software-dtk/DECtalk.conf" "$DECTALK_HOME/DECtalk.conf"
    echo "$DECTALK_HOME/lib is registered with ldconfig, and DECtalk.conf is in place."

    log "Building tcldtk.so, the DECtalk glue, against Tcl 8.6"
    # Command-line variables replace the Makefile's, so these repeat the
    # flags it sets, as the Dockerfile does, plus DECtalk's folders.
    logged "building tcldtk.so" make_in "$PREFIX/servers/software-dtk" -B \
        CFLAGS="-g -O2 -fPIC -DPIC -I$TCL_INCLUDE -I$DECTALK_HOME/include" \
        LDFLAGS="-L$DECTALK_HOME/lib" LIBS="-ltcl8.6 -ltts -ltts_us -ldl"
    [ -f "$DTK_SO" ] || die "the build finished but $DTK_SO is missing"
    echo "Built $DTK_SO"
}

# --------------------------------------------------------------------------
# Voxin helpers. The archive is an installer tree; this does what its
# installer does, as install-emacspeak-voxin.sh does:
#   rfs_<arch>.txz           to /opt/oralux/voxin/{lib,bin}: libvoxin, voxin-say
#   rfs_all.txz              to /opt/oralux/voxin/{include,rfs32}: the 32-bit world
#   voxin-viavoice-all_*.txz to /opt/IBM/ibmtts: the engine itself
#   voxin-viavoice-<lang>_*  the voice libraries, and /var/opt/IBM voice data
# The inner tarballs are unpacked straight from the archive, with no
# temporary copies. On bare metal they create /opt/IBM and /var/opt/IBM
# themselves, so no links are needed (the Docker image links them into a
# volume instead).
voxin_members() { # $1 = a file-name pattern in the archive's packages/all
    local m
    while IFS= read -r m; do
        case "$m" in "${VOXIN_TREE}packages/all/"$1) printf '%s\n' "$m" ;; esac
    done <<<"$VOXIN_MEMBERS"
}
check_voxin_archive() { # before anything is installed: is it a Voxin 3.x archive?
    local installer
    log "Checking the Voxin archive $VOXIN_ARCHIVE"
    VOXIN_MEMBERS=$(tar -tf "$VOXIN_ARCHIVE" 2>>"$LOG") ||
        die "tar cannot read $VOXIN_ARCHIVE. Download it again from $VOXIN_SITE"
    installer=$(grep -m 1 -E '(^|/)voxin-installer\.sh$' <<<"$VOXIN_MEMBERS" || true)
    [ -n "$installer" ] || die "$VOXIN_ARCHIVE does not look like a Voxin 3.x archive: \
it has no voxin-installer.sh. Download it again from $VOXIN_SITE"
    VOXIN_TREE=${installer%voxin-installer.sh}
    VOXIN_ARCH=$(uname -m)
    mapfile -t RFS_ARCH < <(voxin_members "rfs_*.$VOXIN_ARCH.txz")
    mapfile -t RFS_ALL < <(voxin_members 'rfs_*.all.txz')
    mapfile -t VV_ALL < <(voxin_members 'voxin-viavoice-all_*.txz')
    mapfile -t VV_LANGS < <(voxin_members 'voxin-viavoice-*.txz' | grep -v -- '-all_' || true)
    [ ${#RFS_ARCH[@]} -gt 0 ] || die "the Voxin archive has no runtime for this \
machine ($VOXIN_ARCH): no packages/all/rfs_*.$VOXIN_ARCH.txz in it."
    [ ${#RFS_ALL[@]} -gt 0 ] || die "the Voxin archive has no packages/all/rfs_*.all.txz. \
Download it again from $VOXIN_SITE"
    [ ${#VV_ALL[@]} -gt 0 ] || die "the Voxin archive has no voxin-viavoice-all \
engine tarball. Download it again from $VOXIN_SITE"
    [ ${#VV_LANGS[@]} -gt 0 ] || die "the Voxin archive has no voice tarball \
(voxin-viavoice-<language>). Download it again from $VOXIN_SITE"
    echo "It has Voxin's installer, its runtime for $VOXIN_ARCH, the engine, and ${#VV_LANGS[@]} voice package(s)."
}
unpack_member() { # $1 = a .txz inside the Voxin archive; unpacks it into /
    tar -xOf "$VOXIN_ARCHIVE" "$1" | tar -C / --no-overwrite-dir -xJf -
}
install_voxin() {
    local m langs="" l
    log "Voxin: unpacking its runtime into /opt/oralux/voxin"
    for m in "${RFS_ARCH[@]}" "${RFS_ALL[@]}"; do
        echo "${m##*/}"
        logged "unpacking ${m##*/}" unpack_member "$m"
    done
    log "Voxin: unpacking the Eloquence engine and voices into /opt/IBM"
    for m in "${VV_ALL[@]}" "${VV_LANGS[@]}"; do
        echo "${m##*/}"
        logged "unpacking ${m##*/}" unpack_member "$m"
    done
    [ -e "$VOXIN_LIB" ] || die "$VOXIN_LIB is missing after unpacking the archive, \
so it is not a complete Voxin 3.x archive. Download it again from $VOXIN_SITE"
    [ -f /opt/IBM/ibmtts/etc/all.ini ] && [ -d /opt/IBM/ibmtts/lib ] ||
        die "the Eloquence engine is missing from /opt/IBM/ibmtts after unpacking the archive"

    # eci.ini: the engine's all.ini, then one section per installed language
    # (a language is installed when its xxx50.so voice library exists).
    log "Voxin: writing $ECI_INI"
    langs=$(find /opt/IBM/ibmtts/lib -name '???50.so' 2>>"$LOG" |
            sed 's|.*/\(...\)50\.so$|\1|' | sort || true)
    [ -n "$langs" ] || die "no Eloquence voice libraries (such as enu50.so) in /opt/IBM/ibmtts/lib"
    mkdir -p "${ECI_INI%/*}"
    cp /opt/IBM/ibmtts/etc/all.ini "$ECI_INI"
    for l in $langs; do
        [ -f "/opt/IBM/ibmtts/etc/$l.ini" ] || die "/opt/IBM/ibmtts/etc/$l.ini is missing"
        cat "/opt/IBM/ibmtts/etc/$l.ini" >>"$ECI_INI"
    done
    echo "Languages: $(printf '%s ' $langs)"

    # libvoxin.so.1 is the 64-bit ECI library; Voxin's own packages link the
    # libibmeci.so name to it. The ld.so.conf.d entry lets voxin-say, linked
    # to libvoxin.so.1 by name, find it too.
    log "Voxin: linking its libraries"
    ln -sf "$VOXIN_LIB" "$SYS_LIBDIR/libibmeci.so"
    echo /opt/oralux/voxin/lib >/etc/ld.so.conf.d/voxin.conf
    ldconfig
    ln -sf /opt/oralux/voxin/bin/voxin-say /usr/local/bin/voxin-say
    # ECIINI tells the engine where its settings are; the launcher sets it too.
    echo "export ECIINI=$ECI_INI" >/etc/profile.d/voxin.sh
    echo "$SYS_LIBDIR/libibmeci.so leads to libvoxin; voxin-say is in /usr/local/bin."
}

# --------------------------------------------------------------------------
# Self-test bookkeeping. Each group (emacspeak itself, then each engine)
# numbers its own tests; a failure stops the script, a warning or a skip
# is noted for the summary.
begin_tests() { # $1 = group name, $2 = how many tests
    GROUP=$1; GROUP_TOTAL=$2; GROUP_N=0; GROUP_PASSED=0; GROUP_NOTES=""; GROUP_STATUS=Pass
}
next_test() { GROUP_N=$((GROUP_N + 1)); log "$GROUP self-test $GROUP_N of $GROUP_TOTAL: $*"; }
passed() { GROUP_PASSED=$((GROUP_PASSED + 1)); echo "Pass: $*"; }
skipped() { GROUP_NOTES="$GROUP_NOTES, test $GROUP_N skipped: $1"; echo "Skipped: $1."; }
warned() {
    GROUP_STATUS=Warning
    GROUP_NOTES="$GROUP_NOTES, test $GROUP_N warning: $1"
    echo "Warning: $1."
}
failed() { die "$GROUP self-test $GROUP_N failed: $*"; }
end_tests() { # $1 = the engine's server, or nothing for emacspeak itself
    local count
    if [ "$GROUP_PASSED" -eq "$GROUP_TOTAL" ]; then
        count="all $GROUP_TOTAL tests passed"
    else
        count="$GROUP_PASSED of $GROUP_TOTAL passed"
    fi
    RESULTS+=("$GROUP: $GROUP_STATUS${1:+, server $1}, $count$GROUP_NOTES.")
}
sound_device_found() { compgen -G '/dev/snd/pcmC*p' >/dev/null; }
# Starts a server the way Emacs does, with stdin at end of file, so it
# should exit 0 at once. Servers that open the sound device first stop
# without one: then the test is skipped, with the reason.
server_test() { # $1 = server, $2 = yes when a sound device was found
    local rc=0
    EMACSPEAK_DIR=$PREFIX ECIINI=$ECI_INI timeout 30 "$PREFIX/servers/$1" \
        </dev/null >>"$LOG" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        passed "the $1 server started and exited cleanly."
    elif [ "$2" = no ]; then
        skipped "no sound device here, and the $1 server needs one to start (it stopped with status $rc)"
    else
        warned "the $1 server stopped with status $rc. Root may not reach your sound; try DTK_PROGRAM=$1 emacspeak as yourself. See $LOG"
    fi
}

# --------------------------------------------------------------------------
need_value() { [ $# -ge 2 ] || die "$1 needs a value (try --help)"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)        need_value "$@"; PREFIX=$2; shift ;;
        --repo)          need_value "$@"; REPO=$2; shift ;;
        --ref)           need_value "$@"; REF=$2; shift ;;
        --speech)        need_value "$@"; SPEECH=$2; SPEECH_GIVEN=yes; shift ;;
        --voxin-archive) need_value "$@"; VOXIN_ARCHIVE=$2; shift ;;
        --skip-deps)     SKIP_DEPS=yes ;;
        --no-test)       RUN_TESTS=no ;;
        --help|-h)       usage; exit 0 ;;
        *)               die "unknown option $1 (try --help)" ;;
    esac
    shift
done
if [ "$SPEECH_GIVEN" = yes ] && [ "${SPEECH,,}" = list ]; then
    print_engines
    exit 0
fi
if [ -n "$VOXIN_ARCHIVE" ]; then
    [ -f "$VOXIN_ARCHIVE" ] || die "--voxin-archive: there is no file $VOXIN_ARCHIVE"
    [ -r "$VOXIN_ARCHIVE" ] || die "--voxin-archive: $VOXIN_ARCHIVE cannot be read"
    VOXIN_ARCHIVE=$(realpath "$VOXIN_ARCHIVE")
fi
if [ "$SPEECH_GIVEN" = yes ]; then
    parse_speech "$SPEECH"
    if selected voxin && [ -z "$VOXIN_ARCHIVE" ] && ! voxin_installed; then
        die "$VOXIN_NEEDS"
    fi
fi
PREFIX=$(realpath -m "$PREFIX")
# The prefix goes into Lisp strings and a shell script.
case "$PREFIX" in
    *'"'*|*\\*|*'$'*|*'`'*) die "--prefix must not contain quotes, backslashes, \$ or backquotes" ;;
esac
SERVERS_LIST=$PREFIX/servers/.servers
RECORD=$PREFIX/speech-engines
INIT=$PREFIX/emacspeak-init.el
OMNIVOX_DIR=$PREFIX/omnivox
OMNIVOX_WANT="$OMNIVOX_VERSION source"
SO=$PREFIX/servers/native-espeak/tclespeak.so
DTK_SO=$PREFIX/servers/software-dtk/tcldtk.so
ATCLECI_SO=$PREFIX/servers/linux-outloud/atcleci.so

# --------------------------------------------------------------------------
log "Checking the system"
[ "$EUID" -eq 0 ] || die "run this as root, for example: sudo bash $0"
[ -r /etc/os-release ] ||
    die "no /etc/os-release; this script is for Debian, Ubuntu or Linux Mint"
. /etc/os-release
case "${ID:-}" in
    debian|ubuntu|linuxmint) ;;
    *) case " ${ID_LIKE:-} " in
           *" debian "*|*" ubuntu "*)
               echo "Warning: ${PRETTY_NAME:-this system} is not Debian, Ubuntu or Mint itself; trying anyway." ;;
           *) die "this script is for Debian, Ubuntu or Linux Mint, and this is ${PRETTY_NAME:-unknown}." ;;
       esac ;;
esac
# Mint and other relatives also name the release they are built on.
BASE=${UBUNTU_CODENAME:-${DEBIAN_CODENAME:-${VERSION_CODENAME:-}}}
case "$BASE" in
    trixie) BASE_NAME="Debian 13" ;;
    noble)  BASE_NAME="Ubuntu 24.04" ;;
    *)      BASE_NAME="" ;;
esac
if [ -z "$BASE_NAME" ]; then
    echo "Warning: tested on Debian 13 and Ubuntu 24.04, this is ${PRETTY_NAME:-unknown}; trying anyway."
elif [ "${ID:-}" = debian ] || [ "${ID:-}" = ubuntu ]; then
    echo "${PRETTY_NAME:-$BASE_NAME}: supported."
else
    echo "${PRETTY_NAME:-This system} is built on $BASE_NAME: supported."
fi
case " ${ID:-} ${ID_LIKE:-} " in
    *" ubuntu "*) SOURCES_HINT="On Ubuntu and Mint they are in the universe \
repository. Turn it on with: add-apt-repository universe, then rerun this script." ;;
    *)            SOURCES_HINT="Check the apt sources in /etc/apt, then rerun this script." ;;
esac
: > "$LOG"
echo "Build log: $LOG"

# --------------------------------------------------------------------------
log "Choosing the speech engines"
NO_MENU=no
RECORD_NOTE=""
if [ "$SPEECH_GIVEN" = yes ]; then
    :
elif read_record; then
    RECORD_NOTE="That is the earlier choice, saved in $RECORD. To change it, rerun with --speech."
elif [ -t 0 ] && [ -t 1 ]; then
    run_menu
else
    SELECTED=(espeak)
    NO_MENU=yes
fi
if [ -n "$VOXIN_ARCHIVE" ] && ! selected voxin; then
    SELECTED+=(voxin)
    echo "Voxin added, because --voxin-archive was given."
fi
if selected voxin && [ -z "$VOXIN_ARCHIVE" ] && ! voxin_installed; then
    die "$VOXIN_NEEDS"
fi
if [ "$NO_MENU" = yes ] && [ ${#SELECTED[@]} -eq 1 ]; then
    echo "Selected: espeak, the default (no terminal for a menu; --speech chooses)."
else
    echo "Selected: $(titles)."
    [ -z "$RECORD_NOTE" ] || echo "$RECORD_NOTE"
fi
DEFAULT_SERVER=$(engine_server "${SELECTED[0]}")
if [ -n "$VOXIN_ARCHIVE" ]; then
    check_voxin_archive
elif selected voxin; then
    echo "Voxin is already installed in /opt/oralux/voxin; no --voxin-archive given, so it stays as it is."
fi

# Each engine's packages.
if selected espeak; then PACKAGES+=("${ESPEAK_PACKAGES[@]}"); fi
if selected omnivox; then PACKAGES+=("${OMNIVOX_PACKAGES[@]}"); fi
if selected dectalk; then PACKAGES+=("${DECTALK_PACKAGES[@]}"); fi
I386=no
if selected voxin; then
    PACKAGES+=("${VOXIN_PACKAGES[@]}")
    if [ "$(dpkg --print-architecture)" = amd64 ]; then
        I386=yes
        PACKAGES+=(libc6:i386 libstdc++6:i386)
    else
        warn "Voxin's engine is a 32-bit x86 program, and this is $(dpkg --print-architecture); it may not run here."
    fi
fi
dedupe_packages() {
    local p seen=" " out=()
    for p in "${PACKAGES[@]}"; do
        case "$seen" in *" $p "*) ;; *) out+=("$p"); seen="$seen$p " ;; esac
    done
    PACKAGES=("${out[@]}")
}
dedupe_packages

# --------------------------------------------------------------------------
if [ "$SKIP_DEPS" = no ]; then
    if [ "$I386" = yes ]; then
        case " $(dpkg --print-foreign-architectures | tr '\n' ' ') " in
            *" i386 "*) ;;
            *) log "Adding the i386 architecture, for Voxin's 32-bit engine"
               logged "dpkg --add-architecture i386" dpkg --add-architecture i386
               echo "Added: apt now lists 32-bit packages too." ;;
        esac
    fi

    log "Updating the package lists (apt-get update)"
    logged "apt-get update" apt_get update

    # Stop here, before installing anything, if a package is missing or
    # the Emacs would be too old for emacspeak.
    log "Checking that apt has the packages and a new enough Emacs"
    if selected omnivox; then
        choose_rust_packages
        PACKAGES+=("${RUST_PACKAGES[@]}")
    fi
    WANT=("${PACKAGES[@]}")
    command -v emacs >/dev/null || WANT+=(emacs)
    missing=""
    for p in "${WANT[@]}"; do
        [ -n "$(apt_candidate "$p")" ] || missing="$missing $p"
    done
    [ -z "$missing" ] || die "apt cannot find these packages:$missing. $SOURCES_HINT"
    echo "All ${#WANT[@]} packages are available."
    if command -v emacs >/dev/null; then
        check_emacs
        echo "Emacs $EMACS_VERSION is already installed: new enough."
    else
        EMACS_PACKAGE=$(apt_candidate emacs)
        EMACS_PACKAGE=${EMACS_PACKAGE#*:}         # drop the epoch, as in 1:30.1
        EMACS_PACKAGE=${EMACS_PACKAGE%%[-+~]*}    # keep 30.1 of 30.1+1-6
        if ! dpkg --compare-versions "$EMACS_PACKAGE" ge 29.1; then
            hint="Install Emacs 29.1 or newer another way, then rerun this script."
            [ "$BASE" != bookworm ] || hint="Debian 12 has a newer Emacs in \
bookworm-backports (see https://backports.debian.org/Instructions/). Install \
it with: apt-get install -t bookworm-backports emacs, then rerun this script."
            die "emacspeak needs Emacs 29.1 or newer, and apt here offers Emacs $EMACS_PACKAGE. $hint"
        fi
        echo "The emacs package is Emacs $EMACS_PACKAGE: new enough."
    fi

    log "Installing packages with apt-get (this can take a few minutes)"
    echo "Packages: ${PACKAGES[*]}"
    logged "apt-get install" apt_get install --no-install-recommends "${PACKAGES[@]}"
    if ! command -v emacs >/dev/null; then
        log "No Emacs found: installing the emacs package (Emacs $EMACS_PACKAGE)"
        logged "apt-get install emacs" apt_get install --no-install-recommends emacs
    fi
fi

log "Checking Emacs, Tcl 8.6 and TclX"
check_emacs
echo "Emacs $EMACS_VERSION: new enough."
for tool in git make g++; do
    command -v "$tool" >/dev/null || die "$tool not found. Install: ${PACKAGES[*]}"
done
[ -x "$TCLSH86" ] || die "$TCLSH86 not found. Install Tcl 8.6: apt-get install tcl8.6"
grep -q 'define TCL_VERSION[[:space:]]*"8.6"' "$TCL_INCLUDE/tcl.h" 2>/dev/null ||
    die "$TCL_INCLUDE/tcl.h is missing or is not Tcl 8.6. Install tcl8.6-dev."
if selected espeak; then
    [ -r /usr/include/espeak-ng/speak_lib.h ] ||
        die "espeak-ng headers not found. Install libespeak-ng-dev."
fi
# The speech servers start with #!/usr/bin/tclsh. Debian's tcl package makes
# that Tcl 8.6; where it runs another Tcl, the servers get tclsh8.6 instead.
if [ -x /usr/bin/tclsh ] && DEFAULT_TCL=$(tcl_patchlevel /usr/bin/tclsh 2>>"$LOG"); then
    :
else
    DEFAULT_TCL=none
fi
case "$DEFAULT_TCL" in
    8.6.*) TCLSH=/usr/bin/tclsh; REWRITE=no
           echo "Default tclsh is Tcl $DEFAULT_TCL: the speech servers use it as it is." ;;
    none)  TCLSH=$TCLSH86; REWRITE=yes
           echo "No working /usr/bin/tclsh: the speech servers will use $TCLSH86." ;;
    *)     TCLSH=$TCLSH86; REWRITE=yes
           echo "Default tclsh is Tcl $DEFAULT_TCL, not 8.6: the speech servers will use $TCLSH86." ;;
esac
TCL_PATCHLEVEL=$(tcl_patchlevel "$TCLSH" 2>>"$LOG") || die "$TCLSH does not run. See $LOG"
TCLX=$(tclx_version 2>>"$LOG") ||
    die "TclX does not load in $TCLSH. Install it: apt-get install tclx8.4"
echo "Tcl 8.6 headers found; TclX $TCLX loads in $TCLSH."
if selected omnivox; then
    find_rust || die "OmniVox needs Rust $RUST_MIN or newer, and none was found. $RUST_FIX"
    for tool in cmake pkg-config; do
        command -v "$tool" >/dev/null || die "$tool not found. Install it: apt-get install $tool"
    done
    echo "For OmniVox: Rust $RUSTC_VERSION in $RUST_DIR, and cmake."
fi
if selected dectalk; then
    for tool in autoconf automake; do
        command -v "$tool" >/dev/null || die "$tool not found. Install it: apt-get install $tool"
    done
    echo "For DECtalk: autoconf and automake."
fi
if selected voxin; then
    command -v xz >/dev/null || die "xz not found. Install it: apt-get install xz-utils"
fi
# Voxin goes in before emacspeak is built, so an incomplete archive stops
# the script before the long build.
if selected voxin && [ -n "$VOXIN_ARCHIVE" ]; then
    install_voxin
fi

# --------------------------------------------------------------------------
OLD_HEAD=""
if [ -d "$PREFIX/.git" ]; then
    log "Updating emacspeak in $PREFIX from $REPO ($REF)"
    # Undo this script's changes first, so git sees unmodified files: the
    # shebangs, and the OmniVox names in servers/.servers.
    unregister_omnivox
    for f in "$PREFIX"/servers/*; do
        [ -f "$f" ] && [ "$(head -c 2 "$f")" = '#!' ] || continue
        if [ "$(head -n 1 "$f")" = "#!$TCLSH86" ]; then
            original=$(git -C "$PREFIX" show "HEAD:servers/${f##*/}" | sed -n 1p) || continue
            sed -i "1s|.*|$original|" "$f"
        fi
    done
    OLD_HEAD=$(git -C "$PREFIX" rev-parse HEAD)
    logged "updating the clone in $PREFIX" \
        git -C "$PREFIX" pull -q --ff-only "$REPO" "$REF"
    # An OmniVox built earlier stays listed, chosen this time or not.
    [ ! -x "$PREFIX/servers/omnivox" ] || register_omnivox
elif [ -e "$PREFIX" ] && [ -n "$(ls -A "$PREFIX")" ]; then
    die "$PREFIX exists but is not a git clone. Move it away or use --prefix."
else
    log "Cloning emacspeak ($REF) from $REPO into $PREFIX"
    logged "git clone" git clone -q --depth 1 --branch "$REF" "$REPO" "$PREFIX"
fi
echo "Emacspeak source: $(git -C "$PREFIX" log -1 --format='commit %h of %cd' --date=short)"
# What this script adds inside the clone, kept out of git status.
EXCLUDE=$PREFIX/.git/info/exclude
mkdir -p "${EXCLUDE%/*}"
for p in /speech-engines /emacspeak-init.el /omnivox/ /dectalk/ \
         /servers/omnivox /servers/log-omnivox /voxin-selftest.wav; do
    grep -qxF "$p" "$EXCLUDE" 2>/dev/null || printf '%s\n' "$p" >>"$EXCLUDE"
done

log "Configuring emacspeak (make config)"
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
if selected espeak; then
    log "Building tclespeak.so, the espeak glue, against Tcl 8.6"
    # The top-level "make espeak" hides a failed build, so run the sub-make.
    # These values are the Makefile's own defaults, which match Debian's layout;
    # they are spelled out so the build does not depend on them.
    logged "building tclespeak.so" make_in "$PREFIX/servers/native-espeak" -B \
        TCL_INCLUDE="$TCL_INCLUDE" LIBS="-ltcl8.6 -lespeak-ng"
    [ -f "$SO" ] || die "the build finished but $SO is missing"
    echo "Built $SO"
fi

if selected omnivox; then
    INSTALLED=$(cat "$OMNIVOX_DIR/installed-version" 2>/dev/null || true)
    if [ "$INSTALLED" = "$OMNIVOX_WANT" ] && [ -x "$PREFIX/servers/omnivox" ] &&
       [ -f "$OMNIVOX_DIR/elisp/omnivox-voices.el" ]; then
        log "OmniVox $OMNIVOX_VERSION is already built; keeping it"
    else
        build_omnivox
    fi
    log "Registering OmniVox in $SERVERS_LIST"
    register_omnivox
    echo "Listed: omnivox, log-omnivox."
fi

if selected dectalk; then
    install_dectalk
fi

if selected voxin; then
    log "Building atcleci.so, the Voxin glue, against Tcl 8.6"
    # It dlopens libibmeci.so when the server starts, so it builds without
    # the engine. Command-line variables replace the Makefile's own flags.
    logged "building atcleci.so" make_in "$PREFIX/servers/linux-outloud" -B \
        CFLAGS="-g -O2 -fPIC -DPIC -std=c++11 -I$TCL_INCLUDE" \
        LIBS="-ltcl8.6 -lasound -ldl"
    [ -f "$ATCLECI_SO" ] || die "the build finished but $ATCLECI_SO is missing"
    echo "Built $ATCLECI_SO"
fi

# --------------------------------------------------------------------------
if [ "$REWRITE" = yes ]; then
    log "Pointing the speech servers at $TCLSH86 (the default tclsh is not Tcl 8.6)"
else
    log "Checking which Tcl runs the speech servers"
fi
changed=""
kept=""
for f in "$PREFIX"/servers/*; do
    # Only scripts: OmniVox is a binary.
    [ -f "$f" ] && [ "$(head -c 2 "$f")" = '#!' ] || continue
    first=$(head -n 1 "$f")
    case "$first" in
        '#!'*tclsh*)
            if [ "$REWRITE" = no ] && [ "$first" = "#!/usr/bin/tclsh" ]; then
                kept="$kept ${f##*/}"
            else
                sed -i "1s|.*|#!$TCLSH86|" "$f"; changed="$changed ${f##*/}"
            fi ;;
    esac
done
[ -n "$changed$kept" ] || die "no Tcl speech servers found in $PREFIX/servers"
[ -z "$kept" ] || echo "Unchanged, run by /usr/bin/tclsh:$kept"
[ -z "$changed" ] || echo "Changed to $TCLSH86:$changed"

# --------------------------------------------------------------------------
log "Writing $INIT"
{
    cat <<INIT
;;; emacspeak-init.el --- start emacspeak with the chosen speech server  -*- lexical-binding: t; -*-
;; $MARKER, which rewrites it on every run.
;; To use it from your own init file, put this line at the very top:
;;   (load-file "$INIT")

;; The speech server: DTK_PROGRAM when it is set, otherwise $DEFAULT_SERVER,
;; the first speech engine chosen when emacspeak was installed.
(setq dtk-program (or (getenv "DTK_PROGRAM") "$DEFAULT_SERVER"))
(add-to-list 'load-path "$PREFIX/lisp")
INIT
    if [ -f "$OMNIVOX_DIR/elisp/omnivox-voices.el" ]; then
        cat <<INIT

;; OmniVox brings its own voice module, which loads before emacspeak,
;; and it plays the auditory icons itself.
(when (string-match-p "omnivox" dtk-program)
  (add-to-list 'load-path "$OMNIVOX_DIR/elisp")
  (require 'omnivox-voices)
  (setq emacspeak-play-program nil))
INIT
    fi
    cat <<INIT

(load-file "$PREFIX/lisp/emacspeak-setup.el")
INIT
} >"$INIT"
echo "Written."

log "Writing the launcher $LAUNCHER"
SERVER_NAMES=""
for e in "${SELECTED[@]}"; do SERVER_NAMES="${SERVER_NAMES:+$SERVER_NAMES, }$(engine_server "$e")"; done
{
    cat <<LAUNCHER
#!/bin/sh
# Console Emacs with emacspeak. $MARKER.
# DTK_PROGRAM picks the speech server; chosen at install: $SERVER_NAMES.
# -q skips your own init file, so emacspeak always starts the same way.
export EMACSPEAK_DIR="$PREFIX"
export DTK_PROGRAM="\${DTK_PROGRAM:-$DEFAULT_SERVER}"
LAUNCHER
    if voxin_installed; then
        echo "export ECIINI=\"\${ECIINI:-$ECI_INI}\""
    fi
    echo "exec emacs -nw -q -l \"$INIT\" \"\$@\""
} > "$LAUNCHER"
chmod 0755 "$LAUNCHER"
echo "Launcher written. Its default server: $DEFAULT_SERVER."

# --------------------------------------------------------------------------
# Self-tests: three for emacspeak itself, then each chosen engine's own.
# None needs a sound card, except a server that will not start without
# one; that test is then skipped, with the reason.
LOAD_CHECK='(kill-emacs (if (and (featurep (quote emacspeak))
                                 (file-executable-p
                                  (expand-file-name dtk-program emacspeak-servers-directory)))
                            0 1))'
OMNIVOX_LOAD_CHECK='(kill-emacs (if (and (featurep (quote emacspeak))
                                         (featurep (quote omnivox-voices))
                                         (null emacspeak-play-program)
                                         (file-executable-p
                                          (expand-file-name "omnivox" emacspeak-servers-directory)))
                                    0 1))'
if [ "$RUN_TESTS" = yes ]; then
    begin_tests emacspeak 3
    next_test "Emacs is 29.1 or newer"
    emacs_new_enough || failed "Emacs $EMACS_VERSION is too old"
    passed "Emacs $EMACS_VERSION."

    next_test "TclX loads in $TCLSH"
    TCLX=$(tclx_version 2>>"$LOG") || failed "TclX does not load in $TCLSH"
    passed "TclX $TCLX."

    next_test "Emacs loads $INIT and finds the $DEFAULT_SERVER server (no speech)"
    env -u DTK_PROGRAM timeout 120 emacs -Q --batch -l "$INIT" --eval "$LOAD_CHECK" \
        >>"$LOG" 2>&1 ||
        failed "Emacs could not load $INIT, or emacspeak does not find the $DEFAULT_SERVER server. See $LOG"
    passed "emacspeak loads, and finds the $DEFAULT_SERVER server."
    end_tests ""

    if selected espeak; then
        begin_tests espeak 3
        next_test "tclespeak.so loads in $TCLSH"
        INFO=$(espeak_glue_check "$SO" 2>>"$LOG") || failed "$SO does not load. See $LOG"
        passed "$INFO."

        next_test "the espeak server starts the way Emacs starts it"
        timeout 30 "$PREFIX/servers/espeak" </dev/null >>"$LOG" 2>&1 ||
            failed "$PREFIX/servers/espeak did not run. See $LOG"
        passed "the server started and exited cleanly."

        next_test "espeak-ng synthesizes speech (into a pipe)"
        BYTES=$(espeak-ng --stdout "Emacspeak is installed." 2>>"$LOG" | wc -c) || BYTES=0
        [ "$BYTES" -gt 1000 ] || failed "espeak-ng produced no audio"
        passed "$BYTES bytes of audio."
        end_tests espeak
    fi

    if selected omnivox; then
        OMNIVOX=$PREFIX/servers/omnivox
        begin_tests OmniVox 5
        next_test "OmniVox reports its version"
        OUT=$(timeout 30 "$OMNIVOX" --version 2>>"$LOG") ||
            failed "$OMNIVOX --version did not run. See $LOG"
        case "$OUT" in
            "omnivox "*) passed "$OUT." ;;
            *) failed "$OMNIVOX --version printed: $OUT" ;;
        esac

        next_test "OmniVox lists its voices"
        OUT=$(timeout 60 "$OMNIVOX" --list-voices 2>>"$LOG") ||
            failed "$OMNIVOX --list-voices did not finish. See $LOG"
        printf '%s\n' "$OUT" >>"$LOG"
        VOICES=$(sed -n 's/^Found \([0-9][0-9]*\) voices.*/\1/p' <<<"$OUT")
        [ "${VOICES:-0}" -ge 1 ] || failed "OmniVox found no voices. See $LOG"
        passed "$VOICES voices."

        next_test "OmniVox's own check synthesizes speech"
        echo "With a sound device, you may hear a tone and: Omnivox is ready."
        OUT=$(timeout 120 "$OMNIVOX" --check 2>>"$LOG") ||
            failed "$OMNIVOX --check did not run to the end. See $LOG"
        printf '%s\n' "$OUT" >>"$LOG"
        # The status line under [synthesis], such as "OK - 62256 samples, ..."
        # or "WARNING - synthesized empty buffer".
        SYNTH=$(awk '/^\[synthesis\]/ { getline; sub(/^[[:space:]]*Status:[[:space:]]*/, "");
                                         print; exit }' <<<"$OUT")
        OMNIVOX_SOUND=no
        if grep -q 'Audio device: OK' <<<"$OUT"; then OMNIVOX_SOUND=yes; fi
        case "$SYNTH" in
            OK*) if [ "$OMNIVOX_SOUND" = yes ]; then
                     passed "speech synthesized, and a sound device was found."
                 else
                     passed "speech synthesized. No sound device was found."
                 fi ;;
            *)   warned "OmniVox synthesized no speech (${SYNTH:-no status}). See $LOG" ;;
        esac

        next_test "Emacs finds OmniVox's voice module and server (no speech)"
        DTK_PROGRAM=omnivox timeout 120 emacs -Q --batch -l "$INIT" \
            --eval "$OMNIVOX_LOAD_CHECK" >>"$LOG" 2>&1 ||
            failed "Emacs could not load omnivox-voices through $INIT, or emacspeak does not find $OMNIVOX. See $LOG"
        for name in omnivox log-omnivox; do
            grep -qx "$name" "$SERVERS_LIST" ||
                failed "$SERVERS_LIST does not list $name. Rerun the script."
        done
        [ -x "$PREFIX/servers/log-omnivox" ] ||
            failed "$PREFIX/servers/log-omnivox is missing. Rerun the script."
        passed "omnivox-voices loads, and omnivox and log-omnivox are listed."

        next_test "the OmniVox server starts the way Emacs starts it"
        if [ "$OMNIVOX_SOUND" = no ]; then
            skipped "no sound device, and OmniVox's server needs one to start"
        else
            server_test omnivox yes
        fi
        end_tests omnivox
    fi

    if sound_device_found; then SOUND=yes; else SOUND=no; fi

    if selected dectalk; then
        begin_tests DECtalk 3
        next_test "DECtalk synthesizes speech (into a pipe)"
        BYTES=$("$DECTALK_HOME/say" -fo stdout:raw -a "DECtalk is installed." 2>>"$LOG" |
                wc -c) || BYTES=0
        [ "$BYTES" -gt 1000 ] || failed "$DECTALK_HOME/say produced no audio. See $LOG"
        passed "$BYTES bytes of audio."

        next_test "tcldtk.so loads in $TCLSH"
        glue_check "$DTK_SO" 2>>"$LOG" ||
            failed "$DTK_SO does not load. See $LOG"
        passed "the DECtalk glue loads, and finds libtts in $DECTALK_HOME/lib."

        next_test "the dtk-soft server starts the way Emacs starts it"
        server_test dtk-soft "$SOUND"
        end_tests dtk-soft
    fi

    if selected voxin; then
        begin_tests Voxin 3
        next_test "voxin-say writes speech to a file (no sound device)"
        WAV=$PREFIX/voxin-selftest.wav
        : >"$WAV"
        ECIINI=$ECI_INI timeout 60 /opt/oralux/voxin/bin/voxin-say -w "$WAV" \
            "Voxin is installed." >>"$LOG" 2>&1 || failed "voxin-say did not run. See $LOG"
        [ -s "$WAV" ] || failed "voxin-say wrote no speech: libvoxin did not find the \
engine. Check that /opt/IBM/ibmtts/lib/libibmeci.so exists."
        passed "$(stat -c %s "$WAV") bytes of speech in $WAV."

        next_test "libibmeci.so leads to Voxin, and atcleci.so finds its libraries"
        [ "$(readlink -f "$SYS_LIBDIR/libibmeci.so")" = "$(readlink -f "$VOXIN_LIB")" ] ||
            failed "$SYS_LIBDIR/libibmeci.so does not lead to $VOXIN_LIB. Rerun with --voxin-archive."
        MISSING=$(ldd "$ATCLECI_SO" 2>>"$LOG" | grep 'not found' || true)
        [ -z "$MISSING" ] || failed "atcleci.so cannot find: $MISSING"
        passed "$SYS_LIBDIR/libibmeci.so leads to libvoxin, and atcleci.so has its libraries."

        next_test "the outloud server starts the way Emacs starts it"
        server_test outloud "$SOUND"
        end_tests outloud
    fi
else
    for e in "${SELECTED[@]}"; do
        RESULTS+=("$(engine_title "$e"): Skipped, server $(engine_server "$e"), self-tests skipped (--no-test).")
    done
fi

# The install worked: save the choice for the next run.
printf '%s\n' "${SELECTED[@]}" >"$RECORD"

# --------------------------------------------------------------------------
log "Done: emacspeak is installed"
echo "Self-test results:"
printf '%s\n' "${RESULTS[@]}"
OTHERS=""
for e in "${ENGINES[@]}"; do
    if ! selected "$e" && installed_engine "$e"; then
        OTHERS="${OTHERS:+$OTHERS, }$(engine_title "$e") (server $(engine_server "$e"))"
    fi
done
FIRST_TITLE=$(engine_title "${SELECTED[0]}")
if [ "$FIRST_TITLE" = "$DEFAULT_SERVER" ]; then
    DEFAULT_TEXT="$DEFAULT_SERVER, the first engine chosen"
else
    DEFAULT_TEXT="$DEFAULT_SERVER, for $FIRST_TITLE, the first engine chosen"
fi
cat <<DONE
Speech engines: $(titles), saved in $RECORD
Default server: $DEFAULT_TEXT
Emacspeak is in $PREFIX
Tcl servers run by $TCLSH (Tcl $TCL_PATCHLEVEL)
Launcher: $LAUNCHER
Build log: $LOG
DONE
if [ -n "$OTHERS" ]; then echo "Also installed by an earlier run, not rebuilt now: $OTHERS."; fi
cat <<DONE

To start it, run this as your normal user (not root):
  emacspeak

To use another server for one session:
DONE
if [ ${#SELECTED[@]} -gt 1 ]; then
    for e in "${SELECTED[@]:1}"; do echo "  DTK_PROGRAM=$(engine_server "$e") emacspeak"; done
else
    echo "  DTK_PROGRAM=<server> emacspeak"
fi
cat <<DONE
Inside Emacs, M-x dtk-select-server switches servers.

To load emacspeak from your own Emacs init file instead, put this
line at the very top of ~/.emacs or ~/.emacs.d/init.el:
  (load-file "$INIT")

To update emacspeak later, run this script again.
To choose other speech engines, run it with --speech.
DONE
