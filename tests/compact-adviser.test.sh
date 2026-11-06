#!/usr/bin/env bash
# Behavior checks for the pinned compact-adviser plugin source that home.nix
# links at ~/.local/share/compact-adviser. Run: bash tests/compact-adviser.test.sh
#
# Builds each Linux home profile's generated files into the Nix store (never
# activating them). The plugin must be a read-only source copy: nothing installs
# or enables it, so a session loads it only when its launch passes --plugin-dir.
# The settings half (the pluginConfigs budget) is in tests/claude-config.test.sh.
#
# Coverage:
# - both profiles link the pinned source at ~/.local/share/compact-adviser, and
#   the plugin directory packages/claude-mod holds plugin.json version 0.1.14;
# - that copy is read-only;
# - `claude plugin validate` passes on it (skipped where claude is absent);
# - the dotfiles settings enable no plugin at user scope.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v nix >/dev/null 2>&1 || fail "nix is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"

dotfiles_test_tmproot compact-adviser
SYSTEM=$(nix eval --impure --raw --expr builtins.currentSystem)
LINK=.local/share/compact-adviser
PLUGIN=$LINK/packages/claude-mod

# The plugin must stay absent from every session unless a launch asks for it.
jq -e 'has("enabledPlugins") | not' "$ROOT/home/.claude/settings.json" >/dev/null ||
  fail "the dotfiles settings enable no plugin at user scope"
pass "the dotfiles settings enable no plugin at user scope"

check_profile() {
  local profile=$1 files dir version
  files=$(nix build --no-link --print-out-paths \
    "$ROOT#homeConfigurations.\"$profile\".config.home-files") \
    || fail "$profile: home-files build failed"
  [ -L "$files/$LINK" ] || fail "$profile: ~/$LINK is a link"
  dir=$(readlink -f "$files/$PLUGIN")
  [ -f "$dir/.claude-plugin/plugin.json" ] || fail "$profile: ~/$PLUGIN/.claude-plugin/plugin.json exists"
  version=$(jq -r '.version' "$dir/.claude-plugin/plugin.json")
  [ "$version" = 0.1.14 ] || fail "$profile: plugin.json is version 0.1.14, got $version"
  [ "$(jq -r '.name' "$dir/.claude-plugin/plugin.json")" = compact-adviser ] ||
    fail "$profile: plugin.json is named compact-adviser"
  [ -f "$dir/hooks/register.ts" ] || fail "$profile: the hooks module is present"
  [ ! -w "$dir/.claude-plugin/plugin.json" ] || fail "$profile: the plugin copy is read-only"
  pass "$profile: ~/$PLUGIN is the read-only plugin, version $version"

  if command -v claude >/dev/null 2>&1; then
    # An empty config dir keeps validate away from the real user settings.
    local out
    mkdir -p "$TMP_ROOT/$profile/config"
    out=$(CLAUDE_CONFIG_DIR="$TMP_ROOT/$profile/config" claude plugin validate "$dir" 2>&1) ||
      fail "$profile: claude plugin validate passes: $out"
    assert_contains "$out" "Validation passed" "$profile: claude plugin validate reports a pass: $out"
    pass "$profile: claude plugin validate passes"
  else
    pass "$profile: claude plugin validate # SKIP claude not on PATH"
  fi
}

check_profile "dev@$SYSTEM"
check_profile "node@container-$SYSTEM"
