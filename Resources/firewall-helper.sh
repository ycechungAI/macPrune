#!/bin/sh
# macPrune's firewall helper. The app runs it as root through macOS's own password prompt, once
# per change. Nothing is installed and there is no password-free mode.
#
# It only ever adds block rules for addresses the person chose, in a sub-anchor of macOS's own
# com.apple anchor, which /etc/pf.conf already loads. So it never edits /etc/pf.conf, never blocks
# anything by default, and turning it off removes exactly what it added. pf is enabled with a
# reference (pfctl -E), so turning macPrune off never disables pf for anything else that uses it.
#
# The app's file is not trusted: every line is checked again here. Only public IPv4 and global
# IPv6 (2000::/3) addresses and ranges pass, IPv4 ranges no wider than /8 and IPv6 no wider than
# /16, and no IPv4 range may overlap private, local or reserved space, so the local network can
# never be cut off. At most 300,000 entries. The new rules are checked with `pfctl -n` first.
#
#   firewall-helper.sh apply FILE   block the addresses in FILE (one per line)
#   firewall-helper.sh off          remove macPrune's rules and release its pf reference
#   firewall-helper.sh status       print "rules N" and "boot SECONDS" (the boot they were loaded in)
#
# Tests: MACPRUNE_HELPER_DRYRUN=<dir> runs as a normal user, keeps its files in <dir> and prints
# the commands that change pf instead of running them (`pfctl -n` checks still run). Refused as
# root. (sudo and the admin prompt reset the environment, so it can't be reached that way.)
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
ANCHOR=com.apple/250.macPrune
MAX=300000

if [ -n "${MACPRUNE_HELPER_DRYRUN:-}" ]; then
    if [ "$(id -u)" -eq 0 ]; then echo "error: the dry run is refused as root" >&2; exit 2; fi
    STATE=$MACPRUNE_HELPER_DRYRUN
    live() { echo "would run: $*"; }
else
    if [ "$(id -u)" -ne 0 ]; then echo "error: needs root" >&2; exit 2; fi
    STATE=/var/db/macprune
    live() { "$@"; }
fi

# kern.boottime prints "{ sec = 1793512844, usec = 764656 } ...": take sec, not usec.
boot_time() { sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/'; }

write_status() {
    printf 'rules %s\nboot %s\n' "$1" "$(boot_time)" > "$STATE/status.new"
    chmod 644 "$STATE/status.new"
    mv -f "$STATE/status.new" "$STATE/status"
}

# Prints the valid entries of $1, one per line, without duplicates. Exits 1 with a message if a
# line is invalid, so a bad file changes nothing.
validate() {
    awk '
    function overlaps(s, e, ps, pe) { return s <= pe && ps <= e }
    function v4(a,    t, ip, pfx, o, i, s, size) {
        pfx = 32; ip = a
        if (index(a, "/")) {
            split(a, t, "/"); ip = t[1]; pfx = t[2]
            if (pfx !~ /^[0-9]+$/) return 0
            pfx += 0
            if (pfx < 8 || pfx > 32) return 0
        }
        if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return 0
        split(ip, o, ".")
        for (i = 1; i <= 4; i++) {
            if (length(o[i]) > 3 || o[i] + 0 > 255 || (length(o[i]) > 1 && substr(o[i], 1, 1) == "0")) return 0
        }
        s = ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4]
        size = 2 ^ (32 - pfx)
        if (s % size != 0) return 0                  # host bits past the prefix
        e = s + size - 1
        for (i = 1; i <= nprivate; i++) if (overlaps(s, e, ps[i], pe[i])) return 0
        return 1
    }
    function v6(a,    t, pfx) {
        if (a !~ /^[23][0-9a-f]{0,3}(:[0-9a-f]{0,4}){2,7}(\/[0-9]+)?$/) return 0
        if (index(a, "/")) { split(a, t, "/"); pfx = t[2] + 0; if (pfx < 16 || pfx > 128) return 0 }
        return 1
    }
    function range(cidr,    t, o, s) {
        split(cidr, t, "/"); split(t[1], o, ".")
        s = ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4]
        nprivate++; ps[nprivate] = s; pe[nprivate] = s + 2 ^ (32 - t[2]) - 1
    }
    BEGIN {
        # This network, private, CGNAT, loopback, link-local, private, test, private, benchmark,
        # multicast and reserved.
        range("0.0.0.0/8"); range("10.0.0.0/8"); range("100.64.0.0/10"); range("127.0.0.0/8")
        range("169.254.0.0/16"); range("172.16.0.0/12"); range("192.0.0.0/24"); range("192.168.0.0/16")
        range("198.18.0.0/15"); range("224.0.0.0/4"); range("240.0.0.0/4")
    }
    {
        line = tolower($0)
        sub(/#.*/, "", line); gsub(/[ \t\r]/, "", line)
        if (line == "") next
        if (!(v4(line) || v6(line))) { printf "error: line %d is not a blockable public address: %s\n", NR, $0 > "/dev/stderr"; bad = 1; exit 1 }
        if (!(line in seen)) { seen[line] = 1; n++; print line }
        if (n > max) { printf "error: more than %d entries\n", max > "/dev/stderr"; bad = 1; exit 1 }
    }
    END { if (bad) exit 1 }
    ' max="$MAX" "$1"
}

case "${1:-}" in
apply)
    [ $# -eq 2 ] && [ -f "$2" ] || { echo "usage: $0 apply FILE" >&2; exit 2; }
    mkdir -p "$STATE"
    if ! validate "$2" > "$STATE/blocked.new"; then rm -f "$STATE/blocked.new"; exit 1; fi
    count=$(wc -l < "$STATE/blocked.new" | tr -d ' ')
    if [ "$count" -eq 0 ]; then
        rm -f "$STATE/blocked.new"
        exec "$0" off
    fi
    chmod 644 "$STATE/blocked.new"
    cat > "$STATE/anchor.new" <<EOF
# macPrune: blocks only the addresses you chose. Everything else stays allowed.
table <macprune> persist file "$STATE/blocked.txt"
block return out quick inet from any to <macprune>
block return out quick inet6 from any to <macprune>
block drop in quick inet from <macprune> to any
block drop in quick inet6 from <macprune> to any
EOF
    # Check the rules against the new list before anything replaces the old ones.
    sed "s#$STATE/blocked.txt#$STATE/blocked.new#" "$STATE/anchor.new" > "$STATE/anchor.check"
    if ! pfctl -n -a "$ANCHOR" -f "$STATE/anchor.check" 2>"$STATE/pfctl.err"; then
        grep -v 'could result in flushing\|present in the main ruleset\|See /etc/pf.conf' "$STATE/pfctl.err" >&2 || true
        rm -f "$STATE/blocked.new" "$STATE/anchor.new" "$STATE/anchor.check"
        echo "error: pf rejected the new rules; nothing changed" >&2
        exit 1
    fi
    rm -f "$STATE/anchor.check" "$STATE/pfctl.err"
    mv -f "$STATE/blocked.new" "$STATE/blocked.txt"
    mv -f "$STATE/anchor.new" "$STATE/anchor.conf"
    live pfctl -q -a "$ANCHOR" -f "$STATE/anchor.conf"
    if [ ! -s "$STATE/token" ]; then
        out=$(live pfctl -E 2>&1)
        echo "$out"
        echo "$out" | sed -n 's/^Token : //p' > "$STATE/token"
    fi
    write_status "$count"
    echo "blocked $count"
    ;;
off)
    mkdir -p "$STATE"
    live pfctl -q -a "$ANCHOR" -F all
    token=$(tr -cd '0-9' < "$STATE/token" 2>/dev/null || true)
    if [ -n "$token" ]; then
        live pfctl -X "$token"
    fi
    rm -f "$STATE/token" "$STATE/blocked.txt" "$STATE/anchor.conf"
    write_status 0
    echo "off"
    ;;
status)
    if [ -f "$STATE/status" ]; then cat "$STATE/status"; else echo "rules 0"; fi
    ;;
*)
    echo "usage: $0 apply FILE | off | status" >&2
    exit 2
    ;;
esac
