#!/bin/sh
# Builds Book/index.html (Help › Manual) from the chapters here. Needs pandoc.
set -eu
cd "$(dirname "$0")"
rm -rf Book
mkdir -p Book/images
cp images/*.jpg Book/images/
pandoc 0*.md --standalone --toc --toc-depth=2 --metadata title="PhotoWagon Manual" \
  --include-in-header=style.html --output=Book/index.html
