#!/usr/bin/env bash
# A symlink alias reproduces the macOS /var path case on Linux CI too.
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURE_TMP="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_TMP"' EXIT
REAL_ROOT="$FIXTURE_TMP/physical/repo"
ALIAS_ROOT="$FIXTURE_TMP/checkout-alias"
mkdir -p "$REAL_ROOT/core/scripts/lib" "$REAL_ROOT/.claude/hooks" \
  "$REAL_ROOT/workspace/threads" "$REAL_ROOT/workspace/sessions/fixture" \
  "$REAL_ROOT/companies/tenant-a" "$REAL_ROOT/companies/tenant-b" \
  "$FIXTURE_TMP/bin" "$FIXTURE_TMP/home"
ln -s "$REAL_ROOT" "$ALIAS_ROOT"
cp "$SOURCE_ROOT/core/scripts/handoff-finalize.sh" "$REAL_ROOT/core/scripts/handoff-finalize.sh"
cp "$SOURCE_ROOT/core/scripts/lib/session-id.sh" "$REAL_ROOT/core/scripts/lib/session-id.sh"
cp "$SOURCE_ROOT/.claude/hooks/mirror-thread-to-company.sh" "$REAL_ROOT/.claude/hooks/mirror-thread-to-company.sh"
printf 'company_slug: tenant-a\n' > "$REAL_ROOT/workspace/sessions/fixture/meta.yaml"
printf 'synthetic a\n' > "$REAL_ROOT/companies/tenant-a/note.md"
printf 'synthetic b\n' > "$REAL_ROOT/companies/tenant-b/note.md"
cat > "$FIXTURE_TMP/bin/hq" <<'SH'
#!/bin/sh
printf '{}\n'
SH
cat > "$REAL_ROOT/core/scripts/qmd-reindex-bg.sh" <<'SH'
#!/bin/sh
printf 'skipped-fixture\n'
SH
chmod +x "$FIXTURE_TMP/bin/hq" "$REAL_ROOT/core/scripts/qmd-reindex-bg.sh"
for command in jq git; do
  ln -s "$(command -v "$command")" "$FIXTURE_TMP/bin/$command"
done
fixture_run() {
  env -i HOME="$FIXTURE_TMP/home" HQ_ROOT="$ALIAS_ROOT" HQ_SESSION_ID=fixture \
    PATH="$FIXTURE_TMP/bin:/usr/bin:/bin" LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null "$@"
}
fixture_run git -C "$REAL_ROOT" init -q
fixture_run git -C "$REAL_ROOT" config user.name Fixture
fixture_run git -C "$REAL_ROOT" config user.email fixture@example.invalid
fixture_run git -C "$REAL_ROOT" config core.hooksPath /dev/null

mixed_paths="$(jq -cn --arg root "$ALIAS_ROOT" \
  '["./companies/tenant-a/note.md", ($root + "/companies/tenant-b/note.md")]')"
mixed="$(fixture_run bash "$ALIAS_ROOT/core/scripts/handoff-finalize.sh" \
  --company tenant-a --files-touched-json "$mixed_paths" --slug mixed-alias --next-command '')"
thread="$(jq -r .thread_path <<< "$mixed")"
jq -e '.metadata.company == [] and (.files_touched | length) == 2' "$REAL_ROOT/$thread" >/dev/null
jq -e '.mirror_companies == []' <<< "$mixed" >/dev/null
if find "$REAL_ROOT/companies" -path '*/workspace/sessions/*.json' | grep -q .; then
  echo 'FAIL: mixed-company alias changeset was mirrored' >&2
  exit 1
fi
echo 'ok: mixed relative and alias-absolute paths remain canonical'

single_paths="$(jq -cn --arg root "$ALIAS_ROOT" '[($root + "/companies/tenant-a/note.md")]')"
single="$(fixture_run bash "$ALIAS_ROOT/core/scripts/handoff-finalize.sh" \
  --company tenant-a --files-touched-json "$single_paths" --slug single-alias --next-command '')"
thread_id="$(jq -r .thread_id <<< "$single")"
thread="$(jq -r .thread_path <<< "$single")"
jq -e '.metadata.company == ["tenant-a"] and (.files_touched | length) == 1' "$REAL_ROOT/$thread" >/dev/null
jq -e '.mirror_companies == ["tenant-a"]' <<< "$single" >/dev/null
test -f "$REAL_ROOT/companies/tenant-a/workspace/sessions/$thread_id.json"
test ! -d "$REAL_ROOT/companies/tenant-b/workspace"
echo 'ok: single-company alias changeset retains its owner mirror'
echo 'Passed logical-root alias handoff regression checks'
