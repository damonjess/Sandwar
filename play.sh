#!/usr/bin/env bash
# Play Sandwar.
set -euo pipefail
cd "$(dirname "$0")"
exec "$HOME/.local/bin/godot" --path . "$@"
