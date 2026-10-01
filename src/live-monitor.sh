#!/bin/bash
# Keep this file beside Mac Resource Check.command.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
scanner="$script_dir/Mac Resource Check.command"
if [[ ! -f "$scanner" ]]; then
    printf 'Keep Live Monitor.command beside Mac Resource Check.command, then run it again.\n' >&2
    exit 1
fi
exec /bin/bash "$scanner" --watch 30 "$@"
