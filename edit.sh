#!/usr/bin/env bash
# Open Sandwar in the Godot editor.
set -euo pipefail
cd "$(dirname "$0")"
exec "$HOME/.local/bin/godot" --path . --editor "$@"
