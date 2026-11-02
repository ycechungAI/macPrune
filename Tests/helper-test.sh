#!/bin/sh
# Tests Resources/firewall-helper.sh without root: MACPRUNE_HELPER_DRYRUN keeps its files in a temp
# folder and prints the commands that would change pf. The `pfctl -n` syntax checks run for real.
set -u
cd "$(dirname "$0")/.."
HELPER=Resources/firewall-helper.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export MACPRUNE_HELPER_DRYRUN="$T/state"
pass=0 fail=0
check() {  # check NAME CONDITION...
    name=$1; shift
    if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name"; fi
}
has() { grep -qx -- "$2" "$1"; }

cat > "$T/good.txt" <<'EOF'
# a comment, then blank lines and spaces

 203.0.113.9
198.51.100.0/24   # a range
8.8.8.8
8.8.8.8
11.0.0.0/8
2606:4700:4700::1111
2001:db8::/32
EOF
sh "$HELPER" apply "$T/good.txt" > "$T/out" 2>&1
check "apply succeeds" test $? -eq 0
check "6 unique entries" has "$T/state/blocked.txt" "203.0.113.9"
check "count" test "$(wc -l < "$T/state/blocked.txt" | tr -d ' ')" -eq 6
check "ranges kept" has "$T/state/blocked.txt" "198.51.100.0/24"
check "IPv6 kept" has "$T/state/blocked.txt" "2606:4700:4700::1111"
check "loads the anchor" grep -q "would run: pfctl -q -a com.apple/250.macPrune -f $T/state/anchor.conf" "$T/out"
check "takes a pf reference" grep -q "would run: pfctl -E" "$T/out"
check "status says 6" has "$T/state/status" "rules 6"
check "status has the boot time" grep -q "^boot [0-9][0-9]*$" "$T/state/status"
# The boot time in seconds, read a different way: it must match, or the app shows "paused".
boot=$(sysctl -n kern.boottime | tr -d '{},' | awk '{for (i = 1; i < NF; i++) if ($i == "sec") print $(i + 2)}' | head -1)
check "the boot time is in seconds (not usec)" has "$T/state/status" "boot $boot"
check "anchor only blocks" test "$(grep -v '^#' "$T/state/anchor.conf" | grep -vc '^table\|^block ')" -eq 0
check "pf accepts the anchor" pfctl -n -a com.apple/250.macPrune -f "$T/state/anchor.conf" 2>/dev/null

# Every one of these must be refused, and a refused file must change nothing.
for bad in 10.1.2.3 192.168.1.1 172.20.0.0/16 127.0.0.1 169.254.1.1 100.64.0.1 224.0.0.1 0.0.0.0/0 \
           1.0.0.0/7 192.0.0.0/8 172.0.0.0/8 8.8.8.0/16 256.1.1.1 1.2.3 01.2.3.4 fe80::1 fd00::1 ::1 ff02::1 \
           2001:db8::/8 "1.2.3.4; rm -rf /" "\$(reboot)" example.com; do
    printf '%s\n' "8.8.4.4" "$bad" > "$T/bad.txt"
    sh "$HELPER" apply "$T/bad.txt" > "$T/out" 2>&1
    check "refuses $bad" test $? -ne 0
    check "refusing $bad changes nothing" has "$T/state/status" "rules 6"
    check "refusing $bad leaves the list" test "$(wc -l < "$T/state/blocked.txt" | tr -d ' ')" -eq 6
done

awk 'BEGIN { for (i = 0; i <= 300000; i++) printf "%d.%d.%d.1\n", 11 + int(i / 65536), int(i / 256) % 256, i % 256 }' > "$T/big.txt"
sh "$HELPER" apply "$T/big.txt" > "$T/out" 2>&1
check "refuses more than 300,000" test $? -ne 0
check "too many changes nothing" has "$T/state/status" "rules 6"

printf '# nothing\n' > "$T/empty.txt"
sh "$HELPER" apply "$T/empty.txt" > "$T/out" 2>&1
check "an empty list turns it off" grep -q "would run: pfctl -q -a com.apple/250.macPrune -F all" "$T/out"
check "off says 0" has "$T/state/status" "rules 0"

echo "4242; reboot" > "$T/state/token"  # only the digits may reach pfctl
sh "$HELPER" off > "$T/out" 2>&1
check "off releases the pf reference" grep -q "would run: pfctl -X 4242" "$T/out"
check "off forgets the token" test ! -e "$T/state/token"

sh "$HELPER" status > "$T/out" 2>&1
check "status" has "$T/out" "rules 0"
sh "$HELPER" reboot > /dev/null 2>&1
check "unknown verb refused" test $? -eq 2
sh "$HELPER" apply /nonexistent > /dev/null 2>&1
check "missing file refused" test $? -eq 2

echo "helper: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
