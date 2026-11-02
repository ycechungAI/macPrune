#!/bin/zsh
# Runs scripts/ci.sh before every `git push` from this clone. Skip once with `git push --no-verify`.
set -euo pipefail
cd "${0:A:h}/.."
git config core.hooksPath .githooks
print "Pre-push CI is on for this clone (core.hooksPath = .githooks)."
