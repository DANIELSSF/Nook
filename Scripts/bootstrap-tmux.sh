#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Vendor/downloads Vendor/bin
if [ -x Vendor/bin/tmux ]; then exit 0; fi
curl --fail --location --retry 2 https://github.com/tmux/tmux/releases/download/3.5a/tmux-3.5a.tar.gz -o Vendor/downloads/tmux-3.5a.tar.gz
mkdir -p Vendor/tmux-source
tar -xzf Vendor/downloads/tmux-3.5a.tar.gz -C Vendor/tmux-source --strip-components=1
cd Vendor/tmux-source
event_prefix="$(brew --prefix libevent 2>/dev/null || true)"
if [ -z "$event_prefix" ]; then
    echo 'Se necesita libevent para compilar tmux: brew install libevent' >&2
    exit 1
fi
LIBEVENT_CFLAGS="-I$event_prefix/include" LIBEVENT_LIBS="$event_prefix/lib/libevent_core.a" ./configure --disable-utf8proc
make -j4
cp tmux ../bin/tmux
cp COPYING ../TMUX-LICENSE
