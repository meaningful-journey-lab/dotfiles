#!/usr/bin/env bash
# Keeps a real, shallow clone of the private Ixia plugin marketplace (Bitbucket
# iqxbusiness/ixia-marketplace, default branch) for Pi, which has no plugin
# packaging. Pi loads the plugin's skills on demand, for IQX Bitbucket work only:
#   pi-ixia (Zsh function passing individual --skill paths, without feedback)
# See README's Ixia plugins section for setup and usage restrictions. The clone
# must be real, not a copy of skills/, because the review-panel skill finds its
# reviewer agents/ two levels above it. Claude Code needs none of
# this: it fetches and updates the plugin itself (home/.claude/settings.json
# registers the marketplace and enables no plugin; the plugins load per session
# through the `claude` Zsh function, a Firstmate home's config file, or an IQX
# repository's own settings if IQX adds them - see README's Ixia plugins section).
#
# Run by every Home Manager switch (home.nix `home.activation.ixiaMarketplace`),
# so a devcontainer rebuild, which loses ~/.local/share, gets the clone back
# from post-create's switch, and by hand to refresh it between switches:
#   bash ~/.dotfiles/tools/ixia-marketplace.sh
#
# - no clone yet: `git clone --depth 1` into $IXIA_MARKETPLACE_DIR (default
#   ~/.local/share/ixia-marketplace, outside this checkout), through a
#   temporary directory so a failed clone leaves nothing behind;
# - a clone: `git fetch`, then a fast-forward merge only, so the clone follows
#   the marketplace's releases and never discards or overwrites local changes
#   or local commits (it warns and stays put instead).
#
# It never fails: no network, no SSH key or agent, or no Bitbucket access only
# warns (exit 0), so the switch goes on and the next one retries. Git runs with
# no prompts (BatchMode SSH, no terminal prompt). The URL is the SSH form that
# works unattended with the machine's key; it carries no credentials, and none
# belong in this file. IXIA_MARKETPLACE_URL and IXIA_MARKETPLACE_DIR can be
# overridden; the tests point them at a local fixture.
# Usage: tools/ixia-marketplace.sh
set -uo pipefail

URL=${IXIA_MARKETPLACE_URL:-git@bitbucket.org:iqxbusiness/ixia-marketplace.git}
DIR=${IXIA_MARKETPLACE_DIR:-$HOME/.local/share/ixia-marketplace}
SKILLS_SUBDIR=plugins/ixia-stratex/skills

say() { printf 'ixia-marketplace: %s\n' "$*"; }
warn() { printf 'ixia-marketplace: warning: %s\n' "$*" >&2; }

git_run() {
  local workdir=$1 ssh_command
  local cap=() config=()
  shift
  [ "$1" != clone ] || config=(-c "remote.origin.url=$URL")
  if [ "${GIT_SSH_COMMAND+x}" = x ]; then
    ssh_command=$GIT_SSH_COMMAND
  else
    ssh_command=$(git -C "$workdir" ${config[@]+"${config[@]}"} config --get core.sshCommand 2>/dev/null) || ssh_command=ssh
  fi
  command -v timeout >/dev/null 2>&1 && cap=(timeout -k 5 180)
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$ssh_command -o BatchMode=yes -o ConnectTimeout=15" \
    ${cap[@]+"${cap[@]}"} git "$@"
}

clone_fresh() {
  local tmp
  mkdir -p -- "$(dirname -- "$DIR")" || { warn "cannot create $(dirname -- "$DIR")"; return 0; }
  tmp=$(mktemp -d "$DIR.clone.XXXXXX") || { warn "cannot create a temporary directory next to $DIR"; return 0; }
  say "cloning $URL into $DIR"
  if git_run "$tmp" clone --quiet --depth 1 -- "$URL" "$tmp/clone" 2>"$tmp/err"; then
    mv -- "$tmp/clone" "$DIR" || warn "cannot move the clone to $DIR"
  else
    warn "cannot clone $URL (offline, or no SSH key or Bitbucket access?): $(tail -n 1 "$tmp/err"); skipping, the next switch retries"
  fi
  rm -rf -- "$tmp"
}

refresh() {
  local before after
  if ! git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || [ "$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" != "$(cd "$DIR" && pwd -P)" ]; then
    warn "$DIR exists but is not a git clone; leaving it alone (move it aside to get a fresh clone)"
    return 0
  fi
  before=$(git -C "$DIR" rev-parse HEAD 2>/dev/null)
  if ! git_run "$DIR" -C "$DIR" fetch --quiet origin 2>/dev/null; then
    warn "cannot fetch $DIR (offline, or no SSH key or Bitbucket access?); keeping the current version"
    return 0
  fi
  if ! git -C "$DIR" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    warn "$DIR has no upstream branch (detached HEAD?); not updating it"
    return 0
  fi
  if ! git -C "$DIR" merge --quiet --ff-only '@{upstream}' >/dev/null 2>&1; then
    warn "$DIR cannot fast-forward (local changes or commits in the way); leaving it as it is"
    return 0
  fi
  after=$(git -C "$DIR" rev-parse HEAD 2>/dev/null)
  [ "$before" = "$after" ] || say "updated $DIR to ${after:0:9}"
}

main() {
  command -v git >/dev/null 2>&1 || { warn "git not found on PATH; skipping"; return 0; }
  if [ ! -e "$DIR" ] && [ ! -L "$DIR" ]; then
    clone_fresh
  else
    refresh
  fi
  if [ -d "$DIR" ] && [ ! -d "$DIR/$SKILLS_SUBDIR" ]; then
    warn "$DIR/$SKILLS_SUBDIR is missing; Pi finds no ixia skills until the marketplace layout is restored"
  fi
  return 0
}

main "$@"
exit 0
