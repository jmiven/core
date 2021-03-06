#!/usr/bin/env bash
set -e -u -o pipefail

if [ $# -lt 4 ]; then
    echo "Usage: discover.sh OCAML OCAMLC CONFIG_MLH CONFIG_H" >&2
    exit 2
fi

OCAML="$1"
OCAMLC="$2"
CONFIG_MLH="$3"
CONFIG_H="$4"
shift 4

if getconf GNU_LIBC_VERSION | \
    awk -F '[ .]' '{ exit ($2 > 2 || ($2 == 2 && $3 >= 8) ? 0 : 1) }'; then
    set -- -DTIMERFD "$@"
fi

function cpp_test () {
    local name="$1"
    local cond="$2"
    if [[ "$#" == 3 ]]; then
        local warning="$3"
    else
        local warning="Feature $1 will not be availlable"
    fi
    cat <<EOF
#if ${cond}
printf ("#let $name = true\n");
#else
printf ("#let $name = false\n");
EOF
if [[ "$warning" != "" ]]; then
cat <<EOF
#  warning "cpp test --${cond}-- was false"
#  warning "$warning"
EOF
fi
echo "#endif"
}

WORD_SIZE="$(${OCAML} <( echo "print_int Sys.word_size;;"))"
SRC="$(x=$(mktemp "./discover_src.XXXXXXX") && mv "$x"{,.c} && echo "$x".c)"
PGM="$(mktemp "./discover.XXXXXXX")"
OUT="$(mktemp "./discover.out.XXXXXXX")"


trap "rm -f $SRC $PGM $OUT" EXIT
cat > "$SRC" <<EOF
#include <stdio.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/resource.h>
# $LINENO "$(basename "${BASH_SOURCE[0]}")"
int main () {
  $(cpp_test JSC_LINUX_EXT    "defined(LINUX_EXT)")
  $(cpp_test JSC_THREAD_ID    "defined(LINUX_EXT) || defined(__OpenBSD__)")
  $(cpp_test JSC_POSIX_TIMERS "defined(POSIX_TIMERS)")
  $(cpp_test JSC_TIMERFD      "defined(TIMERFD)")
  $(cpp_test JSC_RLIMIT_AS    "defined(RLIMIT_AS)")
  $(cpp_test JSC_RLIMIT_NICE  "defined(RLIMIT_NICE)")
  $(cpp_test JSC_WORDEXP      "defined(WORDEXP)")
  $(if [[ ${WORD_SIZE} = 64 ]]; then
       echo 'printf ("#let JSC_ARCH_SIXTYFOUR = true\n");';
    else
       echo 'printf ("#let JSC_ARCH_SIXTYFOUR = false\n");';
    fi)
  $(if [[ $(uname -p) = "x86_64" ]]; then
       echo 'printf ("#let JSC_ARCH_x86_64 = true\n");';
    else
       echo 'printf ("#let JSC_ARCH_x86_64 = false\n");';
    fi)
  $(if [[ $(uname -p) = "i386" ]]; then
       echo 'printf ("#let JSC_ARCH_i386 = true\n");';
    else
       echo 'printf ("#let JSC_ARCH_i386 = false\n");';
    fi)
  $(cpp_test JSC_MSG_NOSIGNAL "defined MSG_NOSIGNAL" \
     "Bigstring.(unsafe_|really_)?send(to)?(_noblocking)?_no_sigpipe\
 will not be available")
  $(cpp_test JSC_MUTEX_TIMED_LOCK \
     "defined(_POSIX_TIMEOUTS) && (_POSIX_TIMEOUTS > 0)")

  $(cpp_test JSC_FDATASYNC \
     "defined(_POSIX_SYNCHRONIZED_IO) && _POSIX_SYNCHRONIZED_IO > 0")

  $(cpp_test JSC_THREAD_CPUTIME \
	  "defined(_POSIX_THREAD_CPUTIME)")

  return 0;
}
EOF
# Maybe we should leverage the ocaml compiler in here instead of hardcoding
# gcc
gcc "$SRC" -o "$PGM" "$@"
rm "$SRC"
"$PGM" > "$OUT"

# The recvmmsg system call was added in Linux 2.6.32, so is in CentOS
# 6, but not 5.
#
cat > "$SRC" <<EOF
#define _GNU_SOURCE
#include <sys/socket.h>
int main () { return recvmmsg(0, 0, 0, 0, 0); }
EOF
if gcc "$SRC" -o "$PGM" "$@"; then
    echo '#let JSC_RECVMMSG = true' >>"$OUT";
else
    echo '#let JSC_RECVMMSG = false' >>"$OUT";
fi
rm "$SRC"

rm -f "$PGM"
mv "$OUT" "$CONFIG_MLH"

sentinel="CORE_$(basename "$CONFIG_H" | tr a-z. A-Z_)"
cat > $OUT <<EOF
#ifndef $sentinel
#define $sentinel

$(sed -r 's|^#let *([A-Za-z0-9_]+) *= *true *$|#define \1|;
          s|^#let *([A-Za-z0-9_]+) *= *false *$|/* #define \1 */|;
          s|^#let *([A-Za-z0-9_]+) *= *([0-9]+) *$|#define \1 \2|' \
  "$CONFIG_MLH")

#endif
EOF
mv $OUT "$CONFIG_H"
