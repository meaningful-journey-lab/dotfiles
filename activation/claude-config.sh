#!/usr/bin/env bash
# Install the dotfiles' Claude Code add-ons into $CLAUDE_CONFIG_DIR.
#
# Usage: claude-config.sh unlink
#        claude-config.sh install <settings.json> <CLAUDE.md source>
#
# Claude Code reads its user config from $CLAUDE_CONFIG_DIR when that is set
# and non-empty, else ~/.claude. Flakes evaluate purely, so only activation
# time can see that variable. home.nix links ~/.claude/settings.json and
# ~/.claude/CLAUDE.md into the dotfiles checkout with plain home.file entries,
# and runs this script around Home Manager's own link steps.
#
# CLAUDE_CONFIG_DIR unset, empty, or naming ~/.claude: both modes do nothing,
# so those home.file links and Home Manager's collision handling are all there is.
#
# Any other CLAUDE_CONFIG_DIR (the devcontainer points it at the workspace),
# which may already hold the owner's own real files:
#
# install (after linkGeneration):
#   - settings.json: additive merge that never rewrites an owner value. Top-level
#     keys (theme, statusLine, pluginConfigs) are added only when absent; the
#     entries of extraKnownMarketplaces (the ixia marketplace) are added one by
#     one inside an owner object that already has that key, never changing an
#     entry the owner has; each hook is added only when no hook for the same
#     event already runs its command. Written only when that changes
#     something, atomically and keeping the file mode, after a one-time
#     byte-for-byte settings.json.pre-dotfiles-<epoch> backup.
#   - CLAUDE.md: linked to the dotfiles copy only when absent.
#   - ~/.claude/settings.json and ~/.claude/CLAUDE.md, just linked by Home
#     Manager, are re-pointed into the configured directory, so installers that
#     hardcode ~/.claude (gh-axi/chrome-devtools-axi/lavish-axi setup hooks)
#     edit the file Claude reads instead of the dotfiles checkout.
#   - skills: a one-way move. Each entry of a real ~/.claude/skills directory
#     moves into $CLAUDE_CONFIG_DIR/skills unless that name already exists
#     there. When it does, a link (never a real file or directory) that cannot
#     be the skill to keep goes: a dangling ~/.claude one is removed; a dangling
#     configured one is replaced by the ~/.claude entry, as is a configured one
#     that reaches the skill only through that entry; a ~/.claude link reaching
#     the same skill (as an image rebuild re-creates them) is a duplicate and is
#     removed. Only a clash between two live, different skills stays where it
#     is, with a warning. Once ~/.claude/skills is empty (or
#     absent) it becomes a link to $CLAUDE_CONFIG_DIR/skills, so later installs
#     (no-mistakes init) land there. A ~/.claude/skills that is already a link
#     is left alone. While it is the link to $CLAUDE_CONFIG_DIR/skills, each
#     dangling link there is re-pointed at ~/.agents/skills/<name>, or reported
#     with a warning when no copy exists there.
#
# unlink (before checkLinkTargets): removes the two re-pointed ~/.claude links
# again, and only while they still point where install left them, so Home
# Manager's collision check does not trip over them and still judges anything
# else.
#
# A real file or directory in the configured directory is never overwritten,
# moved or deleted, a real one in ~/.claude/skills is only ever moved, and a
# real file where a ~/.claude link belongs is left in place with a warning.
# Re-running is a no-op.
#
# install also checks the user settings Claude reads ($CLAUDE_CONFIG_DIR/settings.json,
# else ~/.claude/settings.json) and warns, never edits, when they enable a plugin
# of the ixia marketplace (any *@ixia id). Ixia plugins belong to IQX sessions only,
# so they load per session (README "Ixia plugins"), never from the user file.
set -euo pipefail

log() { printf 'claude-config: %s\n' "$*"; }
warn() { printf 'claude-config: warning: %s\n' "$*" >&2; }

# Point $1 at $2, unless both already resolve to the same file. A symlink holds
# no data, so an existing one is replaced; a real file or directory is left alone.
link_into_place() {
  local path=$1 target=$2
  [ "$path" -ef "$target" ] && return 0
  if [ -L "$path" ]; then
    [ "$(readlink -- "$path")" = "$target" ] && return 0
    rm -f -- "$path"
  elif [ -e "$path" ]; then
    warn "$path is a real file, not linking it to $target; move it aside and re-apply"
    return 0
  fi
  mkdir -p -- "$(dirname -- "$path")"
  ln -s -- "$target" "$path"
  log "linked $path -> $target"
}

# Point $1 at $2 only if nothing (not even a dangling link) is there yet.
link_if_absent() {
  local path=$1 target=$2
  if [ -e "$path" ] || [ -L "$path" ]; then
    if [ ! -L "$path" ] || [ "$(readlink -- "$path")" != "$target" ]; then
      log "kept existing $path"
    fi
    return 0
  fi
  ln -s -- "$target" "$path"
  log "linked $path -> $target"
}

# jq: add $add[0] (dotfiles settings) to $cur[0] (owner settings) without
# changing any value the owner already has.
# shellcheck disable=SC2016
MERGE='
def id: if type == "object" and has("command") then .command else . end;
reduce ($add[0] | to_entries[]) as $e ($cur[0];
  if $e.key == "hooks" then
    reduce ($e.value | to_entries[]) as $ev (.;
      reduce $ev.value[] as $group (.;
        [.hooks[$ev.key][]?.hooks[]? | id] as $have
        | [$group.hooks[]? | select(id | IN($have[]) | not)] as $missing
        | if $missing == [] then .
          else .hooks[$ev.key] += [$group + {hooks: $missing}] end))
  elif $e.key == "extraKnownMarketplaces"
      and (.[$e.key] | type) == "object" and ($e.value | type) == "object" then
    .[$e.key] as $own
    | .[$e.key] += ($e.value | with_entries(select(.key as $k | $own | has($k) | not)))
  elif has($e.key) then .
  else . + {($e.key): $e.value} end)'

merge_settings() {
  local src=$1 dest=$2 dir tmp backup
  if ! is_json_object "$src"; then
    warn "$src is not a JSON object, skipping settings"
    return 0
  fi
  if [ -L "$dest" ]; then
    # Merge into whatever the owner's link points at, keeping the link.
    if ! dest=$(realpath -e -- "$dest" 2>/dev/null); then
      warn "$2 is a dangling link, skipping settings"
      return 0
    fi
    [ "$dest" = "$(realpath -e -- "$src")" ] && return 0
  fi
  dir=$(dirname -- "$dest")
  mkdir -p -- "$dir"
  if [ ! -e "$dest" ]; then
    tmp=$(mktemp "$dir/.settings.json.XXXXXX")
    if jq . "$src" >"$tmp"; then
      chmod 644 "$tmp"
      mv -f -- "$tmp" "$dest"
      log "created $dest"
    else
      rm -f -- "$tmp"
      warn "could not write $dest"
    fi
    return 0
  fi
  if ! is_json_object "$dest"; then
    warn "$dest is not a JSON object, leaving it untouched"
    return 0
  fi
  # Already merged: leave the file and its directory untouched.
  if jq -e -n --slurpfile cur "$dest" --slurpfile add "$src" "($MERGE) == \$cur[0]" >/dev/null 2>&1; then
    return 0
  fi
  tmp=$(mktemp "$dir/.settings.json.XXXXXX")
  # Copy first so the rewrite keeps the owner's mode, then replace atomically.
  cp -p -- "$dest" "$tmp"
  if ! jq -n --slurpfile cur "$dest" --slurpfile add "$src" "$MERGE" >"$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    warn "could not merge $src into $dest (unexpected hooks shape?), leaving it untouched"
    return 0
  fi
  if ! compgen -G "$dest.pre-dotfiles-*" >/dev/null; then
    backup="$dest.pre-dotfiles-$(date +%s)"
    cp -p -- "$dest" "$backup"
    log "backed up $dest to $backup"
  fi
  mv -f -- "$tmp" "$dest"
  log "merged $src into $dest"
}

is_json_object() {
  jq -e -n --slurpfile doc "$1" '($doc | length) == 1 and ($doc[0] | type) == "object"' >/dev/null 2>&1
}

# Where a moved skill link must point so it still reaches what $1 reaches now.
# A relative target is anchored at the link's directory. The parent is then
# resolved physically, while ~/.claude/skills is still a real directory, because
# the kernel resolves ".." physically and ~/.claude/skills is about to become a
# link elsewhere; the last component is kept, so a re-pointed skill still follows.
moved_link_target() {
  local link=$1 target
  target=$(readlink -- "$link")
  target=${target%"${target##*[!/]}"}
  case $target in
    /*) ;;
    *) target="$(dirname -- "$link")/$target" ;;
  esac
  printf '%s/%s\n' "$(realpath -m -- "$(dirname -- "$target")")" "${target##*/}"
}

# Remove the link $1 when $2 reaches the same file without going through $1,
# as when an image rebuild re-creates a skill link an earlier run already moved.
# $1 is first moved aside and checked from there, and put back if $2 then
# reaches something else (or nothing); a real file or directory is never removed.
drop_duplicate_link() {
  local link=$1 other=$2 aside
  [ -L "$link" ] && [ "$link" -ef "$other" ] || return 1
  aside=$(mktemp -u "$(dirname -- "$link")/.dup.XXXXXX")
  mv -T -- "$link" "$aside"
  if [ "$other" -ef "$aside" ]; then
    rm -f -- "$aside"
    return 0
  fi
  mv -T -- "$aside" "$link"
  return 1
}

# Re-point each dangling link in $1 at the same-named skill in ~/.agents/skills,
# where the skills CLI keeps its copies, or warn when there is none.
heal_skills() {
  local dir=$1 agents="$HOME/.agents/skills" entry name
  for entry in "$dir"/* "$dir"/.[!.]*; do
    [ -L "$entry" ] && [ ! -e "$entry" ] || continue
    name=${entry##*/}
    if [ -e "$agents/$name" ]; then
      rm -f -- "$entry"
      ln -s -- "$agents/$name" "$entry"
      log "re-pointed $entry: a dangling link, to $agents/$name"
    else
      warn "$entry is a dangling link and $agents/$name does not exist; re-install or remove it"
    fi
  done
}

adopt_skills() {
  local home_skills=$1 dest=$2 entry name kept=0
  if [ -L "$home_skills" ]; then
    [ "$home_skills" -ef "$dest" ] && heal_skills "$dest"
    return 0
  fi
  if [ -e "$home_skills" ] && [ ! -d "$home_skills" ]; then
    warn "$home_skills is a real file, not linking it to $dest"
    return 0
  fi
  if [ -L "$dest" ] && [ ! -d "$dest" ]; then
    warn "$dest is a dangling link, skipping skills"
    return 0
  fi
  mkdir -p -- "$dest"
  # The owner linked the configured skills back to ~/.claude/skills: one directory.
  [ "$dest" -ef "$home_skills" ] && return 0

  if [ -d "$home_skills" ]; then
    for entry in "$home_skills"/* "$home_skills"/.[!.]*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      name=${entry##*/}
      if [ -e "$dest/$name" ] || [ -L "$dest/$name" ]; then
        if [ ! -e "$entry" ]; then
          rm -f -- "$entry"
          log "removed $entry: a dangling link, and $dest/$name already exists"
          continue
        elif [ ! -e "$dest/$name" ]; then
          rm -f -- "$dest/$name"
          log "replaced $dest/$name: a dangling link"
        elif drop_duplicate_link "$entry" "$dest/$name"; then
          log "removed $entry: $dest/$name already reaches the same skill"
          continue
        elif [ -L "$dest/$name" ] && [ "$dest/$name" -ef "$entry" ]; then
          # The configured link reaches the skill only through $entry.
          rm -f -- "$dest/$name"
          log "replaced $dest/$name: it reached the skill through $entry"
        else
          kept=1
          warn "kept $entry: $dest/$name already exists"
          continue
        fi
      fi
      if [ -L "$entry" ]; then
        ln -s -- "$(moved_link_target "$entry")" "$dest/$name"
        rm -f -- "$entry"
      else
        mv -- "$entry" "$dest/$name"
      fi
      log "moved $entry to $dest/$name"
    done
    if [ "$kept" = 1 ]; then
      warn "left $home_skills a directory; move or remove the entries above and re-apply"
      return 0
    fi
    rmdir -- "$home_skills"
  fi
  ln -s -- "$dest" "$home_skills"
  log "linked $home_skills -> $dest"
  heal_skills "$dest"
}

# The directory Claude reads when it is not ~/.claude, else nothing.
configured_dir() {
  local dir=${CLAUDE_CONFIG_DIR:-} home_dir="$HOME/.claude"
  case $dir in /*) ;; *) return 0 ;; esac
  dir=$(realpath -m -s -- "$dir")
  if [ "$dir" != "$(realpath -m -s -- "$home_dir")" ] && [ ! "$dir" -ef "$home_dir" ]; then
    printf '%s\n' "$dir"
  fi
}

# Warn, never edit, when the user settings $1/settings.json enable a plugin of the
# ixia marketplace. Enabled at user scope, it would load in every Claude session.
# The fix is `disable`, never `uninstall`, run outside $HOME and
# /workspaces/wp (there "project" scope is the user file).
warn_ixia_enabled() {
  local file=$1/settings.json
  [ -f "$file" ] && is_json_object "$file" || return 0
  jq -e '[.enabledPlugins | objects | to_entries[]
    | select(.value == true and (.key | endswith("@ixia")))] | length > 0' "$file" >/dev/null 2>&1 || return 0
  warn "$file enables Ixia plugins at user scope, so they load in every Claude session (they are for IQX sessions only)"
  # shellcheck disable=SC2016
  {
    printf 'claude-config: warning: not changed here. Run these from a neutral directory, not from $HOME or /workspaces/wp:\n'
    printf 'claude-config:   cd "$(mktemp -d)"\n'
    printf 'claude-config:   claude plugin disable ixia-stratex@ixia --scope user\n'
    printf 'claude-config:   claude plugin disable ixia-onelist@ixia --scope user\n'
    printf 'claude-config: warning: use disable, never uninstall. See README "Ixia plugins".\n'
  } >&2
}

unlink_home_links() {
  local dir=$1 name
  for name in settings.json CLAUDE.md; do
    if [ -L "$HOME/.claude/$name" ] && [ "$(readlink -- "$HOME/.claude/$name")" = "$dir/$name" ]; then
      rm -f -- "$HOME/.claude/$name"
    fi
  done
}

install_into() {
  local dir=$1 settings=$2 claude_md=$3 home_dir="$HOME/.claude"
  mkdir -p -- "$dir"
  merge_settings "$settings" "$dir/settings.json"
  link_if_absent "$dir/CLAUDE.md" "$claude_md"
  adopt_skills "$home_dir/skills" "$dir/skills"
  link_into_place "$home_dir/settings.json" "$dir/settings.json"
  link_into_place "$home_dir/CLAUDE.md" "$dir/CLAUDE.md"
}

usage() {
  printf 'usage: %s unlink\n       %s install <settings.json> <CLAUDE.md source>\n' "$0" "$0" >&2
  exit 2
}

main() {
  local dir
  case ${1:-}:$# in
    unlink:1)
      dir=$(configured_dir)
      [ -z "$dir" ] || unlink_home_links "$dir"
      ;;
    install:3)
      case ${CLAUDE_CONFIG_DIR:-} in
        '' | /*) ;;
        *) warn "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR is not an absolute path, using $HOME/.claude" ;;
      esac
      dir=$(configured_dir)
      [ -z "$dir" ] || install_into "$dir" "$2" "$3"
      warn_ixia_enabled "${dir:-$HOME/.claude}"
      ;;
    *) usage ;;
  esac
}

main "$@"
