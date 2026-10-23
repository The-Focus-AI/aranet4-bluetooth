#!/bin/bash
#
# Build AranetBar.app and package it as a distributable zip.
#
#   ./package.sh                 # 1.1.0
#   VERSION=1.1.0 ./package.sh
#
set -e

cd "$(dirname "$0")"
VERSION="${VERSION:-1.1.0}"

VERSION="$VERSION" ./build.sh

ZIP="AranetBar-${VERSION}.zip"
rm -f "${ZIP}"

# ditto (not zip) so symlinks, permissions and extended attributes inside the
# bundle survive the round trip.
ditto -c -k --keepParent AranetBar.app "${ZIP}"

echo ""
echo "📦 wrote ${ZIP} ($(du -h "${ZIP}" | cut -f1))"
