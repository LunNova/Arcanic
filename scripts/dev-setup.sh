#!/usr/bin/env bash
set -xeuo pipefail

ADDON_NAME=${PWD##*/}
if [ "$ADDON_NAME" == "scripts" ] || [ ! -f "$ADDON_NAME.toc" ]; then
  echo "Call this as scripts/$0 from the root of the repository"
  exit 1
fi

if [ $# -ne 1 ]; then
  echo "Usage: $0 \"wow addons directory\""
  exit 1
fi

if [ ! -d ".release" ]; then
  echo "Making stub .release dir"
  mkdir .release
  pushd .release
  curl https://raw.githubusercontent.com/BigWigsMods/packager/master/release.sh -o release.sh
  mkdir -p $ADDON_NAME/Libs
  popd
fi

bash .release/release.sh

WOW_ADDONS_DIR="$1"
TARGET_DIR="$WOW_ADDONS_DIR/$ADDON_NAME"

if [ ! -d "$WOW_ADDONS_DIR" ]; then
  echo "given wow addons directory $WOW_ADDONS_DIR doesn't exist"
  exit 1
fi

if false && [ -d "$TARGET_DIR" ]; then
  echo "Target addon directory $TARGET_DIR already exists"
  exit 1
fi


pushd ".release/$ADDON_NAME/"
mkdir -p "$TARGET_DIR"
cp -r -t "$TARGET_DIR" *
popd
exit 0

mkdir -p "$TARGET_DIR" Libs/*
RELATIVE_DIR=$(realpath "--relative-to=${TARGET_DIR}" .)
echo "$RELATIVE_DIR"
pushd "$TARGET_DIR"


ln -s "$RELATIVE_DIR/.release/$ADDON_NAME/Libs" "Libs"
ln -s "$RELATIVE_DIR/$ADDON_NAME.toc" "$ADDON_NAME.toc"
ln -s "$RELATIVE_DIR/embeds.xml" "embeds.xml"
ln -s "$RELATIVE_DIR/src" "src"
