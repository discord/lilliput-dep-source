#!/bin/bash
# Build the static archives lilliput-rs links, from the tarballs and patches
# at the root of this repo.
#
#   ./scripts/build-lilliput-rs-deps.sh --arch=amd64
#   ./scripts/build-lilliput-rs-deps.sh --arch=aarch64
#   ./scripts/build-lilliput-rs-deps.sh --osx
#   ./scripts/build-lilliput-rs-deps.sh --arch=amd64 --prefix=/tmp/out
#
# The prefix receives lib/, include/, and BUILD-INFO.json. Everything else
# stays in build/<platform>/.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

usage() {
  echo "usage: $0 --arch=amd64|--arch=aarch64|--osx [--prefix=DIR]" >&2
  exit 1
}

PLATFORM=""
ARCH_ARG=""
OSX=0
PREFIX=""

for arg in "$@"; do
  case "$arg" in
    --arch=*)
      ARCH_ARG=${arg#--arch=}
      ;;
    --osx)
      OSX=1
      ;;
    --prefix=*)
      PREFIX=${arg#--prefix=}
      ;;
    *)
      echo "Unknown parameter: $arg" >&2
      usage
      ;;
  esac
done

if [ "$OSX" -eq 1 ] && [ -n "$ARCH_ARG" ]; then
  echo "--osx and --arch are mutually exclusive" >&2
  exit 1
fi

CC=${CC:-gcc}
CXX=${CXX:-g++}
AR=${AR:-ar}
RANLIB=${RANLIB:-ranlib}
STRIP=${STRIP:-strip}
ARCH_CFLAGS=""
ARCH_CXXFLAGS=""
CMAKE_EXTRA=""
AOM_EXTRA=""
FFMPEG_EXTRA=""
CONFIGURE_HOST=""
OSX_CMAKE=""
ARCH=""
CROSS=0

if [ "$OSX" -eq 1 ]; then
  PLATFORM="osx"
  ARCH=$(uname -m)
  case "$ARCH" in
    arm64)
      FFMPEG_EXTRA="--arch=arm64"
      ;;
    x86_64)
      ARCH_CFLAGS="-march=x86-64-v2 -mtune=generic"
      ARCH_CXXFLAGS="$ARCH_CFLAGS"
      FFMPEG_EXTRA="--arch=x86_64"
      ;;
    *)
      echo "Unsupported macOS architecture: $ARCH" >&2
      exit 1
      ;;
  esac
  OSX_CMAKE="-DCMAKE_OSX_ARCHITECTURES=$ARCH -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0"
  ARCH_CFLAGS="-fPIC -O3 $ARCH_CFLAGS -mmacosx-version-min=14.0"
  ARCH_CXXFLAGS="-fPIC -O3 $ARCH_CXXFLAGS -mmacosx-version-min=14.0 -stdlib=libc++ -std=c++11"
elif [ -n "$ARCH_ARG" ]; then
  case "$ARCH_ARG" in
    amd64)
      ARCH="amd64"
      PLATFORM="linux-amd64"
      ARCH_CFLAGS="-fPIC -O3 -march=x86-64-v3 -mtune=generic"
      ARCH_CXXFLAGS="$ARCH_CFLAGS"
      ;;
    aarch64)
      ARCH="aarch64"
      PLATFORM="linux-aarch64"
      ARCH_CFLAGS="-fPIC -O3 -march=armv8.2-a+crc"
      ARCH_CXXFLAGS="$ARCH_CFLAGS"
      AOM_EXTRA="-DAOM_TARGET_CPU=arm64"
      FFMPEG_EXTRA="--arch=aarch64"
      # GitHub-hosted ubuntu-*-arm runners compile natively. Cross only when
      # this flag is used on an x86_64 machine.
      if [ "$(uname -m)" != "aarch64" ]; then
        CROSS=1
        CC="aarch64-linux-gnu-gcc"
        CXX="aarch64-linux-gnu-g++"
        AR="aarch64-linux-gnu-ar"
        RANLIB="aarch64-linux-gnu-ranlib"
        STRIP="aarch64-linux-gnu-strip"
        CONFIGURE_HOST="aarch64-linux-gnu"
        CMAKE_EXTRA="-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX -DCMAKE_AR=/usr/bin/$AR -DCMAKE_RANLIB=/usr/bin/$RANLIB"
        AOM_EXTRA="$CMAKE_EXTRA $AOM_EXTRA"
        FFMPEG_EXTRA="--arch=aarch64 --target-os=linux --cross-prefix=aarch64-linux-gnu- --enable-cross-compile"
      fi
      ;;
    *)
      echo "Unsupported architecture: $ARCH_ARG" >&2
      usage
      ;;
  esac
else
  usage
fi

if [ -z "$PREFIX" ]; then
  PREFIX="$ROOT/out/$PLATFORM"
fi

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required tool: $1" >&2
    exit 1
  fi
}

require cmake
require make
require python3
require pkg-config
require meson
require ninja
if [ "$ARCH" = "amd64" ] || [ "$ARCH" = "x86_64" ]; then
  require nasm
fi
if [ "$CROSS" -eq 1 ]; then
  require aarch64-linux-gnu-gcc
fi

if [ -z "${MAKEFLAGS:-}" ]; then
  if command -v nproc >/dev/null 2>&1; then
    export MAKEFLAGS="-j$(nproc)"
  else
    export MAKEFLAGS="-j$(sysctl -n hw.ncpu)"
  fi
fi

WORKDIR="$ROOT/build/$PLATFORM"
INSTALL="$WORKDIR/install"
SRC="$WORKDIR/src"

rm -rf "$WORKDIR" "$PREFIX"
mkdir -p "$INSTALL/lib" "$INSTALL/include" "$SRC" "$PREFIX"

check_sha1() {
  local archive="$1"
  echo "checking $archive"
  (cd "$ROOT" && sha1sum -c "$archive.sha1")
}

extract_strip() {
  local archive="$1" dest="$2"
  mkdir -p "$dest"
  tar -xf "$ROOT/$archive" -C "$dest" --strip-components 1
}

extract_into() {
  local archive="$1" dest="$2"
  mkdir -p "$dest"
  tar -xf "$ROOT/$archive" -C "$dest"
}

verify_arch() {
  local file="$1" header expect
  case "$ARCH" in
    aarch64) expect="AArch64" ;;
    amd64) expect="Advanced Micro Devices X86-64" ;;
    *) return 0 ;;
  esac
  # Read the whole header first. grep -q would SIGPIPE readelf, and pipefail
  # would then fail the check on a library that is the right architecture.
  header=$(readelf -h "$file")
  case "$header" in
    *"$expect"*) ;;
    *)
      echo "Error: $file is not $ARCH" >&2
      exit 1
      ;;
  esac
}

export CC CXX AR RANLIB STRIP
export PKG_CONFIG_PATH="$INSTALL/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

echo "--------------------"
echo "libjpeg-turbo 3.1.0"
echo "--------------------"
check_sha1 libjpeg-turbo-3.1.0.tar.gz
extract_strip libjpeg-turbo-3.1.0.tar.gz "$SRC/libjpeg-turbo"
cmake -S "$SRC/libjpeg-turbo" -B "$WORKDIR/libjpeg-turbo" $CMAKE_EXTRA $OSX_CMAKE \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_STATIC=1 \
  -DENABLE_SHARED=0 \
  -DWITH_JPEG8=1 \
  -DCMAKE_INSTALL_PREFIX="$INSTALL" \
  -DCMAKE_C_FLAGS="$ARCH_CFLAGS" \
  -DCMAKE_CXX_FLAGS="$ARCH_CXXFLAGS"
cmake --build "$WORKDIR/libjpeg-turbo"
cmake --install "$WORKDIR/libjpeg-turbo"
verify_arch "$INSTALL/lib/libjpeg.a"

echo "--------------------"
echo "zlib-ng 2.3.3 (zlib-compat)"
echo "--------------------"
check_sha1 zlib-ng-2.3.3.tar.gz
extract_strip zlib-ng-2.3.3.tar.gz "$SRC/zlib-ng"
mkdir -p "$WORKDIR/zlib-ng"
(
  cd "$WORKDIR/zlib-ng"
  CHOST="$CONFIGURE_HOST" \
    CC="$CC" CFLAGS="$ARCH_CFLAGS" \
    AR="$AR" RANLIB="$RANLIB" \
    "$SRC/zlib-ng/configure" \
    --prefix="$INSTALL" \
    --static \
    --zlib-compat
  make
  make install
)
verify_arch "$INSTALL/lib/libz.a"

echo "--------------------"
echo "bzip2 1.0.8"
echo "--------------------"
check_sha1 bzip2-1.0.8.tar.gz
extract_strip bzip2-1.0.8.tar.gz "$SRC/bzip2"
(
  cd "$SRC/bzip2"
  make CC="$CC" AR="$AR" RANLIB="$RANLIB" \
    CFLAGS="-Wall -Winline -O3 -D_FILE_OFFSET_BITS=64 -fPIC $ARCH_CFLAGS" \
    PREFIX="$INSTALL" install
)
verify_arch "$INSTALL/lib/libbz2.a"

echo "--------------------"
echo "dav1d 1.5.1"
echo "--------------------"
check_sha1 dav1d-1.5.1.tar.gz
extract_strip dav1d-1.5.1.tar.gz "$SRC/dav1d"
mkdir -p "$WORKDIR/dav1d"
if [ "$OSX" -eq 1 ] || [ "$CROSS" -eq 0 -a "$ARCH" != "amd64" ]; then
  meson setup "$SRC/dav1d" "$WORKDIR/dav1d" \
    --prefix="$INSTALL" \
    --default-library=static \
    --buildtype=release \
    -Denable_tools=false \
    -Denable_tests=false
else
  meson setup "$SRC/dav1d" "$WORKDIR/dav1d" \
    --prefix="$INSTALL" \
    --default-library=static \
    --buildtype=release \
    -Denable_tools=false \
    -Denable_tests=false \
    --cross-file="$ROOT/scripts/meson-cross-$ARCH.txt"
fi
ninja -C "$WORKDIR/dav1d"
ninja -C "$WORKDIR/dav1d" install
for sub in x86_64-linux-gnu aarch64-linux-gnu; do
  if [ -f "$INSTALL/lib/$sub/libdav1d.a" ]; then
    mv "$INSTALL/lib/$sub/libdav1d.a" "$INSTALL/lib/libdav1d.a"
  fi
  if [ -f "$INSTALL/lib/$sub/pkgconfig/dav1d.pc" ]; then
    mkdir -p "$INSTALL/lib/pkgconfig"
    mv "$INSTALL/lib/$sub/pkgconfig/dav1d.pc" "$INSTALL/lib/pkgconfig/dav1d.pc"
  fi
done
verify_arch "$INSTALL/lib/libdav1d.a"

echo "--------------------"
echo "libaom 3.11.0"
echo "--------------------"
check_sha1 libaom-3.11.0.tar.gz
extract_into libaom-3.11.0.tar.gz "$SRC/aom"
cmake -S "$SRC/aom" -B "$WORKDIR/aom" $CMAKE_EXTRA $AOM_EXTRA $OSX_CMAKE \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_TESTS=0 \
  -DENABLE_TOOLS=0 \
  -DENABLE_DOCS=0 \
  -DENABLE_EXAMPLES=0 \
  -DCMAKE_INSTALL_PREFIX="$INSTALL" \
  -DCMAKE_C_FLAGS="$ARCH_CFLAGS" \
  -DCMAKE_CXX_FLAGS="$ARCH_CXXFLAGS" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
cmake --build "$WORKDIR/aom"
cmake --install "$WORKDIR/aom"
verify_arch "$INSTALL/lib/libaom.a"

echo "--------------------"
echo "ffmpeg 7.0.2"
echo "--------------------"
check_sha1 ffmpeg-7.0.2.orig.tar.xz
extract_strip ffmpeg-7.0.2.orig.tar.xz "$SRC/ffmpeg"
(
  cd "$SRC/ffmpeg"
  for patch in \
    0004-ffmpeg-mov-read-trun-ctts-shift.patch \
    0005-ffmpeg-mov-frag-index-current.patch \
    0006-ffmpeg-mov-ipma-property-index-0.patch \
    0007-ffmpeg-mov-ipco-seekback.patch \
    0008-ffmpeg-mov-bound-ipco-ipma-by-iprp.patch \
    0009-ffmpeg-mov-zero-ctts-gap.patch
  do
    patch -p1 < "$ROOT/$patch"
  done
)
mkdir -p "$WORKDIR/ffmpeg"
(
  cd "$WORKDIR/ffmpeg"
  "$SRC/ffmpeg/configure" $FFMPEG_EXTRA \
    --prefix="$INSTALL" \
    --enable-static \
    --disable-shared \
    --disable-doc \
    --disable-programs \
    --disable-everything \
    --enable-demuxer=mov \
    --enable-demuxer=matroska \
    --enable-demuxer=aac \
    --enable-demuxer=flac \
    --enable-demuxer=mp3 \
    --enable-demuxer=ogg \
    --enable-demuxer=wav \
    --enable-decoder=mpeg4 \
    --enable-decoder=h264 \
    --enable-decoder=hevc \
    --enable-decoder=vp9 \
    --enable-decoder=vp8 \
    --enable-decoder=av1 \
    --enable-decoder=flac \
    --enable-decoder=mp3 \
    --enable-decoder=aac \
    --enable-decoder=vorbis \
    --enable-decoder=libaom \
    --enable-decoder=libdav1d \
    --enable-libaom \
    --enable-libdav1d \
    --enable-zlib \
    --enable-bzlib \
    --extra-cflags="-I$INSTALL/include $ARCH_CFLAGS" \
    --extra-cxxflags="$ARCH_CXXFLAGS" \
    --extra-ldflags="-L$INSTALL/lib" \
    --pkg-config-flags="--static" \
    --disable-iconv \
    --disable-cuda \
    --disable-cuvid \
    --disable-nvenc \
    --disable-xlib
  make
  make install
)
verify_arch "$INSTALL/lib/libavcodec.a"
verify_arch "$INSTALL/lib/libavformat.a"
verify_arch "$INSTALL/lib/libavutil.a"
verify_arch "$INSTALL/lib/libswscale.a"

echo "--------------------"
echo "libyuv"
echo "--------------------"
check_sha1 libyuv-4ed75166cf1885b9690214b362f8675294505a37-2025-04-07.tar.gz
extract_into libyuv-4ed75166cf1885b9690214b362f8675294505a37-2025-04-07.tar.gz "$SRC/libyuv"
cmake -S "$SRC/libyuv" -B "$WORKDIR/libyuv" $CMAKE_EXTRA $OSX_CMAKE \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_INSTALL_PREFIX="$INSTALL" \
  -DCMAKE_C_FLAGS="$ARCH_CFLAGS" \
  -DCMAKE_CXX_FLAGS="$ARCH_CXXFLAGS"
cmake --build "$WORKDIR/libyuv"
if [ -f "$WORKDIR/libyuv/libyuv.a" ]; then
  cp -L "$WORKDIR/libyuv/libyuv.a" "$INSTALL/lib/libyuv.a"
else
  find "$WORKDIR/libyuv" -name 'libyuv.a' -exec cp -L {} "$INSTALL/lib/libyuv.a" \;
fi
mkdir -p "$INSTALL/include"
cp -R "$SRC/libyuv/include/." "$INSTALL/include/"
verify_arch "$INSTALL/lib/libyuv.a"

echo "--------------------"
echo "libavif 1.1.1"
echo "--------------------"
check_sha1 libavif-1.1.1.tar.gz
extract_strip libavif-1.1.1.tar.gz "$SRC/libavif"
cmake -S "$SRC/libavif" -B "$WORKDIR/libavif" $CMAKE_EXTRA $OSX_CMAKE \
  -DCMAKE_BUILD_TYPE=Release \
  -DAVIF_CODEC_AOM=SYSTEM \
  -DAVIF_CODEC_DAV1D=SYSTEM \
  -DAVIF_LIBYUV=SYSTEM \
  -DAVIF_BUILD_APPS=OFF \
  -DAVIF_BUILD_TESTS=OFF \
  -DLIBYUV_LIBRARY="$INSTALL/lib/libyuv.a" \
  -DLIBYUV_INCLUDE_DIR="$INSTALL/include" \
  -DAOM_LIBRARY="$INSTALL/lib/libaom.a" \
  -DAOM_INCLUDE_DIR="$INSTALL/include" \
  -DDAV1D_LIBRARY="$INSTALL/lib/libdav1d.a" \
  -DDAV1D_INCLUDE_DIR="$INSTALL/include" \
  -DCMAKE_PREFIX_PATH="$INSTALL" \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_INSTALL_PREFIX="$INSTALL" \
  -DCMAKE_C_FLAGS="$ARCH_CFLAGS" \
  -DCMAKE_CXX_FLAGS="$ARCH_CXXFLAGS"
cmake --build "$WORKDIR/libavif"
cmake --install "$WORKDIR/libavif"
verify_arch "$INSTALL/lib/libavif.a"

echo "--------------------"
echo "packing keep-set"
echo "--------------------"
ARCHIVES="libturbojpeg.a libjpeg.a libavif.a libaom.a libdav1d.a libyuv.a libavformat.a libavcodec.a libswscale.a libavutil.a libz.a libbz2.a"
HEADER_DIRS="avif libavcodec libavformat libavutil libswscale"

mkdir -p "$PREFIX/lib" "$PREFIX/include"
for archive in $ARCHIVES; do
  if [ ! -f "$INSTALL/lib/$archive" ]; then
    echo "missing $INSTALL/lib/$archive" >&2
    exit 1
  fi
  cp -L "$INSTALL/lib/$archive" "$PREFIX/lib/$archive"
  verify_arch "$PREFIX/lib/$archive"
done
for dir in $HEADER_DIRS; do
  if [ ! -d "$INSTALL/include/$dir" ]; then
    echo "missing $INSTALL/include/$dir" >&2
    exit 1
  fi
  cp -R "$INSTALL/include/$dir" "$PREFIX/include/"
done

SOURCE_COMMIT=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
RELEASE_TAG=$(git -C "$ROOT" describe --tags --exact-match HEAD 2>/dev/null || echo unknown)

python3 - "$PREFIX" "$PLATFORM" "$SOURCE_COMMIT" "$RELEASE_TAG" <<'PY'
import hashlib, json, sys
from pathlib import Path

prefix, platform, commit, tag = sys.argv[1:]
root = Path(prefix)
archives = {}
for path in sorted((root / "lib").glob("*.a")):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    archives[f"lib/{path.name}"] = digest
info = {
    "release_tag": tag,
    "source_commit": commit,
    "platform": platform,
    "packages": {
        "libjpeg-turbo": "3.1.0",
        "zlib-ng": "2.3.3",
        "bzip2": "1.0.8",
        "dav1d": "1.5.1",
        "libaom": "3.11.0",
        "ffmpeg": "7.0.2",
        "ffmpeg_patches": [
            "0004-ffmpeg-mov-read-trun-ctts-shift.patch",
            "0005-ffmpeg-mov-frag-index-current.patch",
            "0006-ffmpeg-mov-ipma-property-index-0.patch",
            "0007-ffmpeg-mov-ipco-seekback.patch",
            "0008-ffmpeg-mov-bound-ipco-ipma-by-iprp.patch",
            "0009-ffmpeg-mov-zero-ctts-gap.patch",
        ],
        "libyuv": "4ed75166cf1885b9690214b362f8675294505a37",
        "libavif": "1.1.1",
    },
    "archives": archives,
}
(root / "BUILD-INFO.json").write_text(json.dumps(info, indent=2) + "\n")
PY

echo "Done: $PREFIX"
find "$PREFIX" -type f | sort
