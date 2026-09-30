#!/bin/bash
# Builds ClaudeCodexBar.app (macOS 13+, Apple silicon and Intel), installs it to ~/Applications,
# (re)starts it, and packs it into ClaudeCodexBar.dmg for sharing.
set -euo pipefail
cd "$(dirname "$0")"

rm -rf build
mkdir -p build/ClaudeCodexBar.app/Contents/MacOS build/ClaudeCodexBar.app/Contents/Resources
cp icons/*.pdf build/ClaudeCodexBar.app/Contents/Resources/
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target $arch-apple-macos13.0 -o build/ClaudeCodexBar-$arch ClaudeCodexBar.swift
done
lipo -create -output build/ClaudeCodexBar.app/Contents/MacOS/ClaudeCodexBar build/ClaudeCodexBar-arm64 build/ClaudeCodexBar-x86_64
cp Info.plist build/ClaudeCodexBar.app/Contents/
codesign --force --sign - build/ClaudeCodexBar.app

pkill -x ClaudeCodexBar || true
mkdir -p ~/Applications
rm -rf ~/Applications/ClaudeCodexBar.app
cp -R build/ClaudeCodexBar.app ~/Applications/
open ~/Applications/ClaudeCodexBar.app
echo "Installed and started ~/Applications/ClaudeCodexBar.app"

# Disk image to share: the app next to an Applications shortcut to drag it onto.
mkdir build/dmg
cp -R build/ClaudeCodexBar.app build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -quiet -volname ClaudeCodexBar -srcfolder build/dmg -ov -format UDZO ClaudeCodexBar.dmg
echo "Created ClaudeCodexBar.dmg"
