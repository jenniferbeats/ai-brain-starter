#!/usr/bin/env bash
# Test the nightly reconcile commit of vault-daily-maintenance.sh: extra paths,
# commit scoping and the optional push.
#
# WHY THIS EXISTS
#
# The reconcile step commits close artifacts a load-deferred session-close left
# behind. Two gaps showed up on a live vault:
#
#   1. Agents write memory files outside Sessions/ and Decisions/ and rarely
#      commit them, so they sat uncommitted for days. ABS_RECONCILE_EXTRA_PATHS
#      adds vault-relative paths to the sweep.
#   2. The sweep committed but never pushed, so its commit lived on one machine.
#      ABS_RECONCILE_PUSH=1 pushes afterwards; a rejected push is logged, never
#      rebased or forced.
#
# It also pins a scoping fix: the step ran a bare `git commit`, which takes the
# ENTIRE index, so a sibling session's staged file rode along under the sweep's
# message. It now commits `--only` the named paths.
#
# It also pins provenance: the sweep commit ends with a `Host:` trailer naming
# the machine that ran it (`hostname -s`), so two machines running the same
# maintenance can be told apart. No `Assisted-by:`: no agent or model took part.
#
# NEGATIVE CONTROL: against the pre-change script, case 1 fails (the extra path
# is not committed), case 2 fails (the foreign staged file is swept in),
# case 3 fails (nothing is pushed), case 3b fails (no `Host:` trailer) and
# case 6 fails (an empty or ignored extra path sinks the whole commit).
#
# Self-contained: temp vault + bare remote + temp HOME, cleaned on exit.
# NEVER touches a real vault. Exit 0 = pass.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAINT="$REPO_ROOT/scripts/vault-daily-maintenance.sh"

# shellcheck source=tests/integration/lib/sandbox_home.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox_home.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "  ok   $1"; }

[ -f "$MAINT" ] || fail "missing $MAINT"
command -v git >/dev/null 2>&1 || fail "git is required for this test"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export VAULT_GIT_LOCK_MAX_WAIT=2

# make_vault <vault> <remote> — a vault with a session file, a memory folder and
# a bare remote it tracks.
make_vault() {
  local v="$1" remote="$2"
  git init --quiet --bare --initial-branch=main "$remote"
  mkdir -p "$v/Meta/Sessions" "$v/Meta/Agent Memory"
  git init --quiet --initial-branch=main "$v"
  git -C "$v" config user.email "t@example.com"
  git -C "$v" config user.name "t"
  echo "# vault" > "$v/README.md"
  git -C "$v" add README.md
  git -C "$v" commit --quiet -m "init"
  git -C "$v" remote add origin "$remote"
  git -C "$v" push --quiet -u origin main
  printf -- '---\ntype: session\n---\n# session\n' > "$v/Meta/Sessions/2026-01-01T00-00-main.md"
  printf -- '---\nname: a-memory\n---\nfact\n' > "$v/Meta/Agent Memory/a-memory.md"
  # A sibling session's half-done work, already staged in the shared index.
  echo "foreign" > "$v/foreign.md"
  git -C "$v" add foreign.md
}

run_reconcile() {
  local v="$1" home="$2"; shift 2
  run_sandboxed "$home" env "$@" CLOSE_MAX_LOAD_PER_CORE=99999 \
    bash "$MAINT" --vault-root "$v" --reconcile-only --force >"$home.out" 2>&1
}

V="$TMP/vault"; R="$TMP/remote.git"
make_vault "$V" "$R"
run_reconcile "$V" "$TMP/home1" ABS_RECONCILE_EXTRA_PATHS="Meta/Agent Memory" ABS_RECONCILE_PUSH=1

COMMITTED="$(git -C "$V" show --name-only --format= HEAD)"

# CASE 1 -- the extra path is committed together with the close artifacts.
echo "$COMMITTED" | grep -q "Meta/Agent Memory/a-memory.md" \
  || fail "the extra path was not committed. HEAD has: $(echo "$COMMITTED" | tr '\n' ' ')"
echo "$COMMITTED" | grep -q "Meta/Sessions/2026-01-01T00-00-main.md" \
  || fail "the session file was not committed"
ok "ABS_RECONCILE_EXTRA_PATHS adds a folder whose name holds a space"

# CASE 2 -- a sibling's staged file stays out of the commit and stays staged.
echo "$COMMITTED" | grep -q "foreign.md" && fail "a sibling's staged file rode along in the sweep commit"
git -C "$V" diff --cached --name-only | grep -q "foreign.md" \
  || fail "the sibling's staged file is no longer staged"
ok "the sweep commits only its own paths"

# CASE 3 -- with ABS_RECONCILE_PUSH=1 the commit reaches the remote.
[ "$(git -C "$V" rev-parse HEAD)" = "$(git -C "$R" rev-parse main)" ] \
  || fail "ABS_RECONCILE_PUSH=1 did not push the sweep commit"
grep -q "\[reconcile-push\] pushed" "$V/Meta/logs/vault-daily-maintenance.log" \
  || fail "the push is not logged"
ok "ABS_RECONCILE_PUSH=1 pushes and logs it"

# CASE 3b -- the sweep commit names the machine that ran it, and no agent.
TRAILERS="$(git -C "$V" log -1 --format='%(trailers:only,unfold)')"
echo "$TRAILERS" | grep -qx "Host: $(hostname -s)" \
  || fail "the sweep commit lacks 'Host: $(hostname -s)'. Trailers: $TRAILERS"
echo "$TRAILERS" | grep -q "^Assisted-by:" && fail "the sweep commit claims an agent with Assisted-by:"
ok "the sweep commit carries Host: and no Assisted-by:"

# CASE 4 -- without the variables nothing is pushed and the extra path is left alone.
V2="$TMP/vault2"; R2="$TMP/remote2.git"
make_vault "$V2" "$R2"
run_reconcile "$V2" "$TMP/home2"
git -C "$V2" show --name-only --format= HEAD | grep -q "Agent Memory" \
  && fail "without ABS_RECONCILE_EXTRA_PATHS the memory folder was committed"
[ "$(git -C "$V2" rev-parse HEAD)" != "$(git -C "$R2" rev-parse main)" ] \
  || fail "without ABS_RECONCILE_PUSH the sweep pushed"
ok "defaults unchanged: no extra paths, no push"

# CASE 5 -- a rejected push is logged and not forced.
V3="$TMP/vault3"; R3="$TMP/remote3.git"
make_vault "$V3" "$R3"
OTHER="$TMP/other"
git clone --quiet "$R3" "$OTHER"
git -C "$OTHER" config user.email "o@example.com"; git -C "$OTHER" config user.name "o"
echo "remote change" > "$OTHER/remote.md"
git -C "$OTHER" add remote.md; git -C "$OTHER" commit --quiet -m "remote"; git -C "$OTHER" push --quiet
REMOTE_HEAD="$(git -C "$R3" rev-parse main)"
git -C "$V3" fetch --quiet
run_reconcile "$V3" "$TMP/home3" ABS_RECONCILE_PUSH=1
[ "$(git -C "$R3" rev-parse main)" = "$REMOTE_HEAD" ] || fail "a diverged remote was overwritten"
grep -q "\[reconcile-push\] FAILED" "$V3/Meta/logs/vault-daily-maintenance.log" || fail "the rejected push is not logged"
ok "a rejected push is logged and left alone"

# CASE 6 -- an extra path git knows no file under (an empty folder, an ignored
# folder, a path that does not exist) is skipped with a log line. Before, the
# empty and the ignored folder passed `-e`, `git commit --only` aborted with
# "pathspec did not match any file(s) known to git", NOTHING was committed that
# night and the sweep's paths were left staged for the next commit of any session.
V4="$TMP/vault4"; R4="$TMP/remote4.git"
make_vault "$V4" "$R4"
mkdir -p "$V4/Meta/Empty Folder" "$V4/Meta/Ignored Reports"
echo "Meta/Ignored Reports/" > "$V4/.git/info/exclude"
echo "report" > "$V4/Meta/Ignored Reports/r.md"
run_reconcile "$V4" "$TMP/home4" \
  ABS_RECONCILE_EXTRA_PATHS="Meta/Agent Memory:Meta/Empty Folder:Meta/Ignored Reports:Meta/Missing"
LOG4="$V4/Meta/logs/vault-daily-maintenance.log"
git -C "$V4" show --name-only --format= HEAD | grep -q "Meta/Agent Memory/a-memory.md" \
  || fail "an empty or ignored extra path sank the whole sweep commit. Log: $(tail -5 "$LOG4")"
git -C "$V4" diff --cached --name-only | grep -q "^Meta/" \
  && fail "the sweep left its paths staged: $(git -C "$V4" diff --cached --name-only | tr '\n' ' ')"
for skipped in "Meta/Empty Folder" "Meta/Ignored Reports" "Meta/Missing"; do
  grep -qF "[reconcile-commit] skipped '$skipped'" "$LOG4" \
    || fail "the skipped path '$skipped' is not logged"
done
ok "an empty, ignored or missing extra path is skipped and logged"

echo "test_reconcile_extra_paths_and_push: OK"
