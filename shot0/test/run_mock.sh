#!/bin/bash
# shot0模擬試験の実行(非GPU・実機無変更)。gccのみ必要。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(mktemp -t shot0_mock.XXXXXX)
trap 'rm -f "$BIN"' EXIT
gcc -Wall -Wextra -O2 -o "$BIN" "$HERE/shot0_mock.c"
"$BIN"
