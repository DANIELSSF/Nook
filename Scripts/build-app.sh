#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
bash Scripts/bootstrap-tmux.sh
swift build -c "$configuration" --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
binary_directory="$(swift build -c "$configuration" --show-bin-path --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox)"
app_directory="$PWD/dist/Nook.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources/Licenses"
# Replaced, not overwritten: a running Nook keeps executing the old file instead of being killed for a changed signature.
cp "$binary_directory/Nook" "$app_directory/Contents/MacOS/Nook.new"
mv -f "$app_directory/Contents/MacOS/Nook.new" "$app_directory/Contents/MacOS/Nook"
cp Resources/Info.plist "$app_directory/Contents/Info.plist"
cp Resources/tmux.conf "$app_directory/Contents/Resources/tmux.conf"
cp Resources/claude-commands.json Resources/codex-commands.json "$app_directory/Contents/Resources/"
cp Vendor/bin/tmux "$app_directory/Contents/Resources/tmux"
cp Vendor/TMUX-LICENSE "$app_directory/Contents/Resources/Licenses/tmux.txt"
cp -f .build/checkouts/SwiftTerm/LICENSE "$app_directory/Contents/Resources/Licenses/SwiftTerm.txt"
if [ -f /opt/homebrew/opt/libevent/LICENSE ]; then cp /opt/homebrew/opt/libevent/LICENSE "$app_directory/Contents/Resources/Licenses/libevent.txt"; fi
if [ -f Resources/Nook.icns ]; then cp Resources/Nook.icns "$app_directory/Contents/Resources/Nook.icns"; fi
codesign --force --sign - --identifier dev.nook.tmux "$app_directory/Contents/Resources/tmux"
# Ad-hoc signatures default to a requirement on the binary's exact hash, so macOS forgot the
# Accessibility and Automation permissions with every build. Requiring only the identifier keeps them.
codesign --force --sign - --identifier dev.nook.mac -r='designated => identifier "dev.nook.mac"' "$app_directory"
echo "$app_directory"
