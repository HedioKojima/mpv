common_args="--werror \
-Dlibmpv=false \
-Dtests=false \
"

export CFLAGS="$CFLAGS -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3"
