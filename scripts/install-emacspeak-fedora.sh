#!/usr/bin/env bash
# install-emacspeak-fedora.sh: emacspeak with real speech on Fedora.
#
# Installs emacspeak with one or more speech engines, chosen with --speech
# or from a menu:
#   espeak   eSpeak NG voices through emacspeak's own espeak server
#   omnivox  the OmniVox server (Rust), built from source; on Linux it
#            speaks eSpeak NG voices through its own audio pipeline
#   dectalk  software DECtalk, built from source, for the dtk-soft server
#   voxin    the paid Voxin (Eloquence) voices, for the outloud server
#
# Fedora's default tcl package is Tcl 9, and emacspeak's speech servers and
# their C glue only work with Tcl 8.6, which is why a plain build fails.
# Fedora still ships Tcl 8.6 as tcl8, with tcl8-devel and a TclX built for
# it, so this script installs those, builds emacspeak and each engine's glue
# against them, and points the servers at tclsh8.6 instead of tclsh.

set -euo pipefail

PREFIX=/opt/emacspeak
REPO=https://github.com/tvraman/emacspeak.git
REF=master
SKIP_DEPS=no
RUN_TESTS=yes
SPEECH=""
SPEECH_GIVEN=no
VOXIN_ARCHIVE=""
TCLSH=/usr/bin/tclsh8.6
LAUNCHER=/usr/local/bin/emacspeak
LOG=/var/log/install-emacspeak-fedora.log
MARKER="Written by install-emacspeak-fedora.sh"

# Every engine this script offers, in menu order, and the default.
ENGINES="espeak omnivox dectalk voxin"
DEFAULT_ENGINE=espeak

# Packages: the base set, then each engine's own.
BASE_PACKAGES=(git make gcc gcc-c++ tcl8 tcl8-devel tclx sox pulseaudio-utils)
ESPEAK_PACKAGES=(espeak-ng espeak-ng-devel)
# OmniVox's espeak-rs-sys crate compiles its own espeak-ng with cmake and
# makes its Rust bindings with bindgen, which loads libclang (clang-libs)
# and asks the clang program where clang's own headers, such as stddef.h,
# are; without clang, bindgen fails on stddef.h. Its audio goes through
# ALSA, found with pkg-config. clang-devel is not needed.
OMNIVOX_PACKAGES=(cargo rust cmake espeak-ng espeak-ng-devel clang
                  alsa-lib-devel pkgconf-pkg-config)
DECTALK_PACKAGES=(autoconf automake pulseaudio-libs-devel alsa-lib-devel
                  pkgconf-pkg-config)
# Voxin's engine runs as a 32-bit process; atcleci.so speaks through ALSA.
VOXIN_PACKAGES=(glibc.i686 libstdc++.i686 alsa-lib-devel tar xz)

# OmniVox: no Linux binary is released, so the tag is built from source.
OMNIVOX_REPO=https://github.com/robertmeta/omnivox.git
OMNIVOX_TAG=v1.3.0
RUST_MINOR_NEEDED=70
# DECtalk: the community-preserved sources, as the Dockerfile builds them.
DECTALK_REPO=https://github.com/dectalk/dectalk.git
DECTALK_REF=develop
DECTALK_HOME=/opt/dectalk
# Voxin: where its archive puts the 64-bit ECI library and its config.
VOXIN_HOME=/opt/oralux/voxin
SYS_LIBDIR=/usr/lib64
ECIINI_FILE=/var/opt/IBM/ibmtts/cfg/eci.ini

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# What each engine is, what it needs, and which emacspeak server runs it.
engine_server() {
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
        general) echo General ;;
    esac
}
engine_about() {
    case "$1" in
        espeak)  echo "free, eSpeak NG voices through emacspeak's own server" ;;
        omnivox) echo "free, the OmniVox server built from source, also eSpeak NG voices" ;;
        dectalk) echo "free, software DECtalk built from source" ;;
        voxin)   echo "paid Eloquence voices from voxin.oralux.net" ;;
    esac
}
engine_needs() {
    case "$1" in
        espeak)  echo "Fedora packages only" ;;
        omnivox) echo "Rust 1.$RUST_MINOR_NEEDED or newer, and several minutes to build" ;;
        dectalk) echo "a few minutes to build" ;;
        voxin)   echo "--voxin-archive FILE, the archive you get from voxin.oralux.net" ;;
    esac
}
engine_packages() {
    case "$1" in
        espeak)  echo "${ESPEAK_PACKAGES[*]}" ;;
        omnivox) echo "${OMNIVOX_PACKAGES[*]}" ;;
        dectalk) echo "${DECTALK_PACKAGES[*]}" ;;
        voxin)   echo "${VOXIN_PACKAGES[*]}" ;;
    esac
}
print_engines() { # what --speech list prints: one line per engine
    local e default
    for e in $ENGINES; do
        default=""
        [ "$e" != "$DEFAULT_ENGINE" ] || default=" (the default)"
        echo "$e: $(engine_about "$e"); needs $(engine_needs "$e"); server $(engine_server "$e")$default"
    done
}

usage() {
    cat <<USAGE
Usage: sudo bash install-emacspeak-fedora.sh [options]

Installs emacspeak with real speech on Fedora 43, 44 or 45.
Run it again later to update emacspeak and rebuild it.

Options:
  --speech LIST         speech engines, comma-separated, in order of
                        preference: espeak, omnivox, dectalk, voxin,
                        or all. The first one is the launcher's default.
                        --speech list describes each engine.
                        Without it, the script reuses the engines chosen
                        last time, or asks with a menu, or takes espeak
                        when there is no terminal to ask on.
  --voxin-archive FILE  the Voxin archive, such as voxin-enu-v3.x.tar.gz,
                        from voxin.oralux.net (paid); adds voxin
  --prefix DIR          where emacspeak is cloned and built
                        (default $PREFIX)
  --repo URL            emacspeak git repository (default $REPO)
  --ref REF             branch or tag to build (default $REF)
  --skip-deps           do not run dnf; you installed the packages yourself
  --no-test             skip the self-tests at the end
  --help                show this help

Packages it always installs: ${BASE_PACKAGES[*]},
and emacs if no Emacs is installed. Each engine adds its own:
  espeak: ${ESPEAK_PACKAGES[*]}
  omnivox: ${OMNIVOX_PACKAGES[*]}
  dectalk: ${DECTALK_PACKAGES[*]}
  voxin: ${VOXIN_PACKAGES[*]}
Build output goes to $LOG.
USAGE
}

# --------------------------------------------------------------------------
# Run a noisy command with its output in $LOG. If it fails, show the end of
# the log, then the error, so the last line on screen names the problem.
logged() {
    local what=$1; shift
    if ! "$@" >>"$LOG" 2>&1; then
        printf '\nLast lines of %s:\n' "$LOG" >&2
        tail -n 20 "$LOG" >&2
        die "$what failed. The full output is in $LOG"
    fi
}

# Emacspeak's Makefiles hand $(MAKEFLAGS) to their sub-makes as plain words.
# GNU make 4.3 writes the -w that "make -C" adds as a bare "w", which the
# sub-make then takes for a target and fails. Fedora 43 and later ship make
# 4.4, which is fine, but run make from inside the directory anyway, without
# flags inherited from outside, so this script matches its Debian sibling.
make_in() { # $1 = directory, then the make arguments
    local dir=$1; shift
    ( cd "$dir" && env -u MAKEFLAGS -u MFLAGS make "$@" )
}
in_dir() { # $1 = directory, then a command to run there
    local dir=$1; shift
    ( cd "$dir" && "$@" )
}

# tclsh reading a script from stdin exits 0 even after an error, so these
# Tcl checks exit 1 themselves when something fails.
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
glue_loads() { # $1 = path of a Tcl glue library, $2 = a command it adds
    timeout 30 "$TCLSH" <<TCL
if {[catch {load {$1}} err]} {puts stderr \$err; exit 1}
if {[info commands $2] ne "$2"} {puts stderr "no $2 command"; exit 1}
TCL
}
emacs_new_enough() {
    emacs -Q --batch --eval '(kill-emacs (if (version<= "29.1" emacs-version) 0 1))' \
        2>>"$LOG"
}

# The first line of a server file, if it starts with #!. It reads only two
# bytes of a binary such as omnivox, so no NUL byte reaches the shell.
shebang_of() {
    if [ "$(head -c 2 "$1")" = '#!' ]; then head -n 1 "$1"; fi
}

# --------------------------------------------------------------------------
# The chosen engines live in SELECTED, space-separated, in order.
SELECTED=""
is_selected() { case " $SELECTED " in *" $1 "*) return 0 ;; esac; return 1; }
add_engine() { is_selected "$1" || SELECTED="${SELECTED:+$SELECTED }$1"; }
selected_titles() { # such as "espeak, OmniVox"
    local e out=""
    for e in $SELECTED; do out="${out:+$out, }$(engine_title "$e")"; done
    printf '%s' "$out"
}

# Adds the engines named in $1 (separated by commas, spaces or newlines,
# in any case) to SELECTED. On an unknown name, sets BAD and returns 1.
BAD=""
parse_engines() {
    local word lower e words=()
    read -r -d '' -a words < <(printf '%s' "$1" | tr ',' ' ') || true
    for word in "${words[@]}"; do
        lower=$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')
        case "$lower" in
            espeak|omnivox|dectalk|voxin) add_engine "$lower" ;;
            all)
                for e in $ENGINES; do
                    [ "$e" = voxin ] || add_engine "$e"
                done
                [ -z "$VOXIN_ARCHIVE" ] || add_engine voxin ;;
            *) BAD=$word; return 1 ;;
        esac
    done
}

# Voxin counts as installed when its library and the ECI link are in place.
voxin_installed() {
    [ -e "$VOXIN_HOME/lib/libvoxin.so.1" ] && [ -e "$SYS_LIBDIR/libibmeci.so" ]
}
VOXIN_NEEDS="voxin needs --voxin-archive FILE: Voxin is paid software, and \
FILE is its archive, such as voxin-enu-v3.x.tar.gz, from voxin.oralux.net."

# The menu, shown when nothing else says which engines to install.
ask_engines() {
    local e i answer n picked bad nums
    echo "Which speech engines should emacspeak get?"
    i=0
    for e in $ENGINES; do
        i=$((i + 1))
        if [ "$e" = "$DEFAULT_ENGINE" ]; then
            echo "$i) $e: $(engine_about "$e") (default)"
        elif [ "$e" = voxin ] && [ -z "$VOXIN_ARCHIVE" ] && ! voxin_installed; then
            echo "$i) $e: $(engine_about "$e"), needs --voxin-archive FILE"
        else
            echo "$i) $e: $(engine_about "$e")"
        fi
    done
    if [ -n "$VOXIN_ARCHIVE" ]; then
        echo "Voxin is added in any case, because --voxin-archive was given."
    fi
    while :; do
        printf '%s' "Numbers separated by spaces, or Enter for the default [1]: "
        IFS= read -r answer ||
            die "no answer was given. Run the script again, or choose with --speech."
        nums=()
        read -r -a nums <<<"$(printf '%s' "$answer" | tr ',' ' ')" || true
        [ "${#nums[@]}" -gt 0 ] || nums=(1)
        picked=""
        bad=no
        for n in "${nums[@]}"; do
            case "$n" in
                1) e=espeak ;;
                2) e=omnivox ;;
                3) e=dectalk ;;
                4) e=voxin ;;
                *) bad=yes; break ;;
            esac
            case " $picked " in *" $e "*) ;; *) picked="${picked:+$picked }$e" ;; esac
        done
        if [ "$bad" = yes ]; then
            echo "$n is not on the menu. Answer with numbers from 1 to 4, such as: 1 2"
            continue
        fi
        case " $picked " in
            *" voxin "*)
                if [ -z "$VOXIN_ARCHIVE" ] && ! voxin_installed; then
                    echo "$VOXIN_NEEDS"
                    echo "Choose other numbers, or press Ctrl-C and rerun with that option."
                    continue
                fi ;;
        esac
        SELECTED=$picked
        return 0
    done
}

# --------------------------------------------------------------------------
need_value() { [ $# -ge 2 ] || die "$1 needs a value (try --help)"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --speech)        need_value "$@"; SPEECH=$2; SPEECH_GIVEN=yes; shift ;;
        --voxin-archive) need_value "$@"; VOXIN_ARCHIVE=$2; shift ;;
        --prefix)        need_value "$@"; PREFIX=$2; shift ;;
        --repo)          need_value "$@"; REPO=$2; shift ;;
        --ref)           need_value "$@"; REF=$2; shift ;;
        --skip-deps)     SKIP_DEPS=yes ;;
        --no-test)       RUN_TESTS=no ;;
        --help|-h)       usage; exit 0 ;;
        *)               die "unknown option $1 (try --help)" ;;
    esac
    shift
done
PREFIX=$(realpath -m "$PREFIX")
# The prefix goes into Lisp strings in the init file.
case "$PREFIX" in
    *'"'*|*\\*) die "--prefix must not contain quotes or backslashes" ;;
esac
RECORD=$PREFIX/speech-engines
INIT=$PREFIX/emacspeak-init.el
SERVERS_LIST=$PREFIX/servers/.servers
OMNIVOX_DIR=$PREFIX/omnivox
DECTALK_DIR=$PREFIX/dectalk
SELFTEST_DIR=$PREFIX/selftest

if [ "$(printf '%s' "$SPEECH" | tr '[:upper:]' '[:lower:]')" = list ]; then
    print_engines
    exit 0
fi
if [ -n "$VOXIN_ARCHIVE" ]; then
    [ -f "$VOXIN_ARCHIVE" ] || die "no such file: $VOXIN_ARCHIVE (from --voxin-archive)"
    VOXIN_ARCHIVE=$(realpath "$VOXIN_ARCHIVE")
fi
if [ "$SPEECH_GIVEN" = yes ]; then
    if ! parse_engines "$SPEECH"; then
        echo "The speech engines on Fedora are:" >&2
        print_engines >&2
        die "unknown speech engine \"$BAD\". Choose from \
$(echo "$ENGINES" | sed 's/ /, /g'), all or list, separated by commas."
    fi
    [ -n "$SELECTED" ] || die "--speech needs at least one engine name (try --speech list)"
    [ -z "$VOXIN_ARCHIVE" ] || add_engine voxin
    if is_selected voxin && [ -z "$VOXIN_ARCHIVE" ] && ! voxin_installed; then
        die "$VOXIN_NEEDS"
    fi
fi

# --------------------------------------------------------------------------
log "Checking the system"
[ "$EUID" -eq 0 ] || die "run this as root, for example: sudo bash $0"
[ -r /etc/os-release ] || die "no /etc/os-release; this script is for Fedora"
. /etc/os-release
if [ "${ID:-}" != fedora ]; then
    case " ${ID_LIKE:-} " in
        *" fedora "*) echo "Warning: ${PRETTY_NAME:-this system} is not Fedora itself; trying anyway." ;;
        *) die "this script is for Fedora, and this is ${PRETTY_NAME:-unknown}." ;;
    esac
fi
case "${VERSION_ID:-}" in
    43|44|45) echo "${PRETTY_NAME:-Fedora}: supported." ;;
    *) echo "Warning: tested on Fedora 43 to 45, this is ${VERSION_ID:-unknown}; trying anyway." ;;
esac

log "Choosing the speech engines"
if [ "$SPEECH_GIVEN" = yes ]; then
    echo "Chosen with --speech."
elif [ -f "$RECORD" ]; then
    parse_engines "$(cat "$RECORD")" ||
        die "$RECORD lists an unknown engine, \"$BAD\". Choose again with --speech."
    [ -n "$SELECTED" ] || die "$RECORD is empty. Choose the engines with --speech."
    echo "Reusing the engines chosen last time, from $RECORD."
    echo "To choose others, run the script with --speech."
elif [ -t 0 ] && [ -t 1 ]; then
    ask_engines
else
    SELECTED=$DEFAULT_ENGINE
    echo "No terminal to ask on, so the default is used: $DEFAULT_ENGINE. Choose others with --speech."
fi
[ -z "$VOXIN_ARCHIVE" ] || add_engine voxin
if is_selected voxin && [ -z "$VOXIN_ARCHIVE" ] && ! voxin_installed; then
    die "$VOXIN_NEEDS"
fi
echo "Selected: $(selected_titles)."
DEFAULT_SERVER=$(engine_server "${SELECTED%% *}")
echo "The launcher's default server: $DEFAULT_SERVER"

: > "$LOG"
echo "Build log: $LOG"

# --------------------------------------------------------------------------
PACKAGES=("${BASE_PACKAGES[@]}")
for e in $SELECTED; do
    for p in $(engine_packages "$e"); do
        case " ${PACKAGES[*]} " in *" $p "*) ;; *) PACKAGES+=("$p") ;; esac
    done
done
if [ "$SKIP_DEPS" = no ]; then
    # tcl8-devel and tcl-devel (Tcl 9) both own /usr/include/tcl.h.
    if rpm -q --quiet tcl-devel; then
        die "tcl-devel (the Tcl 9 headers) is installed and conflicts with \
tcl8-devel, which this build needs. Remove it with: dnf remove tcl-devel, \
then rerun this script."
    fi
    log "Installing packages with dnf (this can take a few minutes)"
    echo "Packages: ${PACKAGES[*]}"
    logged "dnf install" dnf -y install "${PACKAGES[@]}"
    if ! command -v emacs >/dev/null; then
        log "No Emacs found: installing Fedora's emacs package"
        logged "dnf install emacs" dnf -y install emacs
    fi
fi

log "Checking Emacs, Tcl 8.6 and TclX"
command -v emacs >/dev/null || die "emacs not found. Install it: dnf install emacs"
EMACS_VERSION=$(emacs -Q --batch --eval '(princ emacs-version)' 2>>"$LOG") ||
    die "emacs is installed but does not run in batch mode"
emacs_new_enough ||
    die "emacspeak needs Emacs 29.1 or newer, and this is Emacs $EMACS_VERSION"
echo "Emacs $EMACS_VERSION: new enough."
for tool in git make g++; do
    command -v "$tool" >/dev/null || die "$tool not found. Install: ${PACKAGES[*]}"
done
[ -x "$TCLSH" ] || die "$TCLSH not found. Install Tcl 8.6: dnf install tcl8"
grep -q 'define TCL_VERSION[[:space:]]*"8.6"' /usr/include/tcl.h 2>/dev/null ||
    die "/usr/include/tcl.h is missing or is not Tcl 8.6. Install tcl8-devel."
TCLX=$(tclx_version 2>>"$LOG") ||
    die "TclX does not load in $TCLSH. Install it: dnf install tclx"
echo "Tcl 8.6 headers found; TclX $TCLX loads in $TCLSH."

# What each chosen engine needs to build, so that a --skip-deps run stops
# here naming the package, not later inside a build.
if is_selected espeak || is_selected omnivox; then
    [ -r /usr/include/espeak-ng/speak_lib.h ] ||
        die "espeak-ng headers not found. Install espeak-ng-devel."
fi
if is_selected omnivox; then
    log "Checking Rust, cmake and clang for OmniVox"
    for tool in cargo rustc cmake clang pkg-config; do
        command -v "$tool" >/dev/null ||
            die "$tool not found; OmniVox's build needs it. Install: ${OMNIVOX_PACKAGES[*]}"
    done
    RUSTC_VERSION=$(rustc --version | awk '{ print $2 }')
    rust_minor=${RUSTC_VERSION#1.}
    rust_minor=${rust_minor%%.*}
    case "$rust_minor" in ''|*[!0-9]*) rust_minor=0 ;; esac
    [ "$rust_minor" -ge "$RUST_MINOR_NEEDED" ] ||
        die "OmniVox needs Rust 1.$RUST_MINOR_NEEDED or newer, and this is \
$RUSTC_VERSION. Update it: dnf upgrade rust cargo, then rerun this script."
    compgen -G "$SYS_LIBDIR/libclang.so*" >/dev/null ||
        die "libclang not found; OmniVox's build needs it. Install it: dnf install clang"
    pkg-config --exists alsa ||
        die "the ALSA headers are missing; OmniVox's build needs them. Install alsa-lib-devel."
    echo "Rust $RUSTC_VERSION: new enough. cmake, clang and the ALSA headers found."
fi
if is_selected dectalk; then
    for tool in autoreconf automake; do
        command -v "$tool" >/dev/null ||
            die "$tool not found; the DECtalk build needs it. Install: ${DECTALK_PACKAGES[*]}"
    done
    [ -r /usr/include/pulse/simple.h ] && [ -r /usr/include/alsa/asoundlib.h ] ||
        die "the PulseAudio or ALSA headers are missing; DECtalk needs them. Install: ${DECTALK_PACKAGES[*]}"
fi
if is_selected voxin; then
    [ -e /usr/lib/ld-linux.so.2 ] && [ -e /usr/lib/libstdc++.so.6 ] ||
        die "the 32-bit C and C++ libraries are missing; Voxin's engine needs \
them. Install them: dnf install glibc.i686 libstdc++.i686"
    [ -r /usr/include/alsa/asoundlib.h ] ||
        die "the ALSA headers are missing; atcleci.so needs them. Install alsa-lib-devel."
fi

# --------------------------------------------------------------------------
# Voxin's archive is unpacked and checked before emacspeak is built, so a
# wrong file stops the script early. The installer tree inside it is
# installed the way its own installer does it:
#   rfs_<arch>.txz and rfs_all.txz  -> /opt/oralux/voxin (libvoxin, voxin-say)
#   voxin-viavoice-all_*.txz        -> /opt/IBM/ibmtts (the engine)
#   voxin-viavoice-<lang>_*.txz     -> voices, and /var/opt/IBM voice data
install_voxin_archive() {
    local stage installer tree arch pattern t voices langs l
    log "Unpacking the Voxin archive ${VOXIN_ARCHIVE##*/}"
    # A new private folder in /var/tmp, which Fedora clears after 30 days.
    stage=$(mktemp -d /var/tmp/emacspeak-voxin.XXXXXXXX)
    logged "unpacking $VOXIN_ARCHIVE" tar -xf "$VOXIN_ARCHIVE" -C "$stage"
    echo "Unpacked into $stage"
    installer=$(find "$stage" -name voxin-installer.sh -print -quit)
    [ -n "$installer" ] || die "${VOXIN_ARCHIVE##*/} is not a Voxin 3.x \
archive: it has no voxin-installer.sh. Download it again from voxin.oralux.net."
    tree=${installer%/*}
    arch=$(uname -m)
    # Check that every part is there before anything goes into /.
    for pattern in "rfs_*.$arch.txz" "rfs_*.all.txz" "voxin-viavoice-all_*.txz"; do
        compgen -G "$tree/packages/all/$pattern" >/dev/null ||
            die "the Voxin archive has no packages/all/$pattern, so it is \
incomplete or not for $arch. Download it again from voxin.oralux.net."
    done
    voices=0
    for t in "$tree"/packages/all/voxin-viavoice-*.txz; do
        case "$t" in *-all_*) ;; *) voices=$((voices + 1)) ;; esac
    done
    [ "$voices" -gt 0 ] || die "the Voxin archive has no voice package \
(packages/all/voxin-viavoice-<language>_*.txz). Download it again from voxin.oralux.net."
    echo "The archive holds the runtime, the engine and $voices voice package(s)."

    log "Installing the Voxin runtime for $arch into $VOXIN_HOME"
    for t in "$tree"/packages/all/rfs_*."$arch".txz "$tree"/packages/all/rfs_*.all.txz; do
        echo "${t##*/}"
        logged "unpacking ${t##*/}" tar -C / --no-overwrite-dir -xf "$t"
    done
    log "Installing the ViaVoice engine and voices into /opt/IBM"
    for t in "$tree"/packages/all/voxin-viavoice-all_*.txz; do
        echo "${t##*/}"
        logged "unpacking ${t##*/}" tar -C / --no-overwrite-dir -xf "$t"
    done
    for t in "$tree"/packages/all/voxin-viavoice-*.txz; do
        case "$t" in *-all_*) continue ;; esac
        echo "${t##*/}"
        logged "unpacking ${t##*/}" tar -C / --no-overwrite-dir -xf "$t"
    done

    # eci.ini: the engine's all.ini, then one section per installed language
    # (a language is installed when its xxx50.so synthesizer library is).
    log "Writing $ECIINI_FILE"
    mkdir -p "${ECIINI_FILE%/*}"
    langs=$(find /opt/IBM/ibmtts/lib -name '???50.so' | sed 's+.*/\(...\)50.so+\1+')
    [ -n "$langs" ] || die "no ViaVoice language libraries found under /opt/IBM/ibmtts/lib"
    cp /opt/IBM/ibmtts/etc/all.ini "$ECIINI_FILE"
    for l in $langs; do
        echo "Language: $l"
        cat "/opt/IBM/ibmtts/etc/$l.ini" >> "$ECIINI_FILE"
    done

    # libvoxin.so.1 is the 64-bit ECI library; Voxin's own packages link the
    # name libibmeci.so to it. atcleci.so dlopens libibmeci.so, which is
    # looked up in the trusted libdir, /usr/lib64 on Fedora. The
    # ld.so.conf.d entry lets voxin-say find libvoxin.so.1 by its soname.
    log "Linking libibmeci.so in $SYS_LIBDIR to Voxin's library"
    [ -e "$VOXIN_HOME/lib/libvoxin.so.1" ] ||
        die "$VOXIN_HOME/lib/libvoxin.so.1 is missing after unpacking the archive"
    ln -sf "$VOXIN_HOME/lib/libvoxin.so.1" "$SYS_LIBDIR/libibmeci.so"
    echo "$VOXIN_HOME/lib" > /etc/ld.so.conf.d/voxin.conf
    ldconfig
    ln -sf "$VOXIN_HOME/bin/voxin-say" /usr/local/bin/voxin-say
    # ECIINI tells the engine where its config is; the launcher sets it too.
    echo "export ECIINI=$ECIINI_FILE" > /etc/profile.d/voxin.sh
    echo "Voxin is installed."
}
if is_selected voxin; then
    if [ -n "$VOXIN_ARCHIVE" ]; then
        install_voxin_archive
    else
        log "Voxin is already installed in $VOXIN_HOME; keeping it"
        echo "To install another Voxin archive, rerun with --voxin-archive FILE."
    fi
fi

# --------------------------------------------------------------------------
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
    sed -i -e '/^omnivox$/d' -e '/^log-omnivox$/d' "$SERVERS_LIST"
}
# Keeps the files this script adds to the clone out of git status.
exclude_own_files() {
    local file=$PREFIX/.git/info/exclude pattern
    mkdir -p "$PREFIX/.git/info"
    touch "$file"
    [ -z "$(tail -c 1 "$file")" ] || printf '\n' >>"$file"
    for pattern in /speech-engines /emacspeak-init.el /selftest/ /omnivox/ \
                   /dectalk/ /servers/omnivox /servers/log-omnivox; do
        grep -qxF "$pattern" "$file" || printf '%s\n' "$pattern" >>"$file"
    done
}

OLD_HEAD=""
if [ -d "$PREFIX/.git" ]; then
    log "Updating emacspeak in $PREFIX from $REPO ($REF)"
    # Undo this script's changes first, so git sees unmodified files: the
    # shebangs, and OmniVox's two names in servers/.servers.
    for f in "$PREFIX"/servers/*; do
        if [ -f "$f" ] && [ "$(shebang_of "$f")" = "#!$TCLSH" ]; then
            original=$(git -C "$PREFIX" show "HEAD:servers/${f##*/}" | sed -n 1p) || continue
            sed -i "1s|.*|$original|" "$f"
        fi
    done
    unregister_omnivox
    OLD_HEAD=$(git -C "$PREFIX" rev-parse HEAD)
    logged "updating the clone in $PREFIX" \
        git -C "$PREFIX" pull -q --ff-only "$REPO" "$REF"
    # An OmniVox installed by an earlier run stays registered.
    if [ -x "$PREFIX/servers/omnivox" ]; then register_omnivox; fi
elif [ -e "$PREFIX" ] && [ -n "$(ls -A "$PREFIX")" ]; then
    die "$PREFIX exists but is not a git clone. Move it away or use --prefix."
else
    log "Cloning emacspeak ($REF) from $REPO into $PREFIX"
    logged "git clone" git clone -q --depth 1 --branch "$REF" "$REPO" "$PREFIX"
fi
echo "Emacspeak source: $(git -C "$PREFIX" log -1 --format='commit %h of %cd' --date=short)"
exclude_own_files

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
# Each engine's own build.
ESPEAK_SO="$PREFIX/servers/native-espeak/tclespeak.so"
DTK_SO="$PREFIX/servers/software-dtk/tcldtk.so"
ECI_SO="$PREFIX/servers/linux-outloud/atcleci.so"

if is_selected espeak; then
    log "Building tclespeak.so, the espeak glue, against Tcl 8.6"
    # tcl8-devel puts the 8.6 headers straight into /usr/include.
    logged "building tclespeak.so" make_in "$PREFIX/servers/native-espeak" -B \
        TCL_INCLUDE=/usr/include LIBS="-ltcl8.6 -lespeak-ng"
    [ -f "$ESPEAK_SO" ] || die "the build finished but $ESPEAK_SO is missing"
    echo "Built $ESPEAK_SO"
fi

install_omnivox() {
    local src=$OMNIVOX_DIR/src installed
    mkdir -p "$OMNIVOX_DIR"
    installed=$(cat "$OMNIVOX_DIR/installed-version" 2>/dev/null || true)
    if [ "$installed" = "$OMNIVOX_TAG" ] && [ -x "$PREFIX/servers/omnivox" ] &&
       [ -f "$OMNIVOX_DIR/elisp/omnivox-voices.el" ]; then
        log "OmniVox ${OMNIVOX_TAG#v} is already built and installed; keeping it"
    else
        if [ -d "$src/.git" ]; then
            log "Updating the OmniVox source in $src to $OMNIVOX_TAG"
            logged "fetching OmniVox $OMNIVOX_TAG" git -C "$src" fetch -q --depth 1 \
                origin "refs/tags/$OMNIVOX_TAG:refs/tags/$OMNIVOX_TAG"
            logged "checking out OmniVox $OMNIVOX_TAG" \
                git -C "$src" -c advice.detachedHead=false checkout -q "$OMNIVOX_TAG"
        else
            log "Cloning OmniVox $OMNIVOX_TAG from $OMNIVOX_REPO into $src"
            logged "cloning OmniVox" git -c advice.detachedHead=false clone -q \
                --depth 1 --branch "$OMNIVOX_TAG" "$OMNIVOX_REPO" "$src"
        fi
        log "Building OmniVox ${OMNIVOX_TAG#v} with cargo (several minutes; it compiles espeak-ng too)"
        # CARGO_HOME keeps cargo's downloads beside the source, and out of
        # the home folder of whoever ran sudo.
        logged "cargo build" env CARGO_HOME="$OMNIVOX_DIR/cargo" \
            cargo build --release --manifest-path "$src/Cargo.toml"
        [ -f "$src/target/release/omnivox" ] ||
            die "the build finished but $src/target/release/omnivox is missing"
        mkdir -p "$OMNIVOX_DIR/elisp"
        cp "$src/elisp/omnivox-voices.el" "$OMNIVOX_DIR/elisp/omnivox-voices.el"
        install -m 0755 "$src/target/release/omnivox" "$PREFIX/servers/omnivox"
        # OmniVox's README registers the same binary under the name log-omnivox.
        ln -sfn omnivox "$PREFIX/servers/log-omnivox"
        printf '%s\n' "$OMNIVOX_TAG" > "$OMNIVOX_DIR/installed-version"
        echo "Installed $PREFIX/servers/omnivox, and log-omnivox beside it."
    fi
    log "Registering OmniVox in $SERVERS_LIST"
    register_omnivox
    echo "Listed: omnivox, log-omnivox."
}
if is_selected omnivox; then install_omnivox; fi

install_dectalk() {
    local src=$DECTALK_DIR/src commit installed
    mkdir -p "$DECTALK_DIR"
    if [ -d "$src/.git" ]; then
        log "Updating the DECtalk source in $src ($DECTALK_REF)"
        logged "updating the DECtalk source" \
            git -C "$src" pull -q --ff-only "$DECTALK_REPO" "$DECTALK_REF"
    else
        log "Cloning DECtalk ($DECTALK_REF) from $DECTALK_REPO into $src"
        logged "cloning DECtalk" git clone -q --depth 1 --branch "$DECTALK_REF" \
            "$DECTALK_REPO" "$src"
    fi
    commit=$(git -C "$src" rev-parse --short HEAD)
    installed=$(cat "$DECTALK_DIR/installed-commit" 2>/dev/null || true)
    if [ "$installed" = "$commit" ] && [ -x "$DECTALK_HOME/say" ] &&
       [ -e "$DECTALK_HOME/lib/libtts.so" ]; then
        log "DECtalk commit $commit is already built and installed in $DECTALK_HOME; keeping it"
    else
        log "Building software DECtalk, commit $commit (a few minutes)"
        # 1990s C: today's gcc needs -fpermissive and fewer errors.
        logged "DECtalk autogen.sh" in_dir "$src/src" ./autogen.sh
        logged "DECtalk configure" in_dir "$src/src" ./configure \
            CFLAGS="-O2 -fpermissive -Wno-implicit-function-declaration"
        logged "building DECtalk" make_in "$src/src" -j"$(nproc)"
        log "Installing DECtalk into $DECTALK_HOME"
        # make puts everything into dist (lib, dic, say). dist lacks the C
        # headers, and tcldtk.c wants them as <dtk/ttsapi.h>.
        mkdir -p "$DECTALK_HOME/include/dtk"
        cp -a "$src/dist/." "$DECTALK_HOME/"
        cp "$src/src/dapi/src/include/"*.h "$DECTALK_HOME/include/dtk/"
        # Some builds make only the US library, libtts_us.so.
        [ -e "$DECTALK_HOME/lib/libtts.so" ] || ln -s libtts_us.so "$DECTALK_HOME/lib/libtts.so"
        echo "$DECTALK_HOME/lib" > /etc/ld.so.conf.d/dectalk.conf
        ldconfig
        printf '%s\n' "$commit" > "$DECTALK_DIR/installed-commit"
        echo "DECtalk is installed."
    fi
    # libtts falls back to <prefix>/DECtalk.conf; emacspeak ships a template
    # whose dictionary paths are already absolute /opt/dectalk/dic entries.
    cp "$PREFIX/servers/software-dtk/DECtalk.conf" "$DECTALK_HOME/DECtalk.conf"
    log "Building tcldtk.so, the DECtalk glue, against Tcl 8.6"
    # Command-line variables override the Makefile's, so repeat its flags.
    # tcl8-devel's headers are in /usr/include, where gcc looks anyway.
    logged "building tcldtk.so" make_in "$PREFIX/servers/software-dtk" -B \
        CFLAGS="-g -O2 -fPIC -DPIC -I$DECTALK_HOME/include" \
        LDFLAGS="-L$DECTALK_HOME/lib" LIBS="-ltcl8.6 -ltts -ltts_us -ldl"
    [ -f "$DTK_SO" ] || die "the build finished but $DTK_SO is missing"
    echo "Built $DTK_SO"
}
if is_selected dectalk; then install_dectalk; fi

if is_selected voxin; then
    # atcleci.so dlopens libibmeci.so when it loads, so it builds without
    # the engine.
    log "Building atcleci.so, the Voxin glue, against Tcl 8.6"
    logged "building atcleci.so" make_in "$PREFIX/servers/linux-outloud" -B \
        CFLAGS="-g -O2 -fPIC -DPIC -std=c++11" LIBS="-ltcl8.6 -lasound -ldl"
    [ -f "$ECI_SO" ] || die "the build finished but $ECI_SO is missing"
    echo "Built $ECI_SO"
fi

# --------------------------------------------------------------------------
log "Pointing the speech servers at $TCLSH (the default tclsh is Tcl 9)"
changed=""
for f in "$PREFIX"/servers/*; do
    [ -f "$f" ] || continue
    case "$(shebang_of "$f")" in
        '#!'*tclsh*) sed -i "1s|.*|#!$TCLSH|" "$f"; changed="$changed ${f##*/}" ;;
    esac
done
[ -n "$changed" ] || die "no Tcl speech servers found in $PREFIX/servers"
echo "Changed:$changed"

log "Writing the init file $INIT"
{
    cat <<INIT
;;; emacspeak-init.el --- start emacspeak with real speech  -*- lexical-binding: t; -*-
;; $MARKER, which rewrites it on every run.
;; The emacspeak launcher loads it. To use it from your own init file,
;; put this line at the very top of ~/.emacs or ~/.emacs.d/init.el:
;;   (load-file "$INIT")

;; DTK_PROGRAM picks the speech server. Without it, $DEFAULT_SERVER:
;; the first engine chosen when the script last ran.
(setq dtk-program (or (getenv "DTK_PROGRAM") "$DEFAULT_SERVER"))
(add-to-list 'load-path "$PREFIX/lisp")
INIT
    if [ -f "$OMNIVOX_DIR/elisp/omnivox-voices.el" ]; then
        cat <<INIT

;; OmniVox's voice module loads before emacspeak, and only for OmniVox.
;; OmniVox plays the auditory icons itself, so emacspeak does not.
(when (member dtk-program '("omnivox" "log-omnivox"))
  (add-to-list 'load-path "$OMNIVOX_DIR/elisp")
  (require 'omnivox-voices)
  (setq emacspeak-play-program nil))
INIT
    fi
    if voxin_installed; then
        cat <<INIT

;; Where Voxin's engine finds its configuration.
(unless (getenv "ECIINI") (setenv "ECIINI" "$ECIINI_FILE"))
INIT
    fi
    cat <<INIT

;; Native compilation runs in the background; do not pop up its warnings.
(setq native-comp-async-report-warnings-errors 'silent)
(load-file "$PREFIX/lisp/emacspeak-setup.el")
INIT
} > "$INIT"
echo "Written."

log "Writing the launcher $LAUNCHER"
{
    cat <<LAUNCHER
#!/bin/sh
# Console Emacs with emacspeak and real speech.
# $MARKER. DTK_PROGRAM picks the speech server.
# -q skips your own init file, so emacspeak always starts the same way.
export EMACSPEAK_DIR="$PREFIX"
export DTK_PROGRAM="\${DTK_PROGRAM:-$DEFAULT_SERVER}"
LAUNCHER
    if voxin_installed; then
        echo "export ECIINI=\"\${ECIINI:-$ECIINI_FILE}\""
    fi
    cat <<LAUNCHER
exec emacs -nw -q -l "$INIT" "\$@"
LAUNCHER
} > "$LAUNCHER"
chmod 0755 "$LAUNCHER"
echo "Launcher written. Its default server: $DEFAULT_SERVER"

# --------------------------------------------------------------------------
# Self-tests: a general group, then each chosen engine's own. Only the
# tests that start OmniVox's and outloud's servers need a sound device,
# and they are skipped, with the reason, when there is none.
declare -A PASSES=() WARNS=() SKIPS=() TOTALS=() WHY=()
GROUP=""
self_test() { # $1 = group, $2 = number, $3 = how many, $4 = what is tested
    GROUP=$1
    TOTALS[$1]=$3
    log "$(engine_title "$1") self-test $2 of $3: $4"
}
passed() { PASSES[$GROUP]=$(( ${PASSES[$GROUP]:-0} + 1 )); echo "Pass: $*"; }
warned() { # $1 = the reason, for the summary too
    WARNS[$GROUP]=$(( ${WARNS[$GROUP]:-0} + 1 ))
    WHY[$GROUP]="${WHY[$GROUP]:+${WHY[$GROUP]}; }$1"
    echo "Warning: $1."
}
skipped() { # $1 = the reason, for the summary too
    SKIPS[$GROUP]=$(( ${SKIPS[$GROUP]:-0} + 1 ))
    WHY[$GROUP]="${WHY[$GROUP]:+${WHY[$GROUP]}; }$1"
    echo "Skipped: $1."
}
group_status() { # Pass, Warning or Skipped
    if [ "$RUN_TESTS" = no ]; then echo Skipped
    elif [ "${WARNS[$1]:-0}" -gt 0 ]; then echo Warning
    elif [ "${PASSES[$1]:-0}" -gt 0 ]; then echo Pass
    else echo Skipped
    fi
}
group_detail() { # such as "4 of 5 passed, 1 skipped: no sound device"
    local out
    if [ "$RUN_TESTS" = no ]; then printf 'self-tests not run (--no-test)'; return; fi
    out="${PASSES[$1]:-0} of ${TOTALS[$1]:-0} passed"
    [ "${WARNS[$1]:-0}" -eq 0 ] || out="$out, ${WARNS[$1]} with a warning"
    [ "${SKIPS[$1]:-0}" -eq 0 ] || out="$out, ${SKIPS[$1]} skipped"
    [ -z "${WHY[$1]:-}" ] || out="$out: ${WHY[$1]}"
    printf '%s' "$out"
}
# Emacs loads the init file in batch mode, which loads emacspeak without
# starting speech, and checks that the server's program is there.
init_loads() { # $1 = server name, $2 = an extra Lisp feature to expect, or ""
    local feature=t
    [ -z "$2" ] || feature="(featurep (quote $2))"
    DTK_PROGRAM=$1 emacs -Q --batch -l "$INIT" --eval "(kill-emacs
        (if (and (featurep (quote emacspeak)) $feature
                 (string= dtk-program \"$1\")
                 (file-executable-p
                  (expand-file-name dtk-program emacspeak-servers-directory)))
            0 1))" >>"$LOG" 2>&1
}

general_tests() {
    self_test general 1 3 "Emacs is 29.1 or newer"
    emacs_new_enough || die "Self-test failed: Emacs $EMACS_VERSION is too old"
    passed "Emacs $EMACS_VERSION."

    self_test general 2 3 "TclX loads in $TCLSH"
    TCLX=$(tclx_version 2>>"$LOG") ||
        die "Self-test failed: TclX does not load in $TCLSH"
    passed "TclX $TCLX."

    self_test general 3 3 "Emacs loads the init file and finds the $DEFAULT_SERVER server (no speech)"
    init_loads "$DEFAULT_SERVER" "" ||
        die "Self-test failed: Emacs could not load $INIT, or emacspeak does \
not find the $DEFAULT_SERVER server. Rerun the script. See $LOG"
    passed "emacspeak loads, and finds $PREFIX/servers/$DEFAULT_SERVER."
}

espeak_tests() {
    local info bytes
    self_test espeak 1 3 "tclespeak.so loads in $TCLSH"
    info=$(espeak_glue_check "$ESPEAK_SO" 2>>"$LOG") ||
        die "Self-test failed: $ESPEAK_SO does not load. See $LOG"
    passed "$info."

    self_test espeak 2 3 "the espeak server starts the way Emacs starts it"
    timeout 30 "$PREFIX/servers/espeak" </dev/null >>"$LOG" 2>&1 ||
        die "Self-test failed: $PREFIX/servers/espeak did not run. See $LOG"
    passed "the server started and exited cleanly."

    self_test espeak 3 3 "espeak-ng synthesizes speech (into a pipe)"
    bytes=$(espeak-ng --stdout "Emacspeak is installed." 2>>"$LOG" | wc -c) || bytes=0
    [ "$bytes" -gt 1000 ] || die "Self-test failed: espeak-ng produced no audio"
    passed "$bytes bytes of audio."
}

omnivox_tests() {
    local omnivox=$PREFIX/servers/omnivox out voices synth sound=no name
    self_test omnivox 1 5 "OmniVox reports its version"
    out=$(timeout 30 "$omnivox" --version 2>>"$LOG") ||
        die "Self-test failed: $omnivox --version did not run. See $LOG"
    case "$out" in
        "omnivox "*) passed "$out." ;;
        *) die "Self-test failed: $omnivox --version printed: $out" ;;
    esac

    self_test omnivox 2 5 "OmniVox lists its voices"
    out=$(timeout 60 "$omnivox" --list-voices 2>>"$LOG") ||
        die "Self-test failed: $omnivox --list-voices did not finish. See $LOG"
    printf '%s\n' "$out" >>"$LOG"
    voices=$(sed -n 's/^Found \([0-9][0-9]*\) voices.*/\1/p' <<<"$out")
    [ "${voices:-0}" -ge 1 ] ||
        die "Self-test failed: OmniVox found no voices. Is espeak-ng-data installed? See $LOG"
    passed "$voices voices."

    self_test omnivox 3 5 "OmniVox's own check synthesizes speech"
    out=$(timeout 120 "$omnivox" --check 2>>"$LOG") ||
        die "Self-test failed: $omnivox --check did not run to the end. See $LOG"
    printf '%s\n' "$out" >>"$LOG"
    # The status line under [synthesis], such as "OK - 9000 samples, ...".
    synth=$(awk '/^\[synthesis\]/ { getline; sub(/^[[:space:]]*Status:[[:space:]]*/, "");
                                     print; exit }' <<<"$out")
    if grep -q 'Audio device: OK' <<<"$out"; then sound=yes; fi
    case "$synth" in
        OK*) passed "speech synthesized ($synth)." ;;
        *)   warned "OmniVox synthesized no speech: ${synth:-no synthesis status}" ;;
    esac

    self_test omnivox 4 5 "OmniVox is registered, and Emacs loads its voice module (no speech)"
    for name in omnivox log-omnivox; do
        grep -qx "$name" "$SERVERS_LIST" ||
            die "Self-test failed: $SERVERS_LIST does not list $name. Rerun the script."
    done
    [ -x "$PREFIX/servers/log-omnivox" ] ||
        die "Self-test failed: $PREFIX/servers/log-omnivox is missing. Rerun the script."
    init_loads omnivox omnivox-voices ||
        die "Self-test failed: Emacs could not load omnivox-voices from $INIT. See $LOG"
    passed "both names are listed, and omnivox-voices loads."

    self_test omnivox 5 5 "the OmniVox server starts the way Emacs starts it"
    if [ "$sound" = yes ]; then
        timeout 30 "$omnivox" </dev/null >>"$LOG" 2>&1 ||
            die "Self-test failed: the OmniVox server did not start or exit cleanly. See $LOG"
        passed "the server started and exited cleanly."
    else
        skipped "no sound output device, which the OmniVox server needs to start"
    fi
}

dectalk_tests() {
    local wav=$SELFTEST_DIR/dectalk.wav bytes
    mkdir -p "$SELFTEST_DIR"
    self_test dectalk 1 3 "DECtalk synthesizes speech (into a wav file)"
    : > "$wav"
    timeout 60 "$DECTALK_HOME/say" -fo "$wav" -a "DECtalk is installed." >>"$LOG" 2>&1 ||
        die "Self-test failed: $DECTALK_HOME/say did not run. See $LOG"
    bytes=$(stat -c%s "$wav")
    [ "$bytes" -gt 1000 ] || die "Self-test failed: DECtalk's say wrote no audio"
    passed "$bytes bytes of speech in $wav."

    self_test dectalk 2 3 "tcldtk.so loads in $TCLSH"
    glue_loads "$DTK_SO" synth 2>>"$LOG" ||
        die "Self-test failed: $DTK_SO does not load. See $LOG"
    passed "the DECtalk glue loads."

    self_test dectalk 3 3 "the dtk-soft server starts the way Emacs starts it"
    EMACSPEAK_DIR=$PREFIX timeout 30 "$PREFIX/servers/dtk-soft" </dev/null >>"$LOG" 2>&1 ||
        die "Self-test failed: $PREFIX/servers/dtk-soft did not run. See $LOG"
    passed "the server started and exited cleanly."
}

voxin_tests() {
    local wav=$SELFTEST_DIR/voxin.wav bytes
    mkdir -p "$SELFTEST_DIR"
    self_test voxin 1 4 "libibmeci.so leads to Voxin's library"
    [ "$(readlink -f "$SYS_LIBDIR/libibmeci.so")" = \
      "$(readlink -f "$VOXIN_HOME/lib/libvoxin.so.1")" ] ||
        die "Self-test failed: $SYS_LIBDIR/libibmeci.so does not lead to \
$VOXIN_HOME/lib/libvoxin.so.1. Rerun with --voxin-archive FILE."
    passed "$SYS_LIBDIR/libibmeci.so leads to $VOXIN_HOME/lib/libvoxin.so.1."

    self_test voxin 2 4 "voxin-say synthesizes speech (into a wav file)"
    : > "$wav"
    ECIINI=$ECIINI_FILE timeout 60 "$VOXIN_HOME/bin/voxin-say" -w "$wav" \
        "Voxin is installed." >>"$LOG" 2>&1 ||
        die "Self-test failed: voxin-say did not run. See $LOG"
    bytes=$(stat -c%s "$wav")
    [ "$bytes" -gt 1000 ] || die "Self-test failed: voxin-say wrote no audio, \
so libvoxin could not find the engine. Check that /opt/IBM/ibmtts/lib exists."
    passed "$bytes bytes of speech in $wav."

    self_test voxin 3 4 "atcleci.so finds the libraries it needs"
    if ldd "$ECI_SO" 2>>"$LOG" | grep -q 'not found'; then
        die "Self-test failed: $ECI_SO lacks a library: $(ldd "$ECI_SO" | grep 'not found' | head -n 1)"
    fi
    passed "the Voxin glue's libraries are all found."

    self_test voxin 4 4 "the outloud server starts the way Emacs starts it"
    if ! compgen -G '/dev/snd/pcmC*p' >/dev/null; then
        skipped "no sound device, which the outloud server needs to start"
    elif ECIINI=$ECIINI_FILE timeout 30 "$PREFIX/servers/outloud" </dev/null >>"$LOG" 2>&1; then
        passed "the server started and exited cleanly."
    else
        warned "the outloud server did not start; as root it may not reach \
your sound device. Try DTK_PROGRAM=outloud emacspeak as your normal user"
    fi
}

if [ "$RUN_TESTS" = yes ]; then
    general_tests
    for e in $SELECTED; do "${e}_tests"; done
fi

# The record of this choice, for the next run without --speech.
printf '%s\n' $SELECTED > "$RECORD"

# Engines an earlier run installed that are not chosen this time stay
# usable. OTHER is a second server, for the example in the summary.
EARLIER=""
OTHER=""
for e in $SELECTED; do
    if [ -z "$OTHER" ] && [ "$(engine_server "$e")" != "$DEFAULT_SERVER" ]; then
        OTHER=$(engine_server "$e")
    fi
done
for e in $ENGINES; do
    if is_selected "$e"; then continue; fi
    case "$e" in
        espeak)  [ -f "$ESPEAK_SO" ] || continue ;;
        omnivox) [ -x "$PREFIX/servers/omnivox" ] || continue ;;
        dectalk) [ -f "$DTK_SO" ] && [ -x "$DECTALK_HOME/say" ] || continue ;;
        voxin)   [ -f "$ECI_SO" ] && voxin_installed || continue ;;
    esac
    EARLIER="${EARLIER:+$EARLIER, }$(engine_title "$e") (server $(engine_server "$e"))"
    [ -n "$OTHER" ] || OTHER=$(engine_server "$e")
done

# --------------------------------------------------------------------------
log "Done: emacspeak is installed"
echo "Speech engines, in order of preference:"
for e in $SELECTED; do
    echo "$(engine_title "$e"): $(group_status "$e"), server $(engine_server "$e"). $(group_detail "$e")."
done
if [ "$RUN_TESTS" = yes ]; then
    echo "General self-tests: $(group_status general). $(group_detail general)."
fi
if [ -n "$EARLIER" ]; then
    echo "Still installed from an earlier run: $EARLIER."
fi
cat <<DONE
Emacspeak is in $PREFIX
Launcher: $LAUNCHER, default server $DEFAULT_SERVER
Init file: $INIT
Engines recorded in: $RECORD
Build log: $LOG

To start it, run this as your normal user (not root):
  emacspeak

DONE
if [ -n "$OTHER" ]; then
    echo "To start with another server, set DTK_PROGRAM, for example:"
    echo "  DTK_PROGRAM=$OTHER emacspeak"
    echo "Inside Emacs, M-x dtk-select-server switches to another server."
else
    if [ "$SELECTED" = espeak ]; then more=espeak,dectalk; else more=$SELECTED,espeak; fi
    echo "Only one engine is installed. To add more, rerun with --speech,"
    echo "such as: --speech $more"
    echo "Then DTK_PROGRAM=<server> emacspeak starts another server,"
    echo "and inside Emacs, M-x dtk-select-server switches servers."
fi
cat <<DONE

The launcher starts console Emacs without your own init file (-q).
To load emacspeak from your own Emacs init file instead, put this
line at the very top of ~/.emacs or ~/.emacs.d/init.el:
  (load-file "$INIT")

To update emacspeak later, run this script again. It reuses the
recorded engines; --speech chooses others.
DONE
