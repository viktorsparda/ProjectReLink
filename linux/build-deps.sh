#!/usr/bin/env bash
# The libraries and headers a Linux build of ReLink needs that a distribution does not give in the right form, built once
# into one prefix (by default /opt/relink-deps, what linux/Containerfile does):
#
#   <prefix>/ffmpeg   FFmpeg as static libraries with only what host/nn_video.c uses (the VP8 and VP9 decoders, AV1 through
#                     dav1d, swscale, swresample). Static, so the game runs on the host whatever FFmpeg it has (Bazzite's and
#                     Fedora's differ), and nx2/build.py takes it with RELINK_FFMPEG=<prefix>/ffmpeg.
#   <prefix>/cpm      the Vulkan and SPIR-V headers and VulkanMemoryAllocator, at the versions .github/workflows/windows.yml
#                     pins, in the CPM cache layout nx2/build.py reads (RX_CPM=<prefix>/cpm).
#
#   bash linux/build-deps.sh [prefix]
#
# Needs git, a C compiler, make, nasm, meson, ninja and pkg-config. Everything is fetched with git (tags), nothing else.
# CC: the C compiler (default cc); scripts/linux/appimage.sh passes the clang it bundles.
set -euo pipefail

PREFIX=${1:-/opt/relink-deps}
CC=${CC:-cc}
export CC
JOBS=${JOBS:-$(nproc)}
DAV1D_TAG=1.5.1
FFMPEG_TAG=n7.1.1
VK_HEADERS_TAG=v1.4.345            # (74d8a6cb930c68ef617b202c3ff3c59d919e086b)
SPIRV_HEADERS_TAG=vulkan-sdk-1.4.341.0   # (04f10f650d514df88b76d25e83db360142c7b174)
VMA_TAG=v3.3.0                     # (1d8f600fd424278486eade7ed3e877c99f0846b1)

say() { printf '\n==> %s\n' "$*"; }
clone() {   # clone <url> <tag> <dir>
    rm -rf "$3"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$2" "$1" "$3"
}

mkdir -p "$PREFIX"
SRC=$(mktemp -d)
trap 'rm -rf "$SRC"' EXIT

say "Vulkan headers, SPIR-V headers, VulkanMemoryAllocator -> $PREFIX/cpm"
clone https://github.com/KhronosGroup/Vulkan-Headers "$VK_HEADERS_TAG" "$PREFIX/cpm/vulkanheaders/$VK_HEADERS_TAG"
clone https://github.com/KhronosGroup/SPIRV-Headers "$SPIRV_HEADERS_TAG" "$PREFIX/cpm/spirv-headers/$SPIRV_HEADERS_TAG"
clone https://github.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator "$VMA_TAG" "$PREFIX/cpm/vulkanmemoryallocator/$VMA_TAG"
rm -rf "$PREFIX"/cpm/*/*/.git

FF=$PREFIX/ffmpeg
say "dav1d $DAV1D_TAG (static) -> $FF"
clone https://github.com/videolan/dav1d "$DAV1D_TAG" "$SRC/dav1d"
meson setup "$SRC/dav1d/build" "$SRC/dav1d" --prefix="$FF" --libdir=lib --buildtype=release \
    --default-library=static -Denable_tools=false -Denable_tests=false -Db_staticpic=true >/dev/null
ninja -C "$SRC/dav1d/build" -j "$JOBS" install >/dev/null

say "FFmpeg $FFMPEG_TAG (static, VP8/VP9/AV1 decoders only) -> $FF"
clone https://github.com/FFmpeg/FFmpeg "$FFMPEG_TAG" "$SRC/ffmpeg"
(
    cd "$SRC/ffmpeg"
    PKG_CONFIG_PATH="$FF/lib/pkgconfig" ./configure --cc="$CC" --prefix="$FF" --libdir="$FF/lib" \
        --enable-static --disable-shared --enable-pic --disable-autodetect --disable-programs --disable-doc \
        --disable-network --disable-everything --disable-avdevice --disable-avformat --disable-avfilter \
        --enable-avcodec --enable-swscale --enable-swresample \
        --enable-libdav1d --enable-decoder=vp8,vp9,av1,libdav1d \
        --extra-cflags="-I$FF/include" --extra-ldflags="-L$FF/lib" >/dev/null
    make -j "$JOBS" >/dev/null
    make install >/dev/null
)
for l in avcodec swscale swresample avutil dav1d; do
    test -f "$FF/lib/lib$l.a" || { echo "build-deps: lib$l.a was not made" >&2; exit 1; }
done
say "done: RELINK_FFMPEG=$FF RX_CPM=$PREFIX/cpm"
