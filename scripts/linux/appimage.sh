#!/usr/bin/env bash
# ReLink-x86_64.AppImage: the Linux builder in one file. Players run it, pick their copy of the game, and it builds a native
# game folder on their PC (builder/linux/launcher.py). No game data is in it. It carries:
#
#   usr/llvm      clang, clang++, lld, llvm-nm and llvm-profdata (LLVM_VERSION, apt.llvm.org's) with the libraries they
#                 load, found through their own rpath: nothing is put on LD_LIBRARY_PATH, so the game never sees them.
#                 And libc++ (headers, static libraries): the sysroot's libstdc++ (GCC 12) has no <format>
#   usr/sysroot   Ubuntu 22.04's C library (glibc 2.35), C++ library and kernel headers: what the game is compiled and
#                 linked against (RELINK_SYSROOT), so a game folder runs on any system with glibc 2.35 or newer
#   usr/python    python-build-standalone's CPython 3.12 with lz4, numpy, capstone, zstandard and Pillow; its Tk draws
#                 the launcher's window
#   usr/deps      FFmpeg as static libraries (linux/build-deps.sh) and the Vulkan headers (a CPU without AVX2 builds the
#                 Vulkan back end itself)
#   usr/lib/relink_vk.so   the Vulkan back end, built here for x86-64-v3 (RELINK_VK_PREBUILT): a player's build skips it
#   usr/tools     ReLink's sources and scripts (git's, not the ignored files) (nx2/make_game.py's ROOT), with the latest release's play profile
#                 in usr/tools/work when it can be downloaded, liba64emit.so built, and VERSION
#
#   scripts/linux/appimage.sh [out folder]      (default dist/; writes ReLink-x86_64.AppImage and relink-linux.txt)
#
# It runs in Ubuntu 22.04: on any other system it starts itself again in an ubuntu:22.04 container (podman or docker).
# LLVM_VERSION (default 23), RELINK_PROFILE=0 (no play profile), APPIMAGE_RUNTIME=<file> (a runtime already downloaded),
# RELINK_CA_BUNDLE=<file> (a certificate authority to trust as well: a network whose proxy inspects HTTPS).
# RELINK_APPIMAGE_WORK=<folder>: build there and keep it (FFmpeg and the back end's objects are reused by the next run).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUT=$(mkdir -p "${1:-$ROOT/dist}" && cd "${1:-$ROOT/dist}" && pwd)
LLVM_VERSION=${LLVM_VERSION:-23}
PY_URL=https://github.com/astral-sh/python-build-standalone/releases/download/20251014/cpython-3.12.12+20251014-x86_64-unknown-linux-gnu-install_only.tar.gz
PY_SHA256=1ab2b6594d1c3d76cbebea09d6bc3e6ba68d8eb3b6322080375c4cc3dd188f34
RUNTIME_URL=https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64
SYSROOT_PKGS="libc6 libc6-dev linux-libc-dev libgcc-s1 libgcc-12-dev libstdc++6 libstdc++-12-dev libcrypt1 libcrypt-dev"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- not Ubuntu 22.04: the same script in a container
if ! grep -q 'VERSION_ID="22.04"' /etc/os-release 2>/dev/null || [[ ! -f /etc/lsb-release ]]; then
    engine=${RELINK_ENGINE:-$(command -v podman || command -v docker || true)}
    [[ -n $engine ]] || { echo "appimage.sh: needs Ubuntu 22.04, or podman or docker to run it in one" >&2; exit 1; }
    say "Building in an ubuntu:22.04 container ($engine)"
    exec "$engine" run --rm -i --network=host --security-opt label=disable \
        -e LLVM_VERSION -e RELINK_PROFILE -e GH_TOKEN -e APPIMAGE_RUNTIME="${APPIMAGE_RUNTIME:+/runtime}" \
        ${RELINK_APPIMAGE_WORK:+-v "$RELINK_APPIMAGE_WORK:/work"} ${RELINK_APPIMAGE_WORK:+-e RELINK_APPIMAGE_WORK=/work} \
        ${APPIMAGE_RUNTIME:+-v "$APPIMAGE_RUNTIME:/runtime:ro"} \
        ${RELINK_CA_BUNDLE:+-v "$RELINK_CA_BUNDLE:/usr/local/share/ca-certificates/relink-extra.crt:ro"} \
        ${RELINK_CA_BUNDLE:+-e RELINK_CA_BUNDLE=/usr/local/share/ca-certificates/relink-extra.crt} \
        -v "$ROOT:/src" -v "$OUT:/out" -w /src docker.io/library/ubuntu:22.04 \
        bash scripts/linux/appimage.sh /out
fi

export DEBIAN_FRONTEND=noninteractive
SUDO=""; [[ $(id -u) == 0 ]] || SUDO=sudo
if [[ -n ${RELINK_APPIMAGE_WORK:-} ]]; then
    TMP=$RELINK_APPIMAGE_WORK
    mkdir -p "$TMP"
else
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
fi
APPDIR=$TMP/AppDir
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/lib"

say "Build tools and LLVM $LLVM_VERSION (apt.llvm.org)"
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg git make nasm meson ninja-build pkg-config \
    squashfs-tools patchelf file xz-utils binutils >/dev/null
if [[ -n ${RELINK_CA_BUNDLE:-} ]]; then
    [[ $RELINK_CA_BUNDLE == /usr/local/share/ca-certificates/*.crt ]] || $SUDO cp "$RELINK_CA_BUNDLE" /usr/local/share/ca-certificates/relink-extra.crt
    $SUDO update-ca-certificates >/dev/null
    export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt PIP_CERT=/etc/ssl/certs/ca-certificates.crt \
        REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
fi
if [[ ! -x /usr/lib/llvm-$LLVM_VERSION/bin/clang ]]; then
    curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | $SUDO gpg --dearmor --yes -o /usr/share/keyrings/llvm.gpg
    echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/jammy/ llvm-toolchain-jammy-$LLVM_VERSION main" |
        $SUDO tee /etc/apt/sources.list.d/llvm.list >/dev/null
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq --no-install-recommends "clang-$LLVM_VERSION" "lld-$LLVM_VERSION" "llvm-$LLVM_VERSION" \
        "libc++-$LLVM_VERSION-dev" "libc++abi-$LLVM_VERSION-dev" libstdc++-12-dev >/dev/null
fi
git config --global --add safe.directory "$ROOT" 2>/dev/null || true
TAG=$(git -C "$ROOT" describe --tags --match 'v[0-9]*' 2>/dev/null || echo "v0.0.0-$(git -C "$ROOT" rev-parse --short HEAD)")
echo "version: $TAG"

# ---------------------------------------------------------------- LLVM, with what it loads
say "LLVM -> usr/llvm"
L=/usr/lib/llvm-$LLVM_VERSION
LL=$APPDIR/usr/llvm
mkdir -p "$LL/bin" "$LL/lib/clang"
cp -L "$L/bin/clang-$LLVM_VERSION" "$LL/bin/clang"
ln -s clang "$LL/bin/clang++"
cp -L "$L/bin/lld" "$LL/bin/lld"
ln -s lld "$LL/bin/ld.lld"
for t in llvm-nm llvm-profdata llvm-ar; do cp -L "$L/bin/$t" "$LL/bin/$t"; done
ln -s llvm-nm "$LL/bin/nm"   # (nx2/build.py's undefined-symbol check looks for nm)
RES=$("$L/bin/clang" -print-resource-dir)
mkdir -p "$LL/lib/clang/$(basename "$RES")"
cp -r "$RES/include" "$LL/lib/clang/$(basename "$RES")/"
[[ -d $RES/lib ]] && cp -r "$RES/lib" "$LL/lib/clang/$(basename "$RES")/"   # (the profile runtime, when the package has it)
# (libc++, the Vulkan back end's C++ library (nx2/build.py RELINK_LIBCXX): its headers where clang looks, <bin>/../include/c++/v1,
# and its static libraries apart, so that -L finds nothing else there)
mkdir -p "$LL/include" "$LL/lib/libcxx"
cp -r "$L/include/c++" "$LL/include/"
cp "$L/lib/libc++.a" "$L/lib/libc++abi.a" "$LL/lib/libcxx/"
# (every library the tools load except the C library's own: copied beside them and found by rpath)
copy_deps() {
    local f dep
    for f in "$@"; do
        ldd "$f" | awk '/=> \// { print $3 }' | while read -r dep; do
            case $(basename "$dep") in
                libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*|libresolv.so*|libutil.so*|ld-linux*) continue ;;
            esac
            [[ -e $LL/lib/$(basename "$dep") ]] || cp -L "$dep" "$LL/lib/"
        done
    done
}
copy_deps "$LL"/bin/clang "$LL"/bin/lld "$LL"/bin/llvm-*
copy_deps "$LL"/lib/*.so*   # (and what those load)
for f in "$LL"/bin/clang "$LL"/bin/lld "$LL"/bin/llvm-*; do patchelf --set-rpath '$ORIGIN/../lib' "$f"; done
for f in "$LL"/lib/*.so*; do patchelf --set-rpath '$ORIGIN' "$f"; done
"$LL/bin/clang" --version | head -1
"$LL/bin/ld.lld" --version

# ---------------------------------------------------------------- the sysroot: Ubuntu 22.04's C and C++ libraries
say "glibc 2.35 sysroot -> usr/sysroot"
SR=$APPDIR/usr/sysroot
rm -rf "$TMP/debs"
mkdir -p "$SR" "$TMP/debs"
(cd "$TMP/debs" && apt-get download $SYSROOT_PKGS >/dev/null)
for d in "$TMP"/debs/*.deb; do dpkg-deb -x "$d" "$SR"; done
rm -rf "${SR:?}/usr/share" "${SR:?}/etc" "${SR:?}/usr/bin" "${SR:?}/usr/sbin" "${SR:?}/sbin" "${SR:?}/usr/libexec"
# (absolute links point into the system that builds: made relative, so they stay in the sysroot)
find "$SR" -type l | while read -r link; do
    target=$(readlink "$link")
    if [[ $target == /* ]]; then
        ln -sfn "$(realpath -m --relative-to="$(dirname "$link")" "$SR$target")" "$link"
    fi
done
du -sh "$SR"

# ---------------------------------------------------------------- Python
say "Python 3.12 (python-build-standalone) -> usr/python"
[[ -f $TMP/python.tgz ]] || curl -fsSL -o "$TMP/python.tgz" "$PY_URL"
echo "$PY_SHA256  $TMP/python.tgz" | sha256sum -c --quiet
tar -xzf "$TMP/python.tgz" -C "$APPDIR/usr"
PY=$APPDIR/usr/python/bin/python3
"$PY" -m pip install -q --no-cache-dir --disable-pip-version-check lz4 numpy capstone zstandard pillow
rm -rf "$APPDIR"/usr/python/lib/python3.12/test "$APPDIR"/usr/python/lib/python3.12/idlelib "$APPDIR"/usr/python/bin/pip*
"$PY" -c 'import capstone, numpy, zstandard, lz4, PIL, tkinter; print("python packages: ok, Tk", tkinter.TkVersion)'

# ---------------------------------------------------------------- FFmpeg and the Vulkan headers
say "FFmpeg (static) and the Vulkan headers -> usr/deps"
[[ -f $TMP/deps/ffmpeg/lib/libavcodec.a ]] || CC="$LL/bin/clang" bash "$ROOT/linux/build-deps.sh" "$TMP/deps"
mkdir -p "$APPDIR/usr/deps"
cp -r "$TMP/deps/ffmpeg" "$APPDIR/usr/deps/"
rm -rf "$APPDIR/usr/deps/ffmpeg/lib/pkgconfig" "$APPDIR/usr/deps/ffmpeg/share"
for p in "$TMP"/deps/cpm/*/*; do   # (the headers and their licenses: what a build from source reads)
    dst=$APPDIR/usr/deps/cpm/${p#"$TMP"/deps/cpm/}
    mkdir -p "$dst"
    cp -r "$p/include" "$dst/"
    cp "$p"/LICENSE* "$dst/" 2>/dev/null || true
done

# ---------------------------------------------------------------- ReLink's tools
say "ReLink's sources -> usr/tools"
T=$APPDIR/usr/tools
git -C "$ROOT" ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do
    [[ -f $ROOT/$f ]] || continue   # (tracked, deleted in the working tree)
    case $f in .github/*|launcher/*|docs/*|linux/*|*.png|*.ps1|*.bat) [[ $f == assets/relink.png ]] || continue ;; esac
    mkdir -p "$T/$(dirname "$f")"
    cp -p "$ROOT/$f" "$T/$f"
done
# (the working tree's files, tracked or new but not ignored: what this checkout builds, local changes included)
echo "$TAG" > "$T/VERSION"
export PATH=$LL/bin:$APPDIR/usr/python/bin:$PATH
(cd "$T/third_party/a64-kit/lift" && "$PY" -I build_emit.py)   # (the lift's emitter, read-only once packed)
if [[ ${RELINK_PROFILE:-1} != 0 ]]; then
    list=$TMP/setup.txt
    if "$PY" -I "$ROOT/scripts/release_parts.py" previous "$list" --repo pixl27/ProjectReLink --list-name relink-setup.txt --skip-tag "$TAG" &&
       "$PY" -I "$ROOT/scripts/release_parts.py" profile "$list" "$T/work"; then
        ls "$T/work"
    else
        echo "no play profile: the AppImage builds games without one (RELINK_PROFILE=0 to skip this)"
    fi
fi

# ---------------------------------------------------------------- the Vulkan back end, prebuilt for x86-64-v3
say "relink_vk.so (x86-64-v3, against the sysroot)"
VKW=$TMP/vk-work
vk_env=(RX_VK_ONLY=1 RX_RELEASE=1 RX_MARCH=x86-64-v3 RELINK_SYSROOT="$SR" RELINK_LIBCXX="$LL/lib/libcxx" RX_CPM="$APPDIR/usr/deps/cpm"
        OOT_WORK="$VKW")
if [[ -f $T/work/relink_vk.profdata ]] && "$LL/bin/clang" -fprofile-instr-use="$T/work/relink_vk.profdata" -x c -c /dev/null \
        -o /dev/null -Wno-everything 2>/dev/null; then
    vk_env+=(RX_VK_PGO="$T/work/relink_vk.profdata")
fi
rm -f "$VKW/sa/build/relink_vk.so"
(cd "$T" && env "${vk_env[@]}" "$PY" -I nx2/build.py --standalone --jobs "$(nproc)") > "$TMP/vk.log" 2>&1 || true
grep -E -A12 '^FAILED' "$TMP/vk.log" | head -60 || true
tail -3 "$TMP/vk.log"
[[ -f $VKW/sa/build/relink_vk.so ]] || { echo "appimage.sh: relink_vk.so was not built ($TMP/vk.log)" >&2; exit 1; }
cp "$VKW/sa/build/relink_vk.so" "$APPDIR/usr/lib/relink_vk.so"
echo "relink_vk.so needs: $(objdump -T "$APPDIR/usr/lib/relink_vk.so" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)," \
    "$(readelf -d "$APPDIR/usr/lib/relink_vk.so" | grep -o 'NEEDED.*' | grep -o '\[.*\]' | tr '\n' ' ')"

"$PY" -m compileall -q -j 0 "$T/nx2" "$T/scripts" "$T/tools" "$T/third_party/a64-kit" "$T/builder" >/dev/null || true

# ---------------------------------------------------------------- the AppImage
say "ReLink-x86_64.AppImage"
cp "$ROOT/builder/linux/AppRun" "$APPDIR/AppRun"
chmod +x "$APPDIR/AppRun"
cp "$ROOT/assets/relink.png" "$APPDIR/relink.png"
ln -s relink.png "$APPDIR/.DirIcon"
cat > "$APPDIR/relink.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Project ReLink
Comment=Builds Zelda: Ocarina of Time (Switch 2 remake) for Linux from your own copy
Exec=AppRun
Icon=relink
Terminal=false
Categories=Game;
X-AppImage-Version=$TAG
EOF
if [[ -n ${APPIMAGE_RUNTIME:-} ]]; then cp "$APPIMAGE_RUNTIME" "$TMP/runtime"; else curl -fsSL -o "$TMP/runtime" "$RUNTIME_URL"; fi
echo "runtime: $(sha256sum "$TMP/runtime" | cut -c1-64)"
mksquashfs "$APPDIR" "$TMP/fs.squashfs" -comp zstd -Xcompression-level 19 -b 1M -root-owned -noappend -quiet
cat "$TMP/runtime" "$TMP/fs.squashfs" > "$OUT/ReLink-x86_64.AppImage"
chmod +x "$OUT/ReLink-x86_64.AppImage"
printf 'tag %s\n' "$TAG" > "$OUT/relink-linux.txt"   # (host/hos_update.c's second way to the latest release)
ls -l "$OUT/ReLink-x86_64.AppImage"
sha256sum "$OUT/ReLink-x86_64.AppImage"
