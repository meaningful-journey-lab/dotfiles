#!/usr/bin/env bash
# Behavioral checks for the .secrets *.env loader in home.nix's .zshenv.
#
# Builds each Linux home profile's generated files into the Nix store (never
# activating them), then runs a non-interactive `zsh -c` against the generated
# .zshenv with a scratch HOME whose ~/.secrets folder is set up per scenario.
# The probe reads each variable through printenv, so it only counts as loaded
# once a child process inherits it.
#
# Coverage:
# - no ~/.secrets folder: nothing loads and nothing is printed;
# - a 755 ~/.secrets folder, or a symlink to a 700 one, is skipped;
# - an unreadable (000) ~/.secrets folder is skipped silently;
# - in a 700 ~/.secrets folder, owner-only *.env files load in name order;
#   group- or world-writable, symlinked, unreadable and non-.env files are
#   skipped; a file with a syntax error is skipped whole without stopping the
#   files after it; nothing a file prints reaches the shell's output;
# - a file in a subfolder of ~/.secrets (a scoped secret, such as
#   compact-adviser/typesafe.env) is not exported, because the glob reads only
#   top-level *.env files;
# - the loader leaves no variable or helper function behind.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v nix >/dev/null 2>&1 || fail "nix is required"
command -v zsh >/dev/null 2>&1 || fail "zsh is required"

dotfiles_test_tmproot secrets-env
SYSTEM=$(nix eval --impure --raw --expr builtins.currentSystem)
# Root reads a 000 file or folder anyway, so those cases need a normal user.
[ "$(id -u)" -ne 0 ] && AS_USER=1 || AS_USER=

VARS=(GOOD ORDER NOISY AFTER_SYNTAX SYNTAX GROUPW WORLDW LINK UNREADABLE TXT SUBDIR)
# shellcheck disable=SC2016
PROBE='
  for v in '"${VARS[*]}"'; do
    print -r -- "$v=$(printenv DOTFILES_SECRET_$v || print unset)"
  done
  print -r -- "leaked=${+d}${+f}${+functions[__secrets_parse]}"
'

# Prints the probe output expected when exactly the given NAME=value pairs load.
expected() {
  local v kv line
  for v in "${VARS[@]}"; do
    line="$v=unset"
    for kv in "$@"; do
      [ "${kv%%=*}" = "$v" ] && line=$kv
    done
    printf '%s\n' "$line"
  done
  printf 'leaked=000'
}

# Writes an env file with the given mode.
env_file() {
  local path=$1 mode=$2 body=$3
  printf '%s\n' "$body" >"$path"
  chmod "$mode" "$path"
}

# Runs the probe in the scratch HOME $2 and checks stdout against $3 and that
# stderr is empty. $4, when set, is a mode to restore on ~/.secrets afterwards
# so the temp root stays removable whatever the outcome.
probe() {
  local label=$1 home=$2 want=$3 restore=${4:-} out err
  out=$(HOME="$home" ZDOTDIR="$home" zsh -c "$PROBE" </dev/null 2>"$home.err")
  err=$(cat "$home.err")
  [ -n "$restore" ] && chmod "$restore" "$home/.secrets"
  [ "$out" = "$want" ] || fail "$label: expected
$want
got
$out"
  [ -z "$err" ] || fail "$label: stderr is not empty: $err"
  pass "$label"
}

new_home() {
  local home=$1 files=$2
  mkdir -p "$home"
  cp -L "$files/.zshenv" "$home/.zshenv"
}

probe_profile() {
  local profile=$1 files home
  files=$(nix build --no-link --print-out-paths \
    "$ROOT#homeConfigurations.\"$profile\".config.home-files") \
    || fail "$profile: home-files build failed"
  [ -e "$files/.zshenv" ] || fail "$profile: generated .zshenv missing"

  home="$TMP_ROOT/$profile/absent"
  new_home "$home" "$files"
  probe "$profile: no ~/.secrets folder loads nothing, silently" "$home" "$(expected)"

  home="$TMP_ROOT/$profile/open"
  new_home "$home" "$files"
  mkdir -m 755 "$home/.secrets"
  env_file "$home/.secrets/10-good.env" 600 'export DOTFILES_SECRET_GOOD=good'
  probe "$profile: a 755 ~/.secrets folder is skipped" "$home" "$(expected)"

  home="$TMP_ROOT/$profile/linked"
  new_home "$home" "$files"
  mkdir -m 700 "$home/real-secrets"
  env_file "$home/real-secrets/10-good.env" 600 'export DOTFILES_SECRET_GOOD=good'
  ln -s real-secrets "$home/.secrets"
  probe "$profile: a symlinked ~/.secrets folder is skipped" "$home" "$(expected)"

  if [ -n "$AS_USER" ]; then
    home="$TMP_ROOT/$profile/locked"
    new_home "$home" "$files"
    mkdir -m 700 "$home/.secrets"
    env_file "$home/.secrets/10-good.env" 600 'export DOTFILES_SECRET_GOOD=good'
    chmod 000 "$home/.secrets"
    probe "$profile: an unreadable ~/.secrets folder is skipped silently" \
      "$home" "$(expected)" 700
  fi

  home="$TMP_ROOT/$profile/private"
  new_home "$home" "$files"
  mkdir -m 700 "$home/.secrets"
  local s="$home/.secrets"
  env_file "$s/10-good.env" 600 'export DOTFILES_SECRET_GOOD=good'
  # shellcheck disable=SC2016
  env_file "$s/20-order.env" 600 'export DOTFILES_SECRET_ORDER="$DOTFILES_SECRET_GOOD-then-order"'
  env_file "$s/30-noisy.env" 644 'echo hi; echo err >&2; print -u2 again
export DOTFILES_SECRET_NOISY=loaded'
  env_file "$s/40-syntax.env" 600 'export DOTFILES_SECRET_SYNTAX=half
if then fi ('
  env_file "$s/50-after-syntax.env" 600 'export DOTFILES_SECRET_AFTER_SYNTAX=loaded'
  env_file "$s/60-groupw.env" 620 'export DOTFILES_SECRET_GROUPW=loaded'
  env_file "$s/61-worldw.env" 602 'export DOTFILES_SECRET_WORLDW=loaded'
  env_file "$home/link-target.env" 600 'export DOTFILES_SECRET_LINK=loaded'
  ln -s ../link-target.env "$s/62-link.env"
  env_file "$s/64-txt.env.txt" 600 'export DOTFILES_SECRET_TXT=loaded'
  # A scoped secret: a 700 subfolder holding an owner-only *.env file, which the
  # loader must never export (README's Secrets section names compact-adviser).
  mkdir -m 700 "$s/compact-adviser"
  env_file "$s/compact-adviser/typesafe.env" 600 'export DOTFILES_SECRET_SUBDIR=loaded'
  if [ -n "$AS_USER" ]; then
    env_file "$s/63-unreadable.env" 000 'export DOTFILES_SECRET_UNREADABLE=loaded'
  fi
  probe "$profile: a 700 ~/.secrets folder loads only its top-level owner-only *.env files, in order, silently (a file in a subfolder is not exported)" \
    "$home" "$(expected GOOD=good ORDER=good-then-order NOISY=loaded AFTER_SYNTAX=loaded)"
}

probe_profile "dev@$SYSTEM"
probe_profile "node@container-$SYSTEM"
