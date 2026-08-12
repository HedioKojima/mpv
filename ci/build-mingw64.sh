#!/bin/bash -e

prefix_dir=$PWD/mingw_prefix
mkdir -p "$prefix_dir"
ln -snf . "$prefix_dir/usr"
ln -snf . "$prefix_dir/local"

wget="wget --progress=bar:force"
gitclone="git clone --depth=1 --recursive --shallow-submodules"

if [[ -z "$TARGET" ]]; then
    echo "Error: must set TARGET" >&2
    exit 1
fi

if [[ "$TARGET" != "x86_64-w64-mingw32" ]]; then
    echo "Error: this build only supports x86_64-w64-mingw32" >&2
    exit 1
fi

if ! command -v pkg-config >/dev/null; then
    echo "Error: missing pkg-config" >&2
    exit 1
fi

# llvm-mingw
export CC="$TARGET-clang"
export AS="$TARGET-clang"
export CXX="$TARGET-clang++"
export AR="$TARGET-ar"
export NM="$TARGET-nm"
export RANLIB="$TARGET-ranlib"
export STRIP="$TARGET-strip"
export WINDRES="$TARGET-windres"
export DLLTOOL="$TARGET-dlltool"

# Optimization
export CFLAGS="-O3 -pipe -Wall"
export CXXFLAGS="-O3 -pipe -Wall"
export LDFLAGS="-fstack-protector-strong -fuse-ld=lld"

. ./ci/build-common.sh

# Anything that uses pkg-config
export PKG_CONFIG_SYSROOT_DIR="$prefix_dir"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_SYSROOT_DIR/lib/pkgconfig"

# autotools(-like)
at_flags="--disable-static --enable-shared"

# meson
fam=x86_64

cat >"$prefix_dir/crossfile" <<EOF
[built-in options]
buildtype = 'release'
wrap_mode = 'nodownload'
default_library = 'shared'

[binaries]
c = ['ccache', '${CC}']
cpp = ['ccache', '${CXX}']
ar = '${AR}'
nm = '${NM}'
strip = '${STRIP}'
pkgconfig = 'pkg-config'
pkg-config = 'pkg-config'
windres = '${WINDRES}'
dlltool = '${DLLTOOL}'
nasm = 'nasm'
exe_wrapper = 'wine'

[host_machine]
system = 'windows'
cpu_family = '${fam}'
cpu = 'x86_64'
endian = 'little'
EOF

# CMake
cmake_args=(
    -Wno-dev
    -GNinja
    -DCMAKE_SYSTEM_PROCESSOR="${fam}"
    -DCMAKE_SYSTEM_NAME=Windows
    -DCMAKE_FIND_ROOT_PATH="$PKG_CONFIG_SYSROOT_DIR"
    -DCMAKE_C_COMPILER="${CC}"
    -DCMAKE_CXX_COMPILER="${CXX}"
    -DCMAKE_RC_COMPILER="${WINDRES}"
    -DCMAKE_ASM_COMPILER="$AS"
    -DCMAKE_AR="${AR}"
    -DCMAKE_NM="${NM}"
    -DCMAKE_RANLIB="${RANLIB}"
    -DCMAKE_STRIP="${STRIP}"
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=ON
    -DCMAKE_C_FLAGS="$CFLAGS"
    -DCMAKE_CXX_FLAGS="$CXXFLAGS"
)

# Use ccache through the compiler launcher rather than changing
# the compiler path itself.
export CCACHE_BASEDIR="${CCACHE_BASEDIR:-$PWD}"
export CCACHE_DIR="${CCACHE_DIR:-$PWD/.ccache}"

function builddir {
    [ -d "$1/builddir" ] && rm -rf "$1/builddir"
    mkdir -p "$1/builddir"
    pushd "$1/builddir"
}

function makeplusinstall {
    if [ -f build.ninja ]; then
        ninja
        DESTDIR="$prefix_dir" ninja install
    else
        make -j$(nproc)
        make DESTDIR="$prefix_dir" install
    fi
}

# $1: URL to download
# $2: directory name inside tar (optional)
function gettar {
    local fname="${1##*/}"
    local dname="$2"

    [ -z "$dname" ] && dname="${fname%.tar.*}"
    [ -d "$dname" ] && return 0

    local cachename="$(md5sum <<<"$1" | cut -d " " -f 1)"

    if [ -s "$fname" ]; then
        :
    elif [[ -n "$DOWNLOAD_CACHE" && -s "$DOWNLOAD_CACHE/$cachename" ]]; then
        cp -v "$DOWNLOAD_CACHE/$cachename" "$fname"
        cachename=
    else
        $wget "$1" -O "$fname" || return 1
    fi

    tar -xaf "$fname" || return 1

    if [ ! -d "$dname" ]; then
        echo "Error: expected $fname to extract to $dname but it was not created" >&2
        return 2
    fi

    if [[ -n "$DOWNLOAD_CACHE" && -n "$cachename" ]]; then
        mkdir -p "$DOWNLOAD_CACHE"
        cp -v "$fname" "$DOWNLOAD_CACHE/$cachename"
    fi
}

function build_if_missing {
    local name=${1//-/_}
    local mark_var=_${name}_mark
    local mark_file=$prefix_dir/${!mark_var}

    [ -e "$mark_file" ] && return 0

    echo "::group::Building $1"
    _$name
    echo "::endgroup::"

    if [ ! -e "$mark_file" ]; then
        echo "Error: Build of $1 completed but $mark_file was not created" >&2
        return 2
    fi
}

## mpv's dependencies

_iconv () {
    local ver=1.19

    gettar "https://ftpmirror.gnu.org/gnu/libiconv/libiconv-${ver}.tar.gz" || \
        gettar "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-${ver}.tar.gz"

    builddir libiconv-${ver}

    ../configure --host=$TARGET $at_flags

    makeplusinstall
    popd
}

_iconv_mark=lib/libiconv.dll.a


_zlib_ng () {
    [ -d zlib-ng ] || \
        $gitclone https://github.com/zlib-ng/zlib-ng.git

    builddir zlib-ng

    cmake .. "${cmake_args[@]}" \
        -DZLIB_COMPAT=ON \
        -DBUILD_TESTING=OFF

    makeplusinstall
    popd

    ln -snf libzlib.dll.a "$prefix_dir/lib/libz.dll.a"
}

_zlib_ng_mark=lib/libzlib.dll.a


_dav1d () {
    [ -d dav1d ] || \
        $gitclone https://code.videolan.org/videolan/dav1d.git

    builddir dav1d

    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Denable_{tools,tests}=false

    makeplusinstall
    popd
}

_dav1d_mark=lib/libdav1d.dll.a


_lcms2 () {
    [ -d lcms2 ] || \
        $gitclone https://github.com/mm2/Little-CMS.git lcms2

    builddir lcms2

    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Dtests=disabled \
        -D{utils,versionedlibs}=false

    makeplusinstall
    popd
}

_lcms2_mark=lib/liblcms2.dll.a


_ffmpeg () {
    [ -d ffmpeg ] || \
        $gitclone https://github.com/FFmpeg/FFmpeg.git ffmpeg

    builddir ffmpeg

    local args=(
        --pkg-config=pkg-config
        --target-os=mingw32
        --enable-gpl
        --enable-cross-compile
        --cross-prefix=$TARGET-
        --arch=x86_64
        --cc="ccache $CC"
        --cxx="ccache $CXX"
        $at_flags
        --disable-{doc,programs}
        --enable-muxer=spdif
        --enable-encoder=mjpeg,png
        --enable-libdav1d
    )

    pkg-config vulkan && args+=(--enable-vulkan)

    ../configure "${args[@]}"

    makeplusinstall
    popd
}

_ffmpeg_mark=lib/libavcodec.dll.a


_shaderc () {
    if [ ! -d shaderc ]; then
        $gitclone https://github.com/google/shaderc.git
        (cd shaderc && ./utils/git-sync-deps)
    fi

    builddir shaderc

    cmake .. "${cmake_args[@]}" \
        -DBUILD_SHARED_LIBS=OFF \
        -DSHADERC_SKIP_TESTS=ON

    makeplusinstall
    popd
}

_shaderc_mark=lib/libshaderc_shared.dll.a


_spirv_cross () {
    [ -d SPIRV-Cross ] || \
        $gitclone https://github.com/KhronosGroup/SPIRV-Cross.git

    builddir SPIRV-Cross

    cmake .. "${cmake_args[@]}" \
        -DSPIRV_CROSS_SHARED=ON \
        -DSPIRV_CROSS_{CLI,STATIC}=OFF

    makeplusinstall
    popd
}

_spirv_cross_mark=lib/libspirv-cross-c-shared.dll.a


_nv_headers () {
    [ -d nv-codec-headers ] || \
        $gitclone https://github.com/FFmpeg/nv-codec-headers.git

    pushd nv-codec-headers

    makeplusinstall

    popd
}

_nv_headers_mark=include/ffnvcodec/dynlink_loader.h


_vulkan_headers () {
    [ -d Vulkan-Headers ] || \
        $gitclone https://github.com/KhronosGroup/Vulkan-Headers.git

    builddir Vulkan-Headers

    cmake .. "${cmake_args[@]}"

    makeplusinstall
    popd
}

_vulkan_headers_mark=include/vulkan/vulkan.h


_vulkan_loader () {
    [ -d Vulkan-Loader ] || \
        $gitclone https://github.com/KhronosGroup/Vulkan-Loader.git

    builddir Vulkan-Loader

    cmake .. "${cmake_args[@]}" \
        -DUSE_GAS=ON

    makeplusinstall
    popd
}

_vulkan_loader_mark=lib/libvulkan-1.dll.a


_libplacebo () {
    [ -d libplacebo ] || \
        $gitclone https://code.videolan.org/videolan/libplacebo.git

    builddir libplacebo

    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Ddemos=false \
        -D{opengl,d3d11,lcms}=enabled

    makeplusinstall
    popd
}

_libplacebo_mark=lib/libplacebo.dll.a


_freetype () {
    [ -d freetype ] || \
        $gitclone https://github.com/freetype/freetype.git

    builddir freetype

    meson setup .. --cross-file "$prefix_dir/crossfile"

    makeplusinstall
    popd
}

_freetype_mark=lib/libfreetype.dll.a


_fribidi () {
    [ -d fribidi ] || \
        $gitclone https://github.com/fribidi/fribidi.git

    builddir fribidi

    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -D{tests,docs}=false

    makeplusinstall
    popd
}

_fribidi_mark=lib/libfribidi.dll.a


_harfbuzz () {
    [ -d harfbuzz ] || \
        $gitclone https://github.com/harfbuzz/harfbuzz.git

    builddir harfbuzz

    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Dtests=disabled

    makeplusinstall
    popd
}

_harfbuzz_mark=lib/libharfbuzz.dll.a


_libass () {
    [ -d libass ] || \
        $gitclone https://github.com/libass/libass.git

    builddir libass

    meson setup .. --cross-file "$prefix_dir/crossfile"

    makeplusinstall
    popd
}

_libass_mark=lib/libass.dll.a


_luajit () {
    [ -d LuaJIT ] || \
        $gitclone https://github.com/LuaJIT/LuaJIT.git

    pushd LuaJIT

    local hostcc="ccache cc"

    make TARGET_SYS=Windows clean

    make TARGET_SYS=Windows \
        HOST_CC="$hostcc" \
        CROSS="ccache $TARGET-" \
        BUILDMODE=static \
        XCFLAGS="$CFLAGS" \
        amalg

    make DESTDIR="$prefix_dir" \
        INSTALL_DEP= \
        FILE_T=luajit.exe \
        install

    popd
}

_luajit_mark=lib/libluajit-5.1.a


_curl () {
    [ -d curl ] || \
        $gitclone https://github.com/curl/curl.git

    builddir curl

    cmake .. "${cmake_args[@]}" \
        -DCURL_{USE_SCHANNEL,ZLIB}=ON \
        -DCURL_DISABLE_LDAP=ON \
        -DCURL_USE_LIBPSL=OFF

    makeplusinstall
    popd
}

_curl_mark=lib/libcurl.dll.a


# Build dependencies.
for x in iconv zlib-ng shaderc spirv-cross nv-headers dav1d lcms2; do
    build_if_missing $x
done

build_if_missing vulkan-headers
build_if_missing vulkan-loader

for x in ffmpeg libplacebo freetype fribidi harfbuzz libass luajit curl; do
    build_if_missing $x
done


## mpv

if [ -z "$1" ]; then
    echo "Not building mpv."
    exit 0
fi

CFLAGS+=" -I'$prefix_dir/include'"
LDFLAGS+=" -L'$prefix_dir/lib'"

export CFLAGS LDFLAGS

build=mingw_build
rm -rf "$build"

mpv_args=(
    --cross-file "$prefix_dir/crossfile"
    $common_args
    --buildtype release
    -Dlua=luajit
    -D{shaderc,spirv-cross,d3d11,libcurl}=enabled
    -Djavascript=disabled
    -Damf=disabled
)

meson setup "$build" "${mpv_args[@]}"
meson compile -C "$build"


if [ "$2" = pack ]; then
    mkdir -p artifact/tmp

    echo "Copying:"
    cp -pv \
        "$build/mpv.com" \
        "$build/mpv.exe" \
        etc/mpv-*.bat \
        artifact/

    echo "Adding dependency DLLs:"

    shopt -s nullglob

    # DLLs built by the dependency chain.
    for file in "$prefix_dir/bin/"*.dll; do
        cp -p "$file" artifact/tmp/
    done

    # llvm-mingw runtime DLLs.
    LLVM_MINGW_BIN="/opt/llvm-mingw/$TARGET/bin"

    for file in \
        "$LLVM_MINGW_BIN/libc++.dll" \
        "$LLVM_MINGW_BIN/libunwind.dll" \
        "$LLVM_MINGW_BIN/libwinpthread-1.dll"
    do
        [ -f "$file" ] && cp -p "$file" artifact/tmp/
    done

    echo "Selecting DLLs:"

    pushd artifact/tmp

    dlls=(
        # llvm-mingw runtime
        libc++.dll
        libunwind.dll
        libwinpthread-1.dll

        # FFmpeg
        av*.dll
        sw*.dll
        postproc-[0-9]*.dll

        # Everything else
        lib{ass,freetype,fribidi,harfbuzz,iconv,placebo}-[0-9]*.dll
        lib{curl,shaderc_shared,spirv-cross-c-shared,dav1d,lcms2,zlib1}.dll
    )

    [[ -f vulkan-1.dll ]] && dlls+=(vulkan-1.dll)

    # Remove names that don't exist.
    existing=()

    for file in "${dlls[@]}"; do
        for match in $file; do
            [ -f "$match" ] && existing+=("$match")
        done
    done

    if [ "${#existing[@]}" -eq 0 ]; then
        echo "Error: no DLLs selected for packaging" >&2
        exit 2
    fi

    mv -v "${existing[@]}" ..

    popd

    rm -rf artifact/tmp
fi
