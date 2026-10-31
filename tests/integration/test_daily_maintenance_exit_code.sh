#!/usr/bin/env bash
# Negative control for MYC-4116: scripts/vault-daily-maintenance.sh used to log
# every step's exit code and then DISCARD it, ending in an unconditional
# `exit 0`. A leg that had been failing for weeks reported success to launchd
# every night, so the one surface anyone checks said the job was healthy.
#
# WHAT THIS PROVES, AND WHAT IT DOES NOT
#   It exercises the REAL `run()` definition and the REAL summary block, lifted
#   verbatim out of the shipped script rather than retyped here -- a control
#   built from a copy of the logic proves only that the copy works. The
#   extraction is asserted, so if either block is renamed or moved this test
#   goes RED rather than silently testing nothing.
#
#   It does NOT boot the whole maintenance pass (that needs a real vault, the
#   close mutex, and git). The claim is scoped to the accounting and the exit
#   predicate, which is exactly what MYC-4116 was about.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# HOME alone does NOT sandbox on Windows: ntpath.expanduser reads USERPROFILE and
# ignores HOME, so a bare `HOME=... bash ...` here would write this test's state
# file into the developer's REAL ~/.claude on Git Bash. That exact class once
# rewrote a real settings.json and denied every tool call in later sessions
# (MYC-3536). The shared helper sets HOME + USERPROFILE and neutralises the
# HOMEDRIVE/HOMEPATH fallback; scripts/ci.sh has a guard that fails this file if
# it drifts back to a bare HOME= redirect, and that guard is what caught it.
# shellcheck source=tests/integration/lib/sandbox_home.sh
. "$SCRIPT_DIR/lib/sandbox_home.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/vault-daily-maintenance.sh"
FAILED=0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "  FAIL: $*" >&2; FAILED=1; }
ok()   { echo "  ok   $*"; }

[ -f "$TARGET" ] || { echo "FAIL: $TARGET missing" >&2; exit 1; }

# --- lift the two real blocks out of the shipped script ---------------------
# `run()` ... its closing brace, and the summary block from MAINT_STATE_DIR to
# the final `exit 0`. Both extractions are asserted below: an empty lift means
# the block moved, and a control that tests an empty string always passes.
crit_block="$(awk '/^_is_critical\(\) \{/,/^\}/' "$TARGET")"
run_block="$(awk '/^run\(\) \{/,/^\}/' "$TARGET")"
summary_block="$(awk '/^MAINT_STATE_DIR=/,/^exit 0$/' "$TARGET")"

if ! printf '%s' "$crit_block" | grep -q 'CRITICAL_STEPS'; then
  fail "could not lift _is_critical() -- the allowlist machinery moved, so the"
  fail "advisory-vs-critical cases below would prove nothing."
  exit 1
fi
if ! printf '%s' "$run_block" | grep -q 'FAILED_STEPS+='; then
  fail "could not lift run() with its FAILED_STEPS accounting -- the block moved,"
  fail "so this control would have tested nothing. Fix the extraction, not the assert."
  exit 1
fi
if ! printf '%s' "$summary_block" | grep -q 'exit 1'; then
  fail "could not lift the summary block with its non-zero exit -- extraction is stale."
  exit 1
fi
ok "lifted run() + summary block from the shipped script (not retyped)"

# --- harness: the real blocks, with the vault/mutex setup stubbed out -------
build_harness() { # build_harness <steps...>  -> a runnable script at $tmp/h.sh
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo 'log() { printf "%s\n" "$*"; }'
    echo "CRITICAL_STEPS=(${HARNESS_CRITICAL:-})"
    echo 'FAILED_STEPS=()'
    echo 'FAILED_CRITICAL=()'
    printf '%s\n' "$crit_block"
    printf '%s\n' "$run_block"
    cat                      # caller pipes in the step invocations
    printf '%s\n' "$summary_block"
  } > "$tmp/h.sh"
  chmod +x "$tmp/h.sh"
}

# CASE 1 -- a failing CRITICAL step must reach the exit code. This is the defect
# MYC-4116 was filed for.
HARNESS_CRITICAL='"deliberately-failing-leg"'
build_harness <<'STEPS'
run "deliberately-failing-leg" false
STEPS
set +e
run_sandboxed "$tmp/home1" bash "$tmp/h.sh" > "$tmp/o1" 2>&1
rc1=$?
set -e
if [ "$rc1" -eq 0 ]; then
  fail "a failing CRITICAL step still exited 0 -- the swallow is back (MYC-4116)"
else
  ok "failing CRITICAL step -> exit $rc1"
fi
grep -q 'CRITICAL STEP' "$tmp/o1" || fail "the log line does not name the failed critical step"
if [ -f "$tmp/home1/.claude/state/vault-daily-maintenance-last.json" ]; then
  grep -q 'deliberately-failing-leg' \
    "$tmp/home1/.claude/state/vault-daily-maintenance-last.json" \
    || fail "state file does not name the failed step"
  ok "state file names the failed step"
else
  fail "no state file written for a failed run"
fi

# CASE 2 -- the inverse. Without this, a harness that exited non-zero for ANY
# reason would satisfy CASE 1 and the control would be theatre.
HARNESS_CRITICAL='"healthy-leg"'
build_harness <<'STEPS'
run "healthy-leg" true
STEPS
set +e
run_sandboxed "$tmp/home2" bash "$tmp/h.sh" > "$tmp/o2" 2>&1
rc2=$?
set -e
if [ "$rc2" -ne 0 ]; then
  fail "an all-green pass exited $rc2, expected 0 -- CASE 1 may be passing for the wrong reason"
else
  ok "all-green pass -> exit 0"
fi

# CASE 3 -- a failing step must NOT abort the remaining steps. That behaviour
# was correct before and is the reason run() swallows rather than `set -e`s;
# breaking it while fixing the exit code would trade one defect for a worse one.
HARNESS_CRITICAL='"first-leg-fails"'
build_harness <<'STEPS'
run "first-leg-fails" false
run "second-leg-still-runs" true
STEPS
set +e
run_sandboxed "$tmp/home3" bash "$tmp/h.sh" > "$tmp/o3" 2>&1
rc3=$?
set -e
grep -q 'second-leg-still-runs' "$tmp/o3" \
  || fail "a failing leg aborted the pass -- later legs must still run"
[ "$rc3" -ne 0 ] || fail "mixed pass should still exit non-zero"
ok "a failing leg does not abort the legs after it (exit $rc3)"

# CASE 4 -- an ADVISORY failure must NOT red. Most legs of the real pass are
# surfacers whose non-zero is a findings count (aggregate-sessions,
# relocate-watch, check-rule-conflicts...). A blanket rule shipped briefly in
# b27fd6e and would have reported failure EVERY day, which is how a real alarm
# becomes background. This is the case that keeps the allowlist honest.
HARNESS_CRITICAL=''            # nothing is critical
build_harness <<'STEPS'
run "surfacer-with-findings" false
STEPS
set +e
run_sandboxed "$tmp/home4" bash "$tmp/h.sh" > "$tmp/o4" 2>&1
rc4=$?
set -e
if [ "$rc4" -ne 0 ]; then
  fail "a NON-critical failing step exited $rc4 -- a blanket rule is back, and"
  fail "the real pass has several legs that exit non-zero while healthy."
else
  ok "advisory (non-critical) failure -> exit 0, logged but not alarmed"
fi
grep -q 'surfacer-with-findings' "$tmp/o4" \
  || fail "an advisory failure must still be RECORDED even though it does not red"
if [ -f "$tmp/home4/.claude/state/vault-daily-maintenance-last.json" ]; then
  grep -q '"failed_critical":\[\]' \
    "$tmp/home4/.claude/state/vault-daily-maintenance-last.json" \
    || fail "failed_critical should be empty for an advisory-only failure"
  ok "state file separates failed_steps from an empty failed_critical"
fi

# CASE 5 -- ABS_SKIP_STEPS turns a leg off: the listed leg never runs and is not
# counted as failed, while a leg whose label only CONTAINS a listed name runs.
HARNESS_CRITICAL='"skipped-leg"'
build_harness <<'STEPS'
ABS_SKIP_STEPS="other-leg,skipped-leg"
run "skipped-leg" sh -c 'echo skipped-leg-ran; exit 1'
run "skipped-leg-twin" sh -c 'echo twin-ran'
STEPS
set +e
run_sandboxed "$tmp/home5" bash "$tmp/h.sh" > "$tmp/o5" 2>&1
rc5=$?
set -e
[ "$rc5" -eq 0 ] || fail "a skipped critical leg exited $rc5 -- skipped must not count as failed"
grep -q 'skipped-leg-ran' "$tmp/o5" && fail "a leg listed in ABS_SKIP_STEPS still ran"
grep -q '\[skipped-leg\] SKIPPED' "$tmp/o5" || fail "the skip is not logged"
grep -q 'twin-ran' "$tmp/o5" || fail "a leg whose label only contains a listed name was skipped"
ok "ABS_SKIP_STEPS skips exactly the listed legs (exit $rc5)"

# CASE 6 -- a vault with no graph cache has nothing to prune: the prune leg is a
# logged SKIP, not a failed step. Before this, graphify_prune_stale_cache.py
# exited 1 ("no cache dir found") and every night's summary listed
# graphify-cache-prune as a non-zero step on a vault that never built a graph,
# which is how a real failure in the same summary turns into background.
# CONTROL: with a cache present the leg still runs -- the gate must not simply
# switch the prune off.
prune_block="$(awk '/^run_graph_cache_prune\(\) \{/,/^\}/' "$TARGET")"
if ! printf '%s' "$prune_block" | grep -q 'graphify-out/cache'; then
  fail "could not lift run_graph_cache_prune() -- the graph-cache gate moved or is gone"
else
  printf 'print("prune-ran")\n' > "$tmp/fake-prune.py"
  for layout in none root meta; do
    v="$tmp/vault-$layout"; mkdir -p "$v/Meta"
    case "$layout" in
      root) mkdir -p "$v/graphify-out/cache" ;;
      meta) mkdir -p "$v/Meta/graphify-out/cache" ;;
    esac
    HARNESS_CRITICAL=''
    build_harness <<STEPS
VAULT="$v"; META_DIR="$v/Meta"
$prune_block
run_graph_cache_prune "$tmp/fake-prune.py"
STEPS
    set +e
    run_sandboxed "$tmp/home6-$layout" bash "$tmp/h.sh" > "$tmp/o6-$layout" 2>&1
    set -e
    case "$layout" in
      none)
        grep -q 'prune-ran' "$tmp/o6-none" && fail "prune ran on a vault with no graph cache"
        grep -q '\[graphify-cache-prune\] SKIPPED' "$tmp/o6-none" || fail "the no-cache skip is not logged"
        grep -q 'graphify-cache-prune(rc=' "$tmp/o6-none" && fail "a vault with no graph cache still counts the prune as a failed step"
        ;;
      *)
        grep -q 'prune-ran' "$tmp/o6-$layout" || fail "prune did NOT run with a $layout graph cache present"
        ;;
    esac
  done
  ok "graph-cache prune: skipped without a cache, runs with a root or Meta cache"
fi

# CASE 7 -- a hung step is cut at its limit, counts as failed and frees the next
# one. On 30-oct-2026 a step hung 16 h and held everything behind it.
HARNESS_CRITICAL=''
build_harness <<'STEPS'
ABS_STEP_TIMEOUT_S=1
run "hung-leg" sleep 60
run "next-leg" echo next-leg-ran
STEPS
started=$SECONDS
set +e
run_sandboxed "$tmp/home7" bash "$tmp/h.sh" > "$tmp/o7" 2>&1
rc7=$?
set -e
grep -q '\[hung-leg\] rc=124' "$tmp/o7" || fail "a hung step did not end with rc=124"
grep -q 'next-leg-ran' "$tmp/o7" || fail "the step after a hung one never ran"
[ "$((SECONDS - started))" -lt 30 ] || fail "the hung step was not cut at its limit"
[ "$rc7" -eq 0 ] || fail "an advisory hung step changed the exit code (got $rc7)"
grep -q 'hung-leg(rc=124)' "$tmp/o7" || fail "the summary does not name the hung step"
ok "a hung step is cut at its limit and the next one runs"

if [ "$FAILED" -ne 0 ]; then
  echo "test_daily_maintenance_exit_code: FAILED" >&2
  exit 1
fi
echo "test_daily_maintenance_exit_code: OK"
