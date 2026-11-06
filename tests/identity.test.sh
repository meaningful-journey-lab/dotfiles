#!/usr/bin/env bash
# Behavior checks for activation/identity.sh end to end against scratch HOMEs,
# throwaway keys, a throwaway ssh-agent, and an ssh shim that logs instead of
# connecting. No network, no Nix.
#
# Coverage:
# 1. fresh workstation: guidance only, nothing rendered;
# 2. filled identity file, one key missing and one not loaded: exact
#    ssh-keygen / ssh-add guidance, only .pub files exported (never a private
#    key), the key list and applied revision written, rewrites only on change;
# 3. remote-URL routing: personal, work GitHub org, Bitbucket workspace
#    (including https with a user), legacy aliases, and an unmatched owner
#    that refuses to commit;
# 4. container render from a read-only identity directory, with and without
#    the mount and the agent;
# 5. GIT_CONFIG_GLOBAL and a ~/.gitconfig with identity keys are flagged, and
#    check exits 1 on problems while render exits 0;
# 6. the identity file is parsed, never sourced, and bad values are rejected;
# 7. stale outputs are removed.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in git ssh ssh-agent ssh-add ssh-keygen; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
dotfiles_test_tmproot identity
S=$ROOT/activation/identity.sh
WS="$TMP_ROOT/ws space's\$home" CT=$TMP_ROOT/ct BIN=$TMP_ROOT/bin
mkdir -p "$WS/.dotfiles" "$CT" "$BIN"
# The pinned host keys home.nix links into a container, which the container
# check expects; a copy from the repo stands in for the Home Manager link.
pin_host_keys() { mkdir -p "$1/.ssh" && chmod 700 "$1/.ssh" && cp "$ROOT/ssh/pinned_known_hosts" "$1/.ssh/pinned_known_hosts"; }
pin_host_keys "$CT"
ln -s "$ROOT/identity.env.example" "$WS/.dotfiles/identity.env.example"
cat >"$BIN/ssh" <<'SHIM'
#!/bin/sh
printf '%s\n' "$@" >"$SSH_LOG"
exit 128
SHIM
chmod +x "$BIN/ssh"
export SSH_LOG=$TMP_ROOT/ssh.log
AGENT_PID=
cleanup() {
  [ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null
  chmod -R u+w "$TMP_ROOT" 2>/dev/null
  dotfiles_test_cleanup
}
trap cleanup EXIT

SOCK=
# run HOME PROFILE MODE [VAR=value...]: prints the script's stdout+stderr and
# leaves its exit status in RC (call it as `run ... >file`, not in $(...),
# when RC matters).
RC=0
run() {
  local h=$1 p=$2 m=$3; shift 3
  env -i HOME="$h" PATH="$PATH" SSH_AUTH_SOCK="$SOCK" "$@" "$S" "$m" "$p" 2>&1
  RC=$?
}
OUT=$TMP_ROOT/out
runo() { run "$@" >"$OUT"; }

echo "== 1. fresh workstation, no identity file"
runo "$WS" workstation render DOTFILES_REV=abc123
out=$(cat "$OUT")
echo "$out"
assert_contains "$out" "install -D -m 600 ~/.dotfiles/identity.env.example ~/.config/dotfiles/identity.env" "guidance names the template copy"
assert_not_contains "$out" "ssh-keygen" "no key guidance before there is an identity file"
[ "$RC" = 0 ] || fail "render never fails the switch"
[ ! -e "$WS/.config/git/identities.gitconfig" ] && [ ! -e "$WS/.ssh" ] || fail "nothing rendered without an identity file"
runo "$WS" workstation check
[ "$RC" = 1 ] || fail "standalone check exits 1 on a problem"
pass "fresh workstation: guidance only, nothing rendered"

echo "== 2. identity file filled, one key missing, one not loaded"
mkdir -p "$WS/.config/dotfiles" "$WS/.ssh"
chmod 700 "$WS/.ssh"
cat >"$WS/.config/dotfiles/identity.env" <<'ENVFILE'
# a comment
IDENTITIES="gh_personal gh_work bb_work"
gh_personal_HOST=github.com
gh_personal_OWNERS="example-owner"
gh_personal_KEY=~/.ssh/id_ed25519_gh_personal
gh_personal_NAME="Test Personal"
gh_personal_EMAIL="personal@example.invalid"
gh_personal_ALIAS=github.com-personal
gh_work_HOST=github.com
gh_work_OWNERS="work-org"
gh_work_KEY=~/.ssh/id_ed25519_gh_work
gh_work_NAME="Test Work"
gh_work_EMAIL="gh-work@example.invalid"
bb_work_HOST=bitbucket.org
bb_work_OWNERS="iqx-test"
bb_work_KEY=~/.ssh/id_ed25519_bb_work
bb_work_NAME="Test BB"
bb_work_EMAIL="bb-work@example.invalid"
bb_work_ALIAS=bitbucket.org-work
ENVFILE
chmod 600 "$WS/.config/dotfiles/identity.env"
# Throwaway keys for two identities; gh_work's is deliberately missing.
for k in id_ed25519_gh_personal id_ed25519_bb_work; do
  ssh-keygen -q -t ed25519 -N '' -C "throwaway-$k" -f "$WS/.ssh/$k" >/dev/null
done
eval "$(ssh-agent -a "$TMP_ROOT/agent.sock")" >/dev/null
AGENT_PID=$SSH_AGENT_PID SOCK=$TMP_ROOT/agent.sock
SSH_AUTH_SOCK=$SOCK ssh-add -q "$WS/.ssh/id_ed25519_gh_personal" 2>/dev/null
runo "$WS" workstation render DOTFILES_REV=abc123 XDG_CONFIG_HOME="$TMP_ROOT/alternate"
out=$(cat "$OUT")
echo "$out"
[ "$RC" = 0 ] || fail "render exits 0 with problems"
[ ! -e "$TMP_ROOT/alternate" ] || fail "identity paths stay under ~/.config"
assert_contains "$out" "ssh-keygen -t ed25519 -C 'gh-work@example.invalid' -f ~/.ssh/id_ed25519_gh_work" "missing key -> ssh-keygen guidance"
assert_contains "$out" "https://github.com/settings/ssh/new" "missing key -> where to register the public key"
assert_contains "$out" "bb_work: key not loaded in the agent: ssh-add ~/.ssh/id_ed25519_bb_work" "unloaded key -> ssh-add guidance"
assert_not_contains "$out" "gh_personal:" "loaded key raises nothing"
assert_contains "$out" "2 problem(s) above" "two problems counted"
assert_contains "$out" "check workstation" "names the standalone check"
D=$WS/.config/dotfiles
echo "--- rendered ~/.config/git/identities.gitconfig (head)"; head -8 "$WS/.config/git/identities.gitconfig"
echo "--- rendered identity/gh_personal.gitconfig"; cat "$WS/.config/git/identity/gh_personal.gitconfig"
echo "--- rendered ~/.ssh/config.d/identities"; cat "$WS/.ssh/config.d/identities"
ls -l "$D/pub"
! grep -rq PRIVATE "$D/pub" "$D/ssh-keys" "$D/applied-rev" "$WS/.config/git" "$WS/.ssh/config.d" || fail "a private key leaked into an output"
[ "$(ls "$D/pub")" = "$(printf 'bb_work.pub\ngh_personal.pub')" ] || fail "only the existing keys' public halves are exported"
for l in gh_personal bb_work; do
  cmp "$D/pub/$l.pub" "$WS/.ssh/id_ed25519_$l.pub" || fail "$l.pub is the public half"
done
[ "$(cat "$D/applied-rev")" = abc123 ] || fail "applied revision recorded"
[ "$(cat "$D/ssh-keys")" = "$(printf '%s\n' "$WS/.ssh/id_ed25519_gh_personal" "$WS/.ssh/id_ed25519_gh_work" "$WS/.ssh/id_ed25519_bb_work")" ] \
  || fail "key list for the zsh agent autoload"
resolved=$(ssh -G -F "$WS/.ssh/config.d/identities" github.com-personal 2>/dev/null) || fail "workstation alias resolves"
[ "$(awk '$1 == "hostname" {print $2}' <<<"$resolved")" = github.com ] || fail "workstation alias uses the real host"
[ "$(awk '$1 == "identityfile" {sub(/^[^ ]+ /, ""); print}' <<<"$resolved")" = "$WS/.ssh/id_ed25519_gh_personal" ] || fail "alias uses only the private key path"
[ "$(stat -c %a "$WS/.ssh/config.d/identities")" = 600 ] || fail "ssh include is mode 600"
# Rewritten only when the content changes.
stamp() { stat -c '%i %Y' "$WS/.config/git/identities.gitconfig" "$WS/.config/git/identity/"*.gitconfig "$WS/.ssh/config.d/identities" "$D/ssh-keys" "$D/applied-rev" "$D/pub/"*; }
before=$(stamp)
sleep 1
runo "$WS" workstation render DOTFILES_REV=abc123
[ "$before" = "$(stamp)" ] || fail "an unchanged render rewrites nothing"
pass "workstation render: rules, per-identity files, aliases, key list, revision, public halves only"

# Minimal Home Manager-like global config: the XDG file includes the rendered rules last.
gitcfg() { # home
  mkdir -p "$1/.config/git"
  printf '[user]\n\tuseConfigOnly = true\n[include]\n\tpath = ~/.config/git/identities.gitconfig\n' >"$1/.config/git/config"
}
gitrun() { # home args...
  local h=$1; shift
  env -i HOME="$h" XDG_CONFIG_HOME="$h/.config" GIT_CONFIG_NOSYSTEM=1 PATH="$BIN:$PATH" SSH_LOG="$SSH_LOG" git "$@"
}
# route HOME URL: sets EMAIL (what a commit in a repo with that remote uses)
# and SSH (the ssh command line git runs to reach it; empty for https).
route() {
  local h=$1 url=$2 d=$TMP_ROOT/probe.$RANDOM
  gitrun "$h" init -q "$d" && gitrun "$h" -C "$d" remote add origin "$url"
  EMAIL=$(gitrun "$h" -C "$d" config user.email || echo NONE) SSH=
  case "$url" in
    https://*) ;;
    *) : >"$SSH_LOG"; gitrun "$h" clone -q "$url" "$d.clone" >/dev/null 2>&1; SSH=$(tr '\n' ' ' <"$SSH_LOG") ;;
  esac
  printf '%-52s email=%-26s %s\n' "$url" "$EMAIL" "${SSH%% -o SendEnv*}"
  rm -rf "$d" "$d.clone"
}
expect_route() { # home url email key-path-or-empty
  route "$1" "$2"
  [ "$EMAIL" = "$3" ] || fail "$2 -> email $3 (got $EMAIL)"
  if [ -n "$4" ]; then
    [ "$(awk '$0 == "-i" {getline; print}' "$SSH_LOG")" = "$4" ] || fail "$2 -> ssh uses exactly one key argument"
    [ "$(awk '$0 == "-o" {getline; if ($0 == "IdentitiesOnly=yes") print}' "$SSH_LOG")" = IdentitiesOnly=yes ] || fail "$2 -> ssh offers only the selected identity"
  fi
}
expect_alias() {
  local h=$1 label=$2 alias=$3 host=$4 key=$5 command resolved
  command=$(git config --file "$h/.config/git/identity/$label.gitconfig" core.sshCommand) || fail "SSH command is readable"
  resolved=$(sh -c "$command -G \"\$1\"" -- "$alias" 2>/dev/null) || fail "$alias: configured SSH command resolves"
  [ "$(awk '$1 == "hostname" {print $2}' <<<"$resolved")" = "$host" ] || fail "$alias: resolves to $host"
  [ "$(awk '$1 == "user" {print $2}' <<<"$resolved")" = git ] || fail "$alias: connects as git"
  [ "$(awk '$1 == "identitiesonly" {print $2}' <<<"$resolved")" = yes ] || fail "$alias: offers only its identity"
  [ "$(awk '$1 == "identityfile" {sub(/^[^ ]+ /, ""); print}' <<<"$resolved" | sort -u)" = "$key" ] || fail "$alias: uses only $key, got: $resolved"
}
echo "== 3. workstation routing (git $(git --version | awk '{print $3}'))"
gitcfg "$WS"
K=$WS/.ssh
expect_route "$WS" git@github.com:example-owner/x.git personal@example.invalid "$K/id_ed25519_gh_personal"
expect_route "$WS" ssh://git@github.com/example-owner/x.git personal@example.invalid "$K/id_ed25519_gh_personal"
expect_route "$WS" https://github.com/example-owner/x.git personal@example.invalid ""
expect_route "$WS" git@github.com-personal:example-owner/x.git personal@example.invalid "$K/id_ed25519_gh_personal"
expect_route "$WS" git@github.com:work-org/y.git gh-work@example.invalid "$K/id_ed25519_gh_work"
expect_route "$WS" https://someone@github.com/work-org/y.git gh-work@example.invalid ""
expect_route "$WS" git@bitbucket.org:iqx-test/z.git bb-work@example.invalid "$K/id_ed25519_bb_work"
expect_route "$WS" https://someone@bitbucket.org/iqx-test/z.git bb-work@example.invalid ""
expect_route "$WS" git@bitbucket.org-work:iqx-test/z.git bb-work@example.invalid "$K/id_ed25519_bb_work"
# An unmatched owner gets no identity, and useConfigOnly refuses the commit.
route "$WS" git@github.com:stranger/w.git
[ "$EMAIL" = NONE ] || fail "an unmatched owner gets no identity"
d=$TMP_ROOT/stranger
gitrun "$WS" init -q "$d" && gitrun "$WS" -C "$d" remote add origin git@github.com:stranger/w.git
if out=$(gitrun "$WS" -C "$d" commit -q --allow-empty -m x 2>&1); then fail "an unmatched owner must refuse the commit"; fi
assert_contains "$out" "Author identity unknown" "git refuses with no identity to guess"
# The same owner name on another host does not match.
expect_route "$WS" git@gitlab.com:work-org/y.git NONE ""
pass "routing: personal, work org, Bitbucket workspace, legacy alias; unmatched owner refuses commit"

echo "== 4. container: identity dir mounted read-only, no ~/.ssh mount"
mkdir -p "$CT/.config"
ln -s "$WS/.config/dotfiles" "$CT/.config/dotfiles"
chmod -R a-w "$WS/.config/dotfiles"
mounted_before=$(find "$D" -printf '%P %m %s %T@\n' | sort)
runo "$CT" container render
out=$(cat "$OUT")
echo "$out"
[ "$RC" = 0 ] || fail "container render exits 0"
assert_contains "$out" "gh_work: the workstation exported no public key" "container names the missing key"
assert_not_contains "$out" "cannot write" "a read-only identity directory is never written"
assert_not_contains "$out" "gh_personal:" "container: the forwarded agent holds gh_personal"
[ "$mounted_before" = "$(find "$D" -printf '%P %m %s %T@\n' | sort)" ] || fail "container leaves the mounted identity directory unchanged"
gitcfg "$CT"
expect_route "$CT" git@github.com:example-owner/x.git personal@example.invalid "$CT/.config/dotfiles/pub/gh_personal.pub"
expect_route "$CT" git@bitbucket.org:iqx-test/z.git bb-work@example.invalid "$CT/.config/dotfiles/pub/bb_work.pub"
for url in git@github.com-personal:example-owner/x.git ssh://git@github.com-personal/example-owner/x.git; do
  expect_route "$CT" "$url" personal@example.invalid "$CT/.config/dotfiles/pub/gh_personal.pub"
done
for url in git@bitbucket.org-work:iqx-test/z.git ssh://git@bitbucket.org-work/iqx-test/z.git; do
  expect_route "$CT" "$url" bb-work@example.invalid "$CT/.config/dotfiles/pub/bb_work.pub"
done
expect_alias "$CT" gh_personal github.com-personal github.com "$CT/.config/dotfiles/pub/gh_personal.pub"
expect_alias "$CT" bb_work bitbucket.org-work bitbucket.org "$CT/.config/dotfiles/pub/bb_work.pub"
chmod -R u+w "$WS/.config/dotfiles"
rm "$CT/.config/dotfiles"
runo "$CT" container check
out=$(cat "$OUT")
assert_contains "$out" "identity directory is not mounted here" "container says plainly the identity file is not mounted"
assert_contains "$out" "install -D -m 600 ~/.dotfiles/identity.env.example" "container points at the workstation setup"
ln -s "$WS/.config/dotfiles" "$CT/.config/dotfiles"
SOCK_KEEP=$SOCK SOCK=$TMP_ROOT/dead.sock
runo "$CT" container check
SOCK=$SOCK_KEEP
out=$(cat "$OUT")
assert_contains "$out" "no ssh-agent at SSH_AUTH_SOCK=$TMP_ROOT/dead.sock" "container names a missing forwarded agent"
pass "container render: public halves only, from the read-only identity dir"

echo "== 4b. container: pinned GitHub and Bitbucket host keys are checked offline"
runo "$CT" container check
assert_not_contains "$(cat "$OUT")" "pinned" "seeded pinned keys raise nothing"
runo "$WS" workstation check
assert_not_contains "$(cat "$OUT")" "pinned" "the workstation has no pinned keys to check"
pinned=$CT/.ssh/pinned_known_hosts
cp "$pinned" "$TMP_ROOT/pinned.good"
rm "$pinned"
runo "$CT" container check
[ "$RC" = 1 ] || fail "container check fails without the pinned keys"
assert_contains "$(cat "$OUT")" "no pinned github.com host key in ~/.ssh/pinned_known_hosts" "a missing pinned file is named for GitHub"
assert_contains "$(cat "$OUT")" "no pinned bitbucket.org host key in ~/.ssh/pinned_known_hosts" "a missing pinned file is named for Bitbucket"
assert_contains "$(cat "$OUT")" "Run hm-update" "the check says how to restore the pins"
# A @revoked entry is not a pin: GitHub left with only its revoked key still fails.
grep -e '^@revoked github.com' -e '^bitbucket.org ' "$TMP_ROOT/pinned.good" >"$pinned"
runo "$CT" container check
[ "$RC" = 1 ] || fail "container check fails when GitHub has only a revoked key"
assert_contains "$(cat "$OUT")" "no pinned github.com host key" "a revoked-only GitHub entry is not a pin"
assert_not_contains "$(cat "$OUT")" "no pinned bitbucket.org" "the Bitbucket pins are found"
# ~/.ssh/known_hosts does not stand in for the pinned file.
grep '^github.com ' "$TMP_ROOT/pinned.good" >"$CT/.ssh/known_hosts"
runo "$CT" container check
assert_contains "$(cat "$OUT")" "no pinned github.com host key" "a user known_hosts entry is not a pin"
rm "$CT/.ssh/known_hosts"
cp "$TMP_ROOT/pinned.good" "$pinned"
runo "$CT" container check
assert_not_contains "$(cat "$OUT")" "pinned" "restored pinned keys raise nothing again"
pass "container check: pinned host keys present, offline, without needing identity.env"

echo "== 5. GIT_CONFIG_GLOBAL and ~/.gitconfig mask the identities"
runo "$CT" container check GIT_CONFIG_GLOBAL=/home/node/.gitconfig-container
out=$(cat "$OUT")
assert_contains "$out" "GIT_CONFIG_GLOBAL=/home/node/.gitconfig-container" "warns about GIT_CONFIG_GLOBAL"
[ "$RC" = 1 ] || fail "check exits 1 on problems"
printf '[user]\n\temail = old@example.invalid\n' >"$WS/.gitconfig"
runo "$WS" workstation check GIT_CONFIG_GLOBAL=
out=$(cat "$OUT")
[ "$RC" = 1 ] || fail "empty-but-set GIT_CONFIG_GLOBAL fails check"
assert_contains "$out" 'GIT_CONFIG_GLOBAL= hides' "warns about empty-but-set GIT_CONFIG_GLOBAL"
# shellcheck disable=SC2088 # diagnostic contains a literal tilde
assert_contains "$out" "~/.gitconfig sets user/includeIf/url/core.sshCommand keys" "also warns about an overriding ~/.gitconfig"
rm "$WS/.gitconfig"
chmod 666 "$D/identity.env"
for profile in workstation container; do
  if [ "$profile" = workstation ]; then h=$WS; else h=$CT; fi
  runo "$h" "$profile" check
  [ "$RC" = 1 ] || fail "$profile rejects writable identity.env"
  assert_contains "$(cat "$OUT")" 'must not be group/world-writable: chmod 600 ~/.config/dotfiles/identity.env' "$profile prints mode repair guidance"
done
chmod 600 "$D/identity.env"
STAT=$(command -v stat)
cat >"$BIN/stat" <<SHIM
#!/bin/sh
if [ "\$1" = -L ] && [ "\$2" = -c ] && [ "\$3" = %u ]; then
  echo 999999
else
  exec "$STAT" "\$@"
fi
SHIM
chmod +x "$BIN/stat"
runo "$WS" workstation check PATH="$BIN:$PATH"
assert_contains "$(cat "$OUT")" "must be owned by you: chown $(id -un) ~/.config/dotfiles/identity.env" "wrong ownership has chown guidance"
runo "$CT" container check PATH="$BIN:$PATH"
assert_not_contains "$(cat "$OUT")" 'must be owned by you' "container skips only the host UID check"
rm "$BIN/stat"
pass "check flags global config, mode and ownership problems"

echo "== 6. strict parsing: never sourced, bad values rejected"
BAD=$TMP_ROOT/bad
mkdir -p "$BAD/.config/dotfiles"
cat >"$BAD/.config/dotfiles/identity.env" <<ENVFILE
IDENTITIES="evil ok"
evil_HOST=github.com
evil_OWNERS="x"
evil_KEY="~/.ssh/k; touch $TMP_ROOT/pwned"
evil_NAME="Ev\\il"
evil_EMAIL="e@example.invalid"
ok_HOST=github.com
ok_OWNERS="fine"
ok_KEY=~/.ssh/ok
ok_NAME="\$(touch $TMP_ROOT/pwned)"
ok_EMAIL="ok@example.invalid"
ENVFILE
chmod 600 "$BAD/.config/dotfiles/identity.env"
runo "$BAD" workstation render
out=$(cat "$OUT")
echo "$out"
[ ! -e "$TMP_ROOT/pwned" ] || fail "the identity file was executed"
assert_contains "$out" "evil_KEY has an invalid value" "shell metacharacters in _KEY rejected"
assert_contains "$out" "evil_NAME has an invalid value" "backslash in _NAME rejected"
[ ! -e "$BAD/.config/git/identity/evil.gitconfig" ] || fail "an invalid identity renders nothing"
[ "$(git config --file "$BAD/.config/git/identity/ok.gitconfig" user.name)" = "\$(touch $TMP_ROOT/pwned)" ] || fail "command substitution stays literal text"
for key in ../.ssh/key '~relative/key'; do
  printf 'IDENTITIES=ok\nok_HOST=github.com\nok_OWNERS=fine\nok_KEY=%s\nok_NAME=Test\nok_EMAIL=t@example.invalid\n' "$key" >"$BAD/.config/dotfiles/identity.env"
  runo "$BAD" workstation render
  assert_contains "$(cat "$OUT")" 'ok_KEY must start with / or ~/' "relative key has clear validation guidance"
  [ ! -e "$BAD/.config/git/identity/ok.gitconfig" ] || fail "relative key renders no identity"
done
printf "IDENTITIES='ok'\n" >"$BAD/.config/dotfiles/identity.env"
runo "$BAD" workstation render
assert_contains "$(cat "$OUT")" "IDENTITIES label 'ok' has an invalid value" "single quotes are not stripped"
[ ! -e "$BAD/.config/git/identity/ok.gitconfig" ] || fail "single-quoted label renders no identity"
printf 'IDENTITIES="a"\nthis is not a setting\n' >"$BAD/.config/dotfiles/identity.env"
runo "$BAD" workstation check
out=$(cat "$OUT")
assert_contains "$out" "identity.env:2 is not a KEY=value line" "a non-KEY=value line is an error"
chmod 000 "$BAD/.config/dotfiles/identity.env"
if [ ! -r "$BAD/.config/dotfiles/identity.env" ]; then
  for profile in workstation container; do
    for mode in check render; do
      runo "$BAD" "$profile" "$mode"
      if [ "$mode" = check ]; then
        [ "$RC" = 1 ] || fail "unreadable identity fails check"
      else
        [ "$RC" = 0 ] || fail "unreadable identity does not fail activation"
      fi
      assert_contains "$(cat "$OUT")" 'cannot read ~/.config/dotfiles/identity.env: chmod u+r' "read failure is counted and has guidance"
      assert_not_contains "$(cat "$OUT")" 'identity: ok' "unreadable identity is never reported as ok"
    done
  done
fi
chmod 600 "$BAD/.config/dotfiles/identity.env"
pass "identity file parsed strictly"

echo "== 7. accepted values survive Git and shell consumers"
Q="$TMP_ROOT/quoted space's\$home"
mkdir -p "$Q/.config/dotfiles"
cat >"$Q/.config/dotfiles/identity.env" <<'ENVFILE'
IDENTITIES=quoted
quoted_HOST=github.com
quoted_OWNERS=quoted-owner
quoted_KEY=~/.ssh/quoted
quoted_NAME="  Alice #1; O'Neil  "
quoted_EMAIL="alice#tag$tag'o@example.invalid"
ENVFILE
chmod 600 "$Q/.config/dotfiles/identity.env"
runo "$Q" workstation render
out=$(cat "$OUT")
[ "$(git config --file "$Q/.config/git/identity/quoted.gitconfig" user.name)" = "  Alice #1; O'Neil  " ] || fail "Git preserves name punctuation and whitespace"
[ "$(git config --file "$Q/.config/git/identity/quoted.gitconfig" user.email)" = "alice#tag\$tag'o@example.invalid" ] || fail "Git preserves email punctuation"
printf '[user]\n\tuseConfigOnly = true\n[include]\n\tpath = ~/.config/git/identities.gitconfig\n' >"$Q/.config/git/config"
expect_route "$Q" git@github.com:quoted-owner/x.git "alice#tag\$tag'o@example.invalid" "$Q/.ssh/quoted"
KEYGEN=$(command -v ssh-keygen)
cat >"$BIN/ssh-keygen" <<'SHIM'
#!/bin/sh
printf '%s\n' "$@" >"$KEYGEN_LOG"
SHIM
chmod +x "$BIN/ssh-keygen"
command=$(printf '%s\n' "$out" | awk '/^identity:     ssh-keygen / {sub(/^identity:     /, ""); print}')
[ -n "$command" ] || fail "key-generation command is printed"
env -i HOME="$Q" PATH="$BIN:$PATH" KEYGEN_LOG="$TMP_ROOT/keygen.log" sh -c "$command" || fail "printed guidance executes"
[ "$(awk '$0 == "-C" {getline; print}' "$TMP_ROOT/keygen.log")" = "alice#tag\$tag'o@example.invalid" ] || fail "copied guidance preserves email literally"
[ "$(awk '$0 == "-f" {getline; print}' "$TMP_ROOT/keygen.log")" = "$Q/.ssh/quoted" ] || fail "copied guidance expands the key path"
rm "$BIN/ssh-keygen"
mkdir -p "$Q/.ssh"
"$KEYGEN" -q -t ed25519 -N '' -f "$Q/.ssh/quoted"
SSH_AUTH_SOCK=$SOCK ssh-add -q "$Q/.ssh/quoted" 2>/dev/null
runo "$Q" workstation render
runo "$Q" workstation check
[ "$RC" = 0 ] || fail "complete ordinary identity passes standalone check"
[ "$(cat "$OUT")" = 'identity: ok' ] || fail "successful check reports ok"
pass "Git and copied shell commands preserve accepted values"

echo "== 8. public halves with and without a final newline"
PC=$TMP_ROOT/public-container
mkdir -p "$PC/.config"
pin_host_keys "$PC"
ln -s "$Q/.config/dotfiles" "$PC/.config/dotfiles"
pub_content=$(cat "$Q/.ssh/quoted.pub")
pub_fp=$(ssh-keygen -lf "$Q/.ssh/quoted.pub" | awk '{print $2}')
printf '%s' "$pub_content" >"$Q/.ssh/quoted.pub"
[ "$(ssh-keygen -lf "$Q/.ssh/quoted.pub" | awk '{print $2}')" = "$pub_fp" ] || fail "newline-free public half is accepted by OpenSSH"
runo "$Q" workstation render
[ "$RC" = 0 ] || fail "newline-free export does not fail activation"
[ -f "$Q/.config/dotfiles/pub/quoted.pub" ] || fail "newline-free public half is exported"
[ "$(ssh-keygen -lf "$Q/.config/dotfiles/pub/quoted.pub" | awk '{print $2}')" = "$pub_fp" ] || fail "export preserves the public key"
runo "$PC" container render
[ "$RC" = 0 ] || fail "container renders newline-free key's export"
runo "$PC" container check
[ "$RC" = 0 ] || fail "container selects the loaded identity from the export"
gitcfg "$PC"
expect_route "$PC" git@github.com:quoted-owner/x.git "alice#tag\$tag'o@example.invalid" "$PC/.config/dotfiles/pub/quoted.pub"
for kind in empty invalid unreadable; do
  printf '%s\n' "$pub_content" >"$Q/.ssh/quoted.pub"
  case "$kind" in
    empty) : >"$Q/.ssh/quoted.pub" ;;
    invalid) printf 'PRIVATE not-a-public-key' >"$Q/.ssh/quoted.pub" ;;
    unreadable)
      chmod 000 "$Q/.ssh/quoted.pub"
      [ ! -r "$Q/.ssh/quoted.pub" ] || continue ;;
  esac
  runo "$Q" workstation render
  [ "$RC" = 0 ] || fail "$kind public half does not fail activation"
  [ ! -e "$Q/.config/dotfiles/pub/quoted.pub" ] || fail "$kind public half is not exported"
  runo "$PC" container check
  [ "$RC" = 1 ] || fail "container rejects a missing export for $kind public half"
  assert_contains "$(cat "$OUT")" 'workstation exported no public key' "container diagnoses $kind public half"
  chmod 644 "$Q/.ssh/quoted.pub"
done
chmod 644 "$Q/.ssh/quoted.pub"
printf '%s\n' "$pub_content" >"$Q/.ssh/quoted.pub"
runo "$Q" workstation render
pass "public key export accepts EOF and rejects unusable files"

echo "== 9. included Git overrides and inspection errors"
expect_config_problem() {
  local h=$1 profile=$2 message=$3 mode
  for mode in check render; do
    runo "$h" "$profile" "$mode"
    if [ "$mode" = check ]; then
      [ "$RC" = 1 ] || fail "$profile check rejects $message, got $RC: $(cat "$OUT")"
    else
      [ "$RC" = 0 ] || fail "$profile activation remains non-failing"
    fi
    assert_contains "$(cat "$OUT")" "$message" "$profile $mode reports the global config problem"
    assert_not_contains "$(cat "$OUT")" 'identity: ok' "config problems are never reported as ok"
  done
}
legacy_command='ssh -i ~/.ssh/old -o IdentitiesOnly=yes'
for profile in workstation container; do
  if [ "$profile" = workstation ]; then h=$Q; else h=$PC; fi
  git config --file "$h/.gitconfig" core.sshCommand "$legacy_command"
  [ "$(gitrun "$h" -C "$h" config core.sshCommand)" = "$legacy_command" ] || fail "Git consumes the direct legacy SSH command"
  # shellcheck disable=SC2088 # diagnostic contains a literal tilde
  expect_config_problem "$h" "$profile" '~/.gitconfig sets user/includeIf/url/core.sshCommand keys'
  rm "$h/.gitconfig"
  git config --file "$h/.gitconfig" include.path legacy-parent.gitconfig
  git config --file "$h/legacy-parent.gitconfig" include.path legacy-leaf.gitconfig
  for field in user.email 'includeIf.gitdir:~/legacy/.path' url.git@github.com:.pushInsteadOf core.sshCommand; do
    rm -f "$h/legacy-leaf.gitconfig"
    case "$field" in
      user.email)
        value=legacy@example.invalid
        git config --file "$h/legacy-leaf.gitconfig" user.name 'Legacy User' ;;
      includeIf.*) value=unused.gitconfig ;;
      url.*) value=https://github.com/ ;;
      core.sshCommand) value=$legacy_command ;;
    esac
    git config --file "$h/legacy-leaf.gitconfig" "$field" "$value"
    if [ "$field" = user.email ]; then
      [ "$(gitrun "$h" -C "$h" config user.email)" = legacy@example.invalid ] || fail "Git consumes the nested legacy identity"
    fi
    if [ "$field" = core.sshCommand ]; then
      [ "$(gitrun "$h" -C "$h" config core.sshCommand)" = "$legacy_command" ] || fail "Git consumes the nested legacy SSH command"
    fi
    # shellcheck disable=SC2088 # diagnostic contains a literal tilde
    expect_config_problem "$h" "$profile" '~/.gitconfig sets user/includeIf/url/core.sshCommand keys'
  done
  rm -f "$h/legacy-leaf.gitconfig"
  git config --file "$h/legacy-leaf.gitconfig" core.editor nvim
  runo "$h" "$profile" check
  [ "$RC" = 0 ] || fail "$profile accepts harmless nested includes"
  [ "$(cat "$OUT")" = 'identity: ok' ] || fail "$profile reports a harmless config as ok"
  for target in "$h/legacy-leaf.gitconfig" "$h/.gitconfig"; do
    cp "$target" "$target.saved"
    printf '[malformed\n' >"$target"
    expect_config_problem "$h" "$profile" 'cannot inspect ~/.gitconfig or its includes'
    assert_contains "$(cat "$OUT")" 'git config --includes --file ~/.gitconfig --list' "inspection failure prints the diagnostic command"
    mv "$target.saved" "$target"
    if [ "$target" = "$h/.gitconfig" ]; then
      chmod 000 "$target"
      if [ ! -r "$target" ]; then
        expect_config_problem "$h" "$profile" 'cannot inspect ~/.gitconfig or its includes'
      fi
      chmod 600 "$target"
    fi
  done
  rm -f "$h/.gitconfig" "$h/legacy-parent.gitconfig" "$h/legacy-leaf.gitconfig"
  runo "$h" "$profile" check
  [ "$RC" = 0 ] || fail "$profile ordinary check still succeeds"
done
pass "global config checks follow includes and distinguish inspection failures"

echo "== 10. symlink metadata follows consumed targets"
mv "$Q/.config/dotfiles/identity.env" "$Q/.config/dotfiles/identity.target"
ln -s identity.target "$Q/.config/dotfiles/identity.env"
mv "$Q/.ssh/quoted" "$Q/.ssh/quoted.target"
ln -s quoted.target "$Q/.ssh/quoted"
for key_mode in 400 600; do
  chmod "$key_mode" "$Q/.ssh/quoted.target"
  for mode in check render; do
    runo "$Q" workstation "$mode"
    [ "$RC" = 0 ] || fail "linked mode-$key_mode key and safe identity target are accepted"
    assert_not_contains "$(cat "$OUT")" 'must be' "safe targets have no ownership or mode warnings"
  done
done
chmod 644 "$Q/.ssh/quoted.target"
for mode in check render; do
  runo "$Q" workstation "$mode"
  if [ "$mode" = check ]; then
    [ "$RC" = 1 ] || fail "linked loose key fails check"
  else
    [ "$RC" = 0 ] || fail "linked loose key only warns during activation"
  fi
  assert_contains "$(cat "$OUT")" 'quoted: ~/.ssh/quoted must be mode 600: chmod 600 ~/.ssh/quoted' "key guidance describes the consumed target's mode"
done
chmod 600 "$Q/.ssh/quoted.target"
chmod 666 "$Q/.config/dotfiles/identity.target"
for profile in workstation container; do
  if [ "$profile" = workstation ]; then h=$Q; else h=$PC; fi
  for mode in check render; do
    runo "$h" "$profile" "$mode"
    if [ "$mode" = check ]; then
      [ "$RC" = 1 ] || fail "$profile rejects a writable identity target"
    else
      [ "$RC" = 0 ] || fail "$profile activation only warns about a writable target"
    fi
    assert_contains "$(cat "$OUT")" 'must not be group/world-writable: chmod 600 ~/.config/dotfiles/identity.env' "$profile checks the linked identity target"
  done
done
chmod 600 "$Q/.config/dotfiles/identity.target"
mv "$Q/.ssh/quoted.target" "$Q/.ssh/quoted.target.saved"
runo "$Q" workstation check
[ "$RC" = 1 ] || fail "dangling key link is missing"
assert_contains "$(cat "$OUT")" 'no private key at ~/.ssh/quoted' "dangling key gets missing-key guidance"
runo "$PC" container check
[ "$RC" = 0 ] || fail "container uses the exported public key, not the private target"
mv "$Q/.ssh/quoted.target.saved" "$Q/.ssh/quoted.target"
mv "$Q/.config/dotfiles/identity.target" "$Q/.config/dotfiles/identity.target.saved"
for profile in workstation container; do
  if [ "$profile" = workstation ]; then h=$Q; else h=$PC; fi
  runo "$h" "$profile" check
  [ "$RC" = 1 ] || fail "$profile rejects a dangling identity link"
  assert_contains "$(cat "$OUT")" 'no ~/.config/dotfiles/identity.env' "$profile diagnoses the missing identity target"
done
mv "$Q/.config/dotfiles/identity.target.saved" "$Q/.config/dotfiles/identity.target"
for profile in workstation container; do
  if [ "$profile" = workstation ]; then h=$Q; else h=$PC; fi
  runo "$h" "$profile" check
  [ "$RC" = 0 ] || fail "$profile succeeds again after targets are restored"
done
pass "symlink checks use target permissions and preserve container public-key selection"

echo "== 11. stale outputs removed"
sed -i 's/^IDENTITIES=.*/IDENTITIES="gh_personal"/' "$WS/.config/dotfiles/identity.env"
runo "$WS" workstation render
if [ -e "$WS/.config/git/identity/gh_work.gitconfig" ] || [ -e "$WS/.config/git/identity/bb_work.gitconfig" ] \
  || [ -e "$WS/.config/dotfiles/pub/bb_work.pub" ]; then fail "a removed identity leaves its files behind"; fi
[ -e "$WS/.config/git/identity/gh_personal.gitconfig" ] || fail "remaining identity kept"
expect_route "$WS" git@bitbucket.org:iqx-test/z.git NONE ""
expect_route "$WS" git@bitbucket.org-work:iqx-test/z.git NONE ""
resolved=$(ssh -G -F "$WS/.ssh/config.d/identities" bitbucket.org-work 2>/dev/null) || fail "SSH evaluates pruned aliases"
[ "$(awk '$1 == "hostname" {print $2}' <<<"$resolved")" = bitbucket.org-work ] || fail "removed alias no longer maps to Bitbucket"
[ "$(cat "$WS/.config/dotfiles/ssh-keys")" = "$WS/.ssh/id_ed25519_gh_personal" ] || fail "key list follows the identities"
rm "$WS/.config/dotfiles/identity.env"
runo "$WS" workstation render
if [ -e "$WS/.config/git/identities.gitconfig" ] || [ -e "$WS/.config/git/identity" ] || [ -e "$WS/.ssh/config.d/identities" ] \
  || [ -e "$WS/.config/dotfiles/pub" ] || [ -e "$WS/.config/dotfiles/ssh-keys" ]; then fail "stale files left"; fi
pass "no stale identities after an identity or the identity file goes"
