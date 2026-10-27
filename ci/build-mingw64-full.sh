#!/usr/bin/env bash
#
# Static mpv builds on top of the FFmpeg-Tinderbox container images
# (ghcr.io/nanake/win64-nonfree, see https://github.com/nanake/ffmpeg-tinderbox).
# The image ships the mingw-w64/UCRT cross toolchain, a matching /cross.meson and
# every FFmpeg dependency as static library in $FFBUILD_PREFIX, so only FFmpeg
# itself and the things FFmpeg does not need are built here. Run it from the mpv
# source tree inside the container:
#
#   docker run --rm -v "$PWD:/mpv" -w /mpv \
#       ghcr.io/nanake/win64-nonfree:latest ./ci/build-mingw64-full.sh
#
# The mpv binaries end up in artifact/.
#
# [HedioKojima/mpv] 本文件基于上游 mpv-player/mpv master 的同名脚本修改：
#   0. [换镜像] 构建镜像从 BtbN 的 win64-gpl 换成 nanake 的 win64-nonfree，随之
#      而来的差异都在本脚本内消化：
#      - Tinderbox 镜像只导出 FFBUILD_* / CC / CFLAGS 这一套变量，不导出
#        FF_CONFIGURE、FF_CFLAGS、FF_CXXFLAGS、FF_LDFLAGS、FF_LIBS（那是
#        BtbN 镜像 build 时固化的），所以 FFmpeg 的 configure 参数由本脚本
#        自己拼；HOST_CC/HOST_CFLAGS 见 build-common.sh。
#      - 工具链是 x86_64-w64-mingw32ucrt-（UCRT 目标），镜像里只保留静态库
#        （import library *.dll.a 已被删掉），产物天然是静态链接的。
#      - 镜像里没有 wine，/cross.meson 的 exe_wrapper 找不到也不影响：meson
#        在拿不到可用 exe wrapper 时会跳过"编译后运行"的检查。
#      - FFmpeg 的 pkg-config 文件不写 Libs.private，静态链接的下游必须自己
#        带上它的外部依赖，这里从 ffbuild/config.mak 的 EXTRALIBS 中取出。
#   1. 只打包 mpv.exe/mpv.com，不再打包 libmpv（配合 build-common.sh 中
#      -Dlibmpv=false 使用，Packaging 段删掉了 artifact-libmpv 相关内容）。
#   2. 不编 subrandr（-Dsubrandr=disabled），因此也不再需要 rust 工具链；
#      其余构建流程（FFmpeg / LuaJIT / cppwinrt / mpv）与上游一致。
#   3. [体积裁剪] FFmpeg 只开必要的外部库（dav1d/zimg/svtav1/jxl/webp/openssl，
#      nonfree 再加 fdk-aac/mpeghdec），其余靠下面的 --disable 兜底：编码器
#      （x264/x265/aom/vpx/lame/xvid/vvenc/openh264/kvazaar/twolame/theora/
#      vorbis/opus，原生解码不受影响）、冷门解码（AVS2/AVS3/APV/LCEVC/AMR/gme/
#      openmpt/zvbi/arib/openjpeg）、滤镜杂项（whisper/vmaf/vidstab/chromaprint/
#      frei0r/lv2/avisynth/snappy/soxr/sdl2/opencl/devices）、网络协议
#      （ssh/srt/rist/zmq/rubberband）；mpv 侧禁用 rubberband。
#      注意：FFmpeg 的 configure 默认 disable 掉整个 EXTERNAL_LIBRARY_LIST，所以
#      这串 --disable 现在大多只是"防止上游哪天改回默认开"的兜底；vulkan、
#      d3d11va/dxva2、nvdec/cuvid、schannel、libcurl、zlib 属于自动探测项。
#   4. [体积裁剪 2] --disable-encoders 全关编码器，仅保留 png/mjpeg/libwebp/
#      libsvtav1/libjxl 供 mpv 截图使用；--o 转码与 stream-record 因此不可用。
#      --disable-decoder 关掉定点重复解码器（aac/ac3/mp1/mp2/mp3/mp3adu/
#      mp3on4 的 fixed 版），float 版保留，播放不受影响。
#   5. [体积裁剪 3] --disable-amf / --disable-libvpl：去掉 AMD AMF 编码封装与
#      Intel QSV(libvpl) 接口、mpv 的 vf_amf 滤镜。AMD/Intel 硬解走内置的
#      d3d11va 不受影响，NVIDIA nvdec 保留。
#   6. [nonfree] 镜像的 nonfree 变体同时含 GPL 与非自由组件（fdk-aac /
#      xHE-AAC / MPEG-H / LCEVC / DeckLink），所以要 --enable-gpl
#      --enable-version3 --enable-nonfree；许可证文件也随之取 LICENSE.GPL。
#      实际启用的是 fdk-aac 解码器与 MPEG-H 解码：xHE-AAC 只有编码器（编码器
#      整体关闭），LCEVC/DeckLink 按第 3 条继续砍掉。
set -euo pipefail

: "${FFBUILD_PREFIX:?not running in a FFmpeg-Tinderbox image}"
: "${VARIANT:?not running in a FFmpeg-Tinderbox image}"

. ./ci/build-common.sh

# The dependency headers are not ours to fix, keep --werror to mpv's own code.
CFLAGS="${CFLAGS/-I${FFBUILD_PREFIX}\/include/-isystem${FFBUILD_PREFIX}/include}"
CXXFLAGS="${CXXFLAGS/-I${FFBUILD_PREFIX}\/include/-isystem${FFBUILD_PREFIX}/include}"

# 变体名对应 https://github.com/nanake/ffmpeg-tinderbox/tree/master/variants
# （win64-nonfree 镜像里 VARIANT=nonfree）。nonfree 变体本身也开着 GPL 组件。
gpl=false
nonfree=false
case $VARIANT in
    nonfree*) gpl=true; nonfree=true ;;
    gpl*)     gpl=true ;;
esac

gitclone="git clone --depth=1 --recursive --shallow-submodules"
group() { echo "::group::$1"; }
endgroup() { echo "::endgroup::"; }

group "Building FFmpeg"
$gitclone https://github.com/FFmpeg/FFmpeg.git ffmpeg
pushd ffmpeg
# 线程模型跟镜像里各依赖的编译方式保持一致（scripts.d/10-mingw.sh 用
# --disable-w32threads --enable-pthreads，winpthreads 静态库在 sysroot 里）。
ff_configure=(--enable-pthreads --disable-w32threads)
if $gpl; then
    ff_configure+=(--enable-gpl --enable-version3)
fi
if $nonfree; then
    ff_configure+=(--enable-nonfree)
fi
# BtbN 镜像是把整套 --enable-libxxx 固化成 FF_CONFIGURE 环境变量的，这里没有，
# 得自己列。FFmpeg 的 configure 默认会 disable 掉整个 EXTERNAL_LIBRARY_LIST，
# 只有 EXTERNAL_AUTODETECT_LIBRARY_LIST（zlib/bzlib/lzma/iconv/schannel/libcurl
# 等）和 HWACCEL_AUTODETECT_LIBRARY_LIST（d3d11va/dxva2/nvdec/cuvid/amf/
# vulkan 等）会自动探测，所以下面没列出来的外部库都是"不编"的状态。
ff_configure+=(
    # 网络：镜像里的 libcurl 也是拿这份 openssl 编的，符号复用，基本不涨体积
    --enable-openssl
    # 解码：AV1 用 dav1d，原生解码器太慢
    --enable-libdav1d
    # 滤镜：zscale（mpv 自己直连 zimg，这里是给 lavfi 用的）
    --enable-libzimg
    # 截图编码器：avif(svtav1) / jxl / webp
    --enable-libsvtav1
    --enable-libjxl
    --enable-libwebp
)
if $nonfree; then
    # nonfree：fdk-aac 解码器（AAC/HE-AAC/HE-AACv2，比原生 aac 解码器准）；
    # MPEG-H 3DA 解码。xHE-AAC 那条 --enable-libfdk-xhe-aac 只提供编码器，
    # 播放用不上（编码器本来也被 --disable-encoders 关了），故不启用。
    ff_configure+=(--enable-libfdk-aac --enable-libmpeghdec)
fi
./configure --prefix="$FFBUILD_PREFIX" --pkg-config-flags="--static" \
            $FFBUILD_TARGET_FLAGS "${ff_configure[@]}" \
            --enable-static --disable-shared --disable-{doc,programs,debug} \
            --disable-{librav1e,librsvg,openal} \
            --disable-{libx264,libx265,libaom,libvpx,libmp3lame,libxvid,libvvenc,libopenh264,libkvazaar,libtwolame,libtheora,libvorbis,libopus} \
            --disable-{libdavs2,libxavs2,libuavs3d,liboapv,liblcevc-dec,libopencore-amrnb,libopencore-amrwb,libgme,libopenmpt,libzvbi,libaribb24,libaribcaption,libopenjpeg} \
            --disable-{whisper,libvmaf,libvidstab,chromaprint,frei0r,lv2,avisynth,libsnappy,libsoxr,sdl2,opencl} \
            --disable-devices \
            --disable-{libssh,libsrt,librist,libzmq,librubberband} \
            --disable-{amf,libvpl,vapoursynth,gmp} \
            --disable-encoders --enable-encoder={png,mjpeg,libwebp,libsvtav1,libjxl} \
            --disable-decoder={aac_fixed,ac3_fixed,mp1,mp2,mp3,mp3adu,mp3on4} || { cat ffbuild/config.log; exit 1; }
make -j"$(nproc)"
make install
# FFmpeg 的 .pc 只有 -lavcodec 之类，没有 Libs.private；它自己链 ffmpeg.exe 时靠
# 的就是 config.mak 里的 EXTRALIBS。mpv 静态链接 libav* 需要同一份列表。
ff_extralibs="$(sed -n 's/^EXTRALIBS=//p' ffbuild/config.mak | head -n 1)"
test -n "$ff_extralibs"
popd
endgroup

group "Building LuaJIT"
$gitclone -b v2.1 https://github.com/LuaJIT/LuaJIT.git
pushd LuaJIT
# Strip -ldl, not needed for Windows.
sed -i "/^Libs\.private/d" etc/luajit.pc
# FILE_T and INSTALL_DEP are only needed to glue install target.
make TARGET_SYS=Windows PREFIX="$FFBUILD_PREFIX" HOST_CC="$HOST_CC" \
     CFLAGS="$HOST_CFLAGS" CROSS="$FFBUILD_CROSS_PREFIX" TARGET_CFLAGS="$CFLAGS" \
     BUILDMODE=static XCFLAGS=-DLUAJIT_ENABLE_LUA52COMPAT FILE_T=luajit.exe \
     INSTALL_DEP=src/luajit.exe amalg install
popd
endgroup

group "Building cppwinrt"
# win32-smtc needs the C++/WinRT projection headers, generated from the
# Windows metadata that windows-rs carries.
cppwinrt_ver=2.0.250303.1
windows_rs_ver=73
wget -q "https://github.com/microsoft/cppwinrt/archive/${cppwinrt_ver}.tar.gz" -O - | tar -xz
git clone --depth=1 --filter=blob:none --sparse -b "$windows_rs_ver" \
    https://github.com/microsoft/windows-rs.git
git -C windows-rs sparse-checkout set crates/libs/bindgen/default
mkdir -p "cppwinrt-$cppwinrt_ver/build"
pushd "cppwinrt-$cppwinrt_ver/build"
CFLAGS="$HOST_CFLAGS" CXXFLAGS="$HOST_CXXFLAGS" LDFLAGS= \
    cmake -GNinja -DCMAKE_CXX_COMPILER="$HOST_CXX" -DCMAKE_BUILD_TYPE=Release \
          -DCPPWINRT_BUILD_VERSION="$cppwinrt_ver" ..
ninja cppwinrt
./cppwinrt -input ../../windows-rs/crates/libs/bindgen/default \
           -output "$FFBUILD_PREFIX/include"
popd
endgroup

group "Building mpv"
mkdir -p subprojects
meson wrap install mujs
meson subprojects download

# -static-libgcc / -static-libstdc++ 只写在 LDFLAGS 里，显式 -Dc_link_args 会盖掉
# meson 从环境变量取到的值，所以这里把 $LDFLAGS 一起带上。--start-group 让 ld
# 反复扫描这批静态库，省得为顺序操心（libav* 的依赖是平铺的 -l 列表）。
# FFmpeg 是按 pthreads 编的，-pthread 只在 configure 内部的 CFLAGS 里，不会进
# EXTRALIBS，所以这里按需补上 winpthreads（镜像里 import library 已删，-l 会
# 落到静态库上）。
pthread_lib=""
if "${FFBUILD_CROSS_PREFIX}gcc" -print-file-name=libwinpthread.a | grep -q /; then
    pthread_lib="-lwinpthread"
fi
link_args="$LDFLAGS -Wl,--start-group $ff_extralibs -lstdc++ $pthread_lib -Wl,--end-group"

mpv_args=(
    --cross-file /cross.meson $common_args
    --buildtype=release
    --prefer-static
    --default-library=shared
    -Dc_link_args="$link_args"
    -Dcpp_link_args="$link_args"
    -Dgpl=$gpl
    --force-fallback-for=mujs
    -Dmujs:werror=false
    -Dmujs:default_library=static
    -Dlua=luajit
    -D{d3d11,javascript,lcms2,libbluray,libcurl,shaderc,spirv-cross}=enabled
    -D{vulkan,win32-smtc,zimg}=enabled
    # [HedioKojima/mpv] 不要 subrandr（省掉 rust 工具链与一整轮 cargo 构建）
    -Dsubrandr=disabled
)
if $gpl; then
    # Only the GPL/nonfree images carry the dependencies of the GPL features.
    mpv_args+=(-D{dvda,dvdnav}=enabled)
fi
# [HedioKojima/mpv] 体积裁剪：禁用 rubberband（变速变调）与 vf_amf（AMD GPU 滤镜）
mpv_args+=(-Drubberband=disabled -Damf=disabled)
meson setup build "${mpv_args[@]}"
meson compile -C build
endgroup

group "Packaging"
license=LICENSE.LGPL
if $gpl; then
    license=LICENSE.GPL
fi
# [HedioKojima/mpv] 只打包 mpv 本体，不打包 libmpv
mkdir -p artifact
cp -p build/mpv.{exe,com} etc/mpv-*.bat "$license" artifact/
"${FFBUILD_CROSS_PREFIX}strip" artifact/mpv.{exe,com}
ls -l artifact
endgroup
