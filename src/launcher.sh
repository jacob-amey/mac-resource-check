#!/bin/bash
# Mac Resource Check __VERSION__. Uses only tools included with macOS.
# Read-only collection; never quits a process or changes system settings.
set -euo pipefail
export LC_ALL=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
launcher_path="$script_dir/$(basename -- "$0")"
output_dir="$script_dir/Reports"
sample_seconds=12
watch_seconds=0
open_report=1
open_only=0
browser=default
history_limit=40
lock_file=""
sleep_pid=""
version="__VERSION__"

usage() {
    cat <<'HELP'
Mac Resource Check — a sorted visual report of macOS resource usage

Double-click this .command file for a detailed 12-second scan and automatic browser launch.

Options:
  --seconds N      Sample for N seconds (2–120, rounded up to 2-second intervals)
  --watch N        Repeat every N seconds (10–3600); stop with Control-C
  --output DIR     Save HTML, JSON, and CSV in DIR (default: Reports beside script)
  --browser NAME   default, safari, chrome, firefox, edge, or brave
  --open-only      Open the existing dashboard without taking a new scan
  --history N      Keep the last N scans for comparisons (1–120; default: 40)
  --quick          Take a shorter 4-second sample
  --no-open        Save the report without opening a browser
  --version        Show the program version
  --help           Show this help

Examples:
  bash "Mac Resource Check.command"
  bash "Mac Resource Check.command" --seconds 20
  bash "Mac Resource Check.command" --watch 30

No extra installs, administrator privileges, or internet connection required.
Power is a CPU / idle-wakeup proxy, not watts or Activity Monitor Energy Impact.
HELP
}
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
integer() { [[ "$1" =~ ^[0-9]+$ ]] && (( ${#1} <= 4 )); }
while (( $# )); do
    case "$1" in
        --seconds)
            [[ $# -ge 2 ]] || fail '--seconds needs a number.'
            integer "$2" || fail '--seconds must be an integer from 2 to 120.'
            sample_seconds=$((10#$2))
            (( sample_seconds >= 2 && sample_seconds <= 120 )) || fail '--seconds must be from 2 to 120.'
            shift 2 ;;
        --watch)
            [[ $# -ge 2 ]] || fail '--watch needs a number.'
            integer "$2" || fail '--watch must be an integer from 10 to 3600.'
            watch_seconds=$((10#$2))
            (( watch_seconds >= 10 && watch_seconds <= 3600 )) || fail '--watch must be from 10 to 3600.'
            shift 2 ;;
        --output)
            [[ $# -ge 2 && -n "$2" ]] || fail '--output needs a folder path.'
            output_dir="$2"; shift 2 ;;
        --no-open) open_report=0; shift ;;
        --quick) sample_seconds=4; shift ;;
        --open-only) open_only=1; shift ;;
        --browser)
            [[ $# -ge 2 ]] || fail '--browser needs a name.'
            case "$2" in default|safari|chrome|firefox|edge|brave) browser="$2" ;; *) fail 'Unsupported browser. Use default, safari, chrome, firefox, edge, or brave.' ;; esac
            shift 2 ;;
        --history)
            [[ $# -ge 2 ]] || fail '--history needs a number.'
            integer "$2" || fail '--history must be an integer from 1 to 120.'
            history_limit=$((10#$2))
            (( history_limit >= 1 && history_limit <= 120 )) || fail '--history must be from 1 to 120.'
            shift 2 ;;
        --version) printf 'Mac Resource Check %s\n' "$version"; exit 0 ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown option: $1. Use --help for usage." ;;
    esac
done
[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail 'This script requires macOS.'
samples=$(((sample_seconds + 1) / 2 + 1))
effective_seconds=$(((samples - 1) * 2))
if (( watch_seconds && watch_seconds < effective_seconds + 2 )); then
    fail '--watch must be at least two seconds longer than the sample window.'
fi
/bin/mkdir -p -- "$output_dir" || fail 'Could not create the report folder. Try --output with a writable folder.'
output_dir="$(cd -- "$output_dir" && pwd -P)"
temp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/mac-resource-check.XXXXXXXX")"
cleanup() {
    if [[ -n "$sleep_pid" ]]; then
        kill -TERM "$sleep_pid" 2>/dev/null || true
        wait "$sleep_pid" 2>/dev/null || true
    fi
    /bin/rm -rf -- "$temp_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
collector_pid=$$
collector_uid="$(/usr/bin/id -u)"
report_file="$output_dir/Mac Resource Report.html"

cat > "$temp_dir/renderer.js" <<'RESOURCE_CHECK_JXA'
__RENDERER__
RESOURCE_CHECK_JXA

optional_read() {
    local label="$1" destination="$2"
    shift 2
    if ! "$@" > "$destination" 2> "$temp_dir/optional-error.txt"; then
        : > "$destination"
        printf '%s unavailable; the rest of the report is still usable.\n' "$label" >> "$temp_dir/warnings.txt"
    fi
}

launch_dashboard() {
    [[ -s "$report_file" ]] || fail 'No dashboard exists yet. Run a normal scan first.'
    local browser_bundle="" browser_path=""
    case "$browser" in
        safari) browser_bundle=com.apple.Safari ;;
        chrome) browser_bundle=com.google.Chrome ;;
        firefox) browser_bundle=org.mozilla.firefox ;;
        edge) browser_bundle=com.microsoft.edgemac ;;
        brave) browser_bundle=com.brave.Browser ;;
        default)
            # Resolve the HTTPS handler to avoid an HTML association that opens an editor.
            browser_path="$(/usr/bin/osascript -l JavaScript -e 'ObjC.import("AppKit"); var u=$.NSWorkspace.sharedWorkspace.URLForApplicationToOpenURL($.NSURL.URLWithString("https://example.invalid")); u ? ObjC.unwrap(u.path) : ""' 2>/dev/null || true)"
            ;;
    esac
    printf 'Opening your dashboard in a web browser…\n'
    if [[ -n "$browser_bundle" ]] && /usr/bin/open -b "$browser_bundle" "$report_file"; then return; fi
    if [[ -n "$browser_path" && -d "$browser_path" ]] && /usr/bin/open -a "$browser_path" "$report_file"; then return; fi
    if /usr/bin/open -b com.apple.Safari "$report_file"; then return; fi
    printf 'Automatic browser launch failed. Your dashboard is saved at:\n%s\nTry --browser chrome or open the HTML file in a browser.\n' "$report_file" >&2
}

if (( open_only )); then launch_dashboard; exit 0; fi

# Keep one open descriptor for the report folder. BSD file locks attach to that
# descriptor, survive the lock helper's exit, and release when this shell exits.
# Keep the empty file in place so concurrent collectors always lock the same inode.
lock_file="$output_dir/.mac-resource-check.lock"
exec 9>"$lock_file"
/usr/bin/lockf -s -t 0 9 || fail 'Another scan is already using this report folder, or locking is unavailable. Stop it, or choose a different --output folder.'

printf 'Mac Resource Check\nSampling for about %s seconds. Use your Mac normally during the scan.\n' "$effective_seconds"
if (( watch_seconds )); then printf 'Repeating every %s seconds. Press Control-C to stop.\n' "$watch_seconds"; fi
while :; do
    started_at="$(/bin/date +%s)"
    : > "$temp_dir/warnings.txt"
    optional_read 'Initial virtual memory statistics' "$temp_dir/vmBefore.txt" /usr/bin/vm_stat
    optional_read 'Initial network counters' "$temp_dir/networkBefore.txt" /usr/sbin/netstat -ibn
    optional_read 'Initial disk counters' "$temp_dir/ioBefore.txt" /usr/sbin/iostat -d -I -n 64 -c 1
    counter_started="$(/bin/date +%s)"
    # COMMAND is last to preserve spaces in names. -F/-R reduce collection overhead.
    # -c n preserves absolute memory and wakeup counters; CPU/POWER remain interval based.
    if ! /usr/bin/top -l "$samples" -s 2 -n 99999 -o pid -F -R -c n \
        -stats pid,ppid,uid,cpu,mem,threads,idlew,power,command > "$temp_dir/top.txt" 2> "$temp_dir/top-error.txt"; then
        if ! /usr/bin/top -l "$samples" -s 2 -n 99999 -o pid -F -R -c n \
            -stats pid,ppid,uid,cpu,mem,threads,command > "$temp_dir/top.txt" 2> "$temp_dir/top-error.txt"; then
            /bin/cat "$temp_dir/top-error.txt" >&2
            fail 'macOS process collection failed. Run this .command file in Terminal outside an app sandbox.'
        fi
        printf 'Power and wakeup columns were not supported on this macOS version.\n' >> "$temp_dir/warnings.txt"
    fi
    # comm is the executable name/path, not the full arguments (which can contain secrets).
    optional_read 'Process paths' "$temp_dir/ps.txt" /bin/ps -ww -axo pid=,ppid=,uid=,rss=,etime=,state=,nice=,comm=
    optional_read 'Memory pressure' "$temp_dir/pressure.txt" /usr/sbin/sysctl -n kern.memorystatus_vm_pressure_level
    optional_read 'Swap usage' "$temp_dir/swap.txt" /usr/sbin/sysctl vm.swapusage
    optional_read 'Virtual memory statistics' "$temp_dir/vm.txt" /usr/bin/vm_stat
    optional_read 'Network counters' "$temp_dir/networkAfter.txt" /usr/sbin/netstat -ibn
    optional_read 'Disk counters' "$temp_dir/ioAfter.txt" /usr/sbin/iostat -d -I -n 64 -c 1
    printf '%s\n' "$(( $(/bin/date +%s) - counter_started ))" > "$temp_dir/counterSeconds.txt"
    optional_read 'System uptime' "$temp_dir/boot.txt" /usr/sbin/sysctl -n kern.boottime
    optional_read 'Sleep assertions' "$temp_dir/assertions.txt" /usr/bin/pmset -g assertions
    optional_read 'Battery status' "$temp_dir/battery.txt" /usr/bin/pmset -g batt
    disk_path=/
    [[ -d /System/Volumes/Data ]] && disk_path=/System/Volumes/Data
    optional_read 'Startup disk space' "$temp_dir/disk.txt" /bin/df -k "$disk_path"
    /usr/bin/osascript -l JavaScript "$temp_dir/renderer.js" "$temp_dir" "$output_dir" \
        "$collector_pid" "$collector_uid" "$watch_seconds" "$launcher_path" "$history_limit"
    if (( open_report )); then
        launch_dashboard
        open_report=0
    fi
    (( watch_seconds )) || break
    now="$(/bin/date +%s)"
    delay=$((watch_seconds - (now - started_at)))
    (( delay > 0 )) || delay=1
    /bin/sleep "$delay" &
    sleep_pid=$!
    wait "$sleep_pid"
    sleep_pid=""
done
printf 'Done. Double-click this script again to take another snapshot.\n'
