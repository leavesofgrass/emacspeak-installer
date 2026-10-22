#!/bin/sh
# install-emacspeak-voxin.sh
#
# One-shot installer: emacspeak with high-quality speech on bare-metal
# Linux. Give it a Voxin 3.x archive for the Outloud (IBM ViaVoice /
# Eloquence) voice, --with-dectalk for software DECtalk, or both.
#
# Supported distribution families (auto-detected from /etc/os-release):
#   - Debian family:  Debian, Ubuntu, Mint, ...          (apt)
#   - Arch family:    Arch, CachyOS, EndeavourOS, ...    (pacman)
#   - Fedora family:  Fedora, and dnf-based relatives    (dnf)
# Anything else: install the dependencies yourself, rerun with --skip-deps.
#
# Usage:
#   sudo ./install-emacspeak-voxin.sh /path/to/voxin-enu-v3.x.tar.gz [options]
#   sudo ./install-emacspeak-voxin.sh --with-dectalk        # DECtalk only, no license needed
#
# Options:
#   --with-dectalk        also build the software DECtalk server (dtk-soft)
#   --emacspeak-dir DIR   where emacspeak lives          (default /opt/emacspeak)
#   --emacspeak-ref REF   emacspeak git branch/tag       (default master)
#   --skip-deps           don't install packages (you installed them yourself)
#   --help
#
# What you get: an `emacspeak` command that starts console Emacs talking —
# with Eloquence when Voxin is installed, otherwise with DECtalk.
# Every step is explained in GUIDE.md in this repository.

set -e

VOXIN_TGZ=""
EMACSPEAK_DIR=/opt/emacspeak
EMACSPEAK_REF=master
DECTALK_REF=develop
WITH_DECTALK=no
SKIP_DEPS=no

# Emacspeak's servers and glue need Tcl 8.6: Tcl 9 removed APIs that both
# TclX and emacspeak's C glue still use. Where the distro has moved to
# Tcl 9 (Fedora), we use its Tcl 8.6 packages and point the servers at them.
# TclX is pinned to a release tag, which ships its configure script.
TCLX_URL=https://github.com/flightaware/tclx
TCLX_REF=v8.6.3
# On Arch, pacman's output goes to this log instead of the screen.
LOG=/var/log/install-emacspeak-voxin.log

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Run a noisy command with its output in $LOG only. If it fails, show the
# end of the log, then the error, so the last line on screen names the problem.
logged() { # $1 = what it does, then the command
    logged_what=$1; shift
    if ! "$@" >>"$LOG" 2>&1; then
        printf '\nLast lines of %s:\n' "$LOG" >&2
        tail -n 20 "$LOG" >&2
        die "$logged_what failed. The full output is in $LOG"
    fi
}

# Emacspeak's Makefiles hand $(MAKEFLAGS) to their sub-makes as plain words.
# GNU make 4.3 writes the -w that "make -C" adds as a bare "w", which the
# sub-make then takes for a target and fails; a MAKEFLAGS such as -s set in
# the environment does the same. So every make here runs from inside its
# directory, without flags inherited from outside.
make_in() { # $1 = directory, then the make arguments
    ( cd "$1" && shift && env -u MAKEFLAGS -u MFLAGS make "$@" )
}

while [ $# -gt 0 ]; do
    case "$1" in
        --with-dectalk)  WITH_DECTALK=yes ;;
        --emacspeak-dir) EMACSPEAK_DIR="$2"; shift ;;
        --emacspeak-ref) EMACSPEAK_REF="$2"; shift ;;
        --skip-deps)     SKIP_DEPS=yes ;;
        --help) sed -n '2,28p' "$0"; exit 0 ;;
        -*) die "unknown option $1" ;;
        *)  VOXIN_TGZ="$1" ;;
    esac
    shift
done

[ "$(id -u)" = 0 ] || die "run me as root (sudo)"
if [ -z "$VOXIN_TGZ" ] && [ "$WITH_DECTALK" = no ]; then
    die "nothing to install. Give me a Voxin archive for the Eloquence voice, \
--with-dectalk for DECtalk (no license needed), or both. --help for usage."
fi
[ -z "$VOXIN_TGZ" ] || [ -f "$VOXIN_TGZ" ] || die "no such file: $VOXIN_TGZ"

# --------------------------------------------------------------------------
# 0. Which distribution family is this?
FAMILY=unknown
if [ -r /etc/os-release ]; then
    . /etc/os-release
    for candidate in "$ID" $ID_LIKE; do
        case "$candidate" in
            debian|ubuntu) FAMILY=debian; break ;;
            arch)          FAMILY=arch;   break ;;
            fedora|rhel)   FAMILY=fedora; break ;;
        esac
    done
fi
log "Distribution family: $FAMILY (ID=${ID:-?} ID_LIKE=${ID_LIKE:-})"
if [ "$FAMILY" = unknown ] && [ "$SKIP_DEPS" = no ]; then
    die "unrecognized distribution. Install the dependencies listed in the \
README yourself, then rerun with --skip-deps."
fi

# Where 64-bit dlopen looks for libraries by default differs by family.
case "$FAMILY" in
    fedora) SYS_LIBDIR=/usr/lib64 ;;
    *)      SYS_LIBDIR=/usr/lib ;;
esac

# --------------------------------------------------------------------------
# 1. Dependencies.
#    The 32-bit runtime is for Voxin's voxind engine process; TclX is the
#    Tcl extension every emacspeak speech server requires; the Tcl headers
#    plus g++ and ALSA headers compile atcleci.so, the Tcl<->ECI glue.
install_deps_debian() {
    dpkg --add-architecture i386
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        git ca-certificates curl make gcc g++ file unzip xz-utils \
        tcl tcl8.6 tcl8.6-dev tclx8.4 \
        libasound2-dev sox libsox-fmt-all pulseaudio-utils \
        libc6:i386 libstdc++6:i386
    command -v emacs >/dev/null || \
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends emacs-nox
    [ "$WITH_DECTALK" = yes ] && DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends \
        build-essential autoconf automake libpulse-dev
    return 0
}

install_deps_arch() {
    # Voxin's 32-bit engine needs the multilib repo for lib32 glibc. It is
    # enabled first, so the one pacman -Syu below also syncs it.
    if [ -n "$VOXIN_TGZ" ] && ! grep -q '^\[multilib\]' /etc/pacman.conf; then
        log "Enabling the [multilib] repository (needed for Voxin's 32-bit engine)"
        # Uncomment the standard commented block if present...
        sed -i '/^#\[multilib\]/,/^#Include = \/etc\/pacman.d\/mirrorlist/ s/^#//' \
            /etc/pacman.conf
        # ...or append the section when the config doesn't carry it at all.
        if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
            printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' \
                >> /etc/pacman.conf
        fi
    fi
    # Arch does not support partial upgrades: refreshing the package lists
    # without upgrading (pacman -Sy) and then installing can break other
    # programs. So everything is installed in one full upgrade (-Syu).
    pkgs="git curl make gcc file unzip xz autoconf automake pkgconf"
    pkgs="$pkgs tcl alsa-lib sox libpulse"
    command -v emacs >/dev/null || pkgs="$pkgs emacs-nox"
    [ -z "$VOXIN_TGZ" ] || pkgs="$pkgs lib32-glibc lib32-gcc-libs"
    : > "$LOG"
    echo "  The whole system is upgraded too: Arch supports only full upgrades."
    echo "  Packages: $pkgs"
    echo "  This takes a few minutes. pacman's output goes to $LOG"
    # $pkgs is unquoted on purpose: one word per package.
    logged "pacman -Syu" pacman -Syu --noconfirm --needed --noprogressbar $pkgs
    return 0
}

install_deps_fedora() {
    # Fedora's tcl is Tcl 9, which emacspeak's stack cannot use. Fedora
    # still ships Tcl 8.6 as tcl8, with tcl8-devel and a tclx built for it.
    # tcl8-devel and tcl-devel (the Tcl 9 headers) both own /usr/include/tcl.h.
    if rpm -q --quiet tcl-devel; then
        die "tcl-devel (the Tcl 9 headers) is installed and conflicts with \
tcl8-devel, which this build needs. Remove it with: dnf remove tcl-devel, \
then rerun this script."
    fi
    dnf install -y \
        git curl make gcc gcc-c++ file unzip xz autoconf automake \
        pkgconf-pkg-config tcl8 tcl8-devel tclx \
        alsa-lib-devel sox pulseaudio-utils
    command -v emacs >/dev/null || dnf install -y emacs
    [ -n "$VOXIN_TGZ" ] && dnf install -y glibc.i686 libstdc++.i686
    [ "$WITH_DECTALK" = yes ] && dnf install -y pulseaudio-libs-devel
    return 0
}

if [ "$SKIP_DEPS" = no ]; then
    log "Installing packages ($FAMILY)"
    "install_deps_$FAMILY"
fi

EMACS_MAJOR=$(emacs --batch --eval '(princ emacs-major-version)' 2>/dev/null || echo 0)
[ "$EMACS_MAJOR" -ge 29 ] || \
    die "emacspeak needs Emacs 29.1+, found major version '$EMACS_MAJOR'. \
Install a newer Emacs and rerun."

# --------------------------------------------------------------------------
# 2. A usable Tcl 8.6 + TclX.
#    - Debian: everything comes from apt (tcl8.6, tclx8.4). Done.
#    - Arch: tcl is 8.6 but TclX isn't packaged; build TclX from source.
#    - Fedora: distro tcl is 9.x; tcl8, tcl8-devel and tclx come from dnf,
#      and later the emacspeak servers' shebangs are pointed at tclsh8.6.
TCLSH=/usr/bin/tclsh
TCL_CFLAGS="-I/usr/include/tcl8.6"
TCL_LIBS="-ltcl8.6"

# Note the explicit exit: tclsh reading stdin reports errors but still
# exits 0, so a bare "package require Tclx" pipe always looks successful.
has_tclx() {
    echo 'if {[catch {package require Tclx}]} {exit 1}' | "$TCLSH" >/dev/null 2>&1
}

build_tclx() { # $1 = tclConfig.sh dir, $2 = install prefix, $3 = libdir
    log "Building TclX ${TCLX_REF#v} from source ($TCLX_URL, tag $TCLX_REF)"
    TCLXSRC=$(mktemp -d)
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$TCLX_REF" \
        "$TCLX_URL" "$TCLXSRC/tclx"
    ( cd "$TCLXSRC/tclx" \
      && { [ -x configure ] || autoreconf -fi; } \
      && ./configure --with-tcl="$1" --prefix="$2" --exec-prefix="$2" \
             --libdir="$3" \
      && make_in . && make_in . install )
    rm -rf "$TCLXSRC"
}

case "$FAMILY" in
    arch)
        TCL_CFLAGS=""   # tcl.h lives directly in /usr/include
        # Arch's tclsh looks for packages only in /usr/lib/tcl8.6 and /usr/lib
        # (its auto_path; /usr/local is not on it), so --libdir=/usr/lib puts
        # TclX's package folder in /usr/lib/tclx8.6, while its header and man
        # page go under /usr/local. pacman does not track these files.
        if ! has_tclx; then
            build_tclx /usr/lib /usr/local /usr/lib
            [ -f /usr/lib/tclx8.6/pkgIndex.tcl ] || \
                die "TclX was installed, but /usr/lib/tclx8.6/pkgIndex.tcl is missing"
            echo "  TclX is in /usr/lib/tclx8.6; pacman does not track it."
        fi
        ;;
    fedora)
        # tcl8 installs Tcl 8.6 beside the default Tcl 9, run as tclsh8.6,
        # and tcl8-devel puts its headers straight into /usr/include.
        TCLSH=/usr/bin/tclsh8.6
        TCL_CFLAGS=""
        [ -x "$TCLSH" ] || die "$TCLSH not found. Install Tcl 8.6: dnf install tcl8"
        grep -q 'define TCL_VERSION[[:space:]]*"8.6"' /usr/include/tcl.h 2>/dev/null || \
            die "/usr/include/tcl.h is missing or is not Tcl 8.6. Install tcl8-devel."
        has_tclx || die "TclX does not load in $TCLSH. Install it: dnf install tclx"
        ;;
esac
has_tclx || die "TclX still does not load in $TCLSH; emacspeak's servers need it."

# --------------------------------------------------------------------------
# 3. Voxin (skipped entirely when no archive was given). The archive is an
#    installer tree; we do what its installer does, deterministically:
#      rfs_<arch>.txz  -> /opt/oralux/voxin/{lib,bin}   (libvoxin, voxin-say)
#      rfs_all.txz     -> /opt/oralux/voxin/{include,rfs32}  (32-bit world)
#      voxin-viavoice-all_*.txz -> /opt/IBM/ibmtts      (the real engine)
#      voxin-viavoice-<lang>_*.txz -> voice libs + /var/opt/IBM voicedata
if [ -n "$VOXIN_TGZ" ]; then

log "Unpacking Voxin archive"
STAGE=$(mktemp -d)
trap '[ -n "$STAGE" ] && rm -rf "$STAGE"' EXIT
tar -xf "$VOXIN_TGZ" -C "$STAGE"
INSTALLER=$(find "$STAGE" -name voxin-installer.sh | head -1)
[ -n "$INSTALLER" ] || die "this doesn't look like a Voxin 3.x archive (no voxin-installer.sh)"
TREE=$(dirname "$INSTALLER")
ARCH=$(uname -m)

log "Extracting Voxin runtime (rfs) for $ARCH"
found=no
for t in "$TREE"/packages/all/rfs_*."$ARCH".txz "$TREE"/packages/all/rfs_*.all.txz; do
    [ -e "$t" ] || die "missing expected tarball: $t"
    echo "  $(basename "$t")"
    tar -C / --no-overwrite-dir -xf "$t"
    found=yes
done
[ "$found" = yes ] || die "no rfs tarballs found for $ARCH"

log "Extracting ViaVoice engine and voices to /opt/IBM"
for t in "$TREE"/packages/all/voxin-viavoice-all_*.txz; do
    [ -e "$t" ] || die "no voxin-viavoice-all engine tarball in the archive"
    echo "  $(basename "$t")"
    tar -C / --no-overwrite-dir -xf "$t"
done
for t in "$TREE"/packages/all/voxin-viavoice-*.txz; do
    case "$t" in *-all_*) continue ;; esac
    echo "  $(basename "$t")"
    tar -C / --no-overwrite-dir -xf "$t"
done

# eci.ini: concatenate the engine's all.ini with one section per installed
# language (a language is present when its xxx50.so synthesizer lib exists).
log "Generating /var/opt/IBM/ibmtts/cfg/eci.ini"
INIDIR=/opt/IBM/ibmtts/etc
NEWCONF=/var/opt/IBM/ibmtts/cfg/eci.ini
mkdir -p "$(dirname "$NEWCONF")"
LANGS=$(find /opt/IBM/ibmtts/lib -name "???50.so" | sed "s+.*/\(...\)50.so+\1+")
[ -n "$LANGS" ] || die "no ViaVoice language libraries found under /opt/IBM/ibmtts/lib"
cp "$INIDIR/all.ini" "$NEWCONF"
for l in $LANGS; do
    echo "  language: $l"
    cat "$INIDIR/$l.ini" >> "$NEWCONF"
done

# Library wiring. libvoxin.so.1 IS the 64-bit ECI shim; Voxin's own packages
# just symlink the libibmeci.so name to it. dlopen("libibmeci.so") searches
# the trusted system libdir directly ($SYS_LIBDIR: /usr/lib64 on Fedora,
# /usr/lib elsewhere); the ld.so.conf.d entry lets binaries linked against
# libvoxin.so.1 by soname (voxin-say) resolve it.
log "Wiring libraries (system libdir: $SYS_LIBDIR)"
[ -e /opt/oralux/voxin/lib/libvoxin.so.1 ] || die "libvoxin.so.1 missing after extraction"
ln -sf /opt/oralux/voxin/lib/libvoxin.so.1 "$SYS_LIBDIR/libibmeci.so"
echo /opt/oralux/voxin/lib > /etc/ld.so.conf.d/voxin.conf
ldconfig
ln -sf /opt/oralux/voxin/bin/voxin-say /usr/local/bin/voxin-say

# ECIINI tells the engine where its config lives; classic ViaVoice lore, still
# honored. Exported system-wide and again by the emacspeak launcher.
echo 'export ECIINI=/var/opt/IBM/ibmtts/cfg/eci.ini' > /etc/profile.d/voxin.sh

log "Voxin self-test (synthesizes to a wav; no audio device needed)"
rm -f /tmp/voxin-selftest.wav
ECIINI="$NEWCONF" voxin-say -w /tmp/voxin-selftest.wav "Voxin is installed." \
    || die "voxin-say failed to run"
[ -s /tmp/voxin-selftest.wav ] || \
    die "voxin-say wrote a zero-byte wav: libvoxin could not find the engine. \
Check that /opt/IBM/ibmtts/lib/libibmeci.so exists."
echo "  OK: $(stat -c%s /tmp/voxin-selftest.wav) bytes of speech"

fi # end of Voxin section

# --------------------------------------------------------------------------
# 4. Emacspeak, run in place from $EMACSPEAK_DIR (no `make install` needed).
if [ -d "$EMACSPEAK_DIR/.git" ]; then
    log "Emacspeak already cloned at $EMACSPEAK_DIR; leaving it as is"
else
    log "Cloning emacspeak ($EMACSPEAK_REF) to $EMACSPEAK_DIR"
    git clone --depth 1 --branch "$EMACSPEAK_REF" \
        https://github.com/tvraman/emacspeak.git "$EMACSPEAK_DIR"
fi

log "Building emacspeak (byte-compiling the lisp)"
make_in "$EMACSPEAK_DIR" config
make_in "$EMACSPEAK_DIR" emacspeak

# The servers run via their "#!/usr/bin/tclsh" shebang. On Fedora, where
# tclsh is Tcl 9, point them at tclsh8.6. Safe to rerun after upstream pulls.
if [ "$TCLSH" != /usr/bin/tclsh ]; then
    log "Pointing emacspeak server shebangs at $TCLSH"
    for f in "$EMACSPEAK_DIR"/servers/*; do
        [ -f "$f" ] || continue
        head -1 "$f" | grep -q '^#!.*tclsh' && \
            sed -i "1s|^#!.*|#!$TCLSH|" "$f"
    done
fi

log "Building atcleci.so (Tcl glue that dlopens libibmeci.so, speaks via ALSA)"
make_in "$EMACSPEAK_DIR/servers/linux-outloud" \
    CFLAGS="-g -O2 -fPIC -DPIC -std=c++11 $TCL_CFLAGS" \
    LIBS="$TCL_LIBS -lasound -ldl"

# --------------------------------------------------------------------------
# 5. Optional software DECtalk.
if [ "$WITH_DECTALK" = yes ]; then
    log "Building software DECtalk (this is 1990s C; newer gcc needs -fpermissive)"
    DTKSRC=$(mktemp -d)
    git clone --depth 1 --branch "$DECTALK_REF" \
        https://github.com/dectalk/dectalk.git "$DTKSRC/dectalk"
    ( cd "$DTKSRC/dectalk/src" \
      && ./autogen.sh \
      && ./configure CFLAGS="-O2 -fpermissive -Wno-implicit-function-declaration" \
      && make_in . -j"$(nproc)" )
    mkdir -p /opt/dectalk
    cp -a "$DTKSRC/dectalk/dist/." /opt/dectalk/
    mkdir -p /opt/dectalk/include/dtk
    cp "$DTKSRC/dectalk/src/dapi/src/include/"*.h /opt/dectalk/include/dtk/
    rm -rf "$DTKSRC"
    [ -e /opt/dectalk/lib/libtts.so ] || \
        ln -s libtts_us.so /opt/dectalk/lib/libtts.so
    echo /opt/dectalk/lib > /etc/ld.so.conf.d/dectalk.conf
    ldconfig
    # libtts falls back to <prefix>/DECtalk.conf; emacspeak ships a template
    # whose dictionary paths are already absolute /opt/dectalk/dic entries.
    cp "$EMACSPEAK_DIR/servers/software-dtk/DECtalk.conf" /opt/dectalk/DECtalk.conf
    log "Building tcldtk.so (Tcl glue for the dtk-soft server)"
    make_in "$EMACSPEAK_DIR/servers/software-dtk" \
        CFLAGS="-g -O2 -fPIC -DPIC $TCL_CFLAGS -I/opt/dectalk/include" \
        LDFLAGS="-L/opt/dectalk/lib" \
        LIBS="$TCL_LIBS -ltts -ltts_us -ldl"
    log "DECtalk self-test"
    /opt/dectalk/say -fo /tmp/dectalk-selftest.wav -a "DECtalk is installed."
    [ -s /tmp/dectalk-selftest.wav ] || die "DECtalk say produced no audio data"
    echo "  OK: $(stat -c%s /tmp/dectalk-selftest.wav) bytes of speech"
fi

# --------------------------------------------------------------------------
# 6. Launcher. Default voice: Eloquence when Voxin is installed, else DECtalk.
if [ -n "$VOXIN_TGZ" ]; then DEFAULT_TTS=outloud; else DEFAULT_TTS=dtk-soft; fi
log "Installing /usr/local/bin/emacspeak launcher (default voice: $DEFAULT_TTS)"
cat > /usr/local/bin/emacspeak <<LAUNCHER
#!/bin/sh
# Console Emacs with emacspeak. DTK_PROGRAM selects the speech server:
# outloud (Eloquence) or dtk-soft (software DECtalk).
export EMACSPEAK_DIR="$EMACSPEAK_DIR"
export DTK_PROGRAM="\${DTK_PROGRAM:-$DEFAULT_TTS}"
export ECIINI="\${ECIINI:-/var/opt/IBM/ibmtts/cfg/eci.ini}"
exec emacs -nw -l "$EMACSPEAK_DIR/lisp/emacspeak-setup.el" "\$@"
LAUNCHER
chmod 0755 /usr/local/bin/emacspeak

log "All done"
echo
echo "  Start it:            emacspeak      (default voice: $DEFAULT_TTS)"
[ "$WITH_DECTALK" = yes ] && [ -n "$VOXIN_TGZ" ] && \
    echo "  DECtalk instead:     DTK_PROGRAM=dtk-soft emacspeak"
[ -n "$VOXIN_TGZ" ] && \
    echo "  Engine self-test:    voxin-say -w /tmp/t.wav \"hello\""
cat <<DONE

  To load emacspeak in your own Emacs config instead of the launcher, put
  this FIRST in ~/.emacs (before anything that produces output):

    (setenv "DTK_PROGRAM" "$DEFAULT_TTS")
    (load-file "$EMACSPEAK_DIR/lisp/emacspeak-setup.el")

DONE
