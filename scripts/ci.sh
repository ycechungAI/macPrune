#!/bin/zsh
# Local CI: every check, in order, stopping at the first failure. Runs before every push (see
# scripts/install-hooks.sh) and needs no root and no network.
#   1. script syntax   2. Swift + helper tests   3. release build   4. app bundle checks
#   5. smoke test: launch the built app and render its windows
set -euo pipefail
cd "${0:A:h}/.."
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
step() { print -P "%B==> $1%b" }
fail() { print -P "%F{red}%BCI failed:%b $1%f" >&2; exit 1 }

step "1/5 Script syntax"
sh -n Resources/firewall-helper.sh || fail "firewall-helper.sh"
sh -n Tests/helper-test.sh || fail "helper-test.sh"
for s in scripts/*.sh; do zsh -n "$s" || fail "$s"; done

step "2/5 Tests (Swift and the firewall helper)"
./scripts/test.sh > "$SCRATCH/test.log" 2>&1 || { tail -40 "$SCRATCH/test.log"; fail "tests"; }
grep -E "Test run with|helper:" "$SCRATCH/test.log"

step "3/5 Release build"
PRUNE_SKIP_TESTS=1 ./scripts/build-app.sh > "$SCRATCH/build.log" 2>&1 || { tail -40 "$SCRATCH/build.log"; fail "build"; }
grep -E "warning: .*\.swift" "$SCRATCH/build.log" && fail "the build has Swift warnings"

step "4/5 App bundle"
APP=build/Prune.app
codesign --verify --strict "$APP" || fail "signature"
cmp -s "$APP/Contents/Resources/firewall-helper.sh" Resources/firewall-helper.sh || fail "the bundled helper differs from Resources/"
[[ $(stat -f %Lp "$APP/Contents/Resources/firewall-helper.sh") == 555 ]] || fail "the helper must be read-only (555)"
vtool -show-build "$APP/Contents/MacOS/Prune" | grep -q "minos 14.0" || fail "the app must run on macOS 14"
version=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
print "Prune $version, signed, helper bundled read-only, macOS 14+"

step "5/5 Smoke test (launches the app; ends nothing)"
PRUNE_DRYRUN=1 "$APP/Contents/MacOS/Prune" > "$SCRATCH/dry.txt" 2>/dev/null || true
grep -q "^== Quick Clean" "$SCRATCH/dry.txt" && grep -q "^== Fresh Start" "$SCRATCH/dry.txt" || fail "the app didn't start and plan its cleans"
for shot in main firewall settings; do
    env_flag=()
    [[ $shot == firewall ]] && env_flag=(PRUNE_SNAPSHOT_FIREWALL=1)
    [[ $shot == settings ]] && env_flag=(PRUNE_SNAPSHOT_SETTINGS=1)
    env "${env_flag[@]}" PRUNE_SNAPSHOT="$SCRATCH/$shot.png" "$APP/Contents/MacOS/Prune" > /dev/null 2>&1 &
    pid=$!
    for i in {1..20}; do [[ -s "$SCRATCH/$shot.png" ]] && break; sleep 0.5; done
    kill $pid 2>/dev/null; wait $pid 2>/dev/null || true
    [[ $(stat -f %z "$SCRATCH/$shot.png" 2>/dev/null || echo 0) -gt 10000 ]] || fail "the $shot window didn't render"
done
print "main window, Firewall sheet and Settings rendered"
print -P "%F{green}%BCI passed%b%f"
