#!/bin/sh
# kitty graphics protocol check for helm terminals — run INSIDE the terminal
# under test (a helm tab, or any terminal you want to compare against):
#
#   sh tools/kitty-icat-test.sh
#
# WORKS:  a small four-color square (red/green over blue/yellow) renders
#         between the marker lines.
# BROKEN: nothing appears between the markers (the sequence was consumed but
#         not rendered), or raw base64 garbage is printed (the APC sequence
#         was not consumed at all).
#
# Self-contained on purpose: the payload is a 115-byte 32x32 PNG generated
# offline and embedded below as base64 — no ImageMagick, no network, no kitty
# install needed. The escape is the kitty graphics APC form
#   ESC _ G f=100,a=T ; <base64 PNG> ESC \
# where f=100 declares PNG data and a=T means transmit-and-display in one
# step. The payload is far under the protocol's 4096-byte chunk limit, so no
# chunking (m=) is required. Expected outcomes and context are documented in
# docs/SPIKE.md ("Kitty graphics verification").

# 32x32 RGB PNG, four 16x16 quadrants: red, green / blue, yellow.
PNG_B64="iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAOklEQVR42mO4Y6RPEmqdyUASYhi1YNSCUQtGLRi1YEhYoNZ9iSS0tZOBJDRqwagFoxaMWjBqwZCwAAD2UBxMBLSZiwAAAABJRU5ErkJggg=="

printf 'kitty graphics test: a colored square should appear below\n'
printf -- '--- begin ---\n'
printf '\033_Gf=100,a=T;%s\033\\' "$PNG_B64"
printf '\n--- end ---\n'
printf 'square visible: kitty graphics work | nothing/garbage: not supported\n'
