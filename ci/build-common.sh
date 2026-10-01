# [HedioKojima/mpv] 基于上游 mpv-player/mpv master 的同名文件修改：
#   -Dlibmpv=false   只编译 mpv.exe，不编 libmpv（上游是 true）
#   -Dtests=false    不编测试（上游是 true，省时间）
#   去掉 --werror    上游用来兜编译警告的；个人仓库追求"总能编出来"，
#                    上游 master 偶发的警告不再导致构建失败。想跟上游完全
#                    一致可把 --werror 加回去。
common_args="-Dlibmpv=false \
-Dtests=false \
"

export CFLAGS="$CFLAGS -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3"

build_subrandr() {
    git clone --depth=1 https://github.com/afishhh/subrandr.git
    pushd subrandr
    cargo xtask install --prefix "$@"
    popd
}
