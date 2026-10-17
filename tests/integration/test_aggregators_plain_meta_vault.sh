#!/usr/bin/env bash
# Test: the vault aggregators work on a vault whose Meta folder is plain "Meta",
# run the way vault-daily-maintenance.sh runs them (AB#186).
#
# Bug class this guards: aggregate-sessions.py and aggregate-decisions.py
# hardcoded `VAULT_ROOT / "⚙️ Meta"`. On a vault that names the folder plain
# "Meta" both died with "⚙️ Meta does not exist" and rc=1, even with VAULT_ROOT
# correct and FORCED — every nightly run, silently, while Last Session.md
# froze. Every other vault script already resolves the folder with
# _meta_resolver.find_meta_dir; these two did not.
#
# Also asserted, because the nightly run must produce what the vault's own copy
# produces on this layout:
#   - generated pointers name the real folder ("Meta/Sessions/"), not "⚙️ Meta";
#   - the Make.md folder note Sessions/Sessions.md is not aggregated as a session;
#   - backups are "<name>.md.bak-<stamp>", so Obsidian does not index them.
#
# NEGATIVE CONTROL: the same run against an "⚙️ Meta" vault still works, so the
# resolver did not trade one layout for the other.
#
# Self-contained: tmpdir fake vaults, the real scripts run from the repo (as the
# maintenance script runs them, with VAULT_ROOT + VAULT_ROOT_FORCE=1). Exit 0 = pass.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SESSIONS_SRC="$REPO_ROOT/scripts/aggregate-sessions.py"
DECISIONS_SRC="$REPO_ROOT/scripts/aggregate-decisions.py"
for s in "$SESSIONS_SRC" "$DECISIONS_SRC"; do
  [ -f "$s" ] || { echo "ERROR: $s not found" >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && sed 's/^/  /' "$2" >&2; exit 1; }

make_vault() {  # vault_dir meta_name
  local meta="$1/$2"
  mkdir -p "$meta/Sessions" "$meta/Decisions"
  cat > "$meta/Sessions/2026-10-16T09-00-main-aaaa1111.md" <<'EOF'
---
creationDate: 2026-10-16
type: session
---
# Session — older
older body line
EOF
  cat > "$meta/Sessions/2026-10-17T09-00-main-bbbb2222.md" <<'EOF'
---
creationDate: 2026-10-17
type: session
---
# Session — newest
newest body line
EOF
  # Make.md folder note: named like its folder, not a session.
  printf -- '---\ntype: folder\n---\nFOLDER_NOTE_BODY\n' > "$meta/Sessions/Sessions.md"
  cat > "$meta/Decisions/2026-10-17-pick.md" <<'EOF'
---
creationDate: 2026-10-17
type: decision
decision_date: 2026-10-17
outcome: pending
---
# Decision pick
pick body
EOF
  printf 'previous last session\n' > "$meta/Last Session.md"
}

run_both() {  # vault_dir label
  local err="$TMP/$2.err"
  VAULT_ROOT="$1" VAULT_ROOT_FORCE=1 python3 "$SESSIONS_SRC" >"$err" 2>&1 \
    || fail "aggregate-sessions rc!=0 on the $2 vault" "$err"
  VAULT_ROOT="$1" VAULT_ROOT_FORCE=1 python3 "$DECISIONS_SRC" >"$err" 2>&1 \
    || fail "aggregate-decisions rc!=0 on the $2 vault" "$err"
}

# --- 1. Plain "Meta" vault --------------------------------------------------
PLAIN="$TMP/plain"
make_vault "$PLAIN" "Meta"
run_both "$PLAIN" plain
pass "both aggregators exit 0 on a plain-Meta vault"

LAST="$PLAIN/Meta/Last Session.md"
grep -q "<!-- aggregate-sessions:BEGIN -->" "$LAST" \
  || fail "Last Session.md was not rebuilt" "$LAST"
grep -q "newest body line" "$LAST" || fail "newest session missing from Last Session.md" "$LAST"
pass "Last Session.md rebuilt from Meta/Sessions/"

grep -q "⚙️ Meta" "$LAST" && fail "Last Session.md points at a non-existent '⚙️ Meta'" "$LAST"
grep -q "Meta/Sessions/" "$LAST" || fail "Last Session.md does not name Meta/Sessions/" "$LAST"
pass "generated pointers name the real folder"

grep -q "FOLDER_NOTE_BODY" "$LAST" && fail "the Sessions.md folder note was aggregated as a session" "$LAST"
pass "the Make.md folder note is not a session"

[ -f "$PLAIN/Meta/Decision Log.md" ] || fail "Decision Log.md was not written in Meta/"
grep -q "Decision pick" "$PLAIN/Meta/Decision Log.md" || fail "decision missing from Decision Log.md"
pass "Decision Log.md rebuilt from Meta/Decisions/"

ls "$PLAIN/Meta/"'Last Session.md.bak-'* >/dev/null 2>&1 \
  || fail "no 'Last Session.md.bak-*' backup before overwriting"
if ls "$PLAIN/Meta/"*.bak-*.md >/dev/null 2>&1; then
  fail "a backup ends in .md, so Obsidian indexes it as a note"
fi
pass "backups are <name>.md.bak-<stamp>"

# --- 2. NEGATIVE CONTROL: the upstream "⚙️ Meta" layout still works --------
EMOJI="$TMP/emoji"
make_vault "$EMOJI" "⚙️ Meta"
run_both "$EMOJI" emoji
grep -q "newest body line" "$EMOJI/⚙️ Meta/Last Session.md" \
  || fail "Last Session.md not rebuilt on the '⚙️ Meta' vault"
[ -e "$EMOJI/Meta" ] && fail "a stray plain Meta/ was created in the '⚙️ Meta' vault"
pass "the '⚙️ Meta' layout still aggregates in place"

echo
echo "All assertions passed. Aggregators resolve the vault's Meta folder (AB#186)."
