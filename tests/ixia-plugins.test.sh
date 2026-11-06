#!/usr/bin/env bash
# Behavior checks for the Ixia plugin marketplace on Pi and for how Claude Code
# loads the plugins (the user-settings warning is in tests/claude-config.test.sh):
# tools/ixia-marketplace.sh, which keeps a real shallow clone that Pi loads on
# demand (`pi-ixia`, excluding feedback; no Pi setting names it), and the `claude`
# Zsh function, which enables the plugins for one session in an IQX Bitbucket
# checkout. Needs bash and git. Run: bash tests/ixia-plugins.test.sh
#
# Everything runs in a scratch HOME and clone directory, against a local fake
# marketplace repository (file:// URL, so --depth applies); nothing contacts
# Bitbucket.
#
# Coverage:
# - home.nix runs the clone step in the Linux and macOS profiles;
# - the `claude` Zsh function, against a fake claude: the Bitbucket SSH, SSH host
#   alias and HTTPS origins under iqxbusiness add the enabledPlugins settings
#   before the caller's arguments; a GitHub origin, another Bitbucket workspace,
#   no repository, no remote, and an explicit --settings (either form) pass the
#   arguments through unchanged; the exit status is kept;
# - tools/ixia-marketplace.sh: a fresh shallow clone (the agents/ directory the
#   review-panel skill needs sits two levels above the skills), a no-op re-run,
#   fast-forward to new upstream commits (including several in a row, which a
#   shallow clone must still follow), local uncommitted changes and local
#   commits never discarded, a non-git directory left alone, the default SSH
#   URL and destination, configured SSH identity preserved, and offline / no
#   access / no git / no timeout only warning, exit 0, leaving nothing
#   half-cloned.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLONE_SCRIPT="$ROOT/tools/ixia-marketplace.sh"
SKILLS_DIR=.local/share/ixia-marketplace/plugins/ixia-stratex/skills
dotfiles_test_tmproot ixia-plugins

GIT=(git -c user.name=dotfiles-test -c user.email=dotfiles-test@example.invalid -c commit.gpgsign=false)

# --- home.nix, as Home Manager evaluates it -------------------------------------

if command -v nix >/dev/null 2>&1; then
  case $(uname -m) in
    aarch64 | arm64) sys=aarch64-linux ;;
    *) sys=x86_64-linux ;;
  esac
  facts=$(nix --extra-experimental-features 'nix-command flakes' eval --json "$ROOT#homeConfigurations" --apply '
    hcs: builtins.mapAttrs (_: hc: {
      clone = hc.config.home.activation ? ixiaMarketplace;
    }) (builtins.removeAttrs hcs (builtins.filter (n: builtins.match ".*[@-]'"$sys"'" n == null) (builtins.attrNames hcs)))' \
    2>"$TMP_ROOT/nix.err") || fail "home.nix evaluates: $(cat "$TMP_ROOT/nix.err")"
  [ "$(jq 'length' <<<"$facts")" -ge 2 ] || fail "home.nix: workstation and container configs found for $sys: $facts"
  jq -e 'all(.[]; .clone)' <<<"$facts" >/dev/null ||
    fail "home.nix: both profiles clone the marketplace each switch: $facts"
  darwin_facts=$(nix --extra-experimental-features 'nix-command flakes' eval --json "$ROOT#darwinConfigurations.mac" --apply '
    dc: builtins.mapAttrs (_: hc: {
      clone = hc.home.activation ? ixiaMarketplace;
    }) dc.config.home-manager.users' 2>"$TMP_ROOT/darwin-nix.err") || fail "macOS home.nix evaluates: $(cat "$TMP_ROOT/darwin-nix.err")"
  jq -e 'length > 0 and all(.[]; .clone)' <<<"$darwin_facts" >/dev/null ||
    fail "home.nix: macOS clones the marketplace: $darwin_facts"
  pass "home.nix provisions the marketplace clone on Linux and macOS"

  if command -v zsh >/dev/null 2>&1; then
    nix --extra-experimental-features 'nix-command flakes' eval --raw \
      "$ROOT#darwinConfigurations.mac.config.home-manager.users.dev.programs.zsh.initContent" \
      >"$TMP_ROOT/init.zsh" 2>"$TMP_ROOT/zsh-nix.err" || fail "Zsh initialization evaluates: $(cat "$TMP_ROOT/zsh-nix.err")"
    PI_HOME="$TMP_ROOT/pi home"
    PI_BIN="$TMP_ROOT/pi-bin"
    PI_SKILLS="$PI_HOME/$SKILLS_DIR"
    mkdir -p "$PI_HOME" "$PI_BIN"
    cat >"$PI_BIN/pi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$PI_ARGS_LOG"
exit "${PI_EXIT:-0}"
SH
    chmod +x "$PI_BIN/pi"
    run_pi_ixia() {
      PI_OUT=$(env -i HOME="$PI_HOME" PATH="$PI_BIN:$PATH" TERM=xterm \
        PI_INIT="$TMP_ROOT/init.zsh" PI_ARGS_LOG="$TMP_ROOT/pi-args" PI_EXIT="${PI_EXIT:-0}" \
        zsh -f -i -c 'source "$PI_INIT"; pi-ixia "$@"' -- "$@" </dev/null 2>&1)
      PI_RC=$?
    }
    for layout in missing empty feedback-only; do
      case $layout in
        empty) mkdir -p "$PI_SKILLS" ;;
        feedback-only)
          mkdir -p "$PI_SKILLS/feedback"
          printf 'feedback\n' >"$PI_SKILLS/feedback/SKILL.md"
          ;;
      esac
      run_pi_ixia
      [ "$PI_RC" != 0 ] && [ ! -e "$TMP_ROOT/pi-args" ] || fail "pi-ixia $layout: must not start Pi: $PI_OUT"
      assert_contains "$PI_OUT" 'pi-ixia: warning:' "pi-ixia $layout: warns"
    done
    mkdir -p "$PI_SKILLS/plan-gate" "$PI_SKILLS/review-panel" "$PI_SKILLS/empty"
    printf 'plan-gate\n' >"$PI_SKILLS/plan-gate/SKILL.md"
    printf 'review-panel\n' >"$PI_SKILLS/review-panel/SKILL.md"
    printf 'not a skill\n' >"$PI_SKILLS/README.md"
    printf '%s\n' --skill "$PI_SKILLS/plan-gate" --skill "$PI_SKILLS/review-panel" \
      --model sonnet 'IQX task with spaces' >"$TMP_ROOT/expected-pi-args"
    run_pi_ixia --model sonnet 'IQX task with spaces'
    [ "$PI_RC" = 0 ] || fail "pi-ixia: starts Pi: $PI_OUT"
    cmp -s "$TMP_ROOT/expected-pi-args" "$TMP_ROOT/pi-args" || fail "pi-ixia: loads individual skills without feedback and preserves caller arguments"
    PI_EXIT=7 run_pi_ixia
    [ "$PI_RC" = 7 ] || fail "pi-ixia: preserves Pi exit status: $PI_RC: $PI_OUT"
    pass "pi-ixia excludes feedback, forwards arguments and exit status, and warns without usable skills"

    # The `claude` function, with a fake claude that records its arguments.
    CL_BIN="$TMP_ROOT/claude-bin"
    mkdir -p "$CL_BIN"
    cat >"$CL_BIN/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CLAUDE_ARGS_LOG"
exit "${CLAUDE_EXIT:-0}"
SH
    chmod +x "$CL_BIN/claude"
    IXIA_SETTINGS='{"enabledPlugins":{"ixia-stratex@ixia":true,"ixia-onelist@ixia":true}}'
    run_claude() { # <dir> [claude arguments...]
      local dir=$1
      shift
      rm -f "$TMP_ROOT/claude-args"
      # shellcheck disable=SC2016
      CLAUDE_OUT=$(env -i HOME="$PI_HOME" PATH="$CL_BIN:$PATH" TERM=xterm GIT_CEILING_DIRECTORIES="$TMP_ROOT" \
        PI_INIT="$TMP_ROOT/init.zsh" CLAUDE_DIR="$dir" CLAUDE_ARGS_LOG="$TMP_ROOT/claude-args" CLAUDE_EXIT="${CLAUDE_EXIT:-0}" \
        zsh -f -i -c 'source "$PI_INIT"; cd "$CLAUDE_DIR" && claude "$@"' -- "$@" </dev/null 2>&1)
      CLAUDE_RC=$?
    }
    claude_repo() { # <name> [origin url]
      local repo="$TMP_ROOT/claude-repos/$1"
      dotfiles_git_init_commit "$repo"
      [ -z "${2:-}" ] || git -C "$repo" remote add origin "$2"
      printf '%s\n' "$repo"
    }
    expect_claude_args() { # <message> <argument>...
      local message=$1
      shift
      [ "$CLAUDE_RC" = 0 ] || fail "claude $message: exit 0, got $CLAUDE_RC: $CLAUDE_OUT"
      printf '%s\n' "$@" >"$TMP_ROOT/expected-claude-args"
      cmp -s "$TMP_ROOT/expected-claude-args" "$TMP_ROOT/claude-args" ||
        fail "claude $message: arguments were: $(tr '\n' '|' <"$TMP_ROOT/claude-args" 2>/dev/null)"
    }

    for origin in \
      git@bitbucket.org:iqxbusiness/iqx.example.git \
      git@bitbucket.org-work:iqxbusiness/iqx.example.git \
      https://bitbucket.org/iqxbusiness/iqx.example.git \
      https://someone@bitbucket.org/iqxbusiness/iqx.example.git; do
      repo=$(claude_repo "bb-$(printf '%s' "$origin" | tr -c 'A-Za-z0-9\n' -)" "$origin")
      run_claude "$repo" --model sonnet 'task with spaces'
      expect_claude_args "in an iqxbusiness checkout ($origin): the plugins are enabled for the session" \
        --settings "$IXIA_SETTINGS" --model sonnet 'task with spaces'
      mkdir -p "$repo/sub/dir"
      run_claude "$repo/sub/dir"
      expect_claude_args "in a subdirectory of an iqxbusiness checkout ($origin): the plugins are enabled" \
        --settings "$IXIA_SETTINGS"
    done
    jq -e . <<<"$IXIA_SETTINGS" >/dev/null || fail "claude: the settings argument is valid JSON"

    github=$(claude_repo github git@github.com:meaningful-journey-lab/dotfiles.git)
    run_claude "$github" --model sonnet
    expect_claude_args "in a GitHub checkout: arguments unchanged" --model sonnet
    other=$(claude_repo other-workspace git@bitbucket.org:someoneelse/iqx.example.git)
    run_claude "$other" --model sonnet
    expect_claude_args "in another Bitbucket workspace: arguments unchanged" --model sonnet
    lookalike=$(claude_repo lookalike https://github.com/me/bitbucket.org-iqxbusiness.git)
    run_claude "$lookalike"
    expect_claude_args "with iqxbusiness only in a GitHub repository name: arguments unchanged"
    noremote=$(claude_repo no-remote)
    run_claude "$noremote" --version
    expect_claude_args "in a repository without origin: arguments unchanged" --version
    mkdir -p "$TMP_ROOT/not-a-repo"
    run_claude "$TMP_ROOT/not-a-repo" --version
    expect_claude_args "outside a repository: arguments unchanged" --version
    run_claude "$TMP_ROOT/not-a-repo"
    expect_claude_args "outside a repository, no arguments: no arguments"

    bb=$(claude_repo bb-settings git@bitbucket.org:iqxbusiness/iqx.example.git)
    run_claude "$bb" --settings '{"theme":"dark"}' --model sonnet
    expect_claude_args "with an explicit --settings in an iqxbusiness checkout: unchanged" \
      --settings '{"theme":"dark"}' --model sonnet
    run_claude "$bb" --model sonnet --settings=/tmp/own-settings.json
    expect_claude_args "with --settings=<file> in an iqxbusiness checkout: unchanged" \
      --model sonnet --settings=/tmp/own-settings.json
    CLAUDE_EXIT=7 run_claude "$bb"
    [ "$CLAUDE_RC" = 7 ] || fail "claude: preserves the exit status: $CLAUDE_RC: $CLAUDE_OUT"
    CLAUDE_EXIT=0
    run_claude "$bb" -p 'check --settings in a prompt'
    expect_claude_args "with the word --settings only inside another argument: the plugins are enabled" \
      --settings "$IXIA_SETTINGS" -p 'check --settings in a prompt'

    # `env ... claude` (Firstmate launches) and `command claude` bypass the function,
    # even inside an iqxbusiness checkout where the function would add --settings.
    for form in "env claude" "command claude"; do
      rm -f "$TMP_ROOT/claude-args"
      # shellcheck disable=SC2016
      env -i HOME="$PI_HOME" PATH="$CL_BIN:$PATH" TERM=xterm GIT_CEILING_DIRECTORIES="$TMP_ROOT" \
        PI_INIT="$TMP_ROOT/init.zsh" CLAUDE_DIR="$bb" CLAUDE_ARGS_LOG="$TMP_ROOT/claude-args" CLAUDE_FORM="$form" \
        zsh -f -i -c 'source "$PI_INIT"; cd "$CLAUDE_DIR" && eval "$CLAUDE_FORM --direct"' </dev/null >/dev/null 2>&1
      CLAUDE_RC=$?
      expect_claude_args "$form in an iqxbusiness checkout never goes through the function" --direct
    done
    pass "claude enables the Ixia plugins only in an iqxbusiness Bitbucket checkout and keeps an explicit --settings"
  else
    pass "pi-ixia checks # SKIP zsh not on PATH"
  fi
else
  pass "home.nix checks # SKIP nix not on PATH"
fi

# --- tools/ixia-marketplace.sh --------------------------------------------------

UP="$TMP_ROOT/upstream"
mkdir -p "$UP/plugins/ixia-stratex/skills/plan-gate" "$UP/plugins/ixia-stratex/agents"
printf 'plan-gate v1\n' >"$UP/plugins/ixia-stratex/skills/plan-gate/SKILL.md"
printf 'reviewer\n' >"$UP/plugins/ixia-stratex/agents/plan-ba.md"
git -C "$UP" init -q -b master
git -C "$UP" add -A
"${GIT[@]}" -C "$UP" commit -qm v1
URL="file://$UP"

new_upstream_commit() {
  printf 'plan-gate %s\n' "$1" >"$UP/plugins/ixia-stratex/skills/plan-gate/SKILL.md"
  "${GIT[@]}" -C "$UP" commit -qam "$1"
}

run_clone() { # [ENV=VAL...]
  OUT=$(env HOME="$HOME_DIR" IXIA_MARKETPLACE_URL="$URL" IXIA_MARKETPLACE_DIR="$DIR" "$@" bash "$CLONE_SCRIPT" 2>&1)
  RC=$?
}

HOME_DIR="$TMP_ROOT/home"
DIR="$TMP_ROOT/share/ixia-marketplace"
mkdir -p "$HOME_DIR"

run_clone
[ "$RC" = 0 ] || fail "clone: exit 0, got $RC: $OUT"
SK="$DIR/plugins/ixia-stratex/skills"
[ "$(cat "$SK/plan-gate/SKILL.md")" = "plan-gate v1" ] || fail "clone: skills present"
[ -f "$SK/../agents/plan-ba.md" ] || fail "clone: agents/ sits two levels above the skills (review-panel needs it)"
[ "$(git -C "$DIR" rev-parse --is-shallow-repository)" = true ] || fail "clone: shallow"
[ "$(git -C "$DIR" rev-list --count HEAD)" = 1 ] || fail "clone: depth 1"
[ "$(git -C "$DIR" remote get-url origin)" = "$URL" ] || fail "clone: origin is the marketplace URL"
[ "$(find "$(dirname "$DIR")" -mindepth 1 -maxdepth 1 | wc -l)" = 1 ] || fail "clone: no temporary leftovers"
pass "fresh shallow clone with the plugin's skills and agents"

before=$(git -C "$DIR" rev-parse HEAD)
run_clone
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(git -C "$DIR" rev-parse HEAD)" = "$before" ] || fail "re-run: silent no-op: $OUT"
pass "re-run with nothing new is a silent no-op"

new_upstream_commit v2
new_upstream_commit v3
run_clone
[ "$RC" = 0 ] || fail "update: exit 0: $OUT"
[ "$(cat "$SK/plan-gate/SKILL.md")" = "plan-gate v3" ] || fail "update: fast-forwarded past two new commits: $OUT"
[ "$(git -C "$DIR" status --porcelain | wc -l)" = 0 ] || fail "update: clean tree"
pass "refresh fast-forwards to the marketplace's latest release"

# Local uncommitted changes survive an update that does not touch them, and one
# that does is refused, never forced.
printf 'mine\n' >"$DIR/local-note.txt"
new_upstream_commit v4
run_clone
[ "$(cat "$SK/plan-gate/SKILL.md")" = "plan-gate v4" ] && [ "$(cat "$DIR/local-note.txt")" = mine ] || fail "local file: update applied, local file kept: $OUT"
printf 'edited\n' >"$SK/plan-gate/SKILL.md"
new_upstream_commit v5
run_clone
[ "$RC" = 0 ] || fail "conflicting local change: exit 0"
[ "$(cat "$SK/plan-gate/SKILL.md")" = edited ] || fail "conflicting local change: never overwritten"
assert_contains "$OUT" "warning:" "conflicting local change: warns"
git -C "$DIR" checkout -q -- . && rm -f "$DIR/local-note.txt"
run_clone
[ "$(cat "$SK/plan-gate/SKILL.md")" = "plan-gate v5" ] || fail "after the local change is gone, the update lands: $OUT"
pass "local changes are never discarded"

# A local commit stops the fast-forward; it is kept, with a warning.
"${GIT[@]}" -C "$DIR" commit -q --allow-empty -m local
local_head=$(git -C "$DIR" rev-parse HEAD)
new_upstream_commit v6
run_clone
[ "$RC" = 0 ] && [ "$(git -C "$DIR" rev-parse HEAD)" = "$local_head" ] || fail "local commit kept: $OUT"
assert_contains "$OUT" "warning:" "local commit: warns"
pass "local commits are never discarded"

# Offline / no access: only warnings, nothing half-cloned, nothing removed.
BAD=file://$TMP_ROOT/does-not-exist
before=$(git -C "$DIR" rev-parse HEAD)
git -C "$DIR" remote set-url origin "$BAD"
run_clone
[ "$RC" = 0 ] && [ "$(git -C "$DIR" rev-parse HEAD)" = "$before" ] || fail "fetch failure: exit 0, clone kept: $OUT"
assert_contains "$OUT" "cannot fetch" "fetch failure: warns"
git -C "$DIR" remote set-url origin "$URL"
DIR="$TMP_ROOT/share2/ixia-marketplace"
run_clone IXIA_MARKETPLACE_URL="$BAD"
[ "$RC" = 0 ] || fail "clone failure: exit 0: $OUT"
assert_contains "$OUT" "warning:" "clone failure: warns"
[ ! -e "$DIR" ] && [ "$(find "$TMP_ROOT/share2" -mindepth 1 | wc -l)" = 0 ] || fail "clone failure: no half-cloned directory or temporary leftovers"
# ... and the next switch with access clones it.
run_clone
[ "$(cat "$DIR/plugins/ixia-stratex/skills/plan-gate/SKILL.md")" = "plan-gate v6" ] || fail "recovery: the next run clones: $OUT"
pass "no network or access only warns and retries next time"

# A directory that is not a git clone is left alone.
DIR="$TMP_ROOT/share3/ixia-marketplace"
mkdir -p "$DIR"
printf 'not mine\n' >"$DIR/keep.txt"
run_clone
[ "$RC" = 0 ] && [ "$(cat "$DIR/keep.txt")" = "not mine" ] && [ "$(find "$DIR" -type f | wc -l)" = 1 ] || fail "non-git directory untouched: $OUT"
assert_contains "$OUT" "not a git clone" "non-git directory: warns"
pass "a non-git directory is left alone with a warning"

# No git on PATH: warns, exits 0.
NOGIT="$TMP_ROOT/nogit-bin"
mkdir -p "$NOGIT"
for tool in bash dirname; do ln -s "$(command -v "$tool")" "$NOGIT/$tool"; done
DIR="$TMP_ROOT/share4/ixia-marketplace"
OUT=$(env -i HOME="$HOME_DIR" PATH="$NOGIT" IXIA_MARKETPLACE_DIR="$DIR" "$NOGIT/bash" "$CLONE_SCRIPT" 2>&1); RC=$?
[ "$RC" = 0 ] && [ ! -e "$DIR" ] || fail "no git: exit 0, nothing created: $OUT"
assert_contains "$OUT" "git not found" "no git: warns"
pass "a missing git only warns"

DEFAULT_BIN="$TMP_ROOT/default-bin"
mkdir -p "$DEFAULT_BIN"
cat >"$DEFAULT_BIN/git" <<'SH'
#!/usr/bin/env bash
args=("$@")
for arg in "$@"; do
  if [ "$arg" = clone ]; then
    i=$((${#args[@]} - 2))
    printf '%s\n' "${args[i]}" >"$CLONE_URL_LOG"
    args[i]=$LOCAL_MARKETPLACE
    break
  fi
done
exec "$REAL_GIT" "${args[@]}"
SH
chmod +x "$DEFAULT_BIN/git"
OUT=$(env -u IXIA_MARKETPLACE_URL -u IXIA_MARKETPLACE_DIR HOME="$TMP_ROOT/home2" PATH="$DEFAULT_BIN:$PATH" \
  REAL_GIT="$(command -v git)" LOCAL_MARKETPLACE="$URL" CLONE_URL_LOG="$TMP_ROOT/clone-url" bash "$CLONE_SCRIPT" 2>&1)
[ "$(cat "$TMP_ROOT/clone-url")" = git@bitbucket.org:iqxbusiness/ixia-marketplace.git ] || fail "default SSH clone URL: $OUT"
[ -f "$TMP_ROOT/home2/$SKILLS_DIR/plan-gate/SKILL.md" ] || fail "default clone provides the skills directory to load on demand: $OUT"
pass "default SSH URL and clone destination provide the skills directory for pi-ixia"

SSH_BIN="$TMP_ROOT/ssh-bin"
mkdir -p "$SSH_BIN"
cat >"$SSH_BIN/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$SSH_ARGS_LOG"
exec git upload-pack "$SSH_UPSTREAM"
SH
chmod +x "$SSH_BIN/ssh"
cat >"$HOME_DIR/.gitconfig" <<EOF
[includeIf "hasconfig:remote.*.url:git@bitbucket.org:iqxbusiness/**"]
  path = $HOME_DIR/work.gitconfig
EOF
git config --file "$HOME_DIR/work.gitconfig" core.sshCommand "'$SSH_BIN/ssh' -i 'work key' -o IdentitiesOnly=yes -F 'pinned hosts'"
for identity in config env default; do
  DIR="$TMP_ROOT/ssh-$identity"
  identity_env=()
  case $identity in
    env) identity_env=("GIT_SSH_COMMAND='$SSH_BIN/ssh' -i 'owner key'" "PATH=$SSH_BIN:$PATH"); key='owner key' ;;
    config) key='work key' ;;
    default) identity_env=("GIT_CONFIG_GLOBAL=/dev/null" "PATH=$SSH_BIN:$PATH"); key= ;;
  esac
  for operation in clone fetch; do
    : >"$TMP_ROOT/ssh-args"
    OUT=$(env -u GIT_SSH_COMMAND HOME="$HOME_DIR" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$HOME_DIR/.gitconfig" \
      GIT_SSH_VARIANT=ssh SSH_ARGS_LOG="$TMP_ROOT/ssh-args" SSH_UPSTREAM="$UP" \
      IXIA_MARKETPLACE_URL=git@bitbucket.org:iqxbusiness/ixia-marketplace.git IXIA_MARKETPLACE_DIR="$DIR" \
      "${identity_env[@]}" bash "$CLONE_SCRIPT" 2>&1)
    [ $? = 0 ] && [ -f "$DIR/plugins/ixia-stratex/skills/plan-gate/SKILL.md" ] || fail "SSH $identity $operation: clone available: $OUT"
    for option in BatchMode=yes ConnectTimeout=15; do
      grep -Fxq "$option" "$TMP_ROOT/ssh-args" || fail "SSH $identity $operation: $option applied: $OUT"
    done
    [ -z "$key" ] || grep -Fxq "$key" "$TMP_ROOT/ssh-args" || fail "SSH $identity $operation: identity preserved: $OUT"
    if [ "$identity" = config ]; then
      grep -Fxq 'pinned hosts' "$TMP_ROOT/ssh-args" || fail "SSH $operation: host-key configuration preserved"
      grep -Fxq IdentitiesOnly=yes "$TMP_ROOT/ssh-args" || fail "SSH $operation: identity selection preserved"
    fi
  done
done
pass "clone and fetch preserve configured or environment SSH identity and apply noninteractive options"

PORTABLE_BIN="$TMP_ROOT/portable-bin"
mkdir -p "$PORTABLE_BIN"
for tool in bash git dirname mkdir mktemp mv rm tail; do ln -s "$(command -v "$tool")" "$PORTABLE_BIN/$tool"; done
DIR="$TMP_ROOT/portable-clone"
for operation in clone fetch; do
  OUT=$(env -u GIT_SSH_COMMAND HOME="$HOME_DIR" PATH="$PORTABLE_BIN" GIT_CONFIG_GLOBAL=/dev/null \
    IXIA_MARKETPLACE_URL="$URL" IXIA_MARKETPLACE_DIR="$DIR" "$PORTABLE_BIN/bash" "$CLONE_SCRIPT" 2>&1)
  [ $? = 0 ] && [ -f "$DIR/plugins/ixia-stratex/skills/plan-gate/SKILL.md" ] || fail "without timeout: $operation succeeds: $OUT"
  assert_not_contains "$OUT" "warning:" "without timeout: $operation needs no warning: $OUT"
done
pass "clone and refresh work without timeout or realpath on PATH"

before=$(git -C "$DIR" rev-parse HEAD)
git -C "$DIR" remote set-url origin git@bitbucket.org:iqxbusiness/ixia-marketplace.git
run_clone PATH="$PORTABLE_BIN" GIT_CONFIG_GLOBAL=/dev/null GIT_SSH_COMMAND=false GIT_SSH_VARIANT=ssh
[ "$RC" = 0 ] && [ "$(git -C "$DIR" rev-parse HEAD)" = "$before" ] || fail "without timeout: rejected SSH fetch exits 0 and keeps clone: $OUT"
assert_contains "$OUT" "warning: cannot fetch" "without timeout: rejected SSH fetch warns"
DIR="$TMP_ROOT/portable-failed/ixia-marketplace"
run_clone PATH="$PORTABLE_BIN" GIT_CONFIG_GLOBAL=/dev/null GIT_SSH_COMMAND=false GIT_SSH_VARIANT=ssh \
  IXIA_MARKETPLACE_URL=git@bitbucket.org:iqxbusiness/ixia-marketplace.git
[ "$RC" = 0 ] && [ ! -e "$DIR" ] && [ "$(find "$TMP_ROOT/portable-failed" -mindepth 1 | wc -l)" = 0 ] ||
  fail "without timeout: rejected SSH clone exits 0 without leftovers: $OUT"
assert_contains "$OUT" "warning: cannot clone" "without timeout: rejected SSH clone warns"
pass "without timeout, missing SSH access only warns and skips clone or refresh"
