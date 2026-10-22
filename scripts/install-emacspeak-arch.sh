#!/usr/bin/env bash
# install-emacspeak-arch.sh: emacspeak with a choice of speech engines on
# Arch Linux and its family (CachyOS, EndeavourOS, Manjaro).
#
# The speech engines, chosen with --speech or from a numbered menu:
#   espeak   eSpeak NG through emacspeak's own espeak server (the default)
#   omnivox  OmniVox, an emacspeak speech server written in Rust. It has no
#            Linux release, so its v1.3.0 tag is built from source. On Linux
#            it speaks with eSpeak NG, which its build compiles into it.
#   dectalk  software DECtalk, built from github.com/dectalk/dectalk into
#            /opt/dectalk, for emacspeak's dtk-soft server
#   voxin    Eloquence, from a Voxin archive bought at voxin.oralux.net,
#            for emacspeak's outloud server
#
# Emacspeak's own speech servers (espeak, dtk-soft, outloud) are Tcl
# scripts that need Tcl 8.6 and TclX. Arch's tcl package is still Tcl 8.6
# (8.6.16 when this was written, in October 2026), so the servers'
# #!/usr/bin/tclsh line already finds the right Tcl and no shebang needs
# changing. Arch does not package TclX, though, so this script builds TclX
# from source when it is missing. OmniVox needs no Tcl.

set -euo pipefail

PREFIX=/opt/emacspeak
REPO=https://github.com/tvraman/emacspeak.git
REF=master
SKIP_DEPS=no
RUN_TESTS=yes
SPEECH_GIVEN=no
SPEECH_ARG=""
VOXIN_ARCHIVE=""
TCLSH=/usr/bin/tclsh
LAUNCHER=/usr/local/bin/emacspeak
LOG=/var/log/install-emacspeak-arch.log
MARKER="Written by install-emacspeak-arch.sh"
# The speech engines this script offers, in menu order.
ENGINES=(espeak omnivox dectalk voxin)
# Packages, by engine. gcc includes g++, and libpulse provides paplay and
# pactl, which emacspeak uses for its auditory icons. Arch's packages
# include their headers; there are no -devel packages.
BASE_PACKAGES=(git make gcc sox libpulse)
ESPEAK_PACKAGES=(tcl espeak-ng)
# OmniVox's eSpeak NG crate compiles its own eSpeak NG with cmake and runs
# bindgen, which needs libclang (from clang); its sound crate finds ALSA
# with pkg-config. It does not use Arch's espeak-ng package (see
# install_omnivox for what that package's libraries would break).
OMNIVOX_PACKAGES=(rust cmake clang alsa-lib pkgconf)
DECTALK_PACKAGES=(tcl autoconf automake pkgconf alsa-lib)
# Voxin's speech engine is a 32-bit program, so it needs 32-bit libraries
# from Arch's [multilib] repository.
VOXIN_PACKAGES=(tcl alsa-lib xz lib32-glibc lib32-gcc-libs)
# TclX is pinned to a release tag, which ships its configure script, so
# autoconf is not needed. TCLX_DIR is where its package folder ends up.
TCLX_REPO=https://github.com/flightaware/tclx.git
TCLX_REF=v8.6.3
TCLX_DIR=/usr/lib/tclx8.6
OMNIVOX_REPO=https://github.com/robertmeta/omnivox.git
OMNIVOX_TAG=v1.3.0
DECTALK_REPO=https://github.com/dectalk/dectalk.git
DECTALK_REF=develop
# emacspeak's DECtalk.conf names dictionaries under /opt/dectalk, so
# DECtalk goes there.
DECTALK_DIR=/opt/dectalk
VOXIN_DIR=/opt/oralux/voxin
ECIINI_FILE=/var/opt/IBM/ibmtts/cfg/eci.ini

usage() {
    cat <<USAGE
Usage: sudo bash install-emacspeak-arch.sh [options]

Installs emacspeak on Arch Linux, CachyOS, EndeavourOS or Manjaro,
with one or more speech engines.
Run it again later to update emacspeak and rebuild it.

Options:
  --speech LIST         speech engines, separated by commas, such as
                        espeak,dectalk. The first one is the launcher's
                        default. all means espeak, omnivox and dectalk,
                        plus voxin when --voxin-archive is given.
                        list shows the engines and what each needs.
                        Without --speech: the engines of the last run,
                        or else a menu in a terminal, or else espeak.
  --voxin-archive FILE  the Voxin archive, such as voxin-enu-v3.x.tar.gz,
                        bought at voxin.oralux.net; adds voxin
  --prefix DIR          where emacspeak is cloned and built
                        (default $PREFIX)
  --repo URL            emacspeak git repository (default $REPO)
  --ref REF             branch or tag to build (default $REF)
  --skip-deps           do not run pacman; you installed the packages yourself
  --no-test             skip the self-tests at the end
  --help                show this help

Packages it installs with pacman:
  always:  ${BASE_PACKAGES[*]}, and emacs if no Emacs is installed
  espeak:  ${ESPEAK_PACKAGES[*]}
  omnivox: ${OMNIVOX_PACKAGES[*]}
           (not rust when cargo or rustup is already installed)
  dectalk: ${DECTALK_PACKAGES[*]}
  voxin:   ${VOXIN_PACKAGES[*]},
           after enabling [multilib] in /etc/pacman.conf
Arch supports only full upgrades, so installing them also upgrades the
whole system (pacman -Syu).
Arch does not package TclX: when an engine needs it and it is missing,
this script builds it from source into $TCLX_DIR, even with --skip-deps.
Build output goes to $LOG.
USAGE
}

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'Warning: %s\n' "$*"; }

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
# sub-make then takes for a target and fails; a MAKEFLAGS such as -s set in
# the environment does the same. Arch ships make 4.4, which is fine, but run
# make from inside the directory anyway, without flags inherited from
# outside, so this script matches its Debian and Fedora siblings.
make_in() { # $1 = directory, then the make arguments
    local dir=$1; shift
    ( cd "$dir" && env -u MAKEFLAGS -u MFLAGS make "$@" )
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
glue_check() { # $1 = path of a speech server's Tcl glue library
    timeout 30 "$TCLSH" <<TCL
if {[catch {load {$1}} err]} {puts stderr \$err; exit 1}
if {[info commands say] ne "say"} {puts stderr "no say command"; exit 1}
TCL
}
emacs_new_enough() {
    emacs -Q --batch --eval '(kill-emacs (if (version<= "29.1" emacs-version) 0 1))' \
        2>>"$LOG"
}

# --------------------------------------------------------------------------
# The speech engines: names, servers, and what each needs.
engine_label() {
    case $1 in
        espeak) echo espeak ;; omnivox) echo OmniVox ;;
        dectalk) echo DECtalk ;; voxin) echo Voxin ;;
    esac
}
engine_server() {
    case $1 in
        espeak) echo espeak ;; omnivox) echo omnivox ;;
        dectalk) echo dtk-soft ;; voxin) echo outloud ;;
    esac
}
engine_about() {
    case $1 in
        espeak)  echo "free, eSpeak NG voices through emacspeak's own server" ;;
        omnivox) echo "free, OmniVox, a Rust server speaking with eSpeak NG, built from source" ;;
        dectalk) echo "free, software DECtalk, built from source" ;;
        voxin)   echo "paid, Eloquence voices from a Voxin archive" ;;
    esac
}
engine_needs() {
    case $1 in
        espeak)  echo "Server espeak. Needs ${ESPEAK_PACKAGES[*]}, and TclX, which it builds from source when missing." ;;
        omnivox) echo "Server omnivox. Needs ${OMNIVOX_PACKAGES[*]}, and a few minutes to build OmniVox ${OMNIVOX_TAG#v}." ;;
        dectalk) echo "Server dtk-soft. Needs ${DECTALK_PACKAGES[*]}, TclX, and a few minutes to build DECtalk into $DECTALK_DIR." ;;
        voxin)   echo "Server outloud. Needs --voxin-archive FILE, bought at voxin.oralux.net, the [multilib] repository, ${VOXIN_PACKAGES[*]}, and TclX." ;;
    esac
}
print_engine_list() {
    local e default
    for e in "${ENGINES[@]}"; do
        default=""
        [ "$e" != espeak ] || default=" (default)"
        printf '%s: %s%s. %s\n' "$e" "$(engine_about "$e")" "$default" "$(engine_needs "$e")"
    done
}

SELECTED=()
is_selected() {
    local e
    for e in "${SELECTED[@]}"; do [ "$e" != "$1" ] || return 0; done
    return 1
}
select_engine() { is_selected "$1" || SELECTED+=("$1"); }
labels_of() { # the display names of the engines given, separated by commas
    local e out=""
    for e in "$@"; do out="${out:+$out, }$(engine_label "$e")"; done
    printf '%s' "$out"
}

# Sets SELECTED from a --speech value. "list" prints the engines and exits.
parse_speech() { # $1 = the --speech value
    local value name parts=()
    value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    IFS=, read -r -a parts <<<"$value" || true
    for name in "${parts[@]}"; do
        name=${name//[[:space:]]/}
        if [ "$name" = list ]; then print_engine_list; exit 0; fi
    done
    SELECTED=()
    for name in "${parts[@]}"; do
        name=${name//[[:space:]]/}
        case $name in
            '') ;;
            all)
                select_engine espeak; select_engine omnivox; select_engine dectalk
                if [ -n "$VOXIN_ARCHIVE" ]; then select_engine voxin; fi ;;
            espeak|omnivox|dectalk|voxin) select_engine "$name" ;;
            *)
                print_engine_list >&2
                die "unknown speech engine \"$name\". Choose from: $(IFS=,; printf '%s' "${ENGINES[*]}" | sed 's/,/, /g'), separated by commas." ;;
        esac
    done
    [ ${#SELECTED[@]} -gt 0 ] || die "--speech names no engine. Try --speech list"
}

voxin_installed() {
    [ -e "$VOXIN_DIR/lib/libvoxin.so.1" ] && [ -d /opt/IBM/ibmtts/lib ] && [ -f "$ECIINI_FILE" ]
}
VOXIN_NEEDS_ARCHIVE="Voxin needs its archive: rerun with --voxin-archive FILE. The archive, such as voxin-enu-v3.x.tar.gz, is sold at voxin.oralux.net."

run_menu() {
    local i e note answer n ok
    local tokens=()
    echo "Which speech engines should emacspeak get?"
    i=1
    for e in "${ENGINES[@]}"; do
        note=""
        case $e in
            espeak) note=" (default)" ;;
            voxin)
                if [ -n "$VOXIN_ARCHIVE" ]; then note=", from the archive you gave"
                elif voxin_installed; then note=", already installed"
                else note="; needs --voxin-archive FILE"; fi ;;
        esac
        printf '%d) %s: %s%s\n' "$i" "$e" "$(engine_about "$e")" "$note"
        i=$((i + 1))
    done
    while :; do
        printf 'Numbers separated by spaces, or Enter for the default [1]: '
        if ! IFS= read -r answer; then
            echo
            die "no answer came. Run the script again, or choose with --speech (try --speech list)."
        fi
        SELECTED=()
        ok=yes
        read -r -a tokens <<<"${answer//,/ }" || true
        for n in "${tokens[@]}"; do
            case $n in
                [1-9]) if [ "$n" -le ${#ENGINES[@]} ]; then
                           select_engine "${ENGINES[$((n - 1))]}"
                       else ok=no; fi ;;
                *) ok=no ;;
            esac
        done
        if [ "$ok" = no ]; then
            echo "Please answer with numbers from 1 to ${#ENGINES[@]}, such as: 1 3"
            continue
        fi
        if [ ${#tokens[@]} -eq 0 ]; then SELECTED=(espeak); fi
        if is_selected voxin && [ -z "$VOXIN_ARCHIVE" ] && ! voxin_installed; then
            echo "$VOXIN_NEEDS_ARCHIVE"
            echo "Choose again without 4, or press Ctrl+C to stop."
            continue
        fi
        break
    done
    echo "Selected: $(labels_of "${SELECTED[@]}")."
}

# The engines of the last run, one name per line in $RECORD.
read_record() {
    local name
    SELECTED=()
    [ -f "$RECORD" ] || return 1
    while IFS= read -r name || [ -n "$name" ]; do
        name=${name//[[:space:]]/}
        case $name in
            '') ;;
            espeak|omnivox|dectalk|voxin) select_engine "$name" ;;
            *) warn "ignoring \"$name\" in $RECORD: it is not a speech engine." ;;
        esac
    done <"$RECORD"
    [ ${#SELECTED[@]} -gt 0 ]
}

# Checks the Voxin archive's file list before anything is installed, so a
# wrong file stops the script before pacman upgrades the system.
check_voxin_archive() {
    local listing arch
    arch=$(uname -m)
    [ -f "$VOXIN_ARCHIVE" ] && [ -r "$VOXIN_ARCHIVE" ] ||
        die "no such file: $VOXIN_ARCHIVE (given with --voxin-archive)"
    listing=$(tar -tf "$VOXIN_ARCHIVE" 2>>"$LOG") ||
        die "tar cannot read $VOXIN_ARCHIVE. Give the Voxin archive, such as voxin-enu-v3.x.tar.gz, from voxin.oralux.net."
    grep -Eq '(^|/)voxin-installer\.sh$' <<<"$listing" ||
        die "$VOXIN_ARCHIVE does not look like a Voxin 3.x archive: it has no voxin-installer.sh."
    grep -Eq "(^|/)packages/all/rfs_[^/]*\.$arch\.txz\$" <<<"$listing" ||
        die "$VOXIN_ARCHIVE has no Voxin runtime for $arch (packages/all/rfs_*.$arch.txz)."
    grep -Eq '(^|/)packages/all/rfs_[^/]*\.all\.txz$' <<<"$listing" ||
        die "$VOXIN_ARCHIVE has no packages/all/rfs_*.all.txz; it does not look like a Voxin 3.x archive."
    grep -Eq '(^|/)packages/all/voxin-viavoice-all_[^/]*\.txz$' <<<"$listing" ||
        die "$VOXIN_ARCHIVE has no ViaVoice engine (packages/all/voxin-viavoice-all_*.txz)."
}

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

add_packages() {
    local p q
    for p in "$@"; do
        for q in "${PACKAGES[@]}"; do [ "$q" != "$p" ] || continue 2; done
        PACKAGES+=("$p")
    done
}

# Uncomments Arch's standard [multilib] block, or adds one, before the one
# pacman -Syu, which then syncs it too. The original is kept beside it.
enable_multilib() {
    if grep -q '^\[multilib\]' /etc/pacman.conf; then
        echo "The [multilib] repository is already enabled."
        return 0
    fi
    log "Enabling the [multilib] repository in /etc/pacman.conf (Voxin's 32-bit engine needs it)"
    [ -e /etc/pacman.conf.before-multilib ] ||
        cp -p /etc/pacman.conf /etc/pacman.conf.before-multilib
    sed -i '/^#\[multilib\]/,/^#Include = \/etc\/pacman.d\/mirrorlist/ s/^#//' \
        /etc/pacman.conf
    if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
        printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >>/etc/pacman.conf
    fi
    echo "Enabled. The original is in /etc/pacman.conf.before-multilib."
}

# --------------------------------------------------------------------------
# The install steps of each engine. They run after emacspeak is built.
install_espeak() {
    log "espeak: building tclespeak.so, the espeak glue, against Tcl 8.6"
    # Arch's tcl package puts the 8.6 headers straight into /usr/include.
    logged "building tclespeak.so" make_in "$PREFIX/servers/native-espeak" -B \
        TCL_INCLUDE=/usr/include LIBS="-ltcl8.6 -lespeak-ng"
    [ -f "$ESPEAK_SO" ] || die "the build finished but $ESPEAK_SO is missing"
    echo "Built $ESPEAK_SO"
}

# OmniVox is built in $OMNIVOX_DIR/src and stays there: the binary reads
# eSpeak NG's voice data from that build folder. Cargo's downloads go to
# $OMNIVOX_DIR/cargo-home, not to root's home folder.
install_omnivox() {
    local want installed
    want="${OMNIVOX_TAG#v} source"
    installed=$(cat "$OMNIVOX_DIR/installed-version" 2>/dev/null || true)
    if [ "$installed" = "$want" ] && [ -x "$OMNIVOX" ] &&
       [ -f "$OMNIVOX_DIR/elisp/omnivox-voices.el" ]; then
        log "OmniVox ${OMNIVOX_TAG#v} is already built and installed; keeping it"
    else
        mkdir -p "$OMNIVOX_DIR"
        if [ -d "$OMNIVOX_DIR/src/.git" ]; then
            log "OmniVox: updating the source in $OMNIVOX_DIR/src to $OMNIVOX_TAG"
            logged "fetching OmniVox $OMNIVOX_TAG" git -C "$OMNIVOX_DIR/src" fetch -q \
                --depth 1 origin "refs/tags/$OMNIVOX_TAG:refs/tags/$OMNIVOX_TAG"
            logged "checking out OmniVox $OMNIVOX_TAG" git -C "$OMNIVOX_DIR/src" \
                -c advice.detachedHead=false checkout -q "$OMNIVOX_TAG"
        else
            log "OmniVox: cloning $OMNIVOX_TAG into $OMNIVOX_DIR/src"
            logged "cloning OmniVox" git -c advice.detachedHead=false clone -q \
                --depth 1 --branch "$OMNIVOX_TAG" "$OMNIVOX_REPO" "$OMNIVOX_DIR/src"
        fi
        # Arch's espeak-ng package brings pcaudiolib and libsonic. The eSpeak
        # NG that OmniVox compiles (crate espeak-rs-sys 0.1.9) finds both and
        # builds against them, but the crate never links them, so the link
        # fails with undefined symbols such as create_audio_device_object and
        # sonicDestroyStream. This cache file turns pcaudio off (OmniVox plays
        # sound itself) and has eSpeak NG build its own copy of sonic: the
        # same build as on a system without espeak-ng. The crate takes no
        # cmake options, so CMake gets the file as CMAKE_TOOLCHAIN_FILE.
        cat >"$OMNIVOX_DIR/espeak-ng-options.cmake" <<'CMAKE'
# Written by install-emacspeak-arch.sh for the eSpeak NG inside OmniVox.
set(USE_LIBPCAUDIO OFF CACHE BOOL "OmniVox plays sound itself" FORCE)
set(SONIC_LIB OFF CACHE FILEPATH "Build eSpeak NG's own copy of sonic" FORCE)
CMAKE
        log "OmniVox: building ${OMNIVOX_TAG#v} with cargo (a few minutes; it compiles eSpeak NG too)"
        logged "cargo build" env CARGO_HOME="$OMNIVOX_DIR/cargo-home" \
            CMAKE_TOOLCHAIN_FILE="$OMNIVOX_DIR/espeak-ng-options.cmake" \
            cargo build --release --manifest-path "$OMNIVOX_DIR/src/Cargo.toml"
        mkdir -p "$OMNIVOX_DIR/elisp"
        cp "$OMNIVOX_DIR/src/elisp/omnivox-voices.el" "$OMNIVOX_DIR/elisp/omnivox-voices.el"
        # Copy, then rename over the old binary, so a running server keeps its file.
        cp "$OMNIVOX_DIR/src/target/release/omnivox" "$OMNIVOX.new"
        chmod 0755 "$OMNIVOX.new"
        mv -f "$OMNIVOX.new" "$OMNIVOX"
        # OmniVox's README registers the same binary under the name log-omnivox.
        ln -sfn omnivox "$PREFIX/servers/log-omnivox"
        printf '%s\n' "$want" >"$OMNIVOX_DIR/installed-version"
        echo "Installed $OMNIVOX, and log-omnivox beside it."
    fi
    register_omnivox
    echo "Listed in $SERVERS_LIST: omnivox, log-omnivox."
}

# DECtalk's develop branch built with Arch's gcc 16.2.1 and a plain
# ./configure when this was tested (commit 986ea12, October 2026), so no
# extra flags are passed. If a newer gcc rejects its 1990s C, the flags
# install-emacspeak-voxin.sh uses also build it: ./configure
# CFLAGS="-O2 -fpermissive -Wno-implicit-function-declaration".
# A rerun rebuilds DECtalk only when the develop branch has moved.
install_dectalk() {
    local remote installed src
    installed=$(cat "$DECTALK_DIR/installed-commit" 2>/dev/null || true)
    remote=$(git ls-remote "$DECTALK_REPO" "refs/heads/$DECTALK_REF" 2>>"$LOG" |
             awk '{ print $1; exit }') || remote=""
    if [ -n "$installed" ] && [ -x "$DECTALK_DIR/say" ] && [ -e "$DECTALK_DIR/lib/libtts.so" ] &&
       { [ -z "$remote" ] || [ "$remote" = "$installed" ]; }; then
        log "DECtalk ${installed:0:7} is already built and installed in $DECTALK_DIR; keeping it"
        [ -n "$remote" ] || warn "could not reach $DECTALK_REPO to look for a newer DECtalk."
    else
        src=$(mktemp -d /tmp/emacspeak-dectalk.XXXXXXXX)
        log "DECtalk: cloning its $DECTALK_REF branch into $src"
        logged "cloning DECtalk" git clone -q --depth 1 --branch "$DECTALK_REF" \
            "$DECTALK_REPO" "$src"
        echo "DECtalk source: $(git -C "$src" log -1 --format='commit %h of %cd' --date=short)"
        log "DECtalk: building it (a few minutes)"
        (cd "$src/src" && logged "DECtalk's autogen.sh" ./autogen.sh)
        (cd "$src/src" && logged "configuring DECtalk" ./configure)
        logged "building DECtalk" make_in "$src/src" -j"$(nproc)"
        [ -x "$src/dist/say" ] && [ -d "$src/dist/lib" ] ||
            die "the DECtalk build finished, but $src/dist has no say program or lib folder. See $LOG"
        log "DECtalk: installing it into $DECTALK_DIR"
        mkdir -p "$DECTALK_DIR/include/dtk"
        cp -a "$src/dist/." "$DECTALK_DIR/"
        # The dist tree does not carry the C headers, and emacspeak's tcldtk.c
        # wants them as <dtk/ttsapi.h>, so stage them under include/dtk.
        cp "$src/src/dapi/src/include/"*.h "$DECTALK_DIR/include/dtk/"
        # Some builds produce only the per-language libtts_us.so.
        [ -e "$DECTALK_DIR/lib/libtts.so" ] || ln -s libtts_us.so "$DECTALK_DIR/lib/libtts.so"
        git -C "$src" rev-parse HEAD >"$DECTALK_DIR/installed-commit"
        echo "Installed. The build folder $src is no longer needed; /tmp is emptied at reboot."
    fi
    echo "$DECTALK_DIR/lib" >/etc/ld.so.conf.d/dectalk.conf
    ldconfig
    # libtts falls back to $DECTALK_DIR/DECtalk.conf. emacspeak ships one
    # whose dictionary paths are already absolute /opt/dectalk/dic entries.
    cp "$PREFIX/servers/software-dtk/DECtalk.conf" "$DECTALK_DIR/DECtalk.conf"
    log "DECtalk: building tcldtk.so, the Tcl glue for the dtk-soft server"
    # Command-line variables replace the Makefile's, so repeat its flags.
    # tcl.h comes from /usr/include, where Arch's tcl package puts it.
    logged "building tcldtk.so" make_in "$PREFIX/servers/software-dtk" -B \
        CFLAGS="-g -O2 -fPIC -DPIC -I$DECTALK_DIR/include" \
        LDFLAGS="-L$DECTALK_DIR/lib" \
        LIBS="-ltcl8.6 -ltts -ltts_us -ldl"
    [ -f "$DTK_SO" ] || die "the build finished but $DTK_SO is missing"
    echo "Built $DTK_SO"
}

# What Voxin's own installer does, done the same way every time:
#   rfs_<arch>.txz              -> /opt/oralux/voxin/{lib,bin}  (libvoxin, voxin-say)
#   rfs_all.txz                 -> /opt/oralux/voxin/{include,rfs32}  (32-bit world)
#   voxin-viavoice-all_*.txz    -> /opt/IBM/ibmtts  (the engine)
#   voxin-viavoice-<lang>_*.txz -> its voice libraries and /var/opt/IBM data
install_voxin() {
    local stage installer tree arch t langs l inidir
    if [ -z "$VOXIN_ARCHIVE" ]; then
        log "Voxin is already installed; keeping it"
        echo "To reinstall it, run again with --voxin-archive FILE."
    else
        stage=$(mktemp -d /tmp/emacspeak-voxin.XXXXXXXX)
        log "Voxin: unpacking $VOXIN_ARCHIVE into $stage"
        logged "unpacking the Voxin archive" tar -xf "$VOXIN_ARCHIVE" -C "$stage"
        installer=$(find "$stage" -name voxin-installer.sh -print -quit)
        [ -n "$installer" ] ||
            die "this does not look like a Voxin 3.x archive: it has no voxin-installer.sh"
        tree=$(dirname "$installer")
        arch=$(uname -m)
        log "Voxin: extracting its runtime for $arch into $VOXIN_DIR"
        for t in "$tree"/packages/all/rfs_*."$arch".txz "$tree"/packages/all/rfs_*.all.txz; do
            [ -e "$t" ] || die "the Voxin archive lacks $(basename "$t")"
            echo "Extracting ${t##*/}"
            logged "extracting ${t##*/} from the Voxin archive" \
                tar -C / --no-overwrite-dir -xf "$t"
        done
        log "Voxin: extracting the ViaVoice engine and voices into /opt/IBM"
        for t in "$tree"/packages/all/voxin-viavoice-all_*.txz; do
            [ -e "$t" ] || die "the Voxin archive has no voxin-viavoice-all engine tarball"
            echo "Extracting ${t##*/}"
            logged "extracting ${t##*/} from the Voxin archive" \
                tar -C / --no-overwrite-dir -xf "$t"
        done
        for t in "$tree"/packages/all/voxin-viavoice-*.txz; do
            case $t in */voxin-viavoice-all_*) continue ;; esac
            echo "Extracting ${t##*/}"
            logged "extracting ${t##*/} from the Voxin archive" \
                tar -C / --no-overwrite-dir -xf "$t"
        done
        # eci.ini: the engine's all.ini, then one section per installed
        # language (a language is there when its xxx50.so library is).
        log "Voxin: writing $ECIINI_FILE"
        inidir=/opt/IBM/ibmtts/etc
        mkdir -p "${ECIINI_FILE%/*}"
        langs=$(find /opt/IBM/ibmtts/lib -name '???50.so' | sed 's+.*/\(...\)50.so+\1+')
        [ -n "$langs" ] || die "no ViaVoice language libraries found under /opt/IBM/ibmtts/lib"
        cp "$inidir/all.ini" "$ECIINI_FILE"
        for l in $langs; do
            echo "Language: $l"
            cat "$inidir/$l.ini" >>"$ECIINI_FILE"
        done
        echo "The unpacked archive in $stage is no longer needed; /tmp is emptied at reboot."
    fi
    # libvoxin.so.1 is the 64-bit ECI library; Voxin's own packages link the
    # name libibmeci.so to it. atcleci.so dlopens libibmeci.so, which looks
    # in the trusted system libdir, /usr/lib on Arch; the ld.so.conf.d entry
    # lets voxin-say find libvoxin.so.1. pacman does not track these links.
    log "Voxin: linking libibmeci.so into /usr/lib"
    [ -e "$VOXIN_DIR/lib/libvoxin.so.1" ] || die "$VOXIN_DIR/lib/libvoxin.so.1 is missing"
    ln -sf "$VOXIN_DIR/lib/libvoxin.so.1" /usr/lib/libibmeci.so
    echo "$VOXIN_DIR/lib" >/etc/ld.so.conf.d/voxin.conf
    ldconfig
    ln -sf "$VOXIN_DIR/bin/voxin-say" /usr/local/bin/voxin-say
    # ECIINI tells the engine where its settings are. It is set for login
    # shells here, and again by emacspeak-init.el.
    echo "export ECIINI=$ECIINI_FILE" >/etc/profile.d/voxin.sh
    log "Voxin: building atcleci.so, the Tcl glue for the outloud server"
    # It dlopens libibmeci.so when it loads, and speaks through ALSA.
    logged "building atcleci.so" make_in "$PREFIX/servers/linux-outloud" -B \
        CFLAGS="-g -O2 -fPIC -DPIC -std=c++11" \
        LIBS="-ltcl8.6 -lasound -ldl"
    [ -f "$OUTLOUD_SO" ] || die "the build finished but $OUTLOUD_SO is missing"
    echo "Built $OUTLOUD_SO"
}

# --------------------------------------------------------------------------
# Self-tests. Each engine has its own numbered tests. A test that needs a
# sound device is skipped, with the reason, when none is available.
RESULT_espeak=Skipped; RESULT_omnivox=Skipped
RESULT_dectalk=Skipped; RESULT_voxin=Skipped
WARNINGS=()
SKIPS=()
set_result() { printf -v "RESULT_$1" '%s' "$2"; }
get_result() { local v="RESULT_$1"; printf '%s' "${!v}"; }
test_warn() { # $1 = engine, $2 = test number, $3 = what happened
    set_result "$1" Warning
    WARNINGS+=("$(engine_label "$1") test $2, $3")
    warn "$3."
}
test_skip() { # $1 = engine, $2 = test number, $3 = why
    SKIPS+=("$(engine_label "$1") test $2, $3")
    echo "Skipped: $3."
}
# For the Tcl servers: is a sound server reachable for this user (root)?
sound_server() { timeout 10 pactl info >/dev/null 2>&1; }
NO_SOUND="no sound server is reachable for root here, which is normal under sudo and in containers"
# Emacs loads emacspeak-init.el with DTK_PROGRAM set, without speaking,
# and finds the server's program. EMACSPEAK_DIR and ECIINI are cleared, so
# the init file has to set them. $2 adds a Lisp condition.
emacs_finds_server() { # $1 = server name, $2 = extra Lisp condition
    env -u EMACSPEAK_DIR -u ECIINI DTK_PROGRAM="$1" \
        emacs -Q --batch -l "$INIT" --eval "(kill-emacs (if (and
            (featurep 'emacspeak) (equal dtk-program \"$1\")
            (file-executable-p (expand-file-name dtk-program emacspeak-servers-directory))
            $2) 0 1))" >>"$LOG" 2>&1
}

test_espeak() {
    local info bytes
    set_result espeak Pass
    log "espeak test 1 of 4: tclespeak.so loads in $TCLSH"
    info=$(espeak_glue_check "$ESPEAK_SO" 2>>"$LOG") ||
        die "espeak test 1 failed: $ESPEAK_SO does not load. See $LOG"
    echo "Pass: $info."

    log "espeak test 2 of 4: the espeak server starts the way Emacs starts it"
    timeout 30 "$PREFIX/servers/espeak" </dev/null >>"$LOG" 2>&1 ||
        die "espeak test 2 failed: $PREFIX/servers/espeak did not run. See $LOG"
    echo "Pass: the server started and exited cleanly."

    log "espeak test 3 of 4: espeak-ng synthesizes speech (into a pipe)"
    bytes=$(espeak-ng --stdout "Emacspeak is installed." 2>>"$LOG" | wc -c) || bytes=0
    [ "$bytes" -gt 1000 ] || die "espeak test 3 failed: espeak-ng produced no audio"
    echo "Pass: $bytes bytes of audio."

    log "espeak test 4 of 4: Emacs loads emacspeak-init.el and finds the espeak server"
    emacs_finds_server espeak "" ||
        die "espeak test 4 failed: Emacs could not load $INIT, or emacspeak does not find its espeak server. See $LOG"
    echo "Pass: emacspeak loads with DTK_PROGRAM=espeak."
}

test_omnivox() {
    local out voices synth sound=no name
    set_result omnivox Pass
    log "OmniVox test 1 of 6: OmniVox reports its version"
    out=$(timeout 30 "$OMNIVOX" --version 2>>"$LOG") ||
        die "OmniVox test 1 failed: $OMNIVOX --version did not run. See $LOG"
    case $out in
        "omnivox "*) echo "Pass: $out." ;;
        *) die "OmniVox test 1 failed: $OMNIVOX --version printed: $out" ;;
    esac

    log "OmniVox test 2 of 6: OmniVox lists its eSpeak NG voices"
    out=$(timeout 60 "$OMNIVOX" --list-voices 2>>"$LOG") ||
        die "OmniVox test 2 failed: $OMNIVOX --list-voices did not finish. See $LOG"
    printf '%s\n' "$out" >>"$LOG"
    voices=$(sed -n 's/^Found \([0-9][0-9]*\) voices.*/\1/p' <<<"$out")
    [ "${voices:-0}" -ge 1 ] ||
        die "OmniVox test 2 failed: OmniVox found no voices. Its voice data is in its build folder, $OMNIVOX_DIR/src; rerun the script to rebuild it."
    echo "Pass: $voices voices."

    log "OmniVox test 3 of 6: OmniVox's own check synthesizes speech"
    out=$(timeout 120 "$OMNIVOX" --check 2>>"$LOG") ||
        die "OmniVox test 3 failed: $OMNIVOX --check did not run to the end. See $LOG"
    printf '%s\n' "$out" >>"$LOG"
    # The status line under [synthesis], such as "OK - 62256 samples, ...".
    synth=$(awk '/^\[synthesis\]/ { getline; sub(/^[[:space:]]*Status:[[:space:]]*/, "");
                                     print; exit }' <<<"$out")
    if grep -q 'Audio device: OK' <<<"$out"; then sound=yes; fi
    case $synth in
        OK*) echo "Pass: speech synthesized ($synth)." ;;
        *) test_warn omnivox 3 "OmniVox synthesized no speech: ${synth:-no synthesis status}" ;;
    esac

    log "OmniVox test 4 of 6: Emacs loads emacspeak-init.el with OmniVox's voice module"
    emacs_finds_server omnivox "(featurep 'omnivox-voices) (null emacspeak-play-program)" ||
        die "OmniVox test 4 failed: Emacs could not load $INIT with DTK_PROGRAM=omnivox, or does not find $OMNIVOX. See $LOG"
    echo "Pass: emacspeak and omnivox-voices load, and emacspeak finds the server."

    log "OmniVox test 5 of 6: OmniVox is registered as a speech server"
    for name in omnivox log-omnivox; do
        grep -qx "$name" "$SERVERS_LIST" ||
            die "OmniVox test 5 failed: $SERVERS_LIST does not list $name. Rerun the script."
    done
    [ -x "$PREFIX/servers/log-omnivox" ] ||
        die "OmniVox test 5 failed: $PREFIX/servers/log-omnivox is missing. Rerun the script."
    echo "Pass: both names are listed, and log-omnivox is beside omnivox."

    log "OmniVox test 6 of 6: the OmniVox server starts the way Emacs starts it"
    if [ "$sound" = yes ]; then
        timeout 30 "$OMNIVOX" </dev/null >>"$LOG" 2>&1 ||
            die "OmniVox test 6 failed: the server did not start or exit cleanly. See $LOG"
        echo "Pass: the server started and exited cleanly."
    else
        # Without a sound device the server stops at once with "Audio
        # streams init failed", so this test needs one.
        test_skip omnivox 6 "OmniVox found no sound output device for root (omnivox --check)"
    fi
}

test_dectalk() {
    local wav bytes
    set_result dectalk Pass
    log "DECtalk test 1 of 4: DECtalk's say program writes speech to a file"
    wav=$TEST_DIR/dectalk.wav
    timeout 60 "$DECTALK_DIR/say" -fo "$wav" -a "DECtalk is installed." >>"$LOG" 2>&1 ||
        die "DECtalk test 1 failed: $DECTALK_DIR/say did not run. See $LOG"
    bytes=$(stat -c %s "$wav" 2>/dev/null || echo 0)
    [ "$bytes" -gt 1000 ] || die "DECtalk test 1 failed: say produced no audio in $wav"
    echo "Pass: $bytes bytes of speech."

    log "DECtalk test 2 of 4: tcldtk.so loads in $TCLSH"
    if glue_check "$DTK_SO" >>"$LOG" 2>&1; then
        echo "Pass: tcldtk.so loads, and its say command is there."
    elif ! sound_server; then
        test_skip dectalk 2 "tcldtk.so opens the sound device when it loads, and $NO_SOUND"
    else
        die "DECtalk test 2 failed: $DTK_SO does not load. See $LOG"
    fi

    log "DECtalk test 3 of 4: the dtk-soft server starts the way Emacs starts it"
    if EMACSPEAK_DIR=$PREFIX timeout 30 "$PREFIX/servers/dtk-soft" </dev/null >>"$LOG" 2>&1; then
        echo "Pass: the server started and exited cleanly."
    elif ! sound_server; then
        test_skip dectalk 3 "the dtk-soft server needs a sound device, and $NO_SOUND"
    else
        die "DECtalk test 3 failed: $PREFIX/servers/dtk-soft did not run. See $LOG"
    fi

    log "DECtalk test 4 of 4: Emacs loads emacspeak-init.el and finds the dtk-soft server"
    emacs_finds_server dtk-soft "(equal (getenv \"EMACSPEAK_DIR\") \"$PREFIX\")" ||
        die "DECtalk test 4 failed: Emacs could not load $INIT with DTK_PROGRAM=dtk-soft. See $LOG"
    echo "Pass: emacspeak loads with DTK_PROGRAM=dtk-soft, and sets EMACSPEAK_DIR."
}

test_voxin() {
    local wav bytes
    set_result voxin Pass
    log "Voxin test 1 of 4: voxin-say writes speech to a file (no sound device needed)"
    wav=$TEST_DIR/voxin.wav
    ECIINI=$ECIINI_FILE timeout 60 voxin-say -w "$wav" "Voxin is installed." >>"$LOG" 2>&1 ||
        die "Voxin test 1 failed: voxin-say did not run. See $LOG"
    bytes=$(stat -c %s "$wav" 2>/dev/null || echo 0)
    [ "$bytes" -gt 1000 ] ||
        die "Voxin test 1 failed: voxin-say wrote no speech, so libvoxin did not find the engine. Check that /opt/IBM/ibmtts/lib/libibmeci.so exists."
    echo "Pass: $bytes bytes of speech."

    log "Voxin test 2 of 4: atcleci.so loads in $TCLSH"
    if ECIINI=$ECIINI_FILE glue_check "$OUTLOUD_SO" >>"$LOG" 2>&1; then
        echo "Pass: atcleci.so loads, and its say command is there."
    elif ! sound_server; then
        test_skip voxin 2 "atcleci.so opens the sound device when it loads, and $NO_SOUND"
    else
        die "Voxin test 2 failed: $OUTLOUD_SO does not load. See $LOG"
    fi

    log "Voxin test 3 of 4: the outloud server starts the way Emacs starts it"
    if ECIINI=$ECIINI_FILE timeout 30 "$PREFIX/servers/outloud" </dev/null >>"$LOG" 2>&1; then
        echo "Pass: the server started and exited cleanly."
    elif ! sound_server; then
        test_skip voxin 3 "the outloud server needs a sound device, and $NO_SOUND"
    else
        die "Voxin test 3 failed: $PREFIX/servers/outloud did not run. See $LOG"
    fi

    log "Voxin test 4 of 4: Emacs loads emacspeak-init.el and finds the outloud server"
    emacs_finds_server outloud "(equal (getenv \"ECIINI\") \"$ECIINI_FILE\")" ||
        die "Voxin test 4 failed: Emacs could not load $INIT with DTK_PROGRAM=outloud. See $LOG"
    echo "Pass: emacspeak loads with DTK_PROGRAM=outloud, and sets ECIINI."
}

# --------------------------------------------------------------------------
need_value() { [ $# -ge 2 ] || die "$1 needs a value (try --help)"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --speech)        need_value "$@"; SPEECH_ARG=$2; SPEECH_GIVEN=yes; shift ;;
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
[ -z "$VOXIN_ARCHIVE" ] || VOXIN_ARCHIVE=$(realpath -m "$VOXIN_ARCHIVE")
# Parsed after all options, so "--speech all" sees --voxin-archive in any order.
if [ "$SPEECH_GIVEN" = yes ]; then parse_speech "$SPEECH_ARG"; fi
PREFIX=$(realpath -m "$PREFIX")
case "$PREFIX" in
    *'"'*|*\\*) die "--prefix must not contain quotes or backslashes" ;;
esac
RECORD=$PREFIX/speech-engines
INIT=$PREFIX/emacspeak-init.el
SERVERS_LIST=$PREFIX/servers/.servers
OMNIVOX_DIR=$PREFIX/omnivox
OMNIVOX=$PREFIX/servers/omnivox
ESPEAK_SO=$PREFIX/servers/native-espeak/tclespeak.so
DTK_SO=$PREFIX/servers/software-dtk/tcldtk.so
OUTLOUD_SO=$PREFIX/servers/linux-outloud/atcleci.so

# --------------------------------------------------------------------------
log "Checking the system"
[ "$EUID" -eq 0 ] || die "run this as root, for example: sudo bash $0"
[ -r /etc/os-release ] || die "no /etc/os-release; this script is for Arch Linux"
. /etc/os-release
case "${ID:-}" in
    arch|cachyos|endeavouros|manjaro)
        echo "${PRETTY_NAME:-$ID}: supported." ;;
    *)
        case " ${ID_LIKE:-} " in
            *" arch "*) echo "Warning: ${PRETTY_NAME:-this system} is based on Arch but untested; trying anyway." ;;
            *) die "this script is for Arch Linux and its family, and this is ${PRETTY_NAME:-unknown}." ;;
        esac ;;
esac
command -v pacman >/dev/null || die "pacman not found; this script is for Arch Linux"
: > "$LOG"
echo "Build log: $LOG"

# --------------------------------------------------------------------------
log "Choosing the speech engines"
if [ "$SPEECH_GIVEN" = yes ]; then
    echo "Chosen with --speech: $(labels_of "${SELECTED[@]}")."
elif read_record; then
    echo "Using the engines of the last run, recorded in $RECORD: $(labels_of "${SELECTED[@]}")."
    echo "To change them, run again with --speech (try --speech list)."
elif [ -t 0 ] && [ -t 1 ]; then
    run_menu
else
    SELECTED=(espeak)
    echo "No terminal for the menu, so the default engine is used: espeak. Choose others with --speech."
fi
if [ -n "$VOXIN_ARCHIVE" ] && ! is_selected voxin; then
    select_engine voxin
    echo "Voxin is added, because --voxin-archive was given."
fi
DEFAULT_SERVER=$(engine_server "${SELECTED[0]}")
echo "Speech engines: $(labels_of "${SELECTED[@]}"). The launcher's default server: $DEFAULT_SERVER."
if is_selected voxin; then
    if [ -n "$VOXIN_ARCHIVE" ]; then
        check_voxin_archive
        echo "Voxin archive: $VOXIN_ARCHIVE. Its file list looks right."
    elif voxin_installed; then
        echo "Voxin is already installed, so no archive is needed."
    else
        die "$VOXIN_NEEDS_ARCHIVE"
    fi
fi
# The Tcl servers need Tcl 8.6 and TclX; OmniVox does not.
NEED_TCL=no
for e in "${SELECTED[@]}"; do
    case $e in espeak|dectalk|voxin) NEED_TCL=yes ;; esac
done

PACKAGES=()
add_packages "${BASE_PACKAGES[@]}"
if is_selected espeak; then add_packages "${ESPEAK_PACKAGES[@]}"; fi
if is_selected omnivox; then
    for p in "${OMNIVOX_PACKAGES[@]}"; do
        # Arch's rust and rustup packages conflict; keep the one installed.
        if [ "$p" = rust ] && { command -v cargo >/dev/null || pacman -Qq rustup >/dev/null 2>&1; }; then
            continue
        fi
        add_packages "$p"
    done
fi
if is_selected dectalk; then add_packages "${DECTALK_PACKAGES[@]}"; fi
if is_selected voxin; then add_packages "${VOXIN_PACKAGES[@]}"; fi

# --------------------------------------------------------------------------
if [ "$SKIP_DEPS" = no ]; then
    if is_selected voxin; then enable_multilib; fi
    # Arch does not support partial upgrades: refreshing the package lists
    # without upgrading (pacman -Sy) and then installing can break other
    # programs. So the install and a full upgrade happen in one -Syu step.
    log "Upgrading the system and installing packages with pacman (a few minutes)"
    echo "Packages: ${PACKAGES[*]}"
    echo "Arch supports only full upgrades, so the rest of the system is upgraded too."
    logged "pacman -Syu" pacman -Syu --noconfirm --needed --noprogressbar "${PACKAGES[@]}"
    if ! command -v emacs >/dev/null; then
        # The emacs package is the graphical (GTK) build. emacs-nox, for the
        # console only and with fewer dependencies, and emacs-wayland also
        # provide the emacs command: install one first if you prefer it.
        log "No Emacs found: installing Arch's emacs package"
        logged "pacman -S emacs" pacman -S --noconfirm --needed --noprogressbar emacs
    fi
fi

log "Checking Emacs and the build tools"
command -v emacs >/dev/null || die "emacs not found. Install it: pacman -Syu emacs"
EMACS_VERSION=$(emacs -Q --batch --eval '(princ emacs-version)' 2>>"$LOG") ||
    die "emacs is installed but does not run in batch mode"
emacs_new_enough ||
    die "emacspeak needs Emacs 29.1 or newer, and this is Emacs $EMACS_VERSION"
echo "Emacs $EMACS_VERSION: new enough."
for tool in git make g++; do
    command -v "$tool" >/dev/null || die "$tool not found. Install: pacman -Syu ${PACKAGES[*]}"
done
if [ "$NEED_TCL" = yes ]; then
    [ -x "$TCLSH" ] || die "$TCLSH not found. Install Tcl 8.6: pacman -Syu tcl"
    TCL_PATCH=$(echo 'puts [info patchlevel]' | "$TCLSH" 2>>"$LOG") || TCL_PATCH=""
    case "$TCL_PATCH" in
        8.6.*) ;;
        *) die "emacspeak needs Tcl 8.6, and $TCLSH is Tcl ${TCL_PATCH:-unknown}. \
If Arch's tcl package has moved to Tcl 9, this script cannot handle that yet." ;;
    esac
    grep -q 'define TCL_VERSION[[:space:]]*"8.6"' /usr/include/tcl.h 2>/dev/null ||
        die "/usr/include/tcl.h is missing or is not Tcl 8.6. It comes with tcl: pacman -Syu tcl"
    echo "Tcl $TCL_PATCH at $TCLSH, with its headers in /usr/include."
fi
if is_selected espeak; then
    [ -r /usr/include/espeak-ng/speak_lib.h ] ||
        die "espeak-ng headers not found. They come with espeak-ng: pacman -Syu espeak-ng"
fi
if is_selected omnivox; then
    command -v cargo >/dev/null && command -v rustc >/dev/null ||
        die "Rust (cargo) not found, and OmniVox is built with it. Install it: pacman -Syu rust"
    RUSTC_VERSION=$(rustc --version 2>>"$LOG" | awk '{ print $2 }') || RUSTC_VERSION=""
    [ -n "$RUSTC_VERSION" ] ||
        die "rustc does not run. If rustup is installed, give root a toolchain: rustup default stable"
    rust_minor=${RUSTC_VERSION#1.}
    rust_minor=${rust_minor%%.*}
    case "$rust_minor" in ''|*[!0-9]*) rust_minor=0 ;; esac
    [ "$rust_minor" -ge 70 ] ||
        die "OmniVox needs Rust 1.70 or newer, and this is $RUSTC_VERSION. Update it: pacman -Syu rust, or rustup update"
    command -v cmake >/dev/null || die "cmake not found. Install it: pacman -Syu cmake"
    compgen -G '/usr/lib/libclang.so*' >/dev/null ||
        die "libclang not found, and OmniVox's build needs it. Install it: pacman -Syu clang"
    pkg-config --exists alsa 2>>"$LOG" ||
        die "ALSA's pkg-config file not found. Install them: pacman -Syu alsa-lib pkgconf"
    echo "Rust $RUSTC_VERSION, cmake, libclang and ALSA found for OmniVox."
fi
if is_selected dectalk; then
    for tool in autoconf automake pkg-config; do
        command -v "$tool" >/dev/null ||
            die "$tool not found, and the DECtalk build needs it. Install: pacman -Syu ${DECTALK_PACKAGES[*]}"
    done
    echo "autoconf, automake and pkg-config found for DECtalk."
fi
if is_selected voxin; then
    [ -e /usr/lib32/libc.so.6 ] && [ -e /usr/lib32/libgcc_s.so.1 ] ||
        die "Voxin's 32-bit engine needs lib32-glibc and lib32-gcc-libs from [multilib]. Install them, or rerun without --skip-deps."
    [ -e /usr/lib/libasound.so ] ||
        die "ALSA's library not found, and atcleci.so needs it. Install it: pacman -Syu alsa-lib"
    echo "32-bit libraries and ALSA found for Voxin."
fi

TCLX_NOTE=""
if [ "$NEED_TCL" = yes ]; then
    log "Checking TclX, the Tcl extension the speech servers need"
    if TCLX=$(tclx_version 2>>"$LOG"); then
        echo "TclX $TCLX loads in $TCLSH: already installed."
        TCLX_NOTE="$TCLX, already installed"
    else
        echo "TclX is missing. Arch does not package it, so it is built next."
        log "Building TclX ${TCLX_REF#v} from source"
        [ -r /usr/lib/tclConfig.sh ] ||
            die "/usr/lib/tclConfig.sh not found. It comes with tcl: pacman -Syu tcl"
        TCLX_SRC=$(mktemp -d /tmp/emacspeak-tclx.XXXXXXXX)
        echo "Source: $TCLX_REPO, tag $TCLX_REF"
        logged "cloning TclX" git -c advice.detachedHead=false clone -q --depth 1 \
            --branch "$TCLX_REF" "$TCLX_REPO" "$TCLX_SRC"
        # Arch's tclsh looks for packages only in /usr/lib/tcl8.6 and /usr/lib
        # (its auto_path; /usr/local is not on it), so --libdir=/usr/lib puts
        # TclX's package folder in /usr/lib/tclx8.6. Its header and man page go
        # under /usr/local. pacman does not track these files.
        (cd "$TCLX_SRC" && logged "configuring TclX" ./configure \
            --with-tcl=/usr/lib --prefix=/usr/local --libdir=/usr/lib)
        logged "building TclX" make_in "$TCLX_SRC"
        logged "installing TclX" make_in "$TCLX_SRC" install
        [ -f "$TCLX_DIR/pkgIndex.tcl" ] ||
            die "TclX was installed, but $TCLX_DIR/pkgIndex.tcl is missing. See $LOG"
        TCLX=$(tclx_version 2>>"$LOG") ||
            die "TclX was installed in $TCLX_DIR but does not load in $TCLSH. See $LOG"
        echo "TclX $TCLX installed in $TCLX_DIR; it loads in $TCLSH."
        echo "The build folder $TCLX_SRC is no longer needed; /tmp is emptied at reboot."
        TCLX_NOTE="$TCLX, built from source into $TCLX_DIR (pacman does not track it)"
    fi
fi

# --------------------------------------------------------------------------
# The only tracked file this script changes in the clone is servers/.servers,
# where OmniVox's two names are taken out before a pull and put back after,
# so a fast-forward pull is all an update needs.
OLD_HEAD=""
if [ -d "$PREFIX/.git" ]; then
    log "Updating emacspeak in $PREFIX from $REPO ($REF)"
    unregister_omnivox
    OLD_HEAD=$(git -C "$PREFIX" rev-parse HEAD)
    logged "updating the clone in $PREFIX" \
        git -C "$PREFIX" pull -q --ff-only "$REPO" "$REF"
    # OmniVox from an earlier run stays registered, chosen or not.
    if [ -x "$OMNIVOX" ]; then register_omnivox; fi
elif [ -e "$PREFIX" ] && [ -n "$(ls -A "$PREFIX")" ]; then
    die "$PREFIX exists but is not a git clone. Move it away or use --prefix."
else
    log "Cloning emacspeak ($REF) from $REPO into $PREFIX"
    logged "git clone" git clone -q --depth 1 --branch "$REF" "$REPO" "$PREFIX"
fi
echo "Emacspeak source: $(git -C "$PREFIX" log -1 --format='commit %h of %cd' --date=short)"

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
for e in "${SELECTED[@]}"; do
    "install_$e"
done

log "Writing $INIT"
# The Lisp covers every engine installed now or by an earlier run, chosen
# or not, so DTK_PROGRAM can pick any of them.
{
    cat <<INIT
;;; emacspeak-init.el --- start emacspeak with its speech server  -*- lexical-binding: t; -*-
;; $MARKER, which rewrites it on every run.
;; The emacspeak launcher loads it. To load emacspeak from your own init
;; file instead, put this line at its very top:
;;   (load-file "$INIT")

;; The speech server: DTK_PROGRAM when it is set, otherwise the first
;; engine chosen when emacspeak was installed.
(setq dtk-program (or (getenv "DTK_PROGRAM") "$DEFAULT_SERVER"))
;; The dtk-soft server finds its Tcl glue through EMACSPEAK_DIR.
(unless (getenv "EMACSPEAK_DIR")
  (setenv "EMACSPEAK_DIR" "$PREFIX"))
(add-to-list 'load-path "$PREFIX/lisp")
INIT
    if [ -f "$OMNIVOX_DIR/elisp/omnivox-voices.el" ]; then
        cat <<INIT

;; OmniVox's voice module, loaded only when OmniVox is the server.
(when (member dtk-program '("omnivox" "log-omnivox"))
  (add-to-list 'load-path "$OMNIVOX_DIR/elisp")
  (require 'omnivox-voices)
  ;; OmniVox plays the auditory icons itself, so its sound volume applies.
  (setq emacspeak-play-program nil))
INIT
    fi
    if voxin_installed; then
        cat <<INIT

;; Voxin's engine reads its settings from the file ECIINI names.
(unless (getenv "ECIINI")
  (setenv "ECIINI" "$ECIINI_FILE"))
INIT
    fi
    cat <<INIT

;; Native compilation runs in the background; do not pop up its warnings.
(setq native-comp-async-report-warnings-errors 'silent)
(load-file "$PREFIX/lisp/emacspeak-setup.el")
INIT
} >"$INIT"
echo "Written."

log "Writing the launcher $LAUNCHER"
cat > "$LAUNCHER" <<LAUNCHER
#!/bin/sh
# Console Emacs with emacspeak. $MARKER.
# DTK_PROGRAM picks the speech server; the default is $DEFAULT_SERVER.
# -q skips your own init file, so emacspeak always starts the same way.
export EMACSPEAK_DIR="$PREFIX"
export DTK_PROGRAM="\${DTK_PROGRAM:-$DEFAULT_SERVER}"
exec emacs -nw -q -l "$INIT" "\$@"
LAUNCHER
chmod 0755 "$LAUNCHER"
echo "Launcher written."

# --------------------------------------------------------------------------
# Self-tests. None of them needs a sound card; the few that need a sound
# device are skipped, with the reason, when there is none.
if [ "$RUN_TESTS" = yes ]; then
    TEST_DIR=$(mktemp -d /tmp/emacspeak-selftest.XXXXXXXX)
    if [ "$NEED_TCL" = yes ]; then COMMON_TESTS=2; else COMMON_TESTS=1; fi
    log "emacspeak test 1 of $COMMON_TESTS: Emacs is 29.1 or newer"
    emacs_new_enough || die "emacspeak test 1 failed: Emacs $EMACS_VERSION is too old"
    echo "Pass: Emacs $EMACS_VERSION."
    if [ "$NEED_TCL" = yes ]; then
        log "emacspeak test 2 of 2: TclX loads in $TCLSH"
        TCLX=$(tclx_version 2>>"$LOG") ||
            die "emacspeak test 2 failed: TclX does not load in $TCLSH"
        echo "Pass: TclX $TCLX."
    fi
    for e in "${SELECTED[@]}"; do
        "test_$e"
    done
    echo "The test files are in $TEST_DIR; /tmp is emptied at reboot."
fi

# Recorded only now, after a successful install, so a rerun reuses it.
printf '%s\n' "${SELECTED[@]}" >"$RECORD.new"
mv -f "$RECORD.new" "$RECORD"

# --------------------------------------------------------------------------
log "Done: emacspeak is installed"
echo "Speech engines, the first is the launcher's default:"
for e in "${SELECTED[@]}"; do
    if [ "$RUN_TESTS" = yes ]; then
        echo "$(engine_label "$e"): $(get_result "$e"), server $(engine_server "$e")"
    else
        echo "$(engine_label "$e"): Skipped (--no-test), server $(engine_server "$e")"
    fi
done
for w in "${WARNINGS[@]}"; do echo "Warning: $w"; done
for s in "${SKIPS[@]}"; do echo "Skipped: $s"; done
# Engines from earlier runs stay installed when they are not chosen.
SERVERS=()
for e in "${SELECTED[@]}"; do SERVERS+=("$(engine_server "$e")"); done
for e in "${ENGINES[@]}"; do
    if is_selected "$e"; then continue; fi
    case $e in
        espeak)  [ -f "$ESPEAK_SO" ] || continue ;;
        omnivox) [ -x "$OMNIVOX" ] || continue ;;
        dectalk) [ -f "$DTK_SO" ] || continue ;;
        voxin)   [ -f "$OUTLOUD_SO" ] && voxin_installed || continue ;;
    esac
    echo "Also installed by an earlier run: $(engine_label "$e"), server $(engine_server "$e")"
    SERVERS+=("$(engine_server "$e")")
done
cat <<DONE
Emacspeak is in $PREFIX
Launcher: $LAUNCHER, default server $DEFAULT_SERVER
Init file: $INIT
Engines recorded in: $RECORD
DONE
if [ "$NEED_TCL" = yes ]; then
    echo "Tcl: $TCL_PATCH at $TCLSH"
    echo "TclX: $TCLX_NOTE"
fi
if is_selected omnivox; then echo "OmniVox: ${OMNIVOX_TAG#v}, built in $OMNIVOX_DIR/src"; fi
if is_selected dectalk; then echo "DECtalk: $DECTALK_DIR"; fi
echo "Build log: $LOG"
echo
echo "To start it, run this as your normal user (not root):"
echo "  emacspeak"
echo
echo "The launcher starts console Emacs without your own init file (-q),"
echo "with DTK_PROGRAM=$DEFAULT_SERVER."
echo "Installed servers: $(IFS=,; printf '%s' "${SERVERS[*]}" | sed 's/,/, /g')."
echo "To use another one for a session: DTK_PROGRAM=<server> emacspeak"
if [ ${#SERVERS[@]} -gt 1 ]; then
    echo "For example: DTK_PROGRAM=${SERVERS[1]} emacspeak"
fi
cat <<DONE
Inside Emacs, M-x dtk-select-server switches the server.
To load emacspeak from your own Emacs init file instead, put this
line at the very top of ~/.emacs or ~/.emacs.d/init.el:
  (load-file "$INIT")

To update emacspeak later, run this script again; it keeps these
engines. To choose others, run it with --speech.
DONE
