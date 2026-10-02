# Shared helpers for the dev-loop scripts. Source, do not execute.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG="${ZIG:-/home/hotschmoe/tools/zig-aarch64-linux-0.16.0/zig}"
TARGET="aarch64-linux-musl"

die() { echo "error: $*" >&2; exit 1; }

# unit name (rtk1|rtk2) -> ssh host. The USB gadget link is preferred when it is
# up (no Wi-Fi dependence); otherwise the Wi-Fi alias (<unit>w) is used.
unit_host() {
    local u="$1"
    case "$u" in rtk1|rtk2) ;; *) die "unknown unit '$u' (expected rtk1 or rtk2)";; esac
    if ssh -o BatchMode=yes -o ConnectTimeout=2 "$u" true 2>/dev/null; then
        echo "$u"
    else
        echo "${u}w"
    fi
}

all_units() { echo "rtk1 rtk2"; }

# Copy a local file to host:dest. rsync when both ends have it, scp otherwise.
push() {
    local src="$1" host="$2" dest="$3"
    if command -v rsync >/dev/null 2>&1; then
        rsync -az "$src" "$host:$dest"
    else
        scp -q "$src" "$host:$dest"
    fi
}
