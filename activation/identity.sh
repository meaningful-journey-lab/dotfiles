#!/usr/bin/env bash
# Renders per-remote git identities and SSH key selection from the
# workstation's identity file, and checks (never creates) the SSH keys behind
# them.
#
#   identity.sh render workstation|container   # activation: render + check, never fails
#   identity.sh check  workstation|container   # doctor: check only, exit 1 on problems
#     Container check also requires non-revoked entries in the pinned forge file.
#
# Inputs (non-secret):
#   ~/.config/dotfiles
#     identity.env     user-authored copy of identity.env.example
#     pub/<label>.pub  public halves, exported here by the workstation render
#                      so a container can select agent keys without ever
#                      seeing a private key
#   $DOTFILES_REV      (workstation render) the dotfiles revision being applied
# Outputs (generated; rewritten only when their content changes). Identity
# outputs are removed when identity.env goes away; applied-rev is independent:
#   ~/.config/git/identities.gitconfig   includeIf rules
#   ~/.config/git/identity/<label>.gitconfig
#   ~/.ssh/config.d/identities          legacy aliases; container also includes
#                                      ~/.ssh/pinned-hosts.conf
#   workstation only, in the identity directory:
#     pub/<label>.pub  public halves of the keys
#     ssh-keys         private key paths, one per line, for the zsh agent autoload
#     applied-rev      $DOTFILES_REV, so a container follows the workstation
#
# Secret rule: this script only tests private keys with test -f / stat. It
# never reads, prints, copies, or generates one; only <key>.pub is ever read.
set -u

mode=${1:-}
profile=${2:-}
case "$mode/$profile" in
  render/workstation | render/container | check/workstation | check/container) ;;
  *) echo "usage: $0 render|check workstation|container" >&2; exit 2 ;;
esac

ID_DIR=$HOME/.config/dotfiles
ID_FILE=$ID_DIR/identity.env
PUB_DIR=$ID_DIR/pub
KEYS_OUT=$ID_DIR/ssh-keys
REV_OUT=$ID_DIR/applied-rev
GIT_OUT=$HOME/.config/git
SSH_OUT=$HOME/.ssh/config.d/identities
TEMPLATE=$HOME/.dotfiles/identity.env.example

problems=0
say() { printf 'identity: %s\n' "$*" >&2; }
problem() { problems=$((problems + 1)); say "$*"; }
tilde() { printf '%s\n' "${1/#"$HOME"\//\~/}"; }

declare -A V=()
# KEY=value parser: no sourcing, no expansion. Surrounding double quotes
# are stripped; anything else on a line is an error.
parse() {
  local line key val n=0
  # tilde only formats the path in diagnostics; it never writes ID_FILE.
  # shellcheck disable=SC2094
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in '' | '#'*) continue ;; esac
    if [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
      if [[ $val =~ ^\"(.*)\"$ ]]; then val=${BASH_REMATCH[1]}; fi
      V[$key]=$val
    else
      problem "$(tilde "$ID_FILE"):$n is not a KEY=value line"
      return 1
    fi
  done <"$ID_FILE" || { problem "cannot read $(tilde "$ID_FILE"): chmod u+r $(tilde "$ID_FILE")"; return 1; }
}

valid() { # name regex value
  [[ $3 =~ $2 ]] || { problem "$1 has an invalid value"; return 1; }
}

# load fills LABELS with every label that passes validation. It runs once;
# LOAD_RC keeps its result for the check that follows a render.
LABELS=()
LOADED=
LOAD_RC=1
load() {
  [ -z "$LOADED" ] || return "$LOAD_RC"
  LOADED=1
  [ -f "$ID_FILE" ] || return 1
  parse || return 1
  local l ok
  for l in ${V[IDENTITIES]:-}; do
    ok=1
    valid "IDENTITIES label $l" '^[A-Za-z][A-Za-z0-9_]*$' "$l" || continue
    valid "${l}_HOST" '^[A-Za-z0-9.-]+$' "${V[${l}_HOST]:-}" || ok=
    valid "${l}_OWNERS" '^[A-Za-z0-9._-]+( [A-Za-z0-9._-]+)*$' "${V[${l}_OWNERS]:-}" || ok=
    valid "${l}_KEY" '^~?[A-Za-z0-9._/-]+$' "${V[${l}_KEY]:-}" || ok=
    # Match the literal ~/ prefix; validation must not expand it here.
    # shellcheck disable=SC2088
    case "${V[${l}_KEY]:-}" in
      /* | '~/'*) ;;
      *) problem "${l}_KEY must start with / or ~/ (relative paths are not supported)"; ok= ;;
    esac
    valid "${l}_NAME" '^[^"\\]+$' "${V[${l}_NAME]:-}" || ok=
    valid "${l}_EMAIL" '^[^"\\ ]+@[^"\\ ]+$' "${V[${l}_EMAIL]:-}" || ok=
    [ -z "${V[${l}_ALIAS]:-}" ] || valid "${l}_ALIAS" '^[A-Za-z0-9.-]+$' "${V[${l}_ALIAS]}" || ok=
    [ -n "$ok" ] && LABELS+=("$l")
  done
  if [ "${#LABELS[@]}" -eq 0 ]; then
    problem "$(tilde "$ID_FILE") defines no valid identity (IDENTITIES=...)"
    return 1
  fi
  LOAD_RC=0
}

# Match literal ~/ before explicitly expanding it for this HOME.
# shellcheck disable=SC2088
expand() { case "$1" in '~/'*) printf '%s\n' "$HOME/${1#'~/'}" ;; *) printf '%s\n' "$1" ;; esac; }

git_quote() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\t'/\\t}
  printf '"%s"' "$value"
}

shell_quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# The key ssh offers for an identity: on the workstation the private key path
# (ssh reads <key>.pub beside it to pick the agent key, and can fall back to
# the file); in a container the exported public half only, so the private
# key never has to be there.
key_ref() {
  if [ "$profile" = workstation ]; then expand "${V[${1}_KEY]}"; else printf '%s\n' "$PUB_DIR/$1.pub"; fi
}

is_public_key() { # first token must be an OpenSSH public key type
  local t=''
  read -r t _ <"$1" 2>/dev/null || [ -n "$t" ] || return 1
  case "$t" in ssh-ed25519 | ssh-rsa | ecdsa-sha2-* | sk-ssh-ed25519@openssh.com | sk-ecdsa-sha2-*) return 0 ;; esac
  return 1
}

# Writes only when the content differs (so mtimes stay put) and reports a
# failure (read-only mount, no space) as one problem instead of raw errors.
write_if_changed() { # path content
  if [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; then return 0; fi
  { mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" >"$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"; } 2>/dev/null \
    || { rm -f "$1.tmp.$$"; problem "cannot write $(tilde "$1")"; return 1; }
}

# Removes files in $1 with suffix $2 whose label is not in the remaining arguments.
prune() { # dir suffix label...
  local dir=$1 suffix=$2 f name l keep; shift 2
  for f in "$dir"/*"$suffix"; do
    [ -e "$f" ] || continue
    name=$(basename "$f" "$suffix") keep=
    for l; do [ "$l" = "$name" ] && keep=1; done
    [ -n "$keep" ] || rm -f "$f"
  done
}

# The host name SSH connects to for a forge host. Bitbucket Cloud's SSH git
# service is ssh.bitbucket.org; bitbucket.org stays the name for HTTPS.
ssh_host() {
  case $1 in
    bitbucket.org) printf '%s' ssh.bitbucket.org ;;
    *) printf '%s' "$1" ;;
  esac
}

render() {
  local header
  header="# Generated by ~/.dotfiles/activation/identity.sh from $(tilde "$ID_FILE") - edit that file, not this one."
  if [ "$profile" = workstation ]; then
    [ -z "${DOTFILES_REV:-}" ] || write_if_changed "$REV_OUT" "$DOTFILES_REV"
  fi
  if ! load; then
    # No usable identity file: drop what an earlier render wrote, so nothing stale applies.
    rm -f "$GIT_OUT/identities.gitconfig" "$SSH_OUT"
    rm -rf "$GIT_OUT/identity"
    [ "$profile" = workstation ] && { rm -f "$KEYS_OUT"; rm -rf "$PUB_DIR"; }
    return 0
  fi
  local l o h a sh key command rules="$header" ssh="$header" keys='' pat pats
  for l in "${LABELS[@]}"; do
    h=${V[${l}_HOST]} a=${V[${l}_ALIAS]:-} key=$(key_ref "$l")
    sh=$(ssh_host "$h")
    command="ssh -i $(shell_quote "$key") -o IdentitiesOnly=yes"
    [ "$profile" = workstation ] || command+=" -F $(shell_quote "$SSH_OUT")"
    write_if_changed "$GIT_OUT/identity/$l.gitconfig" "$header
[user]
	name = $(git_quote "${V[${l}_NAME]}")
	email = $(git_quote "${V[${l}_EMAIL]}")
[core]
	sshCommand = $(git_quote "$command")"
    for o in ${V[${l}_OWNERS]}; do
      # $sh is where SSH goes; $h stays for HTTPS and for remotes cloned
      # before the SSH host changed.
      pats=("git@$h:$o/**" "ssh://git@$h/$o/**" "https://$h/$o/**" "https://*@$h/$o/**")
      [ "$sh" = "$h" ] || pats+=("git@$sh:$o/**" "ssh://git@$sh/$o/**")
      [ -z "$a" ] || pats+=("git@$a:$o/**" "ssh://git@$a/$o/**")
      for pat in "${pats[@]}"; do
        rules+=$'\n'"[includeIf \"hasconfig:remote.*.url:$pat\"]"$'\n'"	path = identity/$l.gitconfig"
      done
    done
    [ -n "$a" ] && ssh+=$'\n'"Host $a"$'\n'"  HostName $sh"$'\n'"  User git"$'\n'"  IdentityFile $(git_quote "$key")"$'\n'"  IdentitiesOnly yes"
    keys+=${keys:+$'\n'}$(expand "${V[${l}_KEY]}")
  done
  # Git's ssh runs with -F on this file alone (container), so it never reads
  # ~/.ssh/config. Last, so the pinned forge host keys that home.nix links
  # (~/.ssh/pinned-hosts.conf) match the host an alias above resolves to.
  # `Match all` ends the last alias block: an include under an inactive Host
  # block never matches anything.
  [ "$profile" = workstation ] || ssh+=$'\n'"Match all"$'\n'"Include $(git_quote "$HOME/.ssh/pinned-hosts.conf")"
  prune "$GIT_OUT/identity" .gitconfig "${LABELS[@]}"
  write_if_changed "$GIT_OUT/identities.gitconfig" "$rules"
  if [ ! -d "$HOME/.ssh" ]; then mkdir -m 700 "$HOME/.ssh" 2>/dev/null; fi
  if write_if_changed "$SSH_OUT" "$ssh"; then
    chmod 700 "$(dirname "$SSH_OUT")" 2>/dev/null
    chmod 600 "$SSH_OUT" 2>/dev/null
  fi
  [ "$profile" = workstation ] || return 0
  write_if_changed "$KEYS_OUT" "$keys"
  mkdir -p "$PUB_DIR" 2>/dev/null
  prune "$PUB_DIR" .pub "${LABELS[@]}"
  for l in "${LABELS[@]}"; do
    key=$(expand "${V[${l}_KEY]}")
    # Public half only, and only when it really is an OpenSSH public key.
    if [ -f "$key.pub" ] && is_public_key "$key.pub"; then
      write_if_changed "$PUB_DIR/$l.pub" "$(cat "$key.pub")" && chmod 644 "$PUB_DIR/$l.pub"
    else
      rm -f "$PUB_DIR/$l.pub"
    fi
  done
}

# Needs no identity file, so check pins before the early return below.
# @revoked entries must not satisfy the presence check. See README's
# SSH in the container profile section for the offline check's contract.
check_pinned() {
  local pinned=$HOME/.ssh/pinned_known_hosts host
  for host in github.com ssh.bitbucket.org bitbucket.org; do
    if ! ssh-keygen -F "$host" -f "$pinned" 2>/dev/null | grep -v -e '^#' -e '^@revoked' | grep -q .; then
      problem "no pinned $host host key in $(tilde "$pinned"): SSH to it would ask to trust the key or refuse it. Run hm-update to switch again"
    fi
  done
}

check() {
  local l key pub fp loaded rc v kd
  [ "$profile" = container ] && check_pinned
  if [ ! -f "$ID_FILE" ]; then
    if [ "$profile" = workstation ]; then
      problem "no $(tilde "$ID_FILE") yet. Create it from the template, fill it in, then switch again:"
      say "    install -D -m 600 $(tilde "$TEMPLATE") $(tilde "$ID_FILE") && \${EDITOR:-nvim} $(tilde "$ID_FILE")"
    else
      problem "no $(tilde "$ID_FILE"): the workstation's identity directory is not mounted here. Create the file on the workstation (install -D -m 600 ~/.dotfiles/identity.env.example ~/.config/dotfiles/identity.env), then rebuild this container."
    fi
    return
  fi
  # A read-only container bind keeps the host's UID mapping; only ownership is skipped.
  if [ "$profile" = workstation ] && [ "$(stat -L -c %u "$ID_FILE" 2>/dev/null)" != "$(id -u)" ]; then
    problem "$(tilde "$ID_FILE") must be owned by you: chown $(id -un) $(tilde "$ID_FILE")"
  fi
  if [ -n "$(find -L "$ID_FILE" -maxdepth 0 -perm /022 2>/dev/null)" ]; then
    problem "$(tilde "$ID_FILE") must not be group/world-writable: chmod 600 $(tilde "$ID_FILE")"
  fi
  load || return
  loaded=$(ssh-add -l 2>/dev/null); rc=$?
  if [ "$rc" = 2 ] || [ "$rc" = 127 ]; then
    if [ "$profile" = workstation ]; then
      problem "no ssh-agent reachable (SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-unset}). On WSL2 enable systemd: add [boot] systemd=true to /etc/wsl.conf, run 'wsl --shutdown' from Windows, reopen."
    else
      problem "no ssh-agent at SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-unset}: the workstation agent was not running (or restarted) when this container started. Recreate the container from a workstation shell where 'ssh-add -l' lists your keys."
    fi
  fi
  for l in "${LABELS[@]}"; do
    key=$(expand "${V[${l}_KEY]}") kd=${V[${l}_KEY]}
    if [ "$profile" = workstation ]; then
      if [ ! -f "$key" ]; then
        problem "$l: no private key at $kd. Create it yourself (this tool never does):"
        say "    ssh-keygen -t ed25519 -C $(shell_quote "${V[${l}_EMAIL]}") -f $kd"
        case "${V[${l}_HOST]}" in
          github.com) say "    then add $kd.pub to the right GitHub account: https://github.com/settings/ssh/new" ;;
          bitbucket.org) say "    then add $kd.pub to Bitbucket: https://bitbucket.org/account/settings/ssh-keys/" ;;
          *) say "    then add $kd.pub to your account on ${V[${l}_HOST]}" ;;
        esac
        continue
      fi
      case "$(stat -L -c %a "$key" 2>/dev/null)" in
        600 | 400) ;;
        *) problem "$l: $kd must be mode 600: chmod 600 $kd" ;;
      esac
      pub=$key.pub
      [ -f "$pub" ] || { problem "$l: no $kd.pub beside the key. Recreate it: ssh-keygen -y -f $kd > $kd.pub"; continue; }
    else
      pub=$PUB_DIR/$l.pub
      [ -f "$pub" ] || { problem "$l: the workstation exported no public key for it ($(tilde "$pub")). Fix the key on the workstation, switch there, then rebuild this container."; continue; }
    fi
    if [ "$rc" = 0 ] || [ "$rc" = 1 ]; then
      fp=$(ssh-keygen -lf "$pub" 2>/dev/null | awk '{print $2}')
      if [ -z "$fp" ]; then
        problem "$l: $(tilde "$pub") is not a readable OpenSSH public key"
        continue
      fi
      case "$loaded" in
        *"$fp"*) ;;
        *) if [ "$profile" = workstation ]; then
             problem "$l: key not loaded in the agent: ssh-add $kd"
           else
             problem "$l: the workstation agent does not hold this key: run 'ssh-add $kd' on the workstation"
           fi ;;
      esac
    fi
  done
  v=$(git --version 2>/dev/null | awk '{print $3}')
  if [ -n "$v" ] && [ "$(printf '%s\n2.36.0\n' "$v" | sort -V | head -n1)" != 2.36.0 ]; then
    problem "git $v is older than 2.36 and ignores includeIf hasconfig:remote.*.url: put ~/.nix-profile/bin first on PATH"
  fi
  if [ "${GIT_CONFIG_GLOBAL+set}" = set ]; then
    problem "GIT_CONFIG_GLOBAL=$GIT_CONFIG_GLOBAL hides ~/.config/git/config (and these identities); unset it"
  fi
  if [ -f "$HOME/.gitconfig" ]; then
    git config --includes --file "$HOME/.gitconfig" --get-regexp '^(user\.|includeif\.|url\.|core\.sshcommand$)' >/dev/null 2>&1
    rc=$?
    if [ "$rc" = 0 ]; then
      # The diagnostic deliberately shows a literal home-relative path.
      # shellcheck disable=SC2088
      problem "~/.gitconfig sets user/includeIf/url/core.sshCommand keys that override these identities (git reads it last). Move them into $(tilde "$ID_FILE") and delete ~/.gitconfig."
    elif [ "$rc" != 1 ] || [ ! -r "$HOME/.gitconfig" ]; then
      problem "cannot inspect ~/.gitconfig or its includes. Run 'git config --includes --file ~/.gitconfig --list', then fix its parse/read errors."
    fi
  fi
}

if [ "$mode" = render ]; then
  render
  check
  [ "$problems" = 0 ] || say "$problems problem(s) above; the switch still completed. Re-check any time with: ~/.dotfiles/activation/identity.sh check $profile"
  exit 0
fi
check
[ "$problems" = 0 ] && say "ok" && exit 0
exit 1
