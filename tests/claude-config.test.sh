#!/usr/bin/env bash
# Behavior checks for the Claude Code files: the ~/.claude/settings.json and
# ~/.claude/CLAUDE.md home.file links in home.nix, and activation/claude-config.sh,
# which installs the add-ons into $CLAUDE_CONFIG_DIR when that points elsewhere.
#
# Every script case runs a Home Manager switch against a scratch HOME and a
# scratch CLAUDE_CONFIG_DIR: `claude-config.sh unlink`, Home Manager's collision
# check and links for those two home.file entries, then `claude-config.sh
# install` with this repo's real home/.claude/settings.json (or that file plus
# hooks) and home/AGENTS.md, as home.nix does. Needs bash, jq and GNU coreutils,
# findutils and diffutils (Home Manager's activation PATH provides the same);
# the home.nix checks also need nix and are skipped without it.
# Run: bash tests/claude-config.test.sh
#
# Coverage:
# - home.nix: both files are ordinary, unforced home.file links into the
#   dotfiles, and the script runs before the collision check and after linking;
# - unset, empty, and ~/.claude-naming CLAUDE_CONFIG_DIR: the script touches
#   nothing, so Home Manager's links and collision handling are all there is;
# - set, with the owner's settings.json, skills, CLAUDE.md and history already
#   there: additive owner-wins merge, one byte-for-byte backup, mode kept,
#   owner files untouched, ~/.claude entries linked into the configured dir;
# - re-runs are no-ops and never trip Home Manager's collision check;
# - third-party installers writing through ~/.claude (a new skill, a settings
#   edit) land in the configured directory;
# - edge cases: absent/invalid/symlinked owner settings, hook already present,
#   foreign files in Home Manager's way;
# - skills: a one-way, one-time move; a clash between two live, different
#   skills stays in place with a warning and keeps ~/.claude/skills a
#   directory; a ~/.claude link reaching the same skill (an image rebuild's
#   re-created links) is dropped as a duplicate; a dangling configured link, or
#   one reaching the skill only through the ~/.claude entry, is replaced by
#   that entry (the 2026-09-30 leak); a dangling ~/.claude link beside a
#   configured skill is dropped; once ~/.claude/skills is the link, a dangling
#   configured link is re-pointed at ~/.agents/skills/<name>, or reported when
#   no copy exists there; a ~/.claude/skills that is
#   another link is left alone, and a moved skill link still reads however
#   its target was written (relative, or absolute through a symlinked directory
#   or through ~/.claude/skills itself);
# - the Ixia marketplace (no enabled plugin): added whole where the owner has no
#   such key, one entry at a time inside an owner object, never over an owner
#   entry (or a non-object owner value);
# - compact-adviser's pluginConfigs budget: added once where the owner has no
#   such key, never over an owner value;
# - configured skills, settings.json or CLAUDE.md the owner linked back into
#   ~/.claude: nothing deleted or re-pointed, no warning and no link loop,
#   across repeated switches.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/activation/claude-config.sh"
SRC_SETTINGS="$ROOT/home/.claude/settings.json"
SRC_AGENTS="$ROOT/home/AGENTS.md"
SRC_SUM=$(sha256sum <"$SRC_SETTINGS")
dotfiles_test_tmproot claude-config
CASE=0
OUT=

# The dotfiles settings plus hooks, for the hook half of the merge.
HOOKED="$TMP_ROOT/hooked-settings.json"
jq '.hooks.SessionStart = [
  {"matcher": "", "hooks": [{"type": "command", "command": "tool-a", "timeout": 10}]},
  {"matcher": "", "hooks": [{"type": "command", "command": "tool-b", "timeout": 10}]},
  {"matcher": "", "hooks": [{"type": "command", "command": "tool-c", "timeout": 10}]}
]' "$SRC_SETTINGS" >"$HOOKED"
SETTINGS=$SRC_SETTINGS

# Stand-in for a Home Manager generation's links for the two home.file entries,
# pointing at the dotfiles like mkOutOfStoreSymlink does.
HM_FILES="$TMP_ROOT/0000-home-manager-files"
mkdir -p "$HM_FILES/.claude"
ln -s "$SRC_SETTINGS" "$HM_FILES/.claude/settings.json"
ln -s "$SRC_AGENTS" "$HM_FILES/.claude/CLAUDE.md"

# --- home.nix, as Home Manager evaluates it -------------------------------------

if command -v nix >/dev/null 2>&1; then
  case $(uname -m) in
    aarch64 | arm64) sys=aarch64-linux ;;
    *) sys=x86_64-linux ;;
  esac
  # shellcheck disable=SC2016
  facts=$(nix --extra-experimental-features 'nix-command flakes' eval --json "$ROOT#homeConfigurations" --apply '
    hcs: builtins.mapAttrs (_: hc: let c = hc.config; in {
      files = map (e: let f = c.home.file.${e.name}; in {
        inherit (e) name;
        inherit (f) enable force target;
        dotfiles = f.source.outPath
          == (c.lib.file.mkOutOfStoreSymlink "${c.home.homeDirectory}/.dotfiles/home/${e.src}").outPath;
      }) [
        { name = ".claude/settings.json"; src = ".claude/settings.json"; }
        { name = ".claude/CLAUDE.md"; src = "AGENTS.md"; }
      ];
      unlinkBefore = c.home.activation.claudeConfigUnlink.before;
      installAfter = c.home.activation.claudeConfig.after;
    }) (builtins.removeAttrs hcs (builtins.filter (n: builtins.match ".*[@-]'"$sys"'" n == null) (builtins.attrNames hcs)))' \
    2>"$TMP_ROOT/nix.err") || fail "home.nix evaluates: $(cat "$TMP_ROOT/nix.err")"
  [ "$(jq 'length' <<<"$facts")" -ge 2 ] || fail "home.nix: workstation and container configs found for $sys: $facts"
  jq -e 'all(.[]; .files | length == 2 and all(.[]; .enable and (.force | not) and .target == .name and .dotfiles))' <<<"$facts" >/dev/null ||
    fail "home.nix: ~/.claude/settings.json and ~/.claude/CLAUDE.md are unforced home.file links into the dotfiles: $facts"
  jq -e 'all(.[]; (.unlinkBefore | index("checkLinkTargets")) and (.installAfter | index("linkGeneration")))' <<<"$facts" >/dev/null ||
    fail "home.nix: unlink runs before the collision check, install after linking: $facts"
  pass "home.nix keeps both Claude files as plain home.file links around the script's two steps"
else
  pass "home.nix checks # SKIP nix not on PATH"
fi

# --- a Home Manager switch, modelled ---------------------------------------------

# Fresh scratch HOME, with ~/.claude as the previous generation left it, and a
# configured directory path; sets H and C.
new_case() {
  CASE=$((CASE + 1))
  H="$TMP_ROOT/$CASE/home"
  C="$TMP_ROOT/$CASE/config"
  mkdir -p "$H/.claude"
  ln -s "$HM_FILES/.claude/settings.json" "$H/.claude/settings.json"
  ln -s "$HM_FILES/.claude/CLAUDE.md" "$H/.claude/CLAUDE.md"
  SETTINGS=$SRC_SETTINGS
}

# Run one script step. $1 is CLAUDE_CONFIG_DIR, or "-" for unset.
step() {
  local dir=$1
  shift
  if [ "$dir" = - ]; then
    env -u CLAUDE_CONFIG_DIR HOME="$H" bash "$SCRIPT" "$@" 2>&1
  else
    env HOME="$H" CLAUDE_CONFIG_DIR="$dir" bash "$SCRIPT" "$@" 2>&1
  fi
}

# Home Manager's part of a switch for the two entries: its collision check (an
# existing path it does not own stops the switch; real files, which -b backup
# would move aside, never reach this in the cases below) and its links.
hm_link() {
  local name
  for name in settings.json CLAUDE.md; do
    if [ -e "$H/.claude/$name" ]; then
      case $(readlink "$H/.claude/$name") in
        "$HM_FILES"/*) ;;
        *) fail "Home Manager would stop at a collision on $H/.claude/$name" ;;
      esac
    fi
  done
  for name in settings.json CLAUDE.md; do
    ln -sfn "$HM_FILES/.claude/$name" "$H/.claude/$name"
  done
}

# A switch as home.nix orders it. $1 is CLAUDE_CONFIG_DIR, or "-" for unset.
activate() {
  local dir=$1 out
  out=$(step "$dir" unlink) || fail "unlink exited non-zero: $out"
  OUT=$out
  hm_link
  out=$(step "$dir" install "$SETTINGS" "$SRC_AGENTS") || fail "install exited non-zero: $out"
  OUT=$OUT$out
}

# Every path, type, mode, link target, and file mtime and content hash under the
# given roots. Link and directory mtimes are left out: Home Manager re-creates
# its links on every switch.
snapshot() {
  local root
  for root in "$@"; do
    [ -e "$root" ] || continue
    find "$root" -printf '%p %y %m %l\n'
    find "$root" -type f -printf '%p %T@\n'
    find "$root" -type f -exec sha256sum {} +
  done | sort
}

assert_link() {
  local path=$1 target=$2 message=$3
  [ -L "$path" ] && [ "$(readlink "$path")" = "$target" ] || fail "$message ($path -> $(readlink "$path" 2>/dev/null))"
}

jqf() { jq -r "$1" "$2"; }

owner_settings() {
  mkdir -p "$C"
  cat >"$C/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "bash owner-hook.sh session", "timeout": 10 }
        ]
      }
    ]
  },
  "modelSettings": { "claude-opus-5-5": { "effortLevel": "xhigh" } },
  "theme": "auto"
}
JSON
  chmod 640 "$C/settings.json"
}

count_hook() { jq --arg c "$1" '[.hooks.SessionStart[].hooks[] | select(.command == $c)] | length' "$2"; }

# --- CLAUDE_CONFIG_DIR unset, empty, or ~/.claude: Home Manager alone -----------

for mode in unset empty home trailing; do
  new_case
  mkdir -p "$H/.claude/skills/someone-else"
  printf 'x\n' >"$H/.claude/skills/someone-else/SKILL.md"
  case $mode in
    unset) dir=- ;;
    empty) dir= ;;
    home) dir="$H/.claude" ;;
    trailing) dir="$H/.claude/" ;;
  esac
  before=$(snapshot "$H")
  activate "$dir"
  activate "$dir"
  assert_link "$H/.claude/settings.json" "$HM_FILES/.claude/settings.json" "$mode: ~/.claude/settings.json is Home Manager's link"
  assert_link "$H/.claude/CLAUDE.md" "$HM_FILES/.claude/CLAUDE.md" "$mode: ~/.claude/CLAUDE.md is Home Manager's link"
  [ "$(snapshot "$H")" = "$before" ] || fail "$mode: nothing else in HOME changes, ~/.claude/skills stays a directory"
  [ ! -e "$C" ] || fail "$mode: configured directory untouched"
  [ -z "$OUT" ] || fail "$mode: silent, got: $OUT"
  pass "CLAUDE_CONFIG_DIR $mode leaves ~/.claude to Home Manager"
done

# Whatever sits where Home Manager links is its collision handling's business.
for dir in - "$TMP_ROOT/elsewhere"; do
  new_case
  rm "$H/.claude/settings.json" "$H/.claude/CLAUDE.md"
  printf '{"mine": true}\n' >"$H/.claude/settings.json"
  ln -s "$TMP_ROOT/other/CLAUDE.md" "$H/.claude/CLAUDE.md"
  before=$(snapshot "$H")
  OUT=$(step "$dir" unlink) || fail "unlink exited non-zero: $OUT"
  [ "$(snapshot "$H")" = "$before" ] || fail "unlink ($dir): a real file and a link it did not make are left in place"
  [ -z "$OUT" ] || fail "unlink ($dir): silent, got: $OUT"
done
pass "unlink leaves everything but its own links to Home Manager's collision check"

# --- set, with the owner's files already there ---------------------------------

new_case
SETTINGS=$HOOKED
owner_settings
cp -p "$C/settings.json" "$TMP_ROOT/owner-settings.orig"
mkdir -p "$C/skills/synced/abc" "$C/projects/p/memory"
printf 'owner skill\n' >"$C/skills/synced/abc/SKILL.md"
printf 'owner memory\n' >"$C/projects/p/memory/MEMORY.md"
printf 'history\n' >"$C/history.jsonl"
mkdir -p "$H/.claude/skills/no-mistakes" "$H/.agents/skills/sap-tool"
printf 'no-mistakes skill\n' >"$H/.claude/skills/no-mistakes/SKILL.md"
printf 'sap skill\n' >"$H/.agents/skills/sap-tool/SKILL.md"
ln -s ../../.agents/skills/sap-tool "$H/.claude/skills/sap-tool"
owner_before=$(snapshot "$C/skills/synced" "$C/projects" "$C/history.jsonl")

activate "$C"

# Owner values win; the dotfiles additions are appended.
[ "$(jqf .theme "$C/settings.json")" = auto ] || fail "set: owner theme kept"
[ "$(jqf '.modelSettings["claude-opus-5-5"].effortLevel' "$C/settings.json")" = xhigh ] || fail "set: owner modelSettings kept"
[ "$(jqf '.hooks.SessionStart[0].hooks[0].command' "$C/settings.json")" = "bash owner-hook.sh session" ] || fail "set: owner hook kept first"
[ "$(jq -c .statusLine "$C/settings.json")" = "$(jq -c .statusLine "$SRC_SETTINGS")" ] || fail "set: dotfiles statusLine added"
for tool in tool-a tool-b tool-c; do
  [ "$(count_hook "$tool" "$C/settings.json")" = 1 ] || fail "set: $tool hook added once"
done
[ "$(jq '.hooks.SessionStart | length' "$C/settings.json")" = 4 ] || fail "set: no other hook groups"
jq -e --slurpfile o "$TMP_ROOT/owner-settings.orig" '($o[0] | del(.hooks)) as $k | . as $m | all($k | paths(scalars); . as $p | ($m | getpath($p)) == ($k | getpath($p)))' "$C/settings.json" >/dev/null ||
  fail "set: every owner value survives unchanged"
[ "$(stat -c %a "$C/settings.json")" = 640 ] || fail "set: settings.json mode kept"
backups=("$C"/settings.json.pre-dotfiles-*)
[ "${#backups[@]}" = 1 ] && [ -f "${backups[0]}" ] || fail "set: exactly one backup"
cmp -s "${backups[0]}" "$TMP_ROOT/owner-settings.orig" || fail "set: backup is byte-for-byte the owner's original"
[ "$(stat -c %a "${backups[0]}")" = 640 ] || fail "set: backup keeps the owner's mode"

# Owner files untouched; add-ons linked or moved in beside them.
[ "$(snapshot "$C/skills/synced" "$C/projects" "$C/history.jsonl")" = "$owner_before" ] || fail "set: owner skills, history and memory untouched"
assert_link "$C/CLAUDE.md" "$SRC_AGENTS" "set: absent CLAUDE.md linked to AGENTS.md"
[ "$(cat "$C/skills/no-mistakes/SKILL.md")" = "no-mistakes skill" ] || fail "set: installer skill moved into the configured skills"
assert_link "$C/skills/sap-tool" "$H/.agents/skills/sap-tool" "set: relative skill link re-pointed absolutely"
[ "$(cat "$C/skills/sap-tool/SKILL.md")" = "sap skill" ] || fail "set: moved skill link still resolves"
assert_link "$H/.claude/skills" "$C/skills" "set: ~/.claude/skills links to the configured skills"
assert_link "$H/.claude/settings.json" "$C/settings.json" "set: ~/.claude/settings.json links to the configured settings"
[ "$H/.claude/CLAUDE.md" -ef "$C/CLAUDE.md" ] || fail "set: ~/.claude/CLAUDE.md is the configured CLAUDE.md"
[ "$(sha256sum <"$SRC_SETTINGS")" = "$SRC_SUM" ] || fail "set: the dotfiles settings.json is only read"
pass "set: owner settings merged additively with one backup, add-ons land beside the owner's files"

# Re-run: Home Manager re-links and install re-points settings; nothing else
# changes, not even formatting or backups.
state=$(snapshot "$H" "$C")
activate "$C"
[ "$(snapshot "$H" "$C")" = "$state" ] || fail "re-run: no-op"
[ "$OUT" = "claude-config: linked $H/.claude/settings.json -> $C/settings.json" ] || fail "re-run: only the re-pointed settings link reported, got: $OUT"
pass "re-run is a no-op that passes Home Manager's collision check"

# Third-party installers that hardcode ~/.claude after activation.
mkdir -p "$H/.claude/skills/late-skill"
printf 'late\n' >"$H/.claude/skills/late-skill/SKILL.md"
[ "$(cat "$C/skills/late-skill/SKILL.md" 2>/dev/null)" = late ] || fail "third-party: a skill dropped into ~/.claude/skills is visible in the configured dir"
jq '.hooks.Stop = [{"matcher": "", "hooks": [{"type": "command", "command": "late-tool"}]}]' "$H/.claude/settings.json" >"$TMP_ROOT/edit.json"
cat "$TMP_ROOT/edit.json" >"$H/.claude/settings.json"
[ "$(jqf '.hooks.Stop[0].hooks[0].command' "$C/settings.json")" = late-tool ] || fail "third-party: a settings edit through ~/.claude lands in the configured settings"
[ "$(sha256sum <"$SRC_SETTINGS")" = "$SRC_SUM" ] || fail "third-party: the dotfiles settings.json stays untouched"
activate "$C"
[ "$(jqf '.hooks.Stop[0].hooks[0].command' "$C/settings.json")" = late-tool ] || fail "third-party: re-run keeps installer settings edits"
[ "$(cat "$C/skills/late-skill/SKILL.md")" = late ] || fail "third-party: re-run keeps the later skill"
pass "third-party installers writing through ~/.claude land in the configured directory"

# A later write (the owner dropped statusLine) merges again without a second backup.
jq 'del(.statusLine)' "$C/settings.json" >"$TMP_ROOT/edit.json"
cat "$TMP_ROOT/edit.json" >"$C/settings.json"
activate "$C"
[ "$(jq -c .statusLine "$C/settings.json")" = "$(jq -c .statusLine "$SRC_SETTINGS")" ] || fail "later write: statusLine re-added"
backups=("$C"/settings.json.pre-dotfiles-*)
[ "${#backups[@]}" = 1 ] || fail "later write: the backup is one-time"
cmp -s "${backups[0]}" "$TMP_ROOT/owner-settings.orig" || fail "later write: the original backup is not overwritten"
[ "$(stat -c %a "$C/settings.json")" = 640 ] || fail "later write: mode kept"
pass "later merges keep the single original backup"

# --- set, edge cases ------------------------------------------------------------

# Owner's own CLAUDE.md and a hook the owner already runs under another matcher.
new_case
SETTINGS=$HOOKED
owner_settings
jq '.hooks.SessionStart += [{"matcher": "startup", "hooks": [{"type": "command", "command": "tool-a"}]}]' "$C/settings.json" >"$TMP_ROOT/s.json"
cat "$TMP_ROOT/s.json" >"$C/settings.json"
printf 'owner rules\n' >"$C/CLAUDE.md"
activate "$C"
[ "$(cat "$C/CLAUDE.md")" = "owner rules" ] && [ ! -L "$C/CLAUDE.md" ] || fail "edge: owner CLAUDE.md never replaced"
assert_link "$H/.claude/CLAUDE.md" "$C/CLAUDE.md" "edge: ~/.claude/CLAUDE.md shows the owner's CLAUDE.md"
[ "$(count_hook tool-a "$C/settings.json")" = 1 ] || fail "edge: hook already present is not duplicated"
[ "$(count_hook tool-c "$C/settings.json")" = 1 ] || fail "edge: missing hooks still added"
pass "edge: owner CLAUDE.md kept, existing hook command not duplicated"

# The Ixia marketplace (a reference only; Claude Code fetches it): SSH source
# (the form that fetches unattended), autoUpdate. The plugin is deliberately
# not enabled at user level: only IQX Bitbucket repositories enable it, in
# their own project settings.
IXIA_URL=git@bitbucket.org:iqxbusiness/ixia-marketplace.git
jq -e --arg u "$IXIA_URL" '.extraKnownMarketplaces == {ixia: {source: {source: "git", url: $u}, autoUpdate: true}}
  and (has("enabledPlugins") | not)' "$SRC_SETTINGS" >/dev/null ||
  fail "ixia: the dotfiles settings register marketplace ixia (SSH git source, autoUpdate) and enable no plugin"
[ "$(jq -r '.extraKnownMarketplaces.ixia.source.url' "$C/settings.json")" = "$IXIA_URL" ] || fail "ixia: marketplace added to settings the owner never had it in"
[ "$(jq 'has("enabledPlugins")' "$C/settings.json")" = false ] || fail "ixia: no plugin enabled in the owner's user settings"
pass "ixia: the marketplace, and no enabled plugin, land in owner settings that lack the key"

# An owner object already there: add the ixia entry inside it, change nothing
# else, and leave the owner's enabledPlugins alone.
new_case
owner_settings
jq '.extraKnownMarketplaces = {"corp": {"source": {"source": "github", "repo": "corp/market"}}}
  | .enabledPlugins = {"corp-tool@corp": true, "other@official": false}' "$C/settings.json" >"$TMP_ROOT/s.json"
cat "$TMP_ROOT/s.json" >"$C/settings.json"
cp -p "$C/settings.json" "$TMP_ROOT/owner-objects.orig"
activate "$C"
jq -e --arg u "$IXIA_URL" '.extraKnownMarketplaces == {"corp": {"source": {"source": "github", "repo": "corp/market"}},
    "ixia": {source: {source: "git", url: $u}, autoUpdate: true}}
  and .enabledPlugins == {"corp-tool@corp": true, "other@official": false}' "$C/settings.json" >/dev/null ||
  fail "ixia: entry added inside the owner's extraKnownMarketplaces, theirs and enabledPlugins untouched: $(jq -c '[.extraKnownMarketplaces,.enabledPlugins]' "$C/settings.json")"
state=$(snapshot "$C")
activate "$C"
[ "$(snapshot "$C")" = "$state" ] || fail "ixia: re-run is a no-op"
backups=("$C"/settings.json.pre-dotfiles-*)
cmp -s "${backups[0]}" "$TMP_ROOT/owner-objects.orig" || fail "ixia: backup is the owner's original"
pass "ixia: entry added inside the owner's existing object, idempotently"

# Owner decisions win: their own ixia source stays, and a non-object owner
# value is left alone.
new_case
owner_settings
jq '.extraKnownMarketplaces = {"ixia": {"source": {"source": "git", "url": "https://example.invalid/mine.git"}}}' "$C/settings.json" >"$TMP_ROOT/s.json"
cat "$TMP_ROOT/s.json" >"$C/settings.json"
activate "$C"
jq -e '.extraKnownMarketplaces == {"ixia": {"source": {"source": "git", "url": "https://example.invalid/mine.git"}}}' "$C/settings.json" >/dev/null || fail "ixia: owner's own ixia entry wins"
new_case
owner_settings
jq '.extraKnownMarketplaces = null' "$C/settings.json" >"$TMP_ROOT/s.json"
cat "$TMP_ROOT/s.json" >"$C/settings.json"
activate "$C"
jq -e '.extraKnownMarketplaces == null' "$C/settings.json" >/dev/null || fail "ixia: non-object owner value left alone"
pass "ixia: owner's own entry and non-object value win"

# compact-adviser's context budget (pluginConfigs): the dotfiles carry exactly
# one entry, with a numeric budget and no mode override (the plugin default is
# hint). It lands only in owner settings that have no pluginConfigs key; an
# owner's own pluginConfigs, whatever its shape, is never touched.
jq -e '.pluginConfigs == {"compact-adviser@inline": {options: {contextBudgetTokens: 150000}}}
  and (.pluginConfigs["compact-adviser@inline"].options.contextBudgetTokens | type) == "number"
  and (has("enabledPlugins") | not)' "$SRC_SETTINGS" >/dev/null ||
  fail "pluginConfigs: the dotfiles settings hold only the compact-adviser@inline budget (a number) and enable no plugin"
new_case
owner_settings
activate "$C"
[ "$(jq -c '.pluginConfigs' "$C/settings.json")" = '{"compact-adviser@inline":{"options":{"contextBudgetTokens":150000}}}' ] ||
  fail "pluginConfigs: added to owner settings that lack the key: $(jq -c '.pluginConfigs' "$C/settings.json")"
state=$(snapshot "$C")
activate "$C"
[ "$(snapshot "$C")" = "$state" ] || fail "pluginConfigs: re-run is a no-op"
pass "pluginConfigs: the budget is added once to owner settings that lack the key"

new_case
owner_settings
jq '.pluginConfigs = {"compact-adviser@inline": {"options": {"contextBudgetTokens": 90000, "mode": "auto"}}}' "$C/settings.json" >"$TMP_ROOT/s.json"
cat "$TMP_ROOT/s.json" >"$C/settings.json"
activate "$C"
jq -e '.pluginConfigs == {"compact-adviser@inline": {"options": {"contextBudgetTokens": 90000, "mode": "auto"}}}' "$C/settings.json" >/dev/null ||
  fail "pluginConfigs: an owner's value is never overwritten: $(jq -c '.pluginConfigs' "$C/settings.json")"
new_case
owner_settings
jq '.pluginConfigs = {"other@inline": {"options": {"x": 1}}}' "$C/settings.json" >"$TMP_ROOT/s.json"
cat "$TMP_ROOT/s.json" >"$C/settings.json"
activate "$C"
jq -e '.pluginConfigs == {"other@inline": {"options": {"x": 1}}}' "$C/settings.json" >/dev/null ||
  fail "pluginConfigs: an owner's other pluginConfigs entries stay as they are, with nothing added"
new_case
owner_settings
jq '.pluginConfigs = null' "$C/settings.json" >"$TMP_ROOT/s.json"
cat "$TMP_ROOT/s.json" >"$C/settings.json"
activate "$C"
jq -e '.pluginConfigs == null' "$C/settings.json" >/dev/null || fail "pluginConfigs: a non-object owner value is left alone"
pass "pluginConfigs: an owner's own value is never overwritten"

# No owner settings yet: a real file with the dotfiles settings.
new_case
activate "$C"
[ -f "$C/settings.json" ] && [ ! -L "$C/settings.json" ] || fail "edge: absent settings created as a real file"
jq -e --slurpfile s "$SRC_SETTINGS" '. == $s[0]' "$C/settings.json" >/dev/null || fail "edge: created settings equal the dotfiles settings"
! compgen -G "$C/settings.json.pre-dotfiles-*" >/dev/null || fail "edge: nothing to back up"
assert_link "$H/.claude/skills" "$C/skills" "edge: absent ~/.claude/skills becomes a link"
pass "edge: absent owner settings are created, not linked"

# Invalid owner settings: untouched, reported, activation still succeeds.
new_case
mkdir -p "$C"
printf '{ "theme": "auto", \n' >"$C/settings.json"
cp -p "$C/settings.json" "$TMP_ROOT/bad.orig"
activate "$C"
cmp -s "$C/settings.json" "$TMP_ROOT/bad.orig" || fail "edge: invalid owner settings untouched"
! compgen -G "$C/settings.json.pre-dotfiles-*" >/dev/null || fail "edge: no backup when nothing is written"
assert_contains "$OUT" "warning: $C/settings.json is not a JSON object" "edge: invalid owner settings reported"
pass "edge: invalid owner settings are left alone"

# Owner hooks in a shape the merge cannot extend: untouched, reported.
new_case
SETTINGS=$HOOKED
mkdir -p "$C"
printf '{"hooks": {"SessionStart": "not a list"}}\n' >"$C/settings.json"
cp -p "$C/settings.json" "$TMP_ROOT/shape.orig"
activate "$C"
cmp -s "$C/settings.json" "$TMP_ROOT/shape.orig" || fail "edge: unmergeable owner settings untouched"
! compgen -G "$C/settings.json.pre-dotfiles-*" >/dev/null || fail "edge: no backup when the merge fails"
[ -z "$(find "$C" -maxdepth 1 -name '.settings.json.*')" ] || fail "edge: no temp file left behind"
assert_contains "$OUT" "warning: could not merge" "edge: unmergeable owner settings reported"
pass "edge: owner hooks the merge cannot extend are left alone"

# Owner settings behind a symlink: merged into the target, link kept.
new_case
owner_settings
mv "$C/settings.json" "$C/real-settings.json"
ln -s real-settings.json "$C/settings.json"
activate "$C"
assert_link "$C/settings.json" real-settings.json "edge: owner's settings link kept"
[ "$(jq -c .statusLine "$C/real-settings.json")" = "$(jq -c .statusLine "$SRC_SETTINGS")" ] || fail "edge: merged into the link target"
pass "edge: owner settings symlink is merged through, not replaced"

# --- set, configured entries the owner linked back into ~/.claude ---------------

new_case
mkdir -p "$C" "$H/.claude/skills/mine" "$H/.agents/skills/rel"
printf 'mine\n' >"$H/.claude/skills/mine/SKILL.md"
printf 'rel\n' >"$H/.agents/skills/rel/SKILL.md"
ln -s ../../.agents/skills/rel "$H/.claude/skills/rel"
ln -s ../../.agents/skills/gone "$H/.claude/skills/gone"
ln -s "$H/.claude/skills" "$C/skills"
state=$(snapshot "$H/.claude/skills")
activate "$C"
assert_not_contains "$OUT" "warning:" "link-back skills: nothing is reported"
activate "$C"
[ -d "$H/.claude/skills" ] && [ ! -L "$H/.claude/skills" ] || fail "link-back skills: ~/.claude/skills stays the real directory"
assert_link "$C/skills" "$H/.claude/skills" "link-back skills: the owner's link is kept"
[ "$(snapshot "$H/.claude/skills")" = "$state" ] || fail "link-back skills: a live link, a real directory and a dangling link are all untouched"
[ "$(cat "$C/skills/mine/SKILL.md" 2>&1)" = mine ] || fail "link-back skills: the skill survives and resolves without a loop"
[ "$(cat "$C/skills/rel/SKILL.md" 2>&1)" = rel ] || fail "link-back skills: a relative skill link still resolves"
assert_not_contains "$OUT" "warning:" "link-back skills: nothing is reported on a re-run"
pass "link-back: skills linked back to ~/.claude/skills are neither deleted nor looped"

new_case
mkdir -p "$C"
ln -s "$H/.claude/settings.json" "$C/settings.json"
activate "$C"
activate "$C"
assert_link "$C/settings.json" "$H/.claude/settings.json" "link-back settings: the owner's link is kept"
jq -e --slurpfile s "$SRC_SETTINGS" '. == $s[0]' "$C/settings.json" >/dev/null 2>&1 || fail "link-back settings: the configured settings resolve without a loop"
! compgen -G "$C/settings.json.pre-dotfiles-*" >/dev/null || fail "link-back settings: nothing written, nothing backed up"
[ "$(sha256sum <"$SRC_SETTINGS")" = "$SRC_SUM" ] || fail "link-back settings: the dotfiles settings.json is untouched"
pass "link-back: settings.json linked back to ~/.claude is not looped"

new_case
mkdir -p "$C"
ln -s "$H/.claude/CLAUDE.md" "$C/CLAUDE.md"
activate "$C"
activate "$C"
assert_link "$C/CLAUDE.md" "$H/.claude/CLAUDE.md" "link-back CLAUDE.md: the owner's link is kept"
cmp -s "$C/CLAUDE.md" "$SRC_AGENTS" || fail "link-back CLAUDE.md: the configured CLAUDE.md resolves without a loop"
pass "link-back: CLAUDE.md linked back to ~/.claude is not looped"

# --- set, skills: a one-way, one-time move ---------------------------------------

# A name clash stays where it is, never overwriting either copy; the other
# entries still move, and ~/.claude/skills stays a directory until it is empty.
new_case
mkdir -p "$C/skills/clash" "$H/.claude/skills/clash" "$H/.claude/skills/fresh"
printf 'owner\n' >"$C/skills/clash/SKILL.md"
printf 'installer\n' >"$H/.claude/skills/clash/SKILL.md"
printf 'fresh\n' >"$H/.claude/skills/fresh/SKILL.md"
activate "$C"
[ "$(cat "$C/skills/clash/SKILL.md")" = owner ] || fail "clash: owner skill never overwritten"
[ "$(cat "$H/.claude/skills/clash/SKILL.md")" = installer ] || fail "clash: the ~/.claude copy stays in place"
[ "$(cat "$C/skills/fresh/SKILL.md")" = fresh ] && [ ! -e "$H/.claude/skills/fresh" ] || fail "clash: other skills still move"
[ -d "$H/.claude/skills" ] && [ ! -L "$H/.claude/skills" ] || fail "clash: ~/.claude/skills stays a directory"
assert_contains "$OUT" "warning: kept $H/.claude/skills/clash" "clash: reported"
state=$(snapshot "$H/.claude/skills" "$C/skills")
activate "$C"
[ "$(snapshot "$H/.claude/skills" "$C/skills")" = "$state" ] || fail "clash: a re-run changes nothing"
rm -rf "$H/.claude/skills/clash"
activate "$C"
assert_link "$H/.claude/skills" "$C/skills" "clash: once ~/.claude/skills is empty, it becomes the link"
pass "skill clashes stay in place with a warning; ~/.claude/skills is linked only once empty"

# A ~/.claude/skills that is already a link is not touched.
new_case
mkdir -p "$TMP_ROOT/$CASE/elsewhere/s"
printf 's\n' >"$TMP_ROOT/$CASE/elsewhere/s/SKILL.md"
ln -s "$TMP_ROOT/$CASE/elsewhere" "$H/.claude/skills"
activate "$C"
assert_link "$H/.claude/skills" "$TMP_ROOT/$CASE/elsewhere" "linked skills: left alone"
[ ! -e "$C/skills/s" ] || fail "linked skills: nothing moved out of it"
pass "a ~/.claude/skills that is already a link is left alone"

# A moved skill link still reads, however its target was written: relative,
# absolute through a symlinked directory, absolute through ~/.claude/skills, or
# with a trailing slash.
new_case
mkdir -p "$H/data/foo" "$H/.agents/skills/viahome" "$H/.agents/skills/relslash" "$H/.agents/skills/absslash" "$H/.claude/skills"
ln -s "$H/data/proj" "$H/proj"
mkdir -p "$H/data/proj"
printf 'foo\n' >"$H/data/foo/SKILL.md"
printf 'viahome\n' >"$H/.agents/skills/viahome/SKILL.md"
ln -s "$H/proj/../foo" "$H/.claude/skills/foo"
ln -s "$H/.claude/skills/../../.agents/skills/viahome" "$H/.claude/skills/viahome"
printf 'relslash\n' >"$H/.agents/skills/relslash/SKILL.md"
printf 'absslash\n' >"$H/.agents/skills/absslash/SKILL.md"
ln -s ../../.agents/skills/relslash/ "$H/.claude/skills/relslash"
ln -s "$H/.agents/skills/absslash//" "$H/.claude/skills/absslash"
[ "$(cat "$H/.claude/skills/foo/SKILL.md")" = foo ] && [ "$(cat "$H/.claude/skills/viahome/SKILL.md")" = viahome ] ||
  fail "moved links: fixtures read before activation"
activate "$C"
activate "$C"
assert_link "$H/.claude/skills" "$C/skills" "moved links: ~/.claude/skills becomes the link"
[ "$(cat "$C/skills/foo/SKILL.md" 2>&1)" = foo ] || fail "moved links: absolute target through a symlinked directory still reads"
[ "$(cat "$C/skills/viahome/SKILL.md" 2>&1)" = viahome ] || fail "moved links: absolute target through ~/.claude/skills still reads"
[ "$(cat "$C/skills/relslash/SKILL.md" 2>&1)" = relslash ] || fail "moved links: relative target with a trailing slash still reads"
[ "$(cat "$C/skills/absslash/SKILL.md" 2>&1)" = absslash ] || fail "moved links: absolute target with trailing slashes still reads"
pass "a moved skill link still reaches what it reached before the move"

# A container rebuild: the image leaves a real ~/.claude/skills of relative
# links whose names an earlier create already moved into the configured
# skills. A link there that reaches the same skill is a duplicate and goes, so
# ~/.claude/skills becomes the link; a link reaching another skill, a real
# directory, and a link the configured entry reaches it through all stay.
new_case
mkdir -p "$H/.agents/skills/arc" "$H/.agents/skills/theirs" "$H/.agents/skills/back" "$TMP_ROOT/$CASE/owner/theirs"
printf 'arc\n' >"$H/.agents/skills/arc/SKILL.md"
printf 'image theirs\n' >"$H/.agents/skills/theirs/SKILL.md"
printf 'back\n' >"$H/.agents/skills/back/SKILL.md"
printf 'owner theirs\n' >"$TMP_ROOT/$CASE/owner/theirs/SKILL.md"
image_skills() {
  rm -rf "$H/.claude/skills"
  mkdir -p "$H/.claude/skills"
  ln -s ../../.agents/skills/arc "$H/.claude/skills/arc"
}
image_skills
activate "$C"
assert_link "$H/.claude/skills" "$C/skills" "rebuild: the first create links ~/.claude/skills"
assert_link "$C/skills/arc" "$H/.agents/skills/arc" "rebuild: the first create moves the image link"
image_skills
activate "$C"
assert_link "$H/.claude/skills" "$C/skills" "rebuild: a same-target duplicate does not keep ~/.claude/skills a directory"
assert_link "$C/skills/arc" "$H/.agents/skills/arc" "rebuild: the configured link is kept"
[ "$(cat "$C/skills/arc/SKILL.md")" = arc ] || fail "rebuild: the skill still reads"
assert_contains "$OUT" "removed $H/.claude/skills/arc" "rebuild: the duplicate's removal is reported"
assert_not_contains "$OUT" "warning:" "rebuild: a duplicate is not a clash"
mkdir -p "$H/.claude/skills/no-mistakes"
[ -d "$C/skills/no-mistakes" ] || fail "rebuild: a later install lands in the configured skills"
activate "$C"
[ "$OUT" = "claude-config: linked $H/.claude/settings.json -> $C/settings.json" ] || fail "rebuild: a re-run is a no-op, got: $OUT"
pass "rebuild: an image link duplicating a configured one is dropped and ~/.claude/skills linked"

# A clash between two live, different skills stays with a warning; a configured
# link that reaches the ~/.claude entry only through it is replaced by that
# entry, whether a real directory or a link, so neither is lost or looped.
image_skills
ln -s ../../.agents/skills/theirs "$H/.claude/skills/theirs"
ln -s "$TMP_ROOT/$CASE/owner/theirs" "$C/skills/theirs"
mkdir -p "$H/.claude/skills/real"
printf 'real\n' >"$H/.claude/skills/real/SKILL.md"
ln -s "$H/.claude/skills/real" "$C/skills/real"
ln -s ../../.agents/skills/back "$H/.claude/skills/back"
ln -s "$H/.claude/skills/back" "$C/skills/back"
activate "$C"
[ -d "$H/.claude/skills" ] && [ ! -L "$H/.claude/skills" ] || fail "rebuild clash: ~/.claude/skills stays a directory"
[ ! -e "$H/.claude/skills/arc" ] && [ ! -L "$H/.claude/skills/arc" ] || fail "rebuild clash: the duplicate still goes"
assert_link "$H/.claude/skills/theirs" ../../.agents/skills/theirs "rebuild clash: a link reaching another skill is kept"
[ "$(cat "$C/skills/theirs/SKILL.md")" = "owner theirs" ] || fail "rebuild clash: the configured skill is untouched"
[ -d "$C/skills/real" ] && [ ! -L "$C/skills/real" ] && [ "$(cat "$C/skills/real/SKILL.md")" = real ] ||
  fail "rebuild clash: a real directory the configured link reached through is moved into its place"
assert_link "$C/skills/back" "$H/.agents/skills/back" "rebuild clash: a link the configured link reached through is moved into its place"
[ "$(cat "$C/skills/back/SKILL.md" 2>&1)" = back ] || fail "rebuild clash: the moved link still reads"
assert_contains "$OUT" "warning: kept $H/.claude/skills/theirs" "rebuild clash: theirs reported"
for name in real back; do
  assert_not_contains "$OUT" "warning: kept $H/.claude/skills/$name" "rebuild clash: $name is not a clash"
done
state=$(snapshot "$H/.claude/skills" "$C/skills")
activate "$C"
[ "$(snapshot "$H/.claude/skills" "$C/skills")" = "$state" ] || fail "rebuild clash: a re-run changes nothing"
pass "rebuild: only a clash between two live, different skills stays with a warning"

# The 2026-09-30 leak: an installer run with a temporary HOME re-pointed the
# configured skill links into it, and they dangled once it was deleted. The
# next switch replaces each dangling configured link with the working
# ~/.claude entry, whether a link or a real directory, and links
# ~/.claude/skills; a dangling ~/.claude link beside a configured skill goes.
new_case
mkdir -p "$H/.agents/skills/arc" "$H/.agents/skills/kept" "$C/skills/kept" "$H/.claude/skills/copy"
printf 'arc\n' >"$H/.agents/skills/arc/SKILL.md"
printf 'copy\n' >"$H/.claude/skills/copy/SKILL.md"
printf 'configured kept\n' >"$C/skills/kept/SKILL.md"
ln -s ../../.agents/skills/arc "$H/.claude/skills/arc"
ln -s "$TMP_ROOT/$CASE/gone/arc" "$C/skills/arc"
ln -s "$TMP_ROOT/$CASE/gone/copy" "$C/skills/copy"
ln -s ../../.agents/skills/gone "$H/.claude/skills/kept"
activate "$C"
assert_link "$H/.claude/skills" "$C/skills" "leak: ~/.claude/skills becomes the link"
assert_link "$C/skills/arc" "$H/.agents/skills/arc" "leak: a dangling configured link is replaced by the working ~/.claude link"
[ "$(cat "$C/skills/arc/SKILL.md")" = arc ] || fail "leak: the healed link reads"
[ -d "$C/skills/copy" ] && [ ! -L "$C/skills/copy" ] && [ "$(cat "$C/skills/copy/SKILL.md")" = copy ] ||
  fail "leak: a dangling configured link is replaced by the working ~/.claude directory"
[ "$(cat "$C/skills/kept/SKILL.md")" = "configured kept" ] || fail "leak: a live configured skill is untouched"
assert_contains "$OUT" "replaced $C/skills/arc: a dangling link" "leak: the replacement is reported"
assert_contains "$OUT" "removed $H/.claude/skills/kept: a dangling link" "leak: the dangling ~/.claude link's removal is reported"
assert_not_contains "$OUT" "warning:" "leak: nothing is a clash"
activate "$C"
[ "$OUT" = "claude-config: linked $H/.claude/settings.json -> $C/settings.json" ] || fail "leak: a re-run is a no-op, got: $OUT"
pass "leak: dangling skill links heal to the working entry and ~/.claude/skills is linked"

# The same leak once ~/.claude/skills is already the link: each dangling
# configured link is re-pointed at ~/.agents/skills/<name>, one with no copy
# there is reported, and live links and real directories are untouched.
new_case
mkdir -p "$H/.agents/skills/arc" "$H/.agents/skills/own" "$C/skills/own" "$TMP_ROOT/$CASE/other/live"
printf 'arc
' >"$H/.agents/skills/arc/SKILL.md"
printf 'configured own
' >"$C/skills/own/SKILL.md"
printf 'live
' >"$TMP_ROOT/$CASE/other/live/SKILL.md"
ln -s "$C/skills" "$H/.claude/skills"
ln -s "$TMP_ROOT/$CASE/gone/arc" "$C/skills/arc"
ln -s "$TMP_ROOT/$CASE/gone/lost" "$C/skills/lost"
ln -s "$TMP_ROOT/$CASE/other/live" "$C/skills/live"
activate "$C"
assert_link "$H/.claude/skills" "$C/skills" "linked leak: ~/.claude/skills stays the link"
assert_link "$C/skills/arc" "$H/.agents/skills/arc" "linked leak: a dangling configured link is re-pointed at ~/.agents/skills"
[ "$(cat "$C/skills/arc/SKILL.md")" = arc ] || fail "linked leak: the healed link reads"
assert_link "$C/skills/lost" "$TMP_ROOT/$CASE/gone/lost" "linked leak: a dangling link with no copy is left in place"
assert_link "$C/skills/live" "$TMP_ROOT/$CASE/other/live" "linked leak: a live link is untouched"
[ -d "$C/skills/own" ] && [ ! -L "$C/skills/own" ] && [ "$(cat "$C/skills/own/SKILL.md")" = "configured own" ] ||
  fail "linked leak: a real directory is untouched, even with a copy in ~/.agents/skills"
assert_contains "$OUT" "re-pointed $C/skills/arc" "linked leak: the repair is reported"
assert_contains "$OUT" "warning: $C/skills/lost is a dangling link" "linked leak: the entry with no copy is reported"
[ "$(grep -c 'warning:' <<<"$OUT")" = 1 ] || fail "linked leak: only the entry with no copy is a warning, got: $OUT"
state=$(snapshot "$C/skills")
activate "$C"
[ "$(snapshot "$C/skills")" = "$state" ] || fail "linked leak: a re-run changes nothing"
assert_not_contains "$OUT" "re-pointed" "linked leak: a re-run repairs nothing"
assert_contains "$OUT" "warning: $C/skills/lost is a dangling link" "linked leak: the entry with no copy is still reported"
pass "linked leak: dangling configured skill links heal from ~/.agents/skills, or are reported"
