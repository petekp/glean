#!/bin/bash

# Raycast Script Command wrapper for glean.
#
# @raycast.schemaVersion 1
# @raycast.title Glean Text
# @raycast.mode silent
# @raycast.packageName Glean
# @raycast.icon 🔍
# @raycast.description Drag a region of the screen; its text lands on the clipboard.
# @raycast.author Pete Petrash
# @raycast.authorURL https://github.com/petekp

# `mode: silent` keeps Raycast's window from stealing focus or covering the
# screen you are about to select from — the crosshair needs an unobstructed view.
#
# stdout goes to /dev/null because in silent mode Raycast pops its own HUD showing
# the *last* line of it — so a captured paragraph flashed its closing fragment and
# nothing else. glean draws its own panel now; this keeps the two from stacking.
exec "$HOME/.local/bin/glean" >/dev/null
