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
exec "$HOME/.local/bin/glean"
