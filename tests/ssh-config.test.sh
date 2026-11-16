#!/usr/bin/env bash
# Behavior checks for the SSH client config and global git config home.nix
# generates (programs.ssh, programs.git).
#
# Builds each Linux home profile for this machine's system into the Nix store
# (never activating it) and reads the generated files.
#
# Coverage:
# - neither profile evaluates with a Home Manager warning;
# - workstation: ~/.ssh/config is the include of the rendered
#   ~/.ssh/config.d/identities plus the `*` defaults this repo has always
#   shipped, and no personal host alias or key path is hard-coded;
# - workstation: with an identity file rendered by activation/identity.sh in a
#   scratch HOME, `ssh -G` resolves a legacy alias to its real host, user git,
#   only its own key, and keys added to the agent;
# - both profiles: the global git config sets useConfigOnly, pushes over SSH
#   for github.com and bitbucket.org (to ssh.bitbucket.org), includes the rendered identity rules
#   last, and has no folder (gitdir:) rules, insteadOf, or gpg section;
# - container: ~/.ssh/config keeps the four `*` defaults the devcontainer image
#   used to write and includes ~/.ssh/config.d/* then the pinned forge host
#   keys; ssh/pinned_known_hosts holds every key type GitHub and Bitbucket
#   publish (checked against their documented fingerprints); plain ssh and
#   git's `ssh -F ~/.ssh/config.d/identities`, including a legacy alias, both
#   verify github.com, ssh.bitbucket.org and bitbucket.org with StrictHostKeyChecking yes against
#   ~/.ssh/known_hosts and that read-only file only, other hosts keep
#   accept-new in the writable ~/.ssh/known_hosts; GitHub's leaked pre-2023
#   RSA key is pinned @revoked; against a local sshd with a throwaway host
#   key, a key the pins do not know is refused by plain ssh and by git's ssh,
#   appending it to ~/.ssh/known_hosts (the documented rotation override)
#   accepts it for both, and a @revoked key is refused even then; the
#   activation step makes ~/.ssh and ~/.ssh/config.d
#   mode 700 from nothing and from a loose directory; the workstation gets
#   none of it.
#
# Nix evaluates the flake from Git, so new files must be tracked (`git add`).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in nix ssh git zsh python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
dotfiles_test_tmproot ssh-config

SYSTEM=$(nix eval --impure --raw --expr builtins.currentSystem)
WS="dev@$SYSTEM"
CT="node@container-$SYSTEM"

home_files() {
  nix build --no-link --print-out-paths \
    "$ROOT#homeConfigurations.\"$1\".config.home-files" \
    || fail "$1: home-files build failed"
}

for profile in "$WS" "$CT"; do
  warnings=$(nix eval --json "$ROOT#homeConfigurations.\"$profile\".config.warnings") \
    || fail "$profile: evaluating warnings failed"
  [ "$warnings" = "[]" ] || fail "$profile: evaluates without warnings, got: $warnings"
  pass "$profile: evaluates without Home Manager warnings"
done

ws_files=$(home_files "$WS")
config="$ws_files/.ssh/config"
[ -e "$config" ] || fail "$WS: ~/.ssh/config is generated"

ssh_value() {
  awk -v key="$1" '$1 == key {sub(/^[^ ]+ /, ""); print}' <<<"${2:-$resolved}"
}

# A legacy alias, rendered the way activation does. ssh expands `~` from the
# passwd entry, not $HOME, so point the include at the scratch HOME.
H="$TMP_ROOT/home"
mkdir -p "$H/.config/dotfiles" "$H/.ssh"
cat >"$H/.config/dotfiles/identity.env" <<'EOT'
IDENTITIES="gh_work bb_work"
gh_work_HOST=github.com
gh_work_OWNERS="work-org"
gh_work_KEY=~/.ssh/id_ed25519_gh_work
gh_work_NAME="Test Work"
gh_work_EMAIL="work@example.invalid"
gh_work_ALIAS=github.com-work
bb_work_HOST=bitbucket.org
bb_work_OWNERS=work-space
bb_work_KEY=~/.ssh/id_ed25519_bb_work
bb_work_NAME="Test BB"
bb_work_EMAIL=bb@example.invalid
bb_work_ALIAS=bitbucket.org-work
EOT
chmod 600 "$H/.config/dotfiles/identity.env"
env -i HOME="$H" PATH="$PATH" bash "$ROOT/activation/identity.sh" render workstation >/dev/null 2>&1
[ -f "$H/.ssh/config.d/identities" ] || fail "identity render wrote ~/.ssh/config.d/identities"
sed "s|~/.ssh/config.d/identities|$H/.ssh/config.d/identities|" "$config" >"$H/ssh_config"

resolved=$(ssh -G -F "$H/ssh_config" github.com-work 2>&1) || fail "$WS: ssh -G github.com-work failed: $resolved"
[ "$(ssh_value hostname)" = github.com ] || fail "$WS: github.com-work resolves to github.com"
[ "$(ssh_value user)" = git ] || fail "$WS: github.com-work logs in as git"
[ "$(ssh_value identitiesonly)" = yes ] || fail "$WS: github.com-work offers only its own key"
[ "$(ssh_value identityfile)" = "$H/.ssh/id_ed25519_gh_work" ] || fail "$WS: github.com-work uses exactly its own key"
cat >"$H/defaults" <<'EOT'
Host github.com-work
  HostName github.com
  User git
Host *
  AddKeysToAgent yes
  Compression no
  ControlMaster no
  ControlPath ~/.ssh/master-%r@%n:%p
  ControlPersist no
  ForwardAgent no
  HashKnownHosts no
  ServerAliveCountMax 3
  ServerAliveInterval 0
  UserKnownHostsFile ~/.ssh/known_hosts
EOT
defaults=$(ssh -G -F "$H/defaults" github.com-work 2>/dev/null) || fail "SSH consumes default settings fixture"
for key in addkeystoagent compression controlmaster controlpath controlpersist forwardagent hashknownhosts serveralivecountmax serveraliveinterval userknownhostsfile; do
  [ "$(ssh_value "$key")" = "$(ssh_value "$key" "$defaults")" ] || fail "$WS: $key retains its default setting"
done
resolved=$(ssh -G -F "$H/ssh_config" bitbucket.org-work 2>&1) || fail "$WS: ssh -G bitbucket.org-work failed: $resolved"
[ "$(ssh_value hostname)" = ssh.bitbucket.org ] || fail "$WS: bitbucket.org-work resolves to Bitbucket's SSH host, ssh.bitbucket.org"
[ "$(ssh_value user)" = git ] || fail "$WS: bitbucket.org-work logs in as git"
[ "$(ssh_value identityfile)" = "$H/.ssh/id_ed25519_bb_work" ] || fail "$WS: bitbucket.org-work uses exactly its own key"
pass "$WS: a rendered legacy alias resolves to git@github.com with only its own key"

for profile in "$WS" "$CT"; do
  files=$(home_files "$profile")
  gitcfg=$files/.config/git/config
  [ -f "$gitcfg" ] || fail "$profile: ~/.config/git/config is generated"
  [ "$(git config --file "$gitcfg" --bool user.useConfigOnly)" = true ] || fail "$profile: git refuses to guess an identity"
  [ "$(git config --file "$gitcfg" --get-all url.git@github.com:.pushInsteadOf)" = https://github.com/ ] || fail "$profile: github.com push rewrite"
  [ "$(git config --file "$gitcfg" --get-all url.git@ssh.bitbucket.org:.pushInsteadOf)" = https://bitbucket.org/ ] || fail "$profile: bitbucket.org pushes go over SSH to ssh.bitbucket.org"
  # shellcheck disable=SC2088 # Git stores this include path with a literal tilde
  [ "$(git config --file "$gitcfg" --get-all include.path)" = '~/.config/git/identities.gitconfig' ] || fail "$profile: includes the rendered identities"
  if git config --file "$gitcfg" --get-regexp '^(includeif\.|url\..*\.insteadof$|gpg\.)' >/dev/null; then
    fail "$profile: no conditional global rules, clone rewrites or signing settings"
  fi
  mkdir -p "$H/.config/git"
  install -m 600 "$gitcfg" "$H/.config/git/config" || fail "$profile: global config fixture installed"
  repo=$TMP_ROOT/git-probe
  rm -rf "$repo"
  git_home() { env -i HOME="$H" XDG_CONFIG_HOME="$H/.config" GIT_CONFIG_NOSYSTEM=1 PATH="$PATH" git "$@"; }
  git_home init -q "$repo" || fail "$profile: fixture repository initialized"
  git_home -C "$repo" remote add origin https://github.com/work-org/repo.git
  for host in github.com bitbucket.org; do
    case "$host" in
      github.com) owner=work-org; email=work@example.invalid; ssh_host=github.com ;;
      bitbucket.org) owner=work-space; email=bb@example.invalid; ssh_host=ssh.bitbucket.org ;;
    esac
    for authority in "$host" "someone@$host"; do
      url=https://$authority/$owner/repo.git
      case "$authority" in
        "$host") push=git@$ssh_host:$owner/repo.git ;;
        *) push=$url ;;
      esac
      git_home -C "$repo" remote set-url origin "$url" || fail "$profile: remote URL set"
      [ "$(git_home -C "$repo" config user.email)" = "$email" ] || fail "$profile: $url selects the commit identity"
      [ "$(git_home -C "$repo" remote get-url origin)" = "$url" ] || fail "$profile: $url fetch URL stays HTTPS"
      [ "$(git_home -C "$repo" remote get-url --push origin)" = "$push" ] || fail "$profile: $url push URL is $push"
    done
  done
  git_home -C "$repo" remote set-url origin https://bitbucket.org/other/repo.git
  if git_home -C "$repo" commit -q --allow-empty -m unmatched >/dev/null 2>&1; then
    fail "$profile: unmatched owner must refuse the commit"
  fi
  pass "$profile: global git config"
done

ct_files=$(home_files "$CT")
ws_has_pinned=
for f in pinned-hosts.conf pinned_known_hosts; do
  [ ! -e "$ws_files/.ssh/$f" ] || ws_has_pinned=1
done
[ -z "$ws_has_pinned" ] || fail "$WS: no pinned host key files"
ws_activation=$(nix eval --json "$ROOT#homeConfigurations.\"$WS\".config.home.activation" --apply 'a: builtins.hasAttr "sshDirs" a') \
  || fail "$WS: activation evaluates"
[ "$ws_activation" = false ] || fail "$WS: no ~/.ssh directory activation"
pass "$WS: gets no pinned host keys or ~/.ssh directory activation"

# Container: ~/.ssh/config, the pinned keys, and both ways ssh reads them. A
# scratch HOME stands in for /home/node: ssh expands `~` from the passwd entry,
# so rewrite it, and the absolute home Home Manager renders, to the scratch one.
CH="$TMP_ROOT/chome"
mkdir -p "$CH/.config/dotfiles/pub"
mkdir -m 700 "$CH/.ssh"
cp "$H/.config/dotfiles/identity.env" "$CH/.config/dotfiles/identity.env"
chmod 600 "$CH/.config/dotfiles/identity.env"
for f in config pinned-hosts.conf; do
  [ -e "$ct_files/.ssh/$f" ] || fail "$CT: ~/.ssh/$f is generated"
  # Replace the original absolute home first: CH may itself be under /home/node.
  sed -e "s|/home/node/|$CH/|g" -e "s|~/|$CH/|g" "$ct_files/.ssh/$f" >"$CH/.ssh/$f"
done
cp "$ct_files/.ssh/pinned_known_hosts" "$CH/.ssh/pinned_known_hosts"
chmod u+w "$CH/.ssh/pinned_known_hosts" # the store copy is read-only; the revoked-key test edits this one
env -i HOME="$CH" PATH="$PATH" bash "$ROOT/activation/identity.sh" render container >/dev/null 2>&1
identities="$CH/.ssh/config.d/identities"
[ -f "$identities" ] || fail "$CT: identity render wrote ~/.ssh/config.d/identities"
[ "$(stat -c %a "$CH/.ssh" "$CH/.ssh/config.d" "$identities" | tr '\n' ' ')" = '700 700 600 ' ] \
  || fail "$CT: identity render keeps ~/.ssh and config.d at 700 and the file at 600"
printf 'Host wildcard-fixture.example\n  ServerAliveInterval 17\n' >"$CH/.ssh/config.d/wildcard-fixture"
resolved=$(ssh -G -F "$CH/.ssh/config" wildcard-fixture.example 2>/dev/null) || fail "$CT: ssh -G wildcard-fixture.example failed"
[ "$(ssh_value serveraliveinterval)" = 17 ] || fail "$CT: ~/.ssh/config applies another config.d entry"
pass "$CT: ~/.ssh/config consumes config.d wildcard entries"

# The Host * defaults the devcontainer image's static file had, nothing else.
cat >"$CH/image_defaults" <<EOT
Host *
  AddKeysToAgent yes
  StrictHostKeyChecking accept-new
  ServerAliveInterval 60
  UserKnownHostsFile $CH/.ssh/known_hosts
EOT
other=$(ssh -G -F "$CH/.ssh/config" unpinned.example 2>/dev/null) || fail "$CT: ssh -G unpinned.example failed"
image=$(ssh -G -F "$CH/image_defaults" unpinned.example 2>/dev/null) || fail "image defaults fixture resolves"
for key in addkeystoagent stricthostkeychecking serveraliveinterval userknownhostsfile globalknownhostsfile updatehostkeys compression forwardagent hashknownhosts controlmaster; do
  [ "$(ssh_value "$key" "$other")" = "$(ssh_value "$key" "$image")" ] || fail "$CT: $key matches the image's defaults"
done
pass "$CT: ~/.ssh/config keeps the image's Host * defaults for other hosts"

for spec in "$CH/.ssh/config:plain ssh" "$identities:git's ssh -F identities"; do
  cfg=${spec%%:*} via=${spec#*:}
  for host in github.com ssh.bitbucket.org bitbucket.org github.com-work bitbucket.org-work; do
    resolved=$(ssh -G -F "$cfg" "$host" 2>/dev/null) || fail "$CT: $via: ssh -G $host failed"
    case "$host" in
      github.com-work) [ "$(ssh_value hostname)" = github.com ] || fail "$CT: $via: the alias resolves to github.com" ;;
      bitbucket.org-work) [ "$(ssh_value hostname)" = ssh.bitbucket.org ] || fail "$CT: $via: the alias resolves to ssh.bitbucket.org" ;;
    esac
    [ "$(ssh_value stricthostkeychecking)" = true ] || fail "$CT: $via: $host is checked with StrictHostKeyChecking yes"
    [ "$(ssh_value userknownhostsfile)" = "$CH/.ssh/known_hosts $CH/.ssh/pinned_known_hosts" ] || fail "$CT: $via: $host reads known_hosts and the pinned file"
    [ "$(ssh_value globalknownhostsfile)" = none ] || fail "$CT: $via: $host ignores the system known_hosts"
    [ "$(ssh_value updatehostkeys)" = false ] || fail "$CT: $via: $host never rewrites the pinned file"
  done
  resolved=$(ssh -G -F "$cfg" unpinned.example 2>/dev/null) || fail "$CT: $via: ssh -G unpinned.example failed"
  if [ "$cfg" = "$CH/.ssh/config" ]; then
    [ "$(ssh_value stricthostkeychecking)" = accept-new ] || fail "$CT: $via: other hosts keep accept-new"
    [ "$(ssh_value userknownhostsfile)" = "$CH/.ssh/known_hosts" ] || fail "$CT: $via: other hosts use the writable known_hosts"
  fi
  pass "$CT: $via verifies github.com, ssh.bitbucket.org, bitbucket.org and the aliases strictly against known_hosts and the pinned keys"
done

# What the pinned file holds: every key type each forge publishes, matching the
# fingerprints documented by GitHub and Atlassian.
pinned="$CH/.ssh/pinned_known_hosts"
fingerprints=$(ssh-keygen -l -f "$pinned" | awk '{print $3, $4, $2}' | sort)
expected=$(sort <<'EOT'
bitbucket.org (ECDSA) SHA256:FC73VB6C4OQLSCrjEayhMp9UMxS97caD/Yyi2bhW/J0
bitbucket.org (ED25519) SHA256:ybgmFkzwOSotHTHLJgHO0QN8L0xErw6vd0VhFA9m3SM
bitbucket.org (RSA) SHA256:46OSHA1Rmj8E8ERTC6xkNcmGOw9oFxYr0WF6zWW8l1E
ssh.bitbucket.org (ECDSA) SHA256:FC73VB6C4OQLSCrjEayhMp9UMxS97caD/Yyi2bhW/J0
ssh.bitbucket.org (ED25519) SHA256:ybgmFkzwOSotHTHLJgHO0QN8L0xErw6vd0VhFA9m3SM
ssh.bitbucket.org (RSA) SHA256:46OSHA1Rmj8E8ERTC6xkNcmGOw9oFxYr0WF6zWW8l1E
github.com (ECDSA) SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM
github.com (ED25519) SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
github.com (RSA) SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s
EOT
)
[ "$fingerprints" = "$expected" ] || fail "$CT: pinned_known_hosts holds exactly the published GitHub and Bitbucket keys, got: $fingerprints"
for host in github.com ssh.bitbucket.org bitbucket.org; do
  [ "$(ssh-keygen -F "$host" -f "$pinned" | grep -v -e '^#' -e '^@revoked' | grep -c ' ssh-\| ecdsa-')" = 3 ] || fail "$CT: ssh-keygen -F finds three $host keys"
done
# GitHub's former RSA host key (exposed and replaced on 2023-03-24) is pinned
# @revoked, on GitHub's line only, so no known_hosts file can make it trusted.
revoked=$(grep '^@revoked ' "$pinned")
[ "$(grep -c . <<<"$revoked")" = 1 ] || fail "$CT: exactly one key is revoked"
printf '%s\n' "${revoked#@revoked }" >"$TMP_ROOT/revoked.key"
[ "$(ssh-keygen -lf "$TMP_ROOT/revoked.key" | awk '{print $2, $3}')" = 'SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8 github.com' ] \
  || fail "$CT: the revoked key is GitHub's former RSA host key"
[ "$(ssh-keygen -F github.com -f "$pinned" | grep -c '^@revoked github.com ssh-rsa ')" = 1 ] || fail "$CT: ssh-keygen -F reports the revoked GitHub key"
[ ! -e "$CH/.ssh/known_hosts" ] || fail "$CT: no known_hosts is created or linked"
[ -L "$ct_files/.ssh/pinned_known_hosts" ] && [ ! -e "$ct_files/.ssh/known_hosts" ] || fail "$CT: only the pinned file is linked; ~/.ssh/known_hosts stays writable"
pass "$CT: pinned_known_hosts holds the published keys; ~/.ssh/known_hosts is left alone"

# Behaviour against a real sshd on loopback with a throwaway host key standing
# in for a forge key the pins do not know (a rotation). The pinned names are
# reached through a ProxyCommand that dials the local sshd, so the generated
# config and the rendered core.sshCommand are used exactly as written. No
# network, no real key: authentication is expected to fail, which is how a
# test tells "host key accepted" from "Host key verification failed".
SSHD=
for out in $(nix build --no-link --print-out-paths --inputs-from "$ROOT" nixpkgs#openssh); do
  [ -x "$out/bin/sshd" ] && SSHD=$out/bin/sshd
done
[ -n "$SSHD" ] || fail "OpenSSH sshd for the host-key test is available"
SD="$TMP_ROOT/sshd"
mkdir -p "$SD"
ssh-keygen -q -t ed25519 -N '' -C throwaway-forge -f "$SD/host" || fail "throwaway host key generated"
port=
for _ in $(seq 1 50); do
  candidate=$((20000 + RANDOM % 30000))
  (exec 3<>"/dev/tcp/127.0.0.1/$candidate") 2>/dev/null || { port=$candidate; break; }
done
[ -n "$port" ] || fail "a free loopback port for the throwaway sshd"
# Repeated deliberate refusals must not trigger OpenSSH's per-source penalties.
printf 'Port %s\nListenAddress 127.0.0.1\nHostKey %s\nPidFile none\nUsePAM no\nPasswordAuthentication no\nAuthorizedKeysFile none\nStrictModes no\nPerSourcePenalties no\nLoginGraceTime 10\n' \
  "$port" "$SD/host" >"$SD/sshd_config"
"$SSHD" -D -e -f "$SD/sshd_config" >"$SD/sshd.log" 2>&1 &
SSHD_PID=$!
trap 'kill "$SSHD_PID" 2>/dev/null; dotfiles_test_cleanup' EXIT
for _ in $(seq 1 50); do
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break
  sleep 0.1
done
cat >"$SD/dial" <<EOT
#!/usr/bin/env python3
import os
import select
import socket

with socket.create_connection(("127.0.0.1", $port), timeout=10) as connection:
    connection.settimeout(None)
    while True:
        readable, _, _ = select.select([0, connection], [], [])
        if 0 in readable:
            data = os.read(0, 65536)
            if not data:
                break
            connection.sendall(data)
        if connection in readable:
            data = connection.recv(65536)
            if not data:
                break
            os.write(1, data)
EOT
chmod +x "$SD/dial"
forge_key="$(cut -d' ' -f1,2 "$SD/host.pub")"
ssh_plain() { env -i HOME="$CH" PATH="$PATH" ssh -F "$CH/.ssh/config" -o ProxyCommand="$SD/dial" -o BatchMode=yes -o ConnectTimeout=10 -T "git@$1" 2>&1; }
git_ssh() { # remote URL
  local cmd
  cmd=$(git config --file "$CH/.config/git/identity/gh_work.gitconfig" core.sshCommand) || fail "$CT: rendered core.sshCommand"
  env -i HOME="$CH" XDG_CONFIG_HOME="$CH/.config" GIT_CONFIG_NOSYSTEM=1 PATH="$PATH" \
    git -c core.sshCommand="$cmd -o ProxyCommand=$SD/dial -o BatchMode=yes -o ConnectTimeout=10" ls-remote "$1" 2>&1
}
expect_refused() { # description, output
  printf '\n--- %s\n%s\n' "$1" "$2"
  case "$2" in *"Host key verification failed"*) ;; *) fail "$1: expected a refusal, got: $2" ;; esac
}
expect_accepted() {
  printf '\n--- %s\n%s\n' "$1" "$2"
  case "$2" in *"Permission denied"*) ;; *) fail "$1: expected the host key to be accepted and authentication to fail, got: $2" ;; esac
  case "$2" in *"Host key verification failed"* | *REVOKED*) fail "$1: host key accepted without a refusal, got: $2" ;; esac
}
for target in "plain ssh:ssh_plain github.com" "plain ssh:ssh_plain ssh.bitbucket.org" "plain ssh:ssh_plain bitbucket.org" "plain ssh via the alias:ssh_plain github.com-work" \
  "plain ssh via the Bitbucket alias:ssh_plain bitbucket.org-work" \
  "git:git_ssh git@github.com:work-org/x.git" "git via the alias:git_ssh git@github.com-work:work-org/x.git" "git on Bitbucket:git_ssh git@ssh.bitbucket.org:work-space/x.git" "git on Bitbucket (older name):git_ssh git@bitbucket.org:work-space/x.git" \
  "git via the Bitbucket alias:git_ssh git@bitbucket.org-work:work-space/x.git"; do
  expect_refused "$CT: ${target%%:*} refuses a key the pins do not know (${target#*:})" "$(${target#*:})"
done
for host in github.com ssh.bitbucket.org bitbucket.org; do
  # The documented rotation override: append the new official key to ~/.ssh/known_hosts.
  rm -f "$CH/.ssh/known_hosts"
  printf '%s %s\n' "$host" "$forge_key" >>"$CH/.ssh/known_hosts"
  expect_accepted "$CT: plain ssh accepts a rotated $host key from ~/.ssh/known_hosts" "$(ssh_plain "$host")"
done
printf 'github.com %s\n' "$forge_key" >"$CH/.ssh/known_hosts"
expect_accepted "$CT: plain ssh via the alias accepts the override" "$(ssh_plain github.com-work)"
expect_accepted "$CT: git accepts the override" "$(git_ssh git@github.com:work-org/x.git)"
expect_accepted "$CT: git via the alias accepts the override" "$(git_ssh git@github.com-work:work-org/x.git)"
printf 'ssh.bitbucket.org %s\n' "$forge_key" >"$CH/.ssh/known_hosts"
expect_accepted "$CT: git accepts the override on Bitbucket" "$(git_ssh git@ssh.bitbucket.org:work-space/x.git)"
expect_accepted "$CT: git via the Bitbucket alias accepts the override" "$(git_ssh git@bitbucket.org-work:work-space/x.git)"
printf 'bitbucket.org %s\n' "$forge_key" >"$CH/.ssh/known_hosts"
expect_accepted "$CT: git accepts the override on Bitbucket's older name" "$(git_ssh git@bitbucket.org:work-space/x.git)"
# The override is per host: GitHub's entry does not vouch for Bitbucket and vice versa.
expect_refused "$CT: the Bitbucket override does not cover GitHub" "$(ssh_plain github.com)"
# A @revoked key is never accepted, even when known_hosts also lists it normally.
cp "$pinned" "$TMP_ROOT/pinned.orig"
printf '@revoked github.com %s\n' "$forge_key" >>"$pinned"
printf 'github.com %s\n' "$forge_key" >"$CH/.ssh/known_hosts"
for out in "$(ssh_plain github.com)" "$(git_ssh git@github.com:work-org/x.git)"; do
  case "$out" in *REVOKED*) ;; *) fail "$CT: a @revoked key is reported as revoked, got: $out" ;; esac
  expect_refused "$CT: a @revoked key is refused despite a known_hosts entry" "$out"
done
cp "$TMP_ROOT/pinned.orig" "$pinned"
rm -f "$CH/.ssh/known_hosts"
kill "$SSHD_PID" 2>/dev/null
pass "$CT: an unknown forge key is refused, ~/.ssh/known_hosts overrides it for plain ssh and git, @revoked stays refused"

# The activation step: a missing ~/.ssh (the image without its own ssh files) and
# a loose one both end at 700, config.d included.
step=$(nix eval --raw "$ROOT#homeConfigurations.\"$CT\".config.home.activation.sshDirs.data") \
  || fail "$CT: ssh directory activation evaluates"
run() { "$@"; }
for start in missing loose; do
  AH="$TMP_ROOT/ahome-$start"
  mkdir -p "$AH"
  [ "$start" = missing ] || { mkdir -p "$AH/.ssh/config.d" && chmod 755 "$AH/.ssh" "$AH/.ssh/config.d"; }
  (HOME="$AH" eval "$step") || fail "$CT: ssh directory activation ran ($start)"
  [ "$(stat -c %a "$AH/.ssh" "$AH/.ssh/config.d" | tr '\n' ' ')" = '700 700 ' ] || fail "$CT: ~/.ssh and ~/.ssh/config.d are 700 from a $start start"
done
pass "$CT: activation leaves ~/.ssh and ~/.ssh/config.d at mode 700"

DARWIN="$ROOT#darwinConfigurations.mac.config.home-manager.users.dev"
unchanged=$(nix eval --json "$DARWIN" --apply 'c:
  !c.programs.git.enable
  && !(builtins.hasAttr "useConfigOnly" (c.programs.git.settings.user or {}))
  && c.programs.git.includes == []
  && !(builtins.hasAttr ".config/git/config" c.home.file)
  && c.programs.ssh.includes == []
  && !(builtins.hasAttr "identity" c.home.activation)
') || fail "macOS identity scope evaluates"
[ "$unchanged" = true ] || fail "macOS has no Linux identity configuration"
nix eval --raw "$DARWIN.home.file.\".ssh/config\".text" >"$H/mac_ssh_config" || fail "macOS SSH configuration evaluates"
for alias in github.com-personal github.com-work bitbucket.org-work; do
  case "$alias" in
    github.com-personal) host=github.com; key=id_ed25519_gh_personal ;;
    github.com-work) host=github.com; key=id_ed25519_gh_work ;;
    bitbucket.org-work) host=ssh.bitbucket.org; key=id_ed25519_bb_work ;;
  esac
  printf 'Host %s\n  HostName %s\n  User git\n  IdentityFile ~/.ssh/%s\n  IdentitiesOnly yes\n' "$alias" "$host" "$key" >"$H/mac_reference"
  reference=$(ssh -G -F "$H/mac_reference" "$alias" 2>/dev/null) || fail "$alias reference resolves"
  resolved=$(ssh -G -F "$H/mac_ssh_config" "$alias" 2>/dev/null) || fail "$alias macOS configuration resolves"
  for field in hostname user identityfile identitiesonly; do
    [ "$(ssh_value "$field")" = "$(ssh_value "$field" "$reference")" ] || fail "macOS $alias preserves $field"
  done
done
mkdir -p "$H/mac_home" "$H/mac_bin"
nix eval --raw "$DARWIN.programs.zsh.initContent" >"$H/mac_home/init.zsh" || fail "macOS zsh initialization evaluates"
cat >"$H/mac_bin/ssh-add" <<'SHIM'
#!/bin/sh
printf '%s\n' "$@" >>"$SSH_ADD_LOG"
exit 1
SHIM
chmod +x "$H/mac_bin/ssh-add"
: >"$H/mac_ssh_add.log"
# shellcheck disable=SC2016 # expanded by the scratch zsh, not here
env -i HOME="$H/mac_home" ZDOTDIR="$H/mac_home" PATH="$H/mac_bin:$PATH" TERM=xterm SSH_ADD_LOG="$H/mac_ssh_add.log" \
  zsh -f -i -c 'source "$HOME/init.zsh"' </dev/null >"$H/mac_shell.out" 2>&1 || fail "macOS interactive initialization runs"
assert_not_contains "$(cat "$H/mac_shell.out")" 'identity.env' "macOS prints no missing-identity notice"
[ ! -s "$H/mac_ssh_add.log" ] || fail "macOS keeps main's agent behavior without Linux autoload"
pass "macOS retains legacy SSH aliases and unmanaged Git behavior"
