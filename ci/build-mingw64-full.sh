#!/usr/bin/env bash
#
# Self-contained mpv + libmpv win64 build using the llvm-mingw toolchain
# (Kosm8/llvm-mingw release, installed by the workflow into ./llvm).
#
# Unlike the upstream mpv ci/build-mingw64-full.sh, this script builds EVERY
# mpv dependency from git master itself, and it does NOT use the FFmpeg-Builds
# container image at all. Package recipes follow Kosm8/mpv-winbuild (rm) where
# they are llvm-mingw-proven, BtbN/FFmpeg-Builds and shinchiro/mpv-winbuild
# otherwise.
#
# Run from the mpv source tree (llvm-mingw unpacked next to it as ./llvm):
#
#   ./ci/build-mingw64-full.sh
#
# A single static mpv.exe/mpv.com ends up in artifact/ (no libmpv).
#
# Version policy: everything tracks git master. The only pinned things are
# libiconv (GNU release tarball: the savannah git needs a gnulib bootstrap
# whose Makefile.devel pins versioned autotools), the cppwinrt/windows-rs
# versions inherited from the upstream mpv CI script (bump them together
# with upstream), and shaderc's glslang/spirv-* submodules which follow the
# known-good pointers of the shaderc repo itself.
#
# ffmpeg encoders are disabled except what mpv screenshots/spdif need
# (libjxl/png/ac3/dca/eac3/truehd). Features intentionally disabled:
# javascript(mujs), libsixel, subrandr, vapoursynth, libcurl, rubberband,
# dvdnav, cuda-hwaccel, cdda, openal, sdl2, pulse, egl-angle, amf.
set -euo pipefail

# ===========================layout===========================================

TARGET=x86_64-w64-mingw32
LLVM_DIR=$PWD/llvm
PREFIX=$LLVM_DIR/$TARGET
CROSS_FILE=$PWD/meson-cross.txt
TOOLCHAIN_FILE=$PWD/toolchain.cmake

[[ -x "$LLVM_DIR/bin/clang" ]] || {
    echo "llvm-mingw not found in $LLVM_DIR (workflow should unpack it there)" >&2
    exit 1
}

# ===========================toolchain========================================

export PATH="$LLVM_DIR/bin:$PATH"
export CC=$TARGET-gcc
export CXX=$TARGET-g++
export AS=$TARGET-gcc
export AR=$TARGET-ar
export RANLIB=$TARGET-ranlib
export NM=$TARGET-nm
# -O3 baseline, Zen 3+ only (znver3 binaries do NOT run on Zen1/Zen2/Intel).
export CFLAGS="-O3 -pipe -march=znver3"
export CXXFLAGS="$CFLAGS"
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"

# meson cross file. prefer_static/wrap_mode=nofallback here apply to every
# meson package including mpv: no leftover libs, no meson wraps.
cat > "$CROSS_FILE" <<EOF
[binaries]
c = '$TARGET-gcc'
cpp = '$TARGET-g++'
as = '$TARGET-gcc'
ar = '$TARGET-ar'
strip = '$TARGET-strip'
windres = '$TARGET-windres'
dlltool = '$TARGET-dlltool'
pkg-config = 'pkg-config'
nasm = 'nasm'

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[built-in options]
prefix = '$PREFIX'
libdir = '$PREFIX/lib'
buildtype = 'release'
default_library = 'static'
prefer_static = true
wrap_mode = 'nofallback'
EOF

# cmake toolchain file
cat > "$TOOLCHAIN_FILE" <<EOF
SET(CMAKE_SYSTEM_NAME Windows)
SET(CMAKE_SYSTEM_PROCESSOR x86_64)

SET(CMAKE_C_COMPILER $TARGET-gcc)
SET(CMAKE_CXX_COMPILER $TARGET-g++)
SET(CMAKE_ASM_COMPILER $TARGET-gcc)
SET(CMAKE_RC_COMPILER_INIT $TARGET-windres)

SET(CMAKE_FIND_ROOT_PATH $PREFIX)
SET(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
SET(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
SET(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF

gpl=true

gitclone="git clone --depth=1 --recursive --shallow-submodules"

group() { echo "::group::$1"; }
endgroup() { echo "::endgroup::"; }

# meson package: static/prefix/buildtype come from the cross file.
meson_build() {
    local src="$1"; shift
    mkdir -p "$src/build"
    pushd "$src/build" >/dev/null
    meson setup --cross-file="$CROSS_FILE" "$@" ..
    ninja -j"$(nproc)"
    ninja install
    popd >/dev/null
}

# cmake package
cmake_build() {
    local src="$1"; shift
    mkdir -p "$src/build"
    pushd "$src/build" >/dev/null
    cmake -GNinja -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" "$@" ..
    ninja -j"$(nproc)"
    ninja install
    popd >/dev/null
}

# ===========================基础链===========================================

group "Building zlib"
$gitclone https://github.com/madler/zlib.git
pushd zlib
./configure --prefix="$PREFIX" --static
make -j"$(nproc)"
make install
popd
endgroup

group "Building libiconv"
# GNU release tarball ships a pre-generated configure: no savannah git, no
# gnulib bootstrap (its Makefile.devel pins versioned autotools like
# aclocal-1.18, which the runner lacks). Recipe from Kosm8/rm
# packages/libiconv.cmake; hash verified against the aliyun GNU mirror.
tarball=libiconv-1.19.tar.gz
curl -sL "https://www.mirrorservice.org/sites/ftp.gnu.org/gnu/libiconv/$tarball" -o "$tarball"
echo "88dd96a8c0464eca144fc791ae60cd31cd8ee78321e67397e25fc095c4a19aa6  $tarball" | sha256sum -c -
rm -rf libiconv-1.19
tar -xzf "$tarball"
pushd libiconv-1.19
./configure --host="$TARGET" --prefix="$PREFIX" --disable-shared --enable-extra-encodings --disable-nls
make -j"$(nproc)"
make install
popd
endgroup

group "Building brotli"
$gitclone https://github.com/google/brotli.git
cmake_build brotli -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF
endgroup

group "Building fast_float"
$gitclone https://github.com/fastfloat/fast_float.git
cmake_build fast_float -DBUILD_TESTING=OFF
endgroup

group "Building xxhash"
# The official cmake project lives in build/cmake, not the repo root
# (Kosm8: -S <src>/build/cmake). Default branch is dev; no submodules.
$gitclone https://github.com/Cyan4973/xxHash.git
mkdir -p xxhash-build
pushd xxhash-build
cmake -GNinja -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF -DXXHASH_BUILD_XXHSUM=OFF -DDISPATCH=ON \
    ../xxHash/build/cmake
ninja -j"$(nproc)"
ninja install
popd
endgroup

# ===========================libass 链========================================

group "Building freetype"
$gitclone https://gitlab.freedesktop.org/freetype/freetype.git
meson_build freetype -Dzlib=enabled -Dbzip2=disabled -Dpng=disabled \
    -Dbrotli=disabled -Dharfbuzz=disabled
endgroup

group "Building fribidi"
$gitclone https://github.com/fribidi/fribidi.git
meson_build fribidi -Ddocs=false -Dbin=false -Dtests=false
sed -i 's/^Cflags:/Cflags: -DFRIBIDI_LIB_STATIC/' "$PREFIX"/lib/pkgconfig/fribidi.pc
endgroup

group "Building harfbuzz"
$gitclone https://github.com/harfbuzz/harfbuzz.git
meson_build harfbuzz -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled \
    -Dcairo=disabled -Dchafa=disabled -Dtests=disabled \
    -Dintrospection=disabled -Ddocs=disabled -Dutilities=disabled
echo "Libs.private: -lpthread" >> "$PREFIX"/lib/pkgconfig/harfbuzz.pc
endgroup

group "Building libunibreak"
$gitclone https://github.com/adah1972/libunibreak.git
pushd libunibreak
# autogen.sh runs ./configure itself unless NOCONFIGURE is set; the bare
# run would fail cross-compile checks (PE binaries can't execute on Linux).
NOCONFIGURE=1 ./autogen.sh
./configure --host="$TARGET" --prefix="$PREFIX" --disable-shared
make -j"$(nproc)"
make install
popd
endgroup

group "Building libass"
$gitclone https://github.com/libass/libass.git
# Inline env: keep the read_file shim out of later packages (single-script,
# unlike BtbN's per-package docker layers).
CFLAGS="$CFLAGS -Dread_file=libass_internal_read_file" \
    meson_build libass -Dtest=disabled -Dcompare=disabled -Dprofile=disabled \
    -Dfuzz=disabled -Dcheckasm=disabled -Dasm=enabled \
    -Dfontconfig=disabled -Ddirectwrite=enabled -Dlibunibreak=enabled
endgroup

# ===========================解码/色彩链=====================================

group "Building dav1d"
$gitclone https://code.videolan.org/videolan/dav1d.git
meson_build dav1d -Denable_tests=false -Denable_tools=false -Denable_examples=false
endgroup

group "Building lcms2"
$gitclone https://github.com/mm2/Little-CMS.git
meson_build Little-CMS -Dfastfloat=true
endgroup

group "Building highway"
$gitclone https://github.com/google/highway.git
meson_build highway -Dcontrib=disabled -Dexamples=disabled -Dtests=disabled \
    -Dtest_standalone=true -Drvv=false
endgroup

group "Building libjxl"
$gitclone https://github.com/libjxl/libjxl.git
cmake_build libjxl \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF -DJPEGXL_STATIC=ON -DBUILD_TESTING=OFF \
    -DJPEGXL_ENABLE_SKCMS=OFF -DJPEGXL_FORCE_SYSTEM_LCMS2=ON \
    -DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_FORCE_SYSTEM_HWY=ON \
    -DJPEGXL_ENABLE_HWY_AVX3=OFF -DJPEGXL_ENABLE_HWY_AVX3_ZEN4=OFF \
    -DJPEGXL_ENABLE_HWY_AVX3_SPR=OFF \
    -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_VIEWERS=OFF \
    -DJPEGXL_ENABLE_JPEGLI=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF \
    -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_PLUGINS=OFF \
    -DJPEGXL_ENABLE_DEVTOOLS=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF \
    -DJPEGXL_BUNDLE_LIBPNG=OFF -DJPEGXL_ENABLE_SJPEG=OFF \
    -DJPEGXL_EMSCRIPTEN=OFF
# idempotent: append libc++/advapi32 to Libs.private (llvm-mingw C++ runtime)
sed -i -e '/Libs.private:.*/ s/[[:blank:]]*$//' \
    -e '/Libs.private:.*/ { / -lc++$/ ! s/$/ -lc++/ }' \
    -e '/Libs.private:.*/ { / -ladvapi32$/ ! s/$/ -ladvapi32/ }' \
    "$PREFIX"/lib/pkgconfig/libjxl.pc "$PREFIX"/lib/pkgconfig/libjxl_threads.pc
echo "Requires.private: lcms2" >> "$PREFIX"/lib/pkgconfig/libjxl_cms.pc
endgroup

group "Building zimg"
$gitclone https://github.com/sekrit-twc/zimg.git
pushd zimg
# upstream misses a stddef include in the API TU; drop the sed if they fix it
sed -i '1i #include <cstddef>' src/zimg/api/zimg.cpp
./autogen.sh
./configure --host="$TARGET" --prefix="$PREFIX" --disable-shared --enable-static --with-pic
make -j"$(nproc)"
make install
popd
endgroup

# ===========================vulkan 链========================================

group "Building Vulkan-Headers"
$gitclone https://github.com/KhronosGroup/Vulkan-Headers.git
cmake_build Vulkan-Headers -DVULKAN_HEADERS_ENABLE_MODULE=NO \
    -DVULKAN_HEADERS_ENABLE_TESTS=NO -DVULKAN_HEADERS_ENABLE_INSTALL=YES
endgroup

group "Building Vulkan-Shim-Loader"
# BtbN's static vulkan loader. The repo carries Vulkan-Headers as a git
# submodule; the --recursive clone already brings it in, so no manual clone
# (would collide: "destination path already exists").
$gitclone https://github.com/BtbN/Vulkan-Shim-Loader.git
pushd Vulkan-Shim-Loader
mkdir -p build
pushd build
cmake -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DVULKAN_SHIM_IMPERSONATE=ON ..
make -j"$(nproc)"
make install
popd
popd
endgroup

group "Building shaderc"
# shaderc dropped git submodules for a Chromium-style DEPS file; sync the
# known-good third_party pointers with its own tool (BtbN does the same).
$gitclone https://github.com/google/shaderc.git
pushd shaderc
python3 utils/git-sync-deps
mkdir -p build
pushd build
cmake -GNinja -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
    -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON \
    -DSHADERC_SKIP_EXECUTABLES=ON -DSHADERC_SKIP_SPVC=ON \
    -DSHADERC_SKIP_COPYRIGHT_CHECK=ON -DSHADERC_SKIP_INSTALL=ON \
    -DSPIRV_SKIP_EXECUTABLES=ON -DSPIRV_SKIP_TESTS=ON \
    -DSPIRV_WERROR=OFF -DDISABLE_RTTI=ON -DDISABLE_EXCEPTIONS=ON \
    -DENABLE_HLSL=OFF -DSHADERC_ENABLE_HLSL=OFF \
    -DENABLE_SPIRV_TOOLS_INSTALL=ON -DSPIRV_TOOLS_BUILD_STATIC=ON \
    -DSPIRV_TOOLS_LIBRARY_TYPE=STATIC -DMINGW_COMPILER_PREFIX="$TARGET" \
    -DENABLE_GLSLANG_BINARIES=OFF ..
# Flag set mirrors Kosm8/rm (verified green). ENABLE_SPIRV_TOOLS_INSTALL is
# mandatory with current glslang: its install(EXPORT) configure-time check
# requires SPIRV-Tools-opt in the export set even though we never install.
ninja -j"$(nproc)"
popd
mkdir -p "$PREFIX/include/shaderc" "$PREFIX/lib/pkgconfig"
cp -a libshaderc/include/shaderc/. "$PREFIX/include/shaderc/"
cp build/libshaderc/libshaderc_combined.a "$PREFIX/lib/"
cp build/shaderc_combined.pc "$PREFIX/lib/pkgconfig/shaderc.pc"
popd
endgroup

group "Building SPIRV-Cross"
$gitclone https://github.com/KhronosGroup/SPIRV-Cross.git
pushd SPIRV-Cross
mkdir -p build
pushd build
cmake -GNinja -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF -DSPIRV_CROSS_SHARED=OFF -DSPIRV_CROSS_CLI=OFF \
    -DSPIRV_CROSS_ENABLE_TESTS=OFF -DSPIRV_CROSS_ENABLE_MSL=OFF \
    -DSPIRV_CROSS_ENABLE_CPP=OFF -DSPIRV_CROSS_ENABLE_REFLECT=OFF \
    -DSPIRV_CROSS_ENABLE_UTIL=OFF -DSPIRV_CROSS_EXCEPTIONS_TO_ASSERTIONS=ON ..
ninja -j"$(nproc)"
# merge the static libs into one C-API archive (llvm-mingw proven recipe)
llvm-lib /out:libspirv-cross-c.a libspirv-cross-c.a \
    libspirv-cross-core.a libspirv-cross-glsl.a libspirv-cross-hlsl.a
ninja install
popd
# mpv only looks for spirv-cross-c-shared.pc
ln -sf spirv-cross-c.pc "$PREFIX"/lib/pkgconfig/spirv-cross-c-shared.pc
echo "Libs.private: -lc++" >> "$PREFIX"/lib/pkgconfig/spirv-cross-c-shared.pc
popd
endgroup

group "Building libplacebo"
$gitclone https://code.videolan.org/videolan/libplacebo.git
meson_build libplacebo -Dvulkan=enabled -Dvk-proc-addr=enabled \
    -Dvulkan-registry="$PREFIX"/share/vulkan/registry/vk.xml \
    -Dshaderc=enabled -Dglslang=disabled -Dlcms=enabled -Dxxhash=enabled \
    -Dopengl=enabled -Dd3d11=enabled \
    -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false
echo "Libs.private: -lc++" >> "$PREFIX"/lib/pkgconfig/libplacebo.pc
endgroup

# ===========================mpv 直链========================================

group "Building libudfread"
$gitclone https://code.videolan.org/videolan/libudfread.git
meson_build libudfread
endgroup

group "Building libbluray"
$gitclone https://code.videolan.org/videolan/libbluray.git
# drop find_library() which breaks cross builds (must run BEFORE meson)
sed -i '/find_library/d' libbluray/meson.build
meson_build libbluray \
    -Denable_docs=false -Denable_tools=false -Denable_devtools=false \
    -Denable_examples=false -Dbdj_jar=disabled \
    -Dfontconfig=disabled -Dlibxml2=disabled -Dfreetype=enabled \
    -Dc_args="-Ddec_init=libbluray_dec_init -Ddir_open_default=libbluray_dir_open_default -Dfile_open_default=libbluray_file_open_default"
sed -i 's/-lbluray/-lbluray -lgdi32/' "$PREFIX"/lib/pkgconfig/libbluray.pc
endgroup

group "Building libarchive"
$gitclone https://github.com/libarchive/libarchive.git
cmake_build libarchive -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
    -DENABLE_ZLIB=ON -DENABLE_ICONV=ON \
    -DENABLE_{CAT,CPIO,TAR,TEST,UNZIP}=OFF \
    -DENABLE_{LIBXML2,EXPAT,OPENSSL,PCREPOSIX,PCRE2POSIX}=OFF \
    -DENABLE_{BZIP2,LZMA,LZ4,ZSTD,LZO,LIBB2,CNG}=OFF \
    -DENABLE_WIN32_XMLLITE=OFF -DENABLE_ACL=OFF -DENABLE_WERROR=OFF \
    -DPOSIX_REGEX_LIB=OFF -DWINDOWS_VERSION=WIN10
endgroup

group "Building uchardet"
$gitclone https://gitlab.freedesktop.org/uchardet/uchardet.git
cmake_build uchardet -DBUILD_SHARED_LIBS=OFF -DBUILD_BINARY=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
endgroup

group "Building LuaJIT"
$gitclone -b v2.1 https://github.com/LuaJIT/LuaJIT.git
pushd LuaJIT
# libm is the only private dep on llvm-mingw
sed -i 's/^Libs.private:.*/Libs.private: -lm/' etc/luajit.pc
# FILE_T and INSTALL_DEP are only needed to glue the install target
make TARGET_SYS=Windows clean
make TARGET_SYS=Windows PREFIX="$PREFIX" HOST_CC=gcc CROSS="$TARGET-" \
    TARGET_CFLAGS="$CFLAGS" BUILDMODE=static FILE_T=luajit.exe \
    INSTALL_DEP=src/luajit.exe amalg
make TARGET_SYS=Windows PREFIX="$PREFIX" FILE_T=luajit.exe \
    INSTALL_DEP= install
popd
endgroup

group "Building cppwinrt"
# win32-smtc needs the C++/WinRT projection headers, generated from the
# Windows metadata that windows-rs carries. Versions follow upstream mpv CI.
cppwinrt_ver=2.0.250303.1
windows_rs_ver=73

# cppwinrt source tarball; tag has no "v" prefix. (The nuget package is a
# zip and ships a Windows exe -- useless on the Linux runner.)
wget -q "https://github.com/microsoft/cppwinrt/archive/refs/tags/$cppwinrt_ver.tar.gz" -O - | tar -xz

git clone --depth=1 --filter=blob:none --sparse -b "$windows_rs_ver" \
    https://github.com/microsoft/windows-rs.git

git -C windows-rs sparse-checkout set crates/libs/bindgen/default

mkdir -p "cppwinrt-$cppwinrt_ver/build"
pushd "cppwinrt-$cppwinrt_ver/build"

# host build: override the target CFLAGS/XXFLAGS (znver3 is meaningless here)
CFLAGS="-O2 -pipe" CXXFLAGS="-O2 -pipe" LDFLAGS= \
cmake -GNinja -DCMAKE_CXX_COMPILER=g++ -DCMAKE_BUILD_TYPE=Release \
    -DCPPWINRT_BUILD_VERSION="$cppwinrt_ver" ..
ninja cppwinrt

./cppwinrt -input ../../windows-rs/crates/libs/bindgen/default \
    -output "$PREFIX/include"

popd
endgroup

# ===========================FFmpeg===========================================

group "Building FFmpeg"
# Only the libs mpv actually needs: zlib, iconv, dav1d (AV1), libjxl
# (jpeg-xl decode + screenshot), zimg, schannel (https/m3u8).
# Built-in hwaccels (d3d11va/dxva2) are always on for mingw targets.
$gitclone https://github.com/FFmpeg/FFmpeg.git ffmpeg
pushd ffmpeg
# llvm-mingw ships no $TARGET-pkg-config, and ffmpeg configure does NOT read
# the PKG_CONFIG env var: it defaults to ${cross_prefix}pkg-config and
# silently degrades to /bin/false when missing (-> "dav1d not found using
# pkg-config"). Pass it explicitly; search dirs come from the global
# PKG_CONFIG_LIBDIR export above.
./configure --prefix="$PREFIX" --pkg-config=pkg-config --pkg-config-flags="--static" \
    --cross-prefix="$TARGET-" --arch=x86_64 --target-os=mingw32 \
    --enable-cross-compile \
    --enable-gpl --enable-static --disable-shared --disable-{doc,programs} \
    --disable-autodetect --disable-debug --disable-avdevice \
    --enable-runtime-cpudetect --enable-lto=thin \
    --enable-{zlib,iconv,libdav1d,libjxl,libzimg,schannel,d3d11va,d3d12va} \
    --disable-encoders \
    --enable-encoder={libjxl,png,ac3,dca,eac3,truehd} \
    --disable-{librav1e,librsvg,openal} \
    || { cat ffbuild/config.log; exit 1; }
make -j"$(nproc)"
make install
popd
endgroup

# ===========================mpv=============================================

group "Building mpv"
common_args="--werror \
-Dlibmpv=false \
-Dtests=true \
"

mpv_args=(
    --cross-file "$CROSS_FILE" $common_args
    # static single-file exe; crossfile built-ins already set
    # buildtype=release / default_library=static / prefer_static=true
    -Db_ndebug=true
    -Db_lto=true
    -Db_lto_mode=thin
    # meson issue 10172: --prefer-static meson searches for libiconv only in
    # the compiler's own directories.
    -Dc_link_args="-L$PREFIX/lib -liconv"
    # uchardet master deprecates uchardet_get_charset, which mpv master still
    # uses (and mpv builds with -Werror) -- silence until mpv switches API.
    -Dc_args="-Wno-deprecated-declarations" \
    -Dcpp_link_args="-L$PREFIX/lib -liconv"
    -Dgpl=$gpl
    -Dlua=luajit
    -D{d3d11,iconv,lcms2,libarchive,libbluray,shaderc,spirv-cross,uchardet,vulkan,win32-smtc,zimg,zlib}=enabled
    # Explicitly disable everything not built above, so nothing unwanted gets
    # picked up accidentally (crossfile already sets wrap_mode=nofallback).
    -D{cdda,cuda-hwaccel,jpeg,javascript,libcurl,openal,pulse,rubberband,sdl2-audio,sdl2-video,sixel,subrandr,vapoursynth,dvdnav,egl-angle,egl-angle-lib,egl-angle-win32}=disabled
)

meson setup "${mpv_args[@]}" build
ninja -C build
endgroup

group "Packaging"
mkdir -p artifact
cp build/mpv.{exe,com} artifact/
ls -l artifact
endgroup
