#!/usr/bin/env bash
# Behavior checks for the toolchain Home Manager installs at switch time on
# Linux, unpinned, in two scripts that home.nix's nodeTools and bashTools
# activations run in that order:
# - tools/node-tools.sh: on the WSL2 workstation nvm, Node.js LTS as nvm's
#   default, and pnpm (the container uses its image's), then the pnpm globals,
#   the npm globals (yo, mbt, mta, and the generators), @sap/cf-tools-local
#   on amd64, the AXI tools Firstmate uses (gh-axi, chrome-devtools-axi,
#   lavish-axi, tasks-axi, quota-axi) and their `setup hooks`, backpass and
#   acpx, the Paseo CLI
#   (@getpaseo/cli, always at the registry's latest), and the agent
#   skills;
# - tools/bash-tools.sh: herdr, Pi, the GitHub Copilot CLI, Claude Code,
#   Antigravity, and treehouse from their own installers.
#
# nvm, its install script, npm, npx, pnpm, yo, mbt, mta, cf, and the herdr, Pi,
# Copilot, Claude Code, and Antigravity install scripts are local fakes that
# log what they are asked to do, so nothing is downloaded, except by the one
# check that runs herdr's real installer. Like the real ones, the fake nvm.sh
# is not errexit/nounset clean, the fake pnpm refuses global commands while its
# global bin directory is off PATH and global installs without a
# pnpm-workspace.yaml in its global directory, the fake yo only lists
# generators under npm's global prefix, the fake herdr installer puts herdr in
# $HERDR_INSTALL_DIR, the fake Pi installer refuses to replace a pi it did not
# install (pnpm's, or a Windows one under /mnt) and links ~/.local/bin/pi to
# its launcher in ~/.pi/agent/bin, the fake Copilot and Claude Code installers
# put their launchers in ~/.local/bin (Copilot's in $PREFIX/bin), and the fake
# Antigravity installer takes --dir, then, like the real one, appends a PATH
# export to the rc files in its HOME.
#
# Coverage:
# - the ARC-1 policy isolation, completed-denial, timeout (including partial
#   denial), and prerequisite-failure cases in test_arc1_policy_check; see
#   README.md's "Upstream CLI tools" section for user-facing behavior;
# - workstation, fresh HOME: nvm from its install script with PROFILE=/dev/null
#   (no rc file touched), `nvm install --lts` as nvm's default, pnpm, then the
#   pnpm globals (with allowBuilds written first), the agent skills with
#   exactly the Dockerfile's arguments, the npm globals with
#   --allow-scripts=mbt,mta into nvm's prefix (found by yo, bins in
#   $NVM_DIR/default/bin), @sap/cf-tools-local on amd64, and one yo smoke
#   check; then bash-tools' six vendor installers (including treehouse), each
#   without a controlling terminal where needed; a re-run of both installs
#   nothing and prints nothing;
# - only what is missing is installed again (a missing pnpm or npm global, a
#   missing skill group), and mattpocock's resolving-merge-conflicts always
#   follows its repo's install, so the pinned copy wins;
# - container: the image's own Node.js and pnpm, npm globals in
#   ~/.npm-global (or $NPM_CONFIG_PREFIX), no nvm; without pnpm node-tools
#   reports the prerequisite failure and unproven policy while bash-tools
#   still installs everything;
# - the lavish skill: ~/.agents/skills/lavish and the Claude skills directory
#   ($CLAUDE_CONFIG_DIR/skills when set) link to lavish-axi's bundled skill in
#   the installed package; nothing is linked without the package, a dangling
#   link of ours is removed, and other entries named lavish are never replaced;
# - a failing pnpm, npm, or skills step is reported and fails the run but does
#   not stop the other steps; broken mbt, a generator yo does not list, and
#   a missing ServiceInfo cf plugin are warnings (the run still reports them
#   and installs everything);
# - a container that an older switch gave pnpm's Pi and Copilot, with a
#   Windows pi on PATH: Pi's installer runs without either on its PATH, and
#   each pnpm copy is removed right after its installer, so ~/.local/bin/pi
#   and ~/.local/bin/copilot are the only ones left; when Pi's installer
#   cannot be downloaded, pnpm's Pi stays;
# - a failing Pi installer shows its own output, fails the run, and keeps
#   pnpm's Pi;
# - a herdr, Claude Code, or Antigravity that does not answer --version after
#   its installer fails the run;
# - Antigravity's installer gets a scratch HOME and --dir ~/.local/bin: agy
#   lands in the real ~/.local/bin and no real rc file changes;
# - a gzip-encoded Antigravity installer download (which the vendor's server
#   sends intermittently) is decoded by curl --compressed and still installs agy;
# - herdr's real installer (https://herdr.dev/install.sh, skipped offline)
#   installs herdr's latest release as ~/.local/bin/herdr, which accepts
#   home/.config/herdr/config.toml; a re-run is a quiet no-op;
# - both profiles' nodeTools and bashTools activations run in that order after
#   writeBoundary, only warn on failure so the switch completes, and the
#   container activation keeps the user's PATH for the image's pnpm;
# - the workstation's interactive zsh puts nvm's node, npm, and pnpm first on
#   PATH; in both profiles every zsh (interactive or not) and a bash login
#   shell, fresh or started from an environment that already marks the
#   session variables sourced without PNPM_HOME or NVM_DIR, find ~/.local/bin
#   (herdr, claude, pi, copilot, agy) and pnpm's global bin right before
#   ~/.nix-profile/bin, once and ahead of a Nix-built herdr left there and of
#   system and Windows-interop copies, with no empty PATH entry, and
#   between them the workstation's nvm default Node.js bin
#   ($NVM_DIR/default/bin, which is also npm's global bin) or the container's
#   npm global bin (~/.npm-global/bin); the container never puts nvm on PATH;
#   the interactive zsh loads the installed herdr's completions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_tmproot node-tools
FAKE_NODE=v24.99.0
PI_INSTALL="pi-installer tty=no"
COPILOT_INSTALL="copilot-installer tty=no"
HERDR_INSTALL="herdr-installer"
CLAUDE_INSTALL="claude-installer"
TREEHOUSE_INSTALL="treehouse-installer"
AGY_INSTALL="antigravity-installer tty=no dir=%HOME%/.local/bin"
PI_REMOVE="pnpm remove -g @earendil-works/pi-coding-agent"
COPILOT_REMOVE="pnpm remove -g @github/copilot"
export NODE_TOOLS_LOG="$TMP_ROOT/calls.log"
REAL_NODE=$(command -v node)
export REAL_NODE NODE_TOOLS_TEST_PATH=$PATH
REAL_PNPM=$(command -v pnpm)
export REAL_PNPM
[ -n "$REAL_NODE" ] && [ -n "$REAL_PNPM" ] || fail "node and pnpm are required for configuration-consumer checks"
unset NVM_DIR NVM_BIN NVM_INC PNPM_HOME XDG_DATA_HOME XDG_STATE_HOME NPM_CONFIG_PREFIX CLAUDE_CONFIG_DIR

# --- fakes --------------------------------------------------------------------

FIX="$TMP_ROOT/fixtures"
mkdir -p "$FIX/image"
export NODE_TOOLS_POLICY_CHECK="$FIX/check-policy"
cat >"$NODE_TOOLS_POLICY_CHECK" <<'EOF'
#!/bin/sh
set -e
policy=$(PATH="$NODE_TOOLS_TEST_PATH" "$REAL_PNPM" --dir "$(dirname "$1")" config get allowBuilds --json)
"$REAL_NODE" - "$policy" <<'JS'
const assert = require('node:assert/strict');
const policy = JSON.parse(process.argv[2]);
for (const [key, value] of Object.entries({ 'better-sqlite3': true, esbuild: true, edgedriver: false, geckodriver: false })) {
  assert.equal(policy[key], value);
}
JS
EOF
chmod +x "$NODE_TOOLS_POLICY_CHECK"

# A stand-in for nvm's install script: installs the fake nvm.sh into $NVM_DIR
# (as the real one does, it needs the directory to exist) and records PROFILE.
cat >"$FIX/install.sh" <<EOF
set -e
printf 'nvm-installer PROFILE=%s\n' "\${PROFILE-unset}" >>"\$NODE_TOOLS_LOG"
[ -d "\$NVM_DIR" ]
cp "$FIX/nvm.sh" "\$NVM_DIR/nvm.sh"
EOF

cat >"$FIX/nvm.sh" <<EOF
# Fake nvm: Node.js $FAKE_NODE is the only LTS.
nvm() {
  local bin="\$NVM_DIR/versions/node/$FAKE_NODE/bin"
  case "\$1 \${2-}" in
    "version default")
      if [ -f "\$NVM_DIR/alias/default" ] && [ -x "\$bin/node" ]; then
        echo $FAKE_NODE
      else
        echo N/A
        return 3
      fi
      ;;
    "install --lts")
      echo "nvm \$*" >>"\$NODE_TOOLS_LOG"
      mkdir -p "\$bin"
      cp "$FIX/npm" "\$bin/npm"
      cp "$FIX/npx" "\$bin/npx"
      printf '#!/bin/sh\nif [ "\$1" = --version ]; then echo $FAKE_NODE; else exec "%s" "\$@"; fi\n' "\$REAL_NODE" >"\$bin/node"
      chmod +x "\$bin/npm" "\$bin/npx" "\$bin/node"
      ;;
    "alias default")
      echo "nvm alias default \$3" >>"\$NODE_TOOLS_LOG"
      mkdir -p "\$NVM_DIR/alias"
      echo "\$3" >"\$NVM_DIR/alias/default"
      ;;
    "use --silent")
      [ -x "\$bin/node" ] || return 3
      PATH="\$bin:\$PATH"
      export PATH
      ;;
    *)
      echo "fake nvm: unexpected: \$*" >&2
      return 1
      ;;
  esac
}
# Like the real nvm.sh: unset variables and failing commands are fine here.
[ -n "\$NVM_FAKE_UNSET" ] || false
if [ "\${1-}" != --no-use ] && [ -f "\$NVM_DIR/alias/default" ]; then
  nvm use --silent default
fi
EOF

# A fake npm: its global prefix is $NPM_CONFIG_PREFIX, else the directory above
# its own bin (nvm's layout). `npm install -g pnpm` installs the fake pnpm;
# the other global installs put each package under lib/node_modules, with a
# bin for mbt, mta, and yo. NPM_FAKE_FAIL makes those fail.
cat >"$FIX/npm" <<EOF
#!/bin/sh
prefix=\${NPM_CONFIG_PREFIX:-\$(cd "\$(dirname "\$0")/.." && pwd)}
case "\$1 \$2" in
  "prefix -g") [ -z "\${NPM_FAKE_PREFIX_FAIL-}" ] || exit 1; echo "\$prefix" ;;
  "root -g") echo "\$prefix/lib/node_modules" ;;
  "view @getpaseo/cli") [ -z "\${NPM_FAKE_VIEW_FAIL-}" ] || exit 1; echo "\${NPM_FAKE_PASEO_VERSION:-9.9.9}" ;;
  "install -g")
    echo "npm \$*" >>"\$NODE_TOOLS_LOG"
    shift 2
    for pkg; do
      case "\$pkg" in
        --*) continue ;;
        pnpm) mkdir -p "\$prefix/bin"; cp "$FIX/pnpm" "\$prefix/bin/pnpm"; continue ;;
      esac
      [ -z "\${NPM_FAKE_FAIL-}" ] || { echo "npm ERR! network" >&2; exit 1; }
      case "\$pkg" in
        @getpaseo/cli@latest)
          mkdir -p "\$prefix/lib/node_modules/@getpaseo/cli" "\$prefix/bin"
          echo '{}' >"\$prefix/lib/node_modules/@getpaseo/cli/package.json"
          # NPM_FAKE_PASEO_VERSION is what the registry's latest is.
          sed "s/@VERSION@/\${NPM_FAKE_PASEO_VERSION:-9.9.9}/" "$FIX/fake-axi" >"\$prefix/bin/paseo"
          chmod +x "\$prefix/bin/paseo"
          continue ;;
        gh-axi@latest | chrome-devtools-axi@latest | lavish-axi@latest | tasks-axi@latest | quota-axi@latest | backpass@latest | acpx@latest)
          pkg=\${pkg%@latest}
          mkdir -p "\$prefix/lib/node_modules/\$pkg" "\$prefix/bin"
          echo '{}' >"\$prefix/lib/node_modules/\$pkg/package.json"
          # lavish-axi bundles its skill, like the real package.
          if [ "\$pkg" = lavish-axi ]; then
            mkdir -p "\$prefix/lib/node_modules/lavish-axi/skills/lavish"
            echo "lavish skill \${NPM_FAKE_AXI_VERSION:-9.9.9}" >"\$prefix/lib/node_modules/lavish-axi/skills/lavish/SKILL.md"
          fi
          # NPM_FAKE_AXI_VERSION is what the registry's latest is.
          sed "s/@VERSION@/\${NPM_FAKE_AXI_VERSION:-9.9.9}/" "$FIX/fake-axi" >"\$prefix/bin/\$pkg"
          chmod +x "\$prefix/bin/\$pkg"
          continue ;;
      esac
      mkdir -p "\$prefix/lib/node_modules/\$pkg" "\$prefix/bin"
      echo '{}' >"\$prefix/lib/node_modules/\$pkg/package.json"
      case "\$pkg" in
        mbt | mta | yo) cp "$FIX/fake-\$pkg" "\$prefix/bin/\$pkg" ;;
      esac
    done
    ;;
  *) echo "fake npm: unexpected: \$*" >&2; exit 1 ;;
esac
EOF

# The fake mbt, mta, and yo; MBT_FAKE_BROKEN breaks mbt, and YO_FAKE_HIDE hides
# one generator namespace. yo lists the generators that are installed under its
# own npm prefix, like the real one.
cat >"$FIX/fake-mbt" <<'EOF'
#!/bin/sh
[ -z "${MBT_FAKE_BROKEN-}" ] || exit 1
echo "Cloud MTA Build Tool version 9.9.9"
EOF
cat >"$FIX/fake-mta" <<'EOF'
#!/bin/sh
echo "MTA version 9.9.9"
EOF
cat >"$FIX/fake-yo" <<'EOF'
#!/bin/sh
echo "yo $*" >>"$NODE_TOOLS_LOG"
root=$(dirname "$0")/../lib/node_modules
echo "Available Generators:"
for dir in "$root"/generator-* "$root"/@*/generator-*; do
  [ -d "$dir" ] || continue
  ns=$(printf '%s\n' "${dir#"$root"/}" | sed 's|generator-||')
  [ "$ns" = "${YO_FAKE_HIDE-}" ] || echo "  $ns"
done
EOF

# The fake AXI tools (gh-axi, chrome-devtools-axi, lavish-axi, tasks-axi,
# quota-axi) the fake npm installs: `--version` prints the baked-in version and
# `setup hooks` logs the call and writes what the real one writes: a codex
# hook, an OpenCode plugin, and, like axi-sdk-js, the Claude Code hook into
# ~/.claude/settings.json (through a link, as Home Manager's is), creating the
# file if it is missing, and only when its command is not already there.
# AXI_FAKE_CLAUDE_REWRITE makes it rewrite an existing Claude hook (what the
# real one does when it is not run from PATH) and AXI_FAKE_HOOKS_FAIL fails it.
cat >"$FIX/fake-axi" <<'EOF'
#!/bin/sh
name=$(basename "$0")
case "$*" in
  --version) echo "$name @VERSION@" ;;
  "setup hooks")
    echo "$name setup hooks" >>"$NODE_TOOLS_LOG"
    case "$name @VERSION@" in
      "chrome-devtools-axi 0.1.0" | "chrome-devtools-axi 0.1.22")
        echo "Unknown command: setup" >&2
        exit 1 ;;
    esac
    [ -z "${AXI_FAKE_HOOKS_FAIL-}" ] || { echo "error: cannot write hooks" >&2; exit 1; }
    mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.config/opencode/plugins"
    echo "$name" >>"$HOME/.codex/hooks.json"
    echo "$name" >"$HOME/.config/opencode/plugins/axi-$name.js"
    if [ -n "${AXI_FAKE_CLAUDE_REWRITE-}" ]; then
      echo "rewritten by $name" >>"$HOME/.claude/settings.json"
    elif ! grep -q "\"command\": \"$name\"" "$HOME/.claude/settings.json" 2>/dev/null; then
      echo "\"command\": \"$name\"" >>"$HOME/.claude/settings.json"
    fi
    echo "hooks:"; echo "  status: installed" ;;
  *) echo "fake $name: unexpected: $*" >&2; exit 1 ;;
esac
EOF

# A fake pnpm 11+: global bins go to $PNPM_HOME/bin, which must be on PATH, and
# global packages live under $PNPM_HOME/global/v11, which needs a
# pnpm-workspace.yaml with allowBuilds one level up before anything is added.
# PNPM_FAKE_FAIL makes `add` fail.
cat >"$FIX/pnpm" <<'EOF'
#!/bin/sh
bin="$PNPM_HOME/bin"
root="$PNPM_HOME/global/v11"
case ":$PATH:" in
  *":$bin:"*) ;;
  *) echo "ERR_PNPM_GLOBAL_BIN_DIR_NOT_IN_PATH: $bin" >&2; exit 1 ;;
esac
case "$1 $2" in
  "bin -g") echo "$bin" ;;
  "root -g") echo "$root" ;;
  "ls -g")
    echo "$root"
    for dir in "$root"/h/node_modules/* "$root"/h/node_modules/@*/*; do
      [ -f "$dir/package.json" ] && echo "$dir"
    done
    exit 0
    ;;
  "add -g" | "remove -g")
    echo "pnpm $*" >>"$NODE_TOOLS_LOG"
    command=$1
    shift 2
    if [ "$command" = add ]; then
      [ -z "${PNPM_FAKE_FAIL-}" ] || { echo "ERR_PNPM_FETCH_404" >&2; exit 1; }
      "$NODE_TOOLS_POLICY_CHECK" "$PNPM_HOME/global/pnpm-workspace.yaml" \
        || { echo "fake pnpm: incorrect allowBuilds in $PNPM_HOME/global/pnpm-workspace.yaml" >&2; exit 1; }
    fi
    for package; do
      case "$package" in -*) continue ;; esac
      package=${package%@latest}
      case "$package" in
        @earendil-works/pi-coding-agent) name=pi ;;
        @github/copilot) name=copilot ;;
        @ui5/mcp-server) name=ui5mcp ;;
        @sap-ux/fiori-mcp-server) name=fiori-mcp ;;
        @playwright/mcp) name=playwright-mcp ;;
        sap-note-search-mcp) name=sap-note-search-mcp ;;
        *) name= ;;
      esac
      if [ "$command" = remove ]; then
        [ -z "$name" ] || rm -f "$bin/$name"
        rm -rf "$root/h/node_modules/$package"
      else
        mkdir -p "$root/h/node_modules/$package"
        echo '{}' >"$root/h/node_modules/$package/package.json"
        [ -z "$name" ] || { mkdir -p "$bin"; printf '#!/bin/sh\n[ "$1" = --version ] && echo "%s 9.9.9" || echo pnpm-%s-fake\n' "$name" "$name" >"$bin/$name"; chmod +x "$bin/$name"; }
      fi
    done
    ;;
  *) echo "fake pnpm: unexpected: $*" >&2; exit 1 ;;
esac
EOF

# A fake npx that only knows `npx --yes skills add SOURCE [--skill NAME]`. Like
# the real CLI it needs --agent universal, --yes, and --global, and writes
# skills to ~/.agents/skills. NPX_FAKE_FAIL makes it fail.
cat >"$FIX/npx" <<'EOF'
#!/bin/sh
echo "npx $*" >>"$NODE_TOOLS_LOG"
[ -z "${NPX_FAKE_FAIL-}" ] || { echo "npm ERR! network" >&2; exit 1; }
[ "$1 $2 $3" = "--yes skills add" ] || { echo "fake npx: unexpected: $*" >&2; exit 1; }
shift 3
source=$1
shift
[ "$source" != "${NPX_FAKE_FAIL_SOURCE-}" ] || { echo "npm ERR! network" >&2; exit 1; }
skill= agent= yes= global=
while [ $# -gt 0 ]; do
  case "$1" in
    --skill) skill=$2; shift ;;
    --agent) agent=$2; shift ;;
    --yes) yes=1 ;;
    --global) global=1 ;;
    *) echo "fake skills: unexpected $1" >&2; exit 1 ;;
  esac
  shift
done
[ "$agent" = universal ] && [ -n "$yes" ] && [ -n "$global" ] \
  || { echo "fake skills: needs --agent universal --yes --global" >&2; exit 1; }
add() {
  mkdir -p "$HOME/.agents/skills/$1"
  echo "$2" >"$HOME/.agents/skills/$1/SKILL.md"
  [ "$2" != pinned ] || [ -z "${NPX_FAKE_SKIP_PIN_LOCK-}" ] || return 0
  node - "$1" "$source" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const file = process.env.XDG_STATE_HOME
  ? path.join(process.env.XDG_STATE_HOME, 'skills', '.skill-lock.json')
  : path.join(process.env.HOME, '.agents', '.skill-lock.json');
let lock = { version: 3, skills: {} };
try { lock = JSON.parse(fs.readFileSync(file, 'utf8')); } catch {}
if (!(lock.version >= 3) || !lock.skills) lock = { version: 3, skills: {} };
const [name, input] = process.argv.slice(2);
const pinned = input.startsWith('https://');
const source = pinned ? 'mattpocock/skills' : input;
lock.skills[name] = {
  source, sourceType: 'github', sourceUrl: `https://github.com/${source}.git`,
  ...(pinned ? { ref: input.split('/tree/')[1].split('/')[0] } : {}),
  skillPath: `skills/engineering/${name}/SKILL.md`, skillFolderHash: 'fake-folder-hash',
};
fs.mkdirSync(path.dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify(lock));
JS
}
case "$source" in
  arc-mcp/arc-1) add explain-abap-code arc ;;
  mattpocock/skills) add tdd matt; add resolving-merge-conflicts unpinned ;;
  vercel-labs/skills) [ "$skill" = find-skills ] || exit 1; add find-skills vercel ;;
  https://github.com/mattpocock/skills/tree/153fc1b93de6584562765cdce299324e1ff9e661/skills/engineering/resolving-merge-conflicts)
    add resolving-merge-conflicts pinned ;;
  https://github.com/kunchenguid/no-mistakes/tree/*/skills/no-mistakes)
    tag=${source#https://github.com/kunchenguid/no-mistakes/tree/}
    mkdir -p "$HOME/.agents/skills/no-mistakes"
    echo "no-mistakes ${tag%%/*}" >"$HOME/.agents/skills/no-mistakes/SKILL.md" ;;
  *) echo "fake skills: unexpected source $source" >&2; exit 1 ;;
esac
EOF

# A fake cf with the ServiceInfo plugin that @sap/cf-tools-local adds, unless
# CF_FAKE_NO_PLUGIN is set.
cat >"$FIX/cf" <<'EOF'
#!/bin/sh
[ -f "$(npm root -g)/@sap/cf-tools-local/package.json" ] && [ -z "${CF_FAKE_NO_PLUGIN-}" ] && echo "ServiceInfo    1.0.0"
exit 0
EOF
chmod +x "$FIX/npm" "$FIX/npx" "$FIX/pnpm" "$FIX/cf" "$FIX"/fake-*
# The devcontainer image's own Node.js tools, fakes of the nvm layout's.
cp "$FIX/pnpm" "$FIX/npm" "$FIX/npx" "$FIX/cf" "$FIX/image/"
ln -s "$REAL_NODE" "$FIX/image/node"

# A stand-in for Claude Code's install script: like the real one, it puts the
# launcher at ~/.local/bin/claude, pointing into the versions directory.
cat >"$FIX/claude-install.sh" <<'EOF'
set -e
echo claude-installer >>"$NODE_TOOLS_LOG"
versions="${XDG_DATA_HOME:-$HOME/.local/share}/claude/versions"
mkdir -p "$versions" "$HOME/.local/bin"
printf '#!/bin/sh\necho claude-fake\n' >"$versions/9.9.9"
chmod +x "$versions/9.9.9"
ln -sfn "$versions/9.9.9" "$HOME/.local/bin/claude"
EOF

# A stand-in for treehouse's install script (run with sh): like the real one, it
# installs into ~/.local/bin only when that is on its PATH (else it would use
# /usr/local/bin with sudo). The fake treehouse's `get --help` mentions --lease
# unless TREEHOUSE_FAKE_OLD is set when it is installed.
cat >"$FIX/treehouse-install.sh" <<'EOF'
set -e
echo treehouse-installer >>"$NODE_TOOLS_LOG"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "fake treehouse installer: would install into /usr/local/bin" >&2; exit 1 ;;
esac
[ -z "${TREEHOUSE_FAKE_FAIL:-}" ] || { echo "Failed to determine latest version"; exit 1; }
mkdir -p "$HOME/.local/bin"
if [ -n "${TREEHOUSE_FAKE_OLD:-}" ]; then
  version=2.0.0
  help="Acquire a worktree from the pool."
else
  version=3.1.4
  help="Pass --lease for a non-interactive, durable acquire."
fi
cat >"$HOME/.local/bin/treehouse" <<TREEHOUSE
#!/bin/sh
case "\$*" in
  --version) echo "treehouse version $version" ;;
  "get --help") echo "$help" ;;
  *) echo "fake treehouse: unexpected: \$*" >&2; exit 1 ;;
esac
TREEHOUSE
chmod +x "$HOME/.local/bin/treehouse"
EOF

# A stand-in for Pi's install script (run with sh): like the real one, it
# refuses a pi on PATH that is not its own managed install, keeps its launcher
# in ~/.pi/agent/bin, and links it from ~/.local/bin, the first of its
# preferred bin directories on PATH. It takes a /mnt/* PATH entry for WSL's
# Windows npm directory with its pi, which the tests cannot create. It records
# whether it could reach a terminal to prompt on.
cat >"$FIX/pi-install.sh" <<'EOF'
set -e
if ( : <>/dev/tty ) 2>/dev/null; then tty=yes; else tty=no; fi
echo "pi-installer tty=$tty" >>"$NODE_TOOLS_LOG"
[ -z "${PI_FAKE_FAIL:-}" ] || { echo "error: Pi requires Node.js 22.19.0 or newer."; exit 1; }
existing=$(command -v pi || true)
case ":$PATH:" in
  *:/mnt/*) existing=${existing:-$(printf '%s\n' "$PATH" | tr : '\n' | grep -m1 '^/mnt/')/pi} ;;
esac
if [ -n "$existing" ]; then
  echo "Managed install refused to replace Pi at $existing. Uninstall it first." >&2
  exit 1
fi
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "fake Pi installer: ~/.local/bin is not on PATH" >&2; exit 1 ;;
esac
mkdir -p "$HOME/.pi/agent/bin" "$HOME/.local/bin"
printf '#!/bin/sh\necho pi-fake\n' >"$HOME/.pi/agent/bin/pi"
chmod +x "$HOME/.pi/agent/bin/pi"
ln -s ../../.pi/agent/bin/pi "$HOME/.local/bin/pi"
echo "Pi was installed successfully."
EOF

# A stand-in for Copilot's install script (run with bash): like the real one,
# it installs the binary into $PREFIX/bin.
cat >"$FIX/copilot-install.sh" <<'EOF'
set -e
if ( : <>/dev/tty ) 2>/dev/null; then tty=yes; else tty=no; fi
echo "copilot-installer tty=$tty" >>"$NODE_TOOLS_LOG"
[ "$PREFIX" = "$HOME/.local" ] || { echo "fake Copilot installer: PREFIX=$PREFIX" >&2; exit 1; }
mkdir -p "$PREFIX/bin"
printf '#!/bin/sh\necho copilot-fake\n' >"$PREFIX/bin/copilot"
chmod +x "$PREFIX/bin/copilot"
EOF

# A stand-in for herdr's install script (run with sh): like the real one, it
# puts the binary at $HERDR_INSTALL_DIR/herdr (default ~/.local/bin). The fake
# herdr prints zsh completions that register _herdr.
cat >"$FIX/herdr-install.sh" <<'EOF'
set -e
dir=${HERDR_INSTALL_DIR:-$HOME/.local/bin}
[ "$dir" = "$HOME/.local/bin" ] || { echo "fake herdr installer: HERDR_INSTALL_DIR=$dir" >&2; exit 1; }
echo herdr-installer >>"$NODE_TOOLS_LOG"
mkdir -p "$dir"
cat >"$dir/herdr" <<'HERDR'
#!/bin/sh
case "$*" in
  "completion zsh") echo '_herdr() { :; }; compdef _herdr herdr' ;;
  *) echo herdr-fake ;;
esac
HERDR
chmod +x "$dir/herdr"
EOF

# A stand-in for Antigravity's install script (run with bash): like the real
# one, it takes --dir, puts agy at <dir>/agy, and ends by appending a PATH
# export to the rc files in its HOME, and it records its HOME and terminal.
cat >"$FIX/antigravity-install.sh" <<'EOF'
set -e
dir=$HOME/.local/bin
while [ $# -gt 0 ]; do
  case "$1" in
    -d | --dir) dir=$2; shift ;;
    *) echo "fake Antigravity installer: unexpected $1" >&2; exit 1 ;;
  esac
  shift
done
if ( : <>/dev/tty ) 2>/dev/null; then tty=yes; else tty=no; fi
echo "antigravity-installer tty=$tty dir=$dir" >>"$NODE_TOOLS_LOG"
echo "$HOME" >"$NODE_TOOLS_LOG.agy-home"
[ -z "${AGY_FAKE_FAIL:-}" ] || { echo "Fatal: Could not connect to the release server." >&2; exit 1; }
mkdir -p "$dir"
printf '#!/bin/sh\necho agy-fake\n' >"$dir/agy"
chmod +x "$dir/agy"
for rc in .zshrc .bashrc .profile; do
  printf '\n# Added by Antigravity CLI installer\nexport PATH="%s:$PATH"\n' "$dir" >>"$HOME/$rc"
done
EOF

# A fake arc1-cli. Its directory holds `mode` and
# the `calls` log. In deny mode it refuses SAPTransport release only when
# SAP_DENY_ACTIONS lists it, as arc-1 does.
mkdir -p "$FIX/arc1"
cat >"$FIX/arc1/arc1-cli" <<'EOF'
#!/bin/sh
here=$(dirname "$0")
env_file=no
[ ! -e .env ] || env_file=yes
empty=yes
[ -z "$(ls -A)" ] || empty=no
echo "$* cwd=$PWD env_file=$env_file url=${SAP_URL-unset} user=${SAP_USER-unset} password=${SAP_PASSWORD-unset} writes=${SAP_ALLOW_TRANSPORT_WRITES-unset} deny=${SAP_DENY_ACTIONS-unset} leak=${ARC1_TEST_LEAK-unset} empty=$empty all_writes=${SAP_ALLOW_WRITES-unset} packages=${SAP_ALLOWED_PACKAGES-unset}" >>"$here/calls"
[ "$1" = call ] || { echo "fake arc1-cli: unexpected: $*" >&2; exit 1; }
mode=$(cat "$here/mode")
case "$mode" in
  deny)
    case "${SAP_DENY_ACTIONS-}" in
      *SAPTransport.release*) echo "WARN: [safety_blocked] SAPTransport.release"; echo "Action 'SAPTransport.release' is denied by server policy (SAP_DENY_ACTIONS)."; exit 1 ;;
    esac
    echo "released POLICYCHECK" ;;
  allow) echo "released POLICYCHECK" ;;
  fail) echo "Unknown action 'SAPTransport.release' in SAP_DENY_ACTIONS" >&2; exit 1 ;;
  hang) exec sleep 30 ;;
  deny-hang | deny-kill)
    [ "$mode" != deny-kill ] || trap '' TERM
    echo "Action 'SAPTransport.release' is denied by server policy (SAP_DENY_ACTIONS)."
    exec sleep 30 ;;
esac
EOF
chmod +x "$FIX/arc1/arc1-cli"
echo deny >"$FIX/arc1/mode"
mkdir -p "$FIX/arc1-timeout" "$FIX/arc1-setup"
REAL_TIMEOUT=$(command -v timeout)
[ -n "$REAL_TIMEOUT" ] || fail "timeout is required for the arc-1 policy check"
cat >"$FIX/arc1-timeout/timeout" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$FIX/arc1-timeout/calls"
[ "\$1 \$2 \$3" = '-k 5 60' ] || exit 2
shift 3
exec "$REAL_TIMEOUT" -k 1 1 "\$@"
EOF
printf '#!/bin/sh\nexit 1\n' >"$FIX/arc1-setup/mktemp"
chmod +x "$FIX/arc1-timeout/timeout" "$FIX/arc1-setup/mktemp"

export NVM_INSTALL_URL="file://$FIX/install.sh"
export HERDR_INSTALL_URL="file://$FIX/herdr-install.sh"
export PI_INSTALL_URL="file://$FIX/pi-install.sh"
export COPILOT_INSTALL_URL="file://$FIX/copilot-install.sh"
export CLAUDE_INSTALL_URL="file://$FIX/claude-install.sh"
export ANTIGRAVITY_INSTALL_URL="file://$FIX/antigravity-install.sh"
export TREEHOUSE_INSTALL_URL="file://$FIX/treehouse-install.sh"
# Hooks go to scratch homes only; the Copilot CLI's hooks directory follows HOME.
unset COPILOT_HOME
mkdir -p "$FIX/common"
cp "$FIX/cf" "$FIX/common/cf"
# A fake no-mistakes CLI printing the real `--version` format; NO_MISTAKES_FAKE_VERSION
# sets the tag (an empty one prints no parseable version).
cat >"$FIX/common/no-mistakes" <<'EOF'
#!/bin/sh
[ "$1" = --version ] || { echo "fake no-mistakes: unexpected: $*" >&2; exit 1; }
echo "no-mistakes version ${NO_MISTAKES_FAKE_VERSION-v1.84.0} (4822244) 2026-09-26T08:30:42Z"
EOF
chmod +x "$FIX/common/no-mistakes"
BASE_PATH="$FIX/arc1:$FIX/common:/usr/bin:/bin"
WINDOWS_NPM="/mnt/c/Users/dev/AppData/Roaming/npm"

# Runs tools/node-tools.sh $2 against scratch HOME $1 with PATH $3.
run_tools() {
  HOME=$1 PATH=$3 bash "$ROOT/tools/node-tools.sh" "$2" 2>&1
}

# Runs tools/bash-tools.sh against scratch HOME $1 with PATH $2.
run_bash_tools() {
  HOME=$1 PATH=$2 bash "$ROOT/tools/bash-tools.sh" 2>&1
}

calls() {
  cat "$NODE_TOOLS_LOG" 2>/dev/null
}

agy_install_line() {
  echo "${AGY_INSTALL//%HOME%/$1}"
}

# What the scripts install, in order.
PNPM_ADD="pnpm add -g arc-1@latest npm-run-all eslint npm-check-updates @ui5/cli @sap/cds-dk @sap/cf-tools @sap/ux-ui5-tooling @sap/html5-app-deployer odata-openapi @wdio/cli @ui5/mcp-server @sap-ux/fiori-mcp-server @playwright/mcp sap-note-search-mcp"
NO_MISTAKES_SKILL_SOURCE=https://github.com/kunchenguid/no-mistakes/tree/v1.84.0/skills/no-mistakes
nm_skill_add() {
  echo "npx --yes skills add https://github.com/kunchenguid/no-mistakes/tree/$1/skills/no-mistakes --agent universal --yes --global"
}
SKILLS_ADD="npx --yes skills add arc-mcp/arc-1 --agent universal --yes --global
npx --yes skills add mattpocock/skills --agent universal --yes --global
npx --yes skills add vercel-labs/skills --skill find-skills --agent universal --yes --global
npx --yes skills add https://github.com/mattpocock/skills/tree/153fc1b93de6584562765cdce299324e1ff9e661/skills/engineering/resolving-merge-conflicts --agent universal --yes --global
npx --yes skills add https://github.com/kunchenguid/no-mistakes/tree/v1.84.0/skills/no-mistakes --agent universal --yes --global"
NPM_ADD="npm install -g --allow-scripts=mbt,mta mbt mta yo generator-easy-ui5 @sap-ux/generator-adp @sap/generator-adaptation-project @sap/generator-add-hdb-module @sap/generator-aicore @sap/generator-base-mta-module @sap/generator-cap-project @sap/generator-fiori"
CF_LOCAL_ADD="npm install -g --allow-scripts=@sap/cf-tools-local @sap/cf-tools-local"
YO_SMOKE="yo --generators --no-insight"
AXI_ADD="npm install -g gh-axi@latest chrome-devtools-axi@latest lavish-axi@latest tasks-axi@latest quota-axi@latest"
BACKPASS_ADD="npm install -g backpass@latest acpx@latest"
PASEO_ADD="npm install -g @getpaseo/cli@latest"
AXI_HOOKS="gh-axi setup hooks
chrome-devtools-axi setup hooks
lavish-axi setup hooks"
# What every node-tools.sh run does once everything is installed.
QUIET_RERUN="$AXI_HOOKS
$YO_SMOKE"
case "$(uname -m)" in
  x86_64 | amd64) AMD64=yes ;;
  *) AMD64= ;;
esac
# What node-tools.sh installs on top of Node.js and pnpm.
NODE_INSTALLS="$PNPM_ADD
$SKILLS_ADD
$NPM_ADD${AMD64:+
$CF_LOCAL_ADD}
$AXI_ADD
$BACKPASS_ADD
$PASEO_ADD
$QUIET_RERUN"
# What bash-tools.sh installs for HOME $1.
bash_installs() {
  printf '%s\n' "$HERDR_INSTALL" "$PI_INSTALL" "$COPILOT_INSTALL" "$CLAUDE_INSTALL" "$(agy_install_line "$1")" "$TREEHOUSE_INSTALL"
}
YO_NAMESPACES="easy-ui5 @sap-ux/adp @sap/adaptation-project @sap/add-hdb-module @sap/aicore @sap/base-mta-module @sap/cap-project @sap/fiori"

# --- tools/node-tools.sh and tools/bash-tools.sh ----------------------------------

test_workstation_fresh_then_quiet() {
  local home="$TMP_ROOT/ws" out nvm_prefix ns
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  out=$(run_tools "$home" workstation "$BASE_PATH") || fail "node-tools on a fresh workstation HOME failed: $out"
  [ "$(calls)" = "nvm-installer PROFILE=/dev/null
nvm install --lts --no-progress
nvm alias default lts/*
npm install -g pnpm
$NODE_INSTALLS" ] || fail "workstation did not install nvm, Node.js LTS as default, pnpm, the pnpm globals, the skills, the npm globals, and cf-tools-local, in order: $(calls)"
  [ "$("$home/.nvm/default/bin/node" --version)" = "$FAKE_NODE" ] || fail "\$NVM_DIR/default is not nvm's default Node.js"
  # The npm globals are in nvm's prefix, which $NVM_DIR/default/bin (on PATH) shows, and yo finds them there.
  nvm_prefix="$home/.nvm/versions/node/$FAKE_NODE"
  [ "$("$home/.nvm/default/bin/mbt" --version)" = "Cloud MTA Build Tool version 9.9.9" ] || fail "mbt is not in nvm's default Node.js bin"
  [ "$("$home/.nvm/default/bin/mta" --version)" = "MTA version 9.9.9" ] || fail "mta is not in nvm's default Node.js bin"
  for ns in $YO_NAMESPACES; do
    assert_contains "$("$home/.nvm/default/bin/yo" --generators)" "$ns" "yo does not list the $ns generator from nvm's prefix"
  done
  [ -d "$nvm_prefix/lib/node_modules/@sap/generator-fiori" ] || fail "the generators are not under npm's global prefix"
  [ ! -e "$home/.local/share/pnpm/global/v11/h/node_modules/yo" ] || fail "yo was installed with pnpm"
  "$NODE_TOOLS_POLICY_CHECK" "$home/.local/share/pnpm/global/pnpm-workspace.yaml" || fail "pnpm's global build policy is wrong"
  for tool in ui5mcp fiori-mcp playwright-mcp sap-note-search-mcp; do
    [ "$("$home/.local/share/pnpm/bin/$tool" --version)" = "$tool 9.9.9" ] || fail "workstation: the MCP server binary $tool does not run from pnpm's global bin"
  done
  [ "$(cat "$home/.agents/skills/resolving-merge-conflicts/SKILL.md")" = pinned ] || fail "resolving-merge-conflicts is not the pinned copy"
  [ -f "$home/.agents/skills/find-skills/SKILL.md" ] || fail "find-skills is missing"
  [ "$(cat "$home/.agents/skills/no-mistakes/SKILL.md")" = "no-mistakes v1.84.0" ] || fail "workstation: the no-mistakes skill of the installed CLI version is missing"

  : >"$NODE_TOOLS_LOG"
  out=$(run_bash_tools "$home" "$BASE_PATH") || fail "bash-tools on a fresh workstation HOME failed: $out"
  [ "$(calls)" = "$(bash_installs "$home")" ] || fail "bash-tools did not install herdr, Pi, Copilot, Claude Code, and Antigravity, in order: $(calls)"
  for tool in herdr pi copilot claude agy; do
    [ "$("$home/.local/bin/$tool" --version)" = "$tool-fake" ] || fail "$tool does not run from ~/.local/bin"
    [ ! -e "$home/.local/share/pnpm/bin/$tool" ] || fail "workstation installed $tool with pnpm"
  done
  for rc in .bashrc .bash_profile .profile .zshrc .zprofile; do
    [ ! -e "$home/$rc" ] || fail "an installer wrote $rc, which Home Manager owns"
  done

  : >"$NODE_TOOLS_LOG"
  out=$(run_tools "$home" workstation "$BASE_PATH") || fail "node-tools re-run failed: $out"
  out="$out$(run_bash_tools "$home" "$BASE_PATH")" || fail "bash-tools re-run failed: $out"
  [ "$(calls)" = "$QUIET_RERUN" ] || fail "a re-run reinstalled something or skipped the generator check: $(calls)"
  [ -z "$out" ] || fail "a re-run is not quiet: $out"
  pass "workstation: nvm (PROFILE=/dev/null), Node.js LTS as default, pnpm, the pnpm globals (allowBuilds first), the skills, the npm globals in nvm's prefix (yo lists every generator), cf-tools-local on amd64; then herdr, Pi, Copilot, Claude Code, and Antigravity; re-runs install and print nothing"
}

test_only_missing_is_installed() {
  local home="$TMP_ROOT/ws" out root status
  root="$home/.nvm/versions/node/$FAKE_NODE/lib/node_modules"
  rm -rf "$home/.local/share/pnpm/global/v11/h/node_modules/eslint" "$home/.local/share/pnpm/global/v11/h/node_modules/@ui5/cli" \
    "$root/mbt" "$root/@sap/generator-aicore" "$home/.agents/skills/find-skills"
  : >"$NODE_TOOLS_LOG"
  out=$(run_tools "$home" workstation "$BASE_PATH") || fail "node-tools after deleting some tools failed: $out"
  [ "$(calls)" = "pnpm add -g eslint @ui5/cli
npx --yes skills add vercel-labs/skills --skill find-skills --agent universal --yes --global
npm install -g --allow-scripts=mbt,mta mbt @sap/generator-aicore
$QUIET_RERUN" ] \
    || fail "node-tools did not install only the missing pnpm globals, skill, and npm globals: $(calls)"
  # mta and the other tools are untouched, and mta/yo from the first install still run.
  [ -f "$root/mbt/package.json" ] || fail "mbt was not reinstalled"

  # mattpocock/skills is always followed by the pinned resolving-merge-conflicts.
  rm -rf "$home/.agents/skills/tdd"
  : >"$NODE_TOOLS_LOG"
  out=$(run_tools "$home" workstation "$BASE_PATH") || fail "node-tools after deleting a mattpocock skill failed: $out"
  [ "$(calls)" = "npx --yes skills add mattpocock/skills --agent universal --yes --global
npx --yes skills add https://github.com/mattpocock/skills/tree/153fc1b93de6584562765cdce299324e1ff9e661/skills/engineering/resolving-merge-conflicts --agent universal --yes --global
$QUIET_RERUN" ] \
    || fail "mattpocock/skills was not followed by the pinned skill: $(calls)"
  [ "$(cat "$home/.agents/skills/resolving-merge-conflicts/SKILL.md")" = pinned ] || fail "the pinned copy lost to mattpocock/skills'"
  pass "a re-switch installs only the missing pnpm and npm globals and skills, and the pinned resolving-merge-conflicts always follows mattpocock/skills"

  # The no-mistakes skill follows the installed CLI's version: left alone while
  # the recorded version matches, restored when missing, and installed again
  # (also for a pre-release) when the CLI version changes.
  : >"$NODE_TOOLS_LOG"
  out=$(run_tools "$home" workstation "$BASE_PATH") || fail "node-tools with the no-mistakes skill current failed: $out"
  [ "$(calls)" = "$QUIET_RERUN" ] || fail "a current no-mistakes skill was installed again: $(calls)"
  [ -z "$out" ] || fail "a current no-mistakes skill made a re-run noisy: $out"
  rm -rf "$home/.agents/skills/no-mistakes"
  : >"$NODE_TOOLS_LOG"
  out=$(run_tools "$home" workstation "$BASE_PATH") || fail "node-tools after deleting the no-mistakes skill failed: $out"
  [ "$(calls)" = "$(nm_skill_add v1.84.0)
$QUIET_RERUN" ] || fail "the no-mistakes skill was not restored by itself: $(calls)"
  : >"$NODE_TOOLS_LOG"
  out=$(NO_MISTAKES_FAKE_VERSION=v1.99.1-rc.1 run_tools "$home" workstation "$BASE_PATH") || fail "node-tools after a no-mistakes update failed: $out"
  [ "$(calls)" = "$(nm_skill_add v1.99.1-rc.1)
$QUIET_RERUN" ] || fail "a new no-mistakes version did not install its skill tag: $(calls)"
  [ "$(cat "$home/.agents/skills/no-mistakes/SKILL.md")" = "no-mistakes v1.99.1-rc.1" ] || fail "the no-mistakes skill did not follow the CLI version"
  : >"$NODE_TOOLS_LOG"
  out=$(NO_MISTAKES_FAKE_VERSION=v1.99.1-rc.1 run_tools "$home" workstation "$BASE_PATH") || fail "node-tools with the updated skill current failed: $out"
  [ "$(calls)" = "$QUIET_RERUN" ] || fail "an up-to-date no-mistakes skill was installed again: $(calls)"
  # A CLI that is absent or prints no version warns, never fails, and leaves the skill.
  : >"$NODE_TOOLS_LOG"
  out=$(NO_MISTAKES_FAKE_VERSION='' run_tools "$home" workstation "$BASE_PATH") || fail "an unparseable no-mistakes version failed the run: $out"
  assert_contains "$out" "warning: no-mistakes is not on PATH or prints no version" "an unparseable no-mistakes version is not warned about: $out"
  [ "$(calls)" = "$QUIET_RERUN" ] || fail "an unparseable no-mistakes version installed a skill: $(calls)"
  [ "$(cat "$home/.agents/skills/no-mistakes/SKILL.md")" = "no-mistakes v1.99.1-rc.1" ] || fail "an unparseable no-mistakes version touched the skill"
  mv "$FIX/common/no-mistakes" "$FIX/no-mistakes.away"
  out=$(run_tools "$home" workstation "$BASE_PATH"); status=$?
  mv "$FIX/no-mistakes.away" "$FIX/common/no-mistakes"
  [ "$status" = 0 ] || fail "a missing no-mistakes failed the run: $out"
  assert_contains "$out" "warning: no-mistakes is not on PATH" "a missing no-mistakes is not warned about: $out"
  [ "$(cat "$home/.agents/skills/no-mistakes/SKILL.md")" = "no-mistakes v1.99.1-rc.1" ] || fail "a missing no-mistakes touched the skill"
  pass "the no-mistakes skill follows the installed CLI version (pre-releases too): restored when missing, installed again on a version change, left alone when current, and a missing or unparseable CLI only warns"
}

test_container_and_failures() {
  local home="$TMP_ROOT/ct" out ns
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm-home" run_tools "$home" container "$FIX/image:$BASE_PATH") \
    || fail "container with the image's Node.js tools failed: $out"
  [ "$(calls)" = "$NODE_INSTALLS" ] || fail "container did not run only the pnpm, skills, and npm installs: $(calls)"
  [ "$(cat "$home/.agents/skills/no-mistakes/SKILL.md")" = "no-mistakes v1.84.0" ] || fail "container: the no-mistakes skill of the installed CLI version is missing"
  # npm's global prefix is ~/.npm-global, where yo finds the generators.
  for ns in $YO_NAMESPACES; do
    assert_contains "$("$home/.npm-global/bin/yo" --generators)" "$ns" "yo does not list $ns from ~/.npm-global"
  done
  [ -x "$home/.npm-global/bin/mbt" ] && [ -x "$home/.npm-global/bin/mta" ] || fail "mbt and mta are not in ~/.npm-global/bin"
  [ ! -e "$home/.nvm" ] || fail "container installed nvm"
  for tool in ui5mcp fiori-mcp playwright-mcp sap-note-search-mcp; do
    [ "$("$home/pnpm-home/bin/$tool" --version)" = "$tool 9.9.9" ] || fail "container: the MCP server binary $tool does not run from pnpm's global bin"
  done
  : >"$NODE_TOOLS_LOG"
  out="$out$(PNPM_HOME="$home/pnpm-home" run_bash_tools "$home" "$FIX/image:$BASE_PATH")" || fail "container bash-tools failed: $out"
  [ "$(calls)" = "$(bash_installs "$home")" ] || fail "container bash-tools did not only run the six vendor installers (including treehouse): $(calls)"
  for tool in herdr pi copilot claude agy; do
    [ -x "$home/.local/bin/$tool" ] || fail "container did not install $tool into ~/.local/bin"
  done

  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm-home" run_tools "$home" container "$FIX/image:$BASE_PATH")
  out="$out$(PNPM_HOME="$home/pnpm-home" run_bash_tools "$home" "$FIX/image:$BASE_PATH")"
  [ "$(calls)" = "$QUIET_RERUN" ] && [ -z "$out" ] || fail "a container re-run reinstalled tools, skipped the generator check, or warned: $(calls) $out"

  # NPM_CONFIG_PREFIX wins over ~/.npm-global.
  home="$TMP_ROOT/ct-prefix"
  mkdir -p "$home"
  out=$(NPM_CONFIG_PREFIX="$home/custom" PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") \
    || fail "container with NPM_CONFIG_PREFIX failed: $out"
  [ -x "$home/custom/bin/yo" ] && [ ! -e "$home/.npm-global" ] || fail "container ignored NPM_CONFIG_PREFIX"

  # No pnpm: node-tools stops with clear warnings, nothing is installed,
  # and bash-tools still runs all six vendor installers (including treehouse).
  home="$TMP_ROOT/ct-nopnpm"
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  if out=$(run_tools "$home" container "$BASE_PATH"); then
    fail "container without pnpm succeeded: $out"
  fi
  assert_contains "$out" "pnpm not found on PATH" "missing pnpm is not reported clearly: $out"
  assert_contains "$out" "deny list is unproven because the policy check did not run" "missing pnpm hid the unproven FAB policy: $out"
  [ -z "$(calls)" ] || fail "node-tools installed something without pnpm: $(calls)"
  out=$(run_bash_tools "$home" "$BASE_PATH") || fail "bash-tools without pnpm failed: $out"
  [ "$(calls)" = "$(bash_installs "$home")" ] || fail "bash-tools without pnpm did not install the six vendor CLIs (including treehouse): $(calls)"

  if out=$(NVM_INSTALL_URL="file://$TMP_ROOT/missing.sh" run_tools "$TMP_ROOT/ws-offline" workstation "$BASE_PATH"); then
    fail "workstation without the nvm install script succeeded: $out"
  fi
  assert_contains "$out" "cannot install nvm" "a failed nvm download is not reported: $out"
  assert_contains "$out" "deny list is unproven because the policy check did not run" "a failed nvm download hid the unproven FAB policy: $out"
  pass "container: the image's Node.js and pnpm, npm globals in ~/.npm-global (or \$NPM_CONFIG_PREFIX) where yo finds them, no nvm; without pnpm node-tools fails clearly and bash-tools still installs everything"
}

test_step_failures_do_not_block() {
  local home out
  # A failing pnpm add: npm globals and skills are still installed.
  home="$TMP_ROOT/fail-pnpm"
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  if out=$(PNPM_FAKE_FAIL=1 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
    fail "a failing pnpm add was accepted: $out"
  fi
  assert_contains "$out" "pnpm add -g arc-1@latest" "a failed pnpm add is not reported: $out"
  [ -x "$home/.npm-global/bin/yo" ] && [ -f "$home/.agents/skills/find-skills/SKILL.md" ] || fail "a failing pnpm add stopped the npm globals or the skills"

  # A failing npm install: pnpm globals and skills are still installed.
  home="$TMP_ROOT/fail-npm"
  mkdir -p "$home"
  if out=$(NPM_FAKE_FAIL=1 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
    fail "a failing npm install was accepted: $out"
  fi
  assert_contains "$out" "npm install -g mbt mta yo" "a failed npm install is not reported: $out"
  [ -d "$home/pnpm/global/v11/h/node_modules/eslint" ] && [ -f "$home/.agents/skills/find-skills/SKILL.md" ] \
    || fail "a failing npm install stopped the pnpm globals or the skills"
  for tool in mbt mta yo; do
    assert_contains "$out" "warning: $tool is not on PATH" "a failing npm install suppressed the $tool smoke warning: $out"
  done
  if [ -n "$AMD64" ]; then
    assert_contains "$out" "warning: cf plugins does not list ServiceInfo" "a failing cf-tools-local install suppressed the plugin warning: $out"
  fi

  # Failing skills: pnpm and npm globals are still installed.
  home="$TMP_ROOT/fail-skills"
  mkdir -p "$home"
  if out=$(NPX_FAKE_FAIL=1 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
    fail "failing skills were accepted: $out"
  fi
  assert_contains "$out" "npx skills add arc-mcp/arc-1 failed" "a failed skills install is not reported: $out"
  [ -d "$home/pnpm/global/v11/h/node_modules/eslint" ] && [ -x "$home/.npm-global/bin/yo" ] \
    || fail "failing skills stopped the pnpm or npm globals"

  # A skills install that leaves find-skills out is caught, as the Dockerfile did.
  home="$TMP_ROOT/fail-skill-missing"
  mkdir -p "$home/.agents/skills/explain-abap-code" "$home/.agents/skills/tdd" "$home/.agents/skills/resolving-merge-conflicts"
  : >"$home/.agents/skills/explain-abap-code/SKILL.md"
  : >"$home/.agents/skills/tdd/SKILL.md"
  mkdir -p "$home/bin"
  # An npx that succeeds without installing anything.
  printf '#!/bin/sh\nexit 0\n' >"$home/bin/npx"
  chmod +x "$home/bin/npx"
  if out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$home/bin:$FIX/image:$BASE_PATH"); then
    fail "a skills install that left skills out was accepted: $out"
  fi
  assert_contains "$out" "find-skills/SKILL.md is missing" "a missing skill is not reported: $out"
  # A failing no-mistakes skill install is reported and fails the run.
  home="$TMP_ROOT/fail-nm-skill"
  mkdir -p "$home"
  if out=$(NPX_FAKE_FAIL_SOURCE=$NO_MISTAKES_SKILL_SOURCE PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
    fail "a failing no-mistakes skill install was accepted: $out"
  fi
  assert_contains "$out" "npx skills add $NO_MISTAKES_SKILL_SOURCE failed" "a failed no-mistakes skill install is not reported: $out"
  pass "a failing pnpm, npm, or skills step is reported and fails the run without stopping the others; a missing find-skills or resolving-merge-conflicts skill is caught"
}

test_smoke_checks_warn() {
  local home out
  home="$TMP_ROOT/smoke"
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  out=$(MBT_FAKE_BROKEN=1 YO_FAKE_HIDE=@sap/aicore CF_FAKE_NO_PLUGIN=1 PNPM_HOME="$home/pnpm" \
    run_tools "$home" container "$FIX/image:$BASE_PATH") && fail "failing smoke checks were not reported as a non-zero exit"
  assert_contains "$out" "warning: mbt --version" "broken mbt is not a warning: $out"
  assert_contains "$out" "warning: yo --generators does not list @sap/aicore" "a missing generator is not a warning: $out"
  if [ -n "$AMD64" ]; then
    assert_contains "$out" "warning: cf plugins does not list ServiceInfo" "a missing ServiceInfo plugin is not a warning: $out"
  fi
  [ -x "$home/.npm-global/bin/yo" ] && [ -f "$home/.agents/skills/find-skills/SKILL.md" ] || fail "smoke warnings stopped the installs"
  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a re-run after smoke warnings failed: $out"
  [ "$(calls)" = "$QUIET_RERUN" ] && [ -z "$out" ] || fail "a re-run after smoke warnings skipped the generator check or was not quiet: $(calls) $out"
  if out=$(YO_FAKE_HIDE=@sap/fiori PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
    fail "an existing but undiscoverable generator was accepted: $out"
  fi
  assert_contains "$out" "warning: yo --generators does not list @sap/fiori" "a re-switch suppressed the generator warning: $out"
  mkdir -p "$home/image-no-cf"
  cp "$FIX/image/npm" "$FIX/image/pnpm" "$FIX/image/npx" "$home/image-no-cf/"
  ln -s "$REAL_NODE" "$home/image-no-cf/node"
  if [ -n "$AMD64" ]; then
    if out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$home/image-no-cf:$FIX/arc1:/usr/bin:/bin"); then
      fail "a missing cf CLI was silently accepted: $out"
    fi
    assert_contains "$out" "ServiceInfo plugin could not be verified because cf is missing" "a missing cf CLI did not warn: $out"
  fi
  printf '#!/bin/sh\necho aarch64\n' >"$home/image-no-cf/uname"
  chmod +x "$home/image-no-cf/uname"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$home/image-no-cf:$FIX/arc1:/usr/bin:/bin") || fail "an ARM re-switch tried to verify an amd64-only plugin: $out"
  assert_not_contains "$out" "ServiceInfo" "an ARM re-switch checked the amd64-only plugin: $out"
  rm -rf "$home/.npm-global/lib/node_modules/mta"
  if out=$(NPM_FAKE_FAIL=1 YO_FAKE_HIDE=@sap/cap-project PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
    fail "a failing install with a smoke warning succeeded: $out"
  fi
  assert_contains "$out" "warning: yo --generators does not list @sap/cap-project" "an npm failure suppressed an existing generator's smoke check: $out"
  pass "smoke checks warn on every switch, including existing globals, failed installs, and a missing cf CLI"
}

# Installs the fake AXI tool $2 at version $3 into bin directory $1, as an
# earlier install (the devcontainer image's, or Firstmate's bootstrap) would.
fake_axi_tool() {
  mkdir -p "$1"
  sed "s/@VERSION@/$3/" "$FIX/fake-axi" >"$1/$2"
  chmod +x "$1/$2"
}

test_axi_tools() {
  local home="$TMP_ROOT/axi" out bin tool version
  mkdir -p "$home"
  bin="$home/.npm-global/bin"

  # The devcontainer image or Firstmate's bootstrap already put the tools in
  # ~/.npm-global: at their floors or above them,
  # a switch installs nothing, leaves no second copy, and only repairs hooks.
  fake_axi_tool "$bin" gh-axi 0.1.29
  fake_axi_tool "$bin" chrome-devtools-axi 0.1.23
  fake_axi_tool "$bin" lavish-axi 0.1.80
  fake_axi_tool "$bin" tasks-axi 0.2.6
  fake_axi_tool "$bin" quota-axi 1.0.0
  PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH" >/dev/null || fail "setup for the AXI floors failed"
  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a switch with the AXI tools at their floors failed: $out"
  [ "$(calls)" = "$QUIET_RERUN" ] && [ -z "$out" ] || fail "tools at their floors were reinstalled or the switch was noisy: $(calls) $out"
  [ "$("$bin/gh-axi" --version)" = "gh-axi 0.1.29" ] || fail "an AXI tool at its floor was replaced"
  [ ! -e "$home/pnpm/bin/gh-axi" ] && [ ! -e "$home/.local/bin/gh-axi" ] || fail "an AXI tool was duplicated outside npm's global bin"
  [ "$("$bin/chrome-devtools-axi" --version)" = "chrome-devtools-axi 0.1.23" ] || fail "a setup-compatible Chrome CLI was replaced"

  for version in 0.1.0 0.1.22; do
    fake_axi_tool "$bin" chrome-devtools-axi "$version"
    rm "$home/.config/opencode/plugins/axi-chrome-devtools-axi.js"
    : >"$NODE_TOOLS_LOG"
    out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") \
      || fail "a legacy Chrome CLI was not upgraded before hook setup: $out"
    [ "$(calls)" = "npm install -g chrome-devtools-axi@latest
$QUIET_RERUN" ] || fail "a legacy Chrome CLI was not the only tool upgraded: $(calls)"
    [ "$("$bin/chrome-devtools-axi" --version)" = "chrome-devtools-axi 9.9.9" ] || fail "Chrome stayed at its legacy version"
    [ -f "$home/.config/opencode/plugins/axi-chrome-devtools-axi.js" ] || fail "upgrading Chrome did not install its hook"
    : >"$NODE_TOOLS_LOG"
    out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a switch after upgrading Chrome failed: $out"
    [ "$(calls)" = "$QUIET_RERUN" ] && [ -z "$out" ] || fail "upgrading Chrome did not converge to a quiet re-switch: $(calls) $out"
  done

  # One patch below a floor, a version that cannot be read, and a missing tool
  # install @latest, each alone, from npm; a newer tool next to them is left.
  fake_axi_tool "$bin" gh-axi 0.1.28
  fake_axi_tool "$bin" lavish-axi 0.1.9
  fake_axi_tool "$bin" tasks-axi 0.2.5
  printf '#!/bin/sh\necho dev-build\n' >"$bin/quota-axi"
  rm "$bin/chrome-devtools-axi"
  : >"$NODE_TOOLS_LOG"
  out=$(NPM_FAKE_AXI_VERSION=2.0.0 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") \
    || fail "a switch that upgrades AXI tools failed: $out"
  [ "$(calls)" = "$AXI_ADD
$QUIET_RERUN" ] || fail "tools below a floor were not all reinstalled, in one npm call: $(calls)"
  # The reinstalled lavish-axi is the first package here, so its skill gets linked (see test_lavish_skill).
  [ "$(grep -vc 'node-tools: linked .*/skills/lavish -> ' <<<"$out")" = 1 ] && [ "$(sed -n 1p <<<"$out")" = "node-tools: $AXI_ADD" ] \
    || fail "reinstalling AXI tools printed more than the npm line and the lavish skill links: $out"
  for tool in gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi; do
    [ "$("$bin/$tool" --version)" = "$tool 2.0.0" ] || fail "$tool was not reinstalled at the registry's latest"
  done
  fake_axi_tool "$bin" gh-axi 3.0.0
  fake_axi_tool "$bin" quota-axi 0.1.50
  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a single stale AXI tool failed the switch: $out"
  [ "$(calls)" = "npm install -g quota-axi@latest
$QUIET_RERUN" ] || fail "only the tool below its floor was not reinstalled: $(calls)"
  [ "$("$bin/gh-axi" --version)" = "gh-axi 3.0.0" ] || fail "a newer AXI tool was replaced"

  # A registry whose latest is still below the floor is reported, not looped on.
  fake_axi_tool "$bin" tasks-axi 0.2.5
  if out=$(NPM_FAKE_AXI_VERSION=0.2.5 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
    fail "an AXI tool still below its floor after npm install was accepted: $out"
  fi
  assert_contains "$out" "tasks-axi is still missing or below 0.2.6" "a floor miss after the install is not named: $out"
  assert_contains "$out" "axi_tools did not complete" "a floor miss is not reported as a failed step: $out"

  fake_axi_tool "$bin" tasks-axi 0.2.6
  fake_axi_tool "$bin" chrome-devtools-axi 0.1.0
  : >"$NODE_TOOLS_LOG"
  if out=$(NPM_FAKE_AXI_VERSION=0.1.22 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
    fail "a Chrome CLI without setup hooks was accepted after npm install: $out"
  fi
  assert_contains "$out" "chrome-devtools-axi is still missing or below 0.1.23" "an incompatible Chrome install was not named: $out"
  assert_contains "$out" "axi_tools" "an incompatible Chrome install was not a failed provisioning step: $out"
  [ "$(calls)" = "npm install -g chrome-devtools-axi@latest
$QUIET_RERUN" ] || fail "an incompatible Chrome install retried or blocked sibling operations: $(calls)"

  # A failing npm install is reported and does not stop the other steps.
  home="$TMP_ROOT/axi-fail"
  mkdir -p "$home"
  if out=$(NPM_FAKE_FAIL=1 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
    fail "a failing AXI install was accepted: $out"
  fi
  assert_contains "$out" "npm install -g gh-axi@latest" "a failed AXI install is not reported: $out"
  assert_contains "$out" "gh-axi is not on PATH; cannot set up its agent hooks" "missing AXI tools did not stop the hooks step from reporting: $out"
  [ -d "$home/pnpm/global/v11/h/node_modules/eslint" ] && [ -f "$home/.agents/skills/find-skills/SKILL.md" ] \
    || fail "a failing AXI install stopped the pnpm globals or the skills"

  # The workstation installs them into nvm's default Node.js, on PATH there.
  home="$TMP_ROOT/axi-ws"
  mkdir -p "$home"
  run_tools "$home" workstation "$BASE_PATH" >/dev/null || fail "workstation setup for the AXI tools failed"
  for tool in gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi; do
    [ "$("$home/.nvm/default/bin/$tool" --version)" = "$tool 9.9.9" ] || fail "workstation: $tool is not in nvm's default Node.js bin"
  done
  fake_axi_tool "$home/.nvm/default/bin" chrome-devtools-axi 0.1.0
  rm "$home/.config/opencode/plugins/axi-chrome-devtools-axi.js"
  : >"$NODE_TOOLS_LOG"
  out=$(run_tools "$home" workstation "$BASE_PATH") || fail "workstation did not upgrade legacy Chrome before hook setup: $out"
  [ "$(calls)" = "npm install -g chrome-devtools-axi@latest
$QUIET_RERUN" ] || fail "workstation did not upgrade only legacy Chrome: $(calls)"
  [ "$("$home/.nvm/default/bin/chrome-devtools-axi" --version)" = "chrome-devtools-axi 9.9.9" ] \
    && [ -f "$home/.config/opencode/plugins/axi-chrome-devtools-axi.js" ] || fail "workstation did not upgrade Chrome and install its hook"
  pass "AXI tools: installed at @latest into npm's global prefix when missing or below their floors, in one call; left alone at or above them (no second copy next to the image's or Firstmate's); a floor missed after the install is reported; a failing install does not stop the other steps; the workstation uses nvm's prefix"
}

# The lavish skill: a link to lavish-axi's bundled skill, never a copy.
test_lavish_skill() {
  local home="$TMP_ROOT/lavish" out pkg dir
  mkdir -p "$home"
  pkg="$home/.npm-global/lib/node_modules/lavish-axi/skills/lavish"

  # Fresh HOME: the package is installed by this run, then linked for Pi and Claude Code.
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "lavish: a fresh switch failed: $out"
  for dir in .agents/skills .claude/skills; do
    [ -L "$home/$dir/lavish" ] && [ "$(readlink "$home/$dir/lavish")" = "$pkg" ] \
      || fail "lavish: $dir/lavish is not a link to the installed package: $(ls -l "$home/$dir" 2>&1)"
  done
  [ "$(cat "$home/.claude/skills/lavish/SKILL.md")" = "lavish skill 9.9.9" ] || fail "lavish: the Claude link does not reach the skill"
  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "lavish: a re-run failed: $out"
  [ -z "$out" ] || fail "lavish: a re-run is not quiet: $out"

  # A package upgrade changes the file behind the link, not the link.
  echo "lavish skill 9.9.10" >"$pkg/SKILL.md"
  [ "$(cat "$home/.agents/skills/lavish/SKILL.md")" = "lavish skill 9.9.10" ] || fail "lavish: the link does not follow a package upgrade"

  # CLAUDE_CONFIG_DIR names the Claude skills directory; ~/.claude is not used.
  home="$TMP_ROOT/lavish-ccd"
  mkdir -p "$home"
  out=$(CLAUDE_CONFIG_DIR="$home/claude-cfg" PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") \
    || fail "lavish: a switch with CLAUDE_CONFIG_DIR failed: $out"
  [ "$(cat "$home/claude-cfg/skills/lavish/SKILL.md")" = "lavish skill 9.9.9" ] || fail "lavish: not linked into \$CLAUDE_CONFIG_DIR/skills"
  [ ! -e "$home/.claude/skills/lavish" ] || fail "lavish: ~/.claude/skills was used although CLAUDE_CONFIG_DIR is set"

  # Package not installed (offline): no link, and no failure from the skill step.
  home="$TMP_ROOT/lavish-none"
  mkdir -p "$home"
  out=$(NPM_FAKE_FAIL=1 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || true
  [ ! -e "$home/.agents/skills/lavish" ] && [ ! -L "$home/.agents/skills/lavish" ] \
    && [ ! -L "$home/.claude/skills/lavish" ] || fail "lavish: a link exists although the package is not installed"
  assert_not_contains "$out" "lavish_skill" "lavish: the skill step failed without the package: $out"

  # The package goes away: a dangling link of ours is removed, other entries stay.
  home="$TMP_ROOT/lavish"
  rm -rf "$home/.npm-global/lib/node_modules/lavish-axi" "$home/.npm-global/bin/lavish-axi"
  mkdir -p "$home/.claude/skills/other"
  ln -s /nowhere "$home/.agents/skills/stale"
  out=$(NPM_FAKE_FAIL=1 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || true
  [ ! -L "$home/.agents/skills/lavish" ] && [ ! -L "$home/.claude/skills/lavish" ] || fail "lavish: a dangling link stayed after the package was removed"
  [ -L "$home/.agents/skills/stale" ] && [ -d "$home/.claude/skills/other" ] || fail "lavish: an unrelated skill entry was touched"

  # An existing entry named lavish is never replaced.
  home="$TMP_ROOT/lavish-own"
  mkdir -p "$home/.agents/skills/lavish" "$home/.claude/skills"
  echo own >"$home/.agents/skills/lavish/SKILL.md"
  ln -s /nowhere "$home/.claude/skills/lavish"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "lavish: a switch with existing entries failed: $out"
  [ "$(cat "$home/.agents/skills/lavish/SKILL.md")" = own ] && [ ! -L "$home/.agents/skills/lavish" ] || fail "lavish: an existing skill directory was replaced"
  [ "$(readlink "$home/.claude/skills/lavish")" = /nowhere ] || fail "lavish: an unrelated link was replaced"
  assert_contains "$out" "$home/.agents/skills/lavish already exists" "lavish: the kept entry is not reported: $out"
  pass "lavish skill: ~/.agents/skills/lavish and the Claude skills directory (\$CLAUDE_CONFIG_DIR/skills when set) link to the installed lavish-axi package and follow its upgrades; nothing is linked without the package, a dangling link of ours is removed, and other entries are never replaced"
}

test_backpass_tools() {
  local home="$TMP_ROOT/backpass" out bin tool
  mkdir -p "$home"
  bin="$home/.npm-global/bin"

  # A fresh container installs backpass and acpx at @latest, in one call, once
  # the AXI tools are in; lavish-axi (the `backpass apply` review UI) is the
  # AXI tools' own and is not installed a second time.
  : >"$NODE_TOOLS_LOG"
  PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH" >/dev/null || fail "setup for backpass failed"
  assert_contains "$(calls)" "$BACKPASS_ADD" "a fresh switch did not install backpass and acpx in one call: $(calls)"
  [ "$(calls | grep -c 'lavish-axi@latest')" = 1 ] || fail "lavish-axi was installed more than once: $(calls)"
  for tool in backpass acpx; do
    [ "$("$bin/$tool" --version)" = "$tool 9.9.9" ] || fail "$tool is not in npm's global bin"
  done

  # At or above the floors: nothing is installed, nothing is printed.
  fake_axi_tool "$bin" backpass 0.1.41
  fake_axi_tool "$bin" acpx 3.0.0
  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a switch with backpass at its floor failed: $out"
  [ "$(calls)" = "$QUIET_RERUN" ] && [ -z "$out" ] || fail "backpass tools at their floors were reinstalled or the switch was noisy: $(calls) $out"
  [ "$("$bin/backpass" --version)" = "backpass 0.1.41" ] || fail "backpass at its floor was replaced"
  [ ! -e "$home/pnpm/bin/backpass" ] && [ ! -e "$home/.local/bin/acpx" ] || fail "a backpass tool was duplicated outside npm's global bin"

  # Below a floor, or missing: only that tool is installed again.
  fake_axi_tool "$bin" backpass 0.1.40
  rm "$bin/acpx"
  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a switch that upgrades backpass failed: $out"
  [ "$(calls)" = "$BACKPASS_ADD
$QUIET_RERUN" ] || fail "backpass below its floor and a missing acpx were not reinstalled in one call: $(calls)"
  fake_axi_tool "$bin" acpx 0.21.0
  : >"$NODE_TOOLS_LOG"
  PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH" >/dev/null || fail "a switch that upgrades acpx failed"
  [ "$(calls)" = "npm install -g acpx@latest
$QUIET_RERUN" ] || fail "only acpx below its floor was not reinstalled alone: $(calls)"

  # A registry whose latest is below the floor is reported, not looped on.
  fake_axi_tool "$bin" backpass 0.1.0
  if out=$(NPM_FAKE_AXI_VERSION=0.1.1 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
    fail "a backpass still below its floor after npm install was accepted: $out"
  fi
  assert_contains "$out" "backpass is still missing or below 0.1.41" "a floor miss after the install is not named: $out"
  assert_contains "$out" "backpass_tools did not complete" "a floor miss is not reported as a failed step: $out"

  # The workstation installs them into nvm's default Node.js, on PATH there.
  home="$TMP_ROOT/backpass-ws"
  mkdir -p "$home"
  run_tools "$home" workstation "$BASE_PATH" >/dev/null || fail "workstation setup for backpass failed"
  for tool in backpass acpx; do
    [ "$("$home/.nvm/default/bin/$tool" --version)" = "$tool 9.9.9" ] || fail "workstation: $tool is not in nvm's default Node.js bin"
  done
  pass "backpass and acpx: installed at @latest into npm's global prefix when missing or below their floors; left alone at or above them; a floor missed after the install is reported; the workstation uses nvm's prefix"
}

test_paseo() {
  local home="$TMP_ROOT/paseo" out bin
  mkdir -p "$home"
  bin="$home/.npm-global/bin"
  PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH" >/dev/null || fail "setup for the Paseo CLI failed"
  [ "$("$bin/paseo" --version)" = "paseo 9.9.9" ] || fail "a fresh switch did not install the registry's latest paseo"

  # Current: nothing is installed and the switch stays quiet.
  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a switch with the latest paseo failed: $out"
  [ "$(calls)" = "$QUIET_RERUN" ] && [ -z "$out" ] || fail "the latest paseo was reinstalled or the switch was noisy: $(calls) $out"

  # A prerelease with the same numeric version is not the registry's stable release.
  fake_axi_tool "$bin" paseo 9.9.9-beta.3
  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a switch from a paseo prerelease failed: $out"
  [ "$("$bin/paseo" --version)" = "paseo 9.9.9" ] || fail "paseo stayed at a prerelease instead of the registry's latest stable release: $("$bin/paseo" --version)"
  [ "$(calls)" = "$PASEO_ADD
$QUIET_RERUN" ] || fail "a prerelease switch did not install only paseo at latest: $(calls)"

  # A new upstream release is picked up on the next switch, with no pin or floor involved.
  : >"$NODE_TOOLS_LOG"
  out=$(NPM_FAKE_PASEO_VERSION=10.0.0 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a switch after a new paseo release failed: $out"
  [ "$out" = "node-tools: $PASEO_ADD" ] || fail "a new paseo release printed more than the npm line: $out"
  [ "$("$bin/paseo" --version)" = "paseo 10.0.0" ] || fail "paseo did not follow the registry's latest"
  [ "$(calls | grep -c '@getpaseo/cli')" = 1 ] || fail "paseo was installed more than once: $(calls)"

  # Offline registry: an installed paseo is kept with a warning; a missing one fails the step.
  : >"$NODE_TOOLS_LOG"
  out=$(NPM_FAKE_VIEW_FAIL=1 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "an offline switch failed with paseo installed: $out"
  assert_contains "$out" "keeping paseo 10.0.0" "an offline switch did not say it kept paseo: $out"
  [ "$(calls)" = "$QUIET_RERUN" ] || fail "an offline switch tried to install paseo: $(calls)"
  rm "$bin/paseo"
  if out=$(NPM_FAKE_VIEW_FAIL=1 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
    fail "an offline switch without paseo succeeded: $out"
  fi
  assert_contains "$out" "paseo is missing and npm cannot read the latest @getpaseo/cli" "a missing paseo with an offline registry is not named: $out"
  assert_contains "$out" "paseo did not complete" "a missing paseo is not reported as a failed step: $out"

  # A failing install is reported.
  if out=$(NPM_FAKE_FAIL=1 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
    fail "a failing paseo install was accepted: $out"
  fi
  assert_contains "$out" "npm install -g @getpaseo/cli@latest failed" "a failed paseo install is not reported: $out"

  # A registry whose latest is below the 0.8.0 floor is reported.
  if out=$(NPM_FAKE_PASEO_VERSION=0.7.9 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
    fail "a paseo below the 0.8.0 floor was accepted: $out"
  fi
  assert_contains "$out" "paseo is still missing or below 0.8.0" "a paseo below the floor is not named: $out"

  # The workstation installs it into nvm's default Node.js, on PATH there.
  home="$TMP_ROOT/paseo-ws"
  mkdir -p "$home"
  run_tools "$home" workstation "$BASE_PATH" >/dev/null || fail "workstation setup for the Paseo CLI failed"
  [ "$("$home/.nvm/default/bin/paseo" --version)" = "paseo 9.9.9" ] || fail "workstation: paseo is not in nvm's default Node.js bin"
  pass "Paseo CLI: @getpaseo/cli installed at the registry's latest when missing or different, so every switch follows upstream; left alone when current; an offline registry keeps an installed copy; the 0.8.0 floor, a failing install, and a missing copy are reported; the workstation uses nvm's prefix"
}

test_axi_hooks() {
  local home="$TMP_ROOT/hooks" out declared settings tool
  declared='{"hooks": {"SessionStart": [{"command": "gh-axi"}, {"command": "chrome-devtools-axi"}, {"command": "lavish-axi"}]}, "theme": "dark-ansi"}'
  settings="$home/.claude/settings.json"
  mkdir -p "$home/dotfiles/home/.claude" "$home/.claude"
  printf '%s\n' "$declared" >"$home/dotfiles/home/.claude/settings.json"
  ln -s "$home/dotfiles/home/.claude/settings.json" "$settings"

  # Claude Code's settings.json is a Home Manager link into the repo and
  # already declares the hooks: the tools' own run leaves it alone, and the
  # other agents' hooks (Codex, OpenCode) are written.
  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a switch with Claude's declared hooks failed: $out"
  assert_not_contains "$out" "Home Manager declares it" "setup hooks changed Claude's declared settings and needed the restore: $out"
  [ "$(calls)" = "$NODE_INSTALLS" ] || fail "the first switch did not install the tools and run each setup hooks once: $(calls)"
  [ -L "$settings" ] && [ "$(cat "$home/dotfiles/home/.claude/settings.json")" = "$declared" ] \
    || fail "setup hooks changed Home Manager's Claude settings"
  for tool in gh-axi chrome-devtools-axi lavish-axi; do
    [ -f "$home/.config/opencode/plugins/axi-$tool.js" ] || fail "$tool's OpenCode hook was not written"
    assert_contains "$(cat "$home/.codex/hooks.json")" "$tool" "$tool's Codex hook was not written"
  done

  # A tool that rewrites the Claude hook anyway (the real one does when it is
  # not run from PATH) is put back byte for byte, through the link.
  out=$(AXI_FAKE_CLAUDE_REWRITE=1 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") \
    || fail "a switch that restored Claude's settings failed: $out"
  assert_contains "$out" "kept $settings as Home Manager declares it" "a restored Claude settings.json was not mentioned: $out"
  [ -L "$settings" ] && [ "$(cat "$home/dotfiles/home/.claude/settings.json")" = "$declared" ] \
    || fail "a rewritten Claude settings.json was not restored through its link"

  # Without a settings.json (a switch that runs before Home Manager links it),
  # the file the tools create is removed, so the link can be made.
  home="$TMP_ROOT/hooks-fresh"
  mkdir -p "$home"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a switch without Claude settings failed: $out"
  assert_not_contains "$out" "settings.json" "the removal of the file that setup hooks created was reported: $out"
  [ ! -e "$home/.claude/settings.json" ] || fail "setup hooks left a plain Claude settings.json for Home Manager to collide with"
  [ -f "$home/.config/opencode/plugins/axi-lavish-axi.js" ] || fail "the other agents' hooks were not written without Claude settings"

  # A failing setup hooks is reported, the others still run, and the Claude
  # file is still put back.
  home="$TMP_ROOT/hooks-fail"
  mkdir -p "$home/.claude"
  printf '%s\n' "$declared" >"$home/.claude/settings.json"
  PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH" >/dev/null || fail "setup for failing hooks failed"
  : >"$NODE_TOOLS_LOG"
  if out=$(AXI_FAKE_HOOKS_FAIL=1 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
    fail "failing setup hooks were accepted: $out"
  fi
  assert_contains "$out" "gh-axi setup hooks failed" "a failing setup hooks is not named: $out"
  assert_contains "$out" "lavish-axi setup hooks failed" "a failing setup hooks stopped the next tool's: $out"
  assert_contains "$out" "axi_hooks did not complete" "failing setup hooks is not a failed step: $out"
  [ "$(calls)" = "$QUIET_RERUN" ] || fail "failing setup hooks stopped the generator check or reinstalled tools: $(calls)"
  pass "AXI hooks: setup hooks runs for gh-axi, chrome-devtools-axi, and lavish-axi on every switch; Claude Code's Home Manager settings.json (which declares them) is never changed or pre-empted; Codex and OpenCode hooks are written; a failing one is reported without stopping the rest"
}

test_treehouse() {
  local home="$TMP_ROOT/treehouse" out
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  out=$(run_bash_tools "$home" "$BASE_PATH") || fail "bash-tools on a fresh HOME failed: $out"
  assert_contains "$(calls)" "$TREEHOUSE_INSTALL" "treehouse was not installed: $(calls)"
  [ "$("$home/.local/bin/treehouse" --version)" = "treehouse version 3.1.4" ] || fail "treehouse is not in ~/.local/bin"
  assert_contains "$("$home/.local/bin/treehouse" get --help)" "--lease" "the fake treehouse lacks --lease"
  : >"$NODE_TOOLS_LOG"
  out=$(run_bash_tools "$home" "$BASE_PATH") || fail "bash-tools re-run failed: $out"
  [ -z "$(calls)" ] && [ -z "$out" ] || fail "a treehouse with --lease was installed again or the re-run was noisy: $(calls) $out"

  # A treehouse without `get --lease` is installed again, and only it.
  home="$TMP_ROOT/treehouse-old"
  mkdir -p "$home"
  # Its installer leaves a treehouse without --lease, which bash-tools reports.
  TREEHOUSE_FAKE_OLD=1 run_bash_tools "$home" "$BASE_PATH" >/dev/null && fail "bash-tools accepted an old treehouse"
  [ "$("$home/.local/bin/treehouse" --version)" = "treehouse version 2.0.0" ] || fail "the old treehouse fixture is wrong"
  : >"$NODE_TOOLS_LOG"
  out=$(run_bash_tools "$home" "$BASE_PATH") || fail "bash-tools upgrading treehouse failed: $out"
  [ "$(calls)" = "$TREEHOUSE_INSTALL" ] || fail "only the treehouse without --lease should have been installed again: $(calls)"
  [ "$("$home/.local/bin/treehouse" --version)" = "treehouse version 3.1.4" ] || fail "treehouse was not upgraded"

  # An installer that leaves a treehouse without --lease is reported; a failing
  # one is reported without stopping the other installers.
  home="$TMP_ROOT/treehouse-stale"
  mkdir -p "$home"
  if out=$(TREEHOUSE_FAKE_OLD=1 run_bash_tools "$home" "$BASE_PATH"); then
    fail "a treehouse installer that leaves no --lease support was accepted"
  fi
  assert_contains "$out" "does not support 'treehouse get --lease'" "a treehouse without --lease is not reported: $out"
  home="$TMP_ROOT/treehouse-fail"
  mkdir -p "$home"
  if out=$(TREEHOUSE_FAKE_FAIL=1 run_bash_tools "$home" "$BASE_PATH"); then
    fail "a failing treehouse installer was accepted: $out"
  fi
  assert_contains "$out" "cannot install treehouse" "a failed treehouse install is not reported: $out"
  assert_contains "$out" "failed: treehouse" "the failed step is not named: $out"
  [ -x "$home/.local/bin/claude" ] && [ -x "$home/.local/bin/agy" ] || fail "a failing treehouse installer stopped the others"
  pass "treehouse: installed to ~/.local/bin (on its installer's PATH, so no sudo); a copy with --lease is left alone and one without it is installed again; failures are reported without stopping the others"
}

test_arc1_policy_check() {
  local home out mode dir log="$FIX/arc1/calls" start path
  local warning="node-tools: warning: the FAB write lane is unsafe with this ARC-1 install: deny list is unproven"
  home="$TMP_ROOT/arc1"
  mkdir -p "$home" "$TMP_ROOT/arc1-cwd"
  echo SAP_PASSWORD=from-dotenv >"$TMP_ROOT/arc1-cwd/.env"
  run_arc1() {
    (cd "$TMP_ROOT/arc1-cwd" && ARC1_TEST_LEAK=real SAP_URL=https://real.example SAP_USER=real-user SAP_PASSWORD=real-secret \
      SAP_ALLOW_WRITES=false SAP_ALLOW_TRANSPORT_WRITES=false SAP_ALLOWED_PACKAGES=real-packages \
      SAP_DENY_ACTIONS=none PNPM_HOME="$home/pnpm" \
      run_tools "$home" container "$FIX/arc1-timeout:$FIX/image:$BASE_PATH")
  }
  PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH" >/dev/null || fail "arc1 check setup failed"

  for mode in deny allow fail hang deny-hang deny-kill; do
    : >"$log"
    : >"$FIX/arc1-timeout/calls"
    echo "$mode" >"$FIX/arc1/mode"
    start=$SECONDS
    if out=$(run_arc1); then
      [ "$mode" = deny ] || fail "an undenied release ($mode) was accepted: $out"
      [ -z "$out" ] || fail "a denied release was not silent: $out"
    else
      [ "$mode" != deny ] || fail "a denied release warned or failed the run: $out"
      assert_contains "$out" "$warning" "an undenied release ($mode) did not warn about the FAB write lane: $out"
      assert_contains "$out" "smoke_checks did not complete" "an undenied release ($mode) was not reported: $out"
      case "$mode" in
        hang | deny-hang | deny-kill) assert_contains "$out" "arc1-cli policy check timed out" "a timeout ($mode) was not identified: $out" ;;
      esac
    fi
    [ $((SECONDS - start)) -lt 20 ] || fail "a hung arc1-cli stalled the check"
    [ "$(wc -l <"$log")" -eq 1 ] || fail "the policy check did not make exactly one ARC-1 invocation: $(cat "$log")"
    assert_contains "$(cat "$log")" 'call SAPTransport --json {"action":"release"' "the policy check did not call SAPTransport release: $(cat "$log")"
    assert_contains "$(cat "$log")" "env_file=no url=http://127.0.0.1:9 user=policy-check password=policy-check writes=true" "the policy check ran with the wrong environment: $(cat "$log")"
    assert_contains "$(cat "$log")" "deny=SAPTransport.release,SAPTransport.release_recursive,SAPTransport.delete,SAPTransport.reassign,SAPTransport.remove_object leak=unset" "the policy check lost the FAB deny list or leaked the environment: $(cat "$log")"
    assert_contains "$(cat "$log")" "empty=yes all_writes=true packages=/IQX/FAB*,/IQX/COMMON,/IQX/ONELIST_*" "the policy check lost FAB settings or did not use an empty directory: $(cat "$log")"
    assert_not_contains "$(cat "$log")" "real" "a real SAP_* value or .env reached arc1-cli: $(cat "$log")"
    assert_contains "$(cat "$FIX/arc1-timeout/calls")" "-k 5 60 env -i" "the policy check did not use the fixed timeout: $(cat "$FIX/arc1-timeout/calls")"
    dir=$(sed -n 's/.* cwd=\([^ ]*\) env_file.*/\1/p' "$log" | head -n 1)
    [ -n "$dir" ] && [ "$dir" != "$TMP_ROOT/arc1-cwd" ] || fail "arc1-cli did not run in its own directory: '$dir'"
    [ ! -e "$dir" ] || fail "the policy check left its temp directory behind: $dir"
  done
  echo deny >"$FIX/arc1/mode"

  for mode in absent setup; do
    : >"$log"
    case "$mode" in
      absent) path="$FIX/image:$FIX/common:/usr/bin:/bin" ;;
      setup) path="$FIX/arc1-setup:$FIX/image:$BASE_PATH" ;;
    esac
    out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$path") && fail "a policy check that could not run ($mode) was accepted: $out"
    assert_contains "$out" "$warning" "a policy check that could not run ($mode) did not warn about the FAB write lane: $out"
    assert_contains "$out" "smoke_checks did not complete" "a policy check that could not run ($mode) was not reported: $out"
    [ ! -s "$log" ] || fail "a policy check that could not run ($mode) invoked arc1-cli: $(cat "$log")"
    case "$mode" in
      absent) assert_contains "$out" "arc1-cli is not on PATH" "an absent CLI was not identified: $out" ;;
      setup) assert_contains "$out" "cannot create a temp directory" "scratch setup failure was not identified: $out" ;;
    esac
  done
  mkdir -p "$FIX/arc1-no-npm"
  ln -s "$(command -v bash)" "$FIX/arc1-no-npm/bash"
  cp "$FIX/pnpm" "$FIX/arc1-no-npm/pnpm"
  for mode in no-pnpm no-npm prefix workstation; do
    : >"$log"
    case "$mode" in
      no-pnpm) out=$(run_tools "$home" container "$BASE_PATH") ;;
      no-npm) out=$(run_tools "$home" container "$FIX/arc1-no-npm") ;;
      prefix) out=$(NPM_FAKE_PREFIX_FAIL=1 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") ;;
      workstation) out=$(NVM_INSTALL_URL="file://$TMP_ROOT/missing.sh" run_tools "$TMP_ROOT/arc1-workstation" workstation "$BASE_PATH") ;;
    esac && fail "a fatal prerequisite failure ($mode) was accepted: $out"
    assert_contains "$out" "$warning" "a fatal prerequisite failure ($mode) did not warn about the FAB write lane: $out"
    assert_contains "$out" "because the policy check did not run" "a fatal prerequisite failure ($mode) hid the skipped policy check: $out"
    case "$mode" in
      no-pnpm) assert_contains "$out" "pnpm not found on PATH" "the missing pnpm path was not exercised: $out" ;;
      no-npm) assert_contains "$out" "npm not found on PATH" "the missing npm path was not exercised: $out" ;;
      prefix) assert_contains "$out" "npm prefix -g failed" "the failed prefix path was not exercised: $out" ;;
      workstation) assert_contains "$out" "cannot install nvm" "the workstation setup failure was not exercised: $out" ;;
    esac
    [ ! -s "$log" ] || fail "a fatal prerequisite failure ($mode) invoked arc1-cli: $(cat "$log")"
  done
  pass "the arc-1 policy check is silent only for completed denial and warns on timeouts and prerequisite failures"
}

test_pnpm_policy() {
  local home="$TMP_ROOT/policy" file out shape setting
  mkdir -p "$home/pnpm/global"
  file="$home/pnpm/global/pnpm-workspace.yaml"
  printf '%s\n' 'packages:' '  - "apps/*"' 'allowBuilds:' '  geckodriver: true' '  "esbuild": false # keep this note' '  custom-native: true' "  '@scope/native': false" '  better-sqlite3: false' 'linkWorkspacePackages: false' 'catalog:' '  foo: latest' >"$file"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "an existing block policy was not repaired: $out"
  "$NODE_TOOLS_POLICY_CHECK" "$file" || fail "required policy values were not repaired"
  PATH="$NODE_TOOLS_TEST_PATH" "$REAL_PNPM" --dir "$(dirname "$file")" config list --json | "$REAL_NODE" -e '
const assert = require("node:assert/strict");
let input = "";
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  const config = JSON.parse(input);
  assert.deepEqual(config.allowBuilds, { "better-sqlite3": true, esbuild: true, edgedriver: false, geckodriver: false, "custom-native": true, "@scope/native": false });
  assert.deepEqual(config.packages, ["apps/*"]);
  assert.equal(config.linkWorkspacePackages, false);
  assert.deepEqual(config.catalog, { foo: "latest" });
});' || fail "repair changed unrelated policy entries or top-level settings"

  printf '%s\n' 'packages:' '  - "apps/*"' 'linkWorkspacePackages: false' >"$file"
  rm -rf "$home/pnpm/global/v11/h/node_modules/eslint"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a missing policy was not added: $out"
  "$NODE_TOOLS_POLICY_CHECK" "$file" || fail "added policy has incorrect values"
  setting=$(PATH="$NODE_TOOLS_TEST_PATH" "$REAL_PNPM" --dir "$(dirname "$file")" config get packages --json)
  "$REAL_NODE" -e 'require("node:assert/strict").deepEqual(JSON.parse(process.argv[1]), ["apps/*"])' "$setting" || fail "adding a policy changed existing settings"

  for shape in flow duplicate alias nested document indented; do
    case "$shape" in
      flow) printf '%s\n' 'allowBuilds: { esbuild: false }' >"$file" ;;
      duplicate) printf '%s\n' 'allowBuilds:' '  esbuild: true' '  esbuild: false' >"$file" ;;
      alias) printf '%s\n' 'allowBuilds:' '  esbuild: *build' >"$file" ;;
      nested) printf '%s\n' 'allowBuilds:' '  esbuild:' '    enabled: true' >"$file" ;;
      document) printf '%s\n' '---' 'allowBuilds:' '  esbuild: false' >"$file" ;;
      indented) printf '%s\n' '  allowBuilds:' '    esbuild: false' >"$file" ;;
    esac
    cp "$file" "$home/original.yaml"
    rm -rf "$home/pnpm/global/v11/h/node_modules/eslint"
    : >"$NODE_TOOLS_LOG"
    if out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
      fail "unsafe $shape policy was accepted: $out"
    fi
    assert_contains "$out" "warning: cannot safely set allowBuilds" "unsafe $shape policy did not warn: $out"
    cmp -s "$file" "$home/original.yaml" || fail "unsafe $shape policy was changed"
    assert_not_contains "$(calls)" "pnpm add" "unsafe $shape policy allowed an install"
    assert_contains "$(calls)" "$YO_SMOKE" "unsafe policy suppressed smoke checks"
  done

  printf '%s\n' 'allowBuilds: { geckodriver: false, esbuild: true, better-sqlite3: true, edgedriver: false }' >"$file"
  HOME="$home" PNPM_HOME="$home/pnpm" PATH="$FIX/image:$home/pnpm/bin:$BASE_PATH" "$FIX/pnpm" add -g eslint \
    || fail "the fake install guard rejected an equivalent flow-style policy"
  printf '%s\n' 'allowBuilds:' '  # better-sqlite3: true' '  # esbuild: true' '  # edgedriver: false' '  # geckodriver: false' >"$file"
  if HOME="$home" PNPM_HOME="$home/pnpm" PATH="$FIX/image:$home/pnpm/bin:$BASE_PATH" "$FIX/pnpm" add -g eslint >/dev/null 2>&1; then
    fail "the fake install guard accepted commented-out policy entries"
  fi
  pass "pnpm policy repairs required booleans, preserves unrelated settings, and leaves unsafe shapes untouched; assertions consume YAML semantically"
}

test_skill_pin_retries() {
  local home out source state entry field
  local pin=https://github.com/mattpocock/skills/tree/153fc1b93de6584562765cdce299324e1ff9e661/skills/engineering/resolving-merge-conflicts
  for source in vercel-labs/skills "$pin"; do
    for state in default xdg; do
      home="$TMP_ROOT/pin-${source##*/}-$state"
      mkdir -p "$home"
      if out=$(XDG_STATE_HOME=$([ "$state" = default ] || echo "$home/state") NPX_FAKE_FAIL_SOURCE="$source" PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
        fail "an interrupted skills install succeeded: $out"
      fi
      [ "$(cat "$home/.agents/skills/resolving-merge-conflicts/SKILL.md")" = unpinned ] || fail "the interrupted install did not reproduce the unpinned skill"
      : >"$NODE_TOOLS_LOG"
      out=$(XDG_STATE_HOME=$([ "$state" = default ] || echo "$home/state") PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a retry did not converge to the pin: $out"
      assert_contains "$(calls)" "npx --yes skills add $pin" "a retry skipped the pin after $source failed"
      [ "$(cat "$home/.agents/skills/resolving-merge-conflicts/SKILL.md")" = pinned ] || fail "a retry retained the unpinned skill"
      : >"$NODE_TOOLS_LOG"
      out=$(XDG_STATE_HOME=$([ "$state" = default ] || echo "$home/state") PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a converged pin was not idempotent: $out"
      [ "$(calls)" = "$QUIET_RERUN" ] && [ -z "$out" ] || fail "a converged pin was reinstalled: $(calls) $out"
    done
  done

  home="$TMP_ROOT/pin-skills-default"
  for field in missing malformed ref source sourceType sourceUrl version; do
    entry="$home/.agents/.skill-lock.json"
    case "$field" in
      missing) rm -f "$entry" ;;
      malformed) echo '{' >"$entry" ;;
      *) "$REAL_NODE" - "$entry" "$field" <<'JS'
const fs = require('node:fs');
const [file, field] = process.argv.slice(2);
const lock = JSON.parse(fs.readFileSync(file, 'utf8'));
if (field === 'version') lock.version = 2;
else lock.skills['resolving-merge-conflicts'][field] = 'wrong';
fs.writeFileSync(file, JSON.stringify(lock));
JS
      ;;
    esac
    : >"$NODE_TOOLS_LOG"
    out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "invalid $field metadata was not repaired: $out"
    assert_contains "$(calls)" "npx --yes skills add $pin" "invalid $field metadata bypassed the pin"
  done
  rm -f "$home/.agents/skills/resolving-merge-conflicts/SKILL.md"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a missing pinned skill was not restored: $out"
  if out=$(NPX_FAKE_SKIP_PIN_LOCK=1 PNPM_HOME="$TMP_ROOT/pin-no-lock/pnpm" run_tools "$TMP_ROOT/pin-no-lock" container "$FIX/image:$BASE_PATH"); then
    fail "a pin install without matching lock metadata was accepted: $out"
  fi
  assert_contains "$out" "lock metadata does not identify the pinned source and revision" "a pin without metadata was not reported: $out"
  pass "interrupted skill installs converge on retry; the pin requires its file and source/revision metadata, including XDG state"
}

test_bash_tools_failures() {
  local home out

  home="$TMP_ROOT/bt-noherdr"
  if out=$(HERDR_INSTALL_URL="file://$TMP_ROOT/missing.sh" run_bash_tools "$home" "$FIX/image:$BASE_PATH"); then
    fail "bash-tools without herdr's install script succeeded: $out"
  fi
  assert_contains "$out" "cannot install herdr" "a failed herdr download is not reported: $out"
  [ -x "$home/.local/bin/agy" ] && [ -x "$home/.local/bin/claude" ] || fail "a failed herdr install stopped the other installers"

  if out=$(PI_INSTALL_URL="file://$TMP_ROOT/missing.sh" run_bash_tools "$TMP_ROOT/bt-nopi" "$FIX/image:$BASE_PATH"); then
    fail "bash-tools offline succeeded: $out"
  fi
  assert_contains "$out" "cannot download the Pi installer" "an offline Pi install is not reported clearly: $out"

  if out=$(COPILOT_INSTALL_URL="file://$TMP_ROOT/missing.sh" run_bash_tools "$TMP_ROOT/bt-nocopilot" "$FIX/image:$BASE_PATH"); then
    fail "bash-tools without Copilot's install script succeeded: $out"
  fi
  assert_contains "$out" "cannot install the GitHub Copilot CLI" "a failed Copilot download is not reported: $out"

  if out=$(CLAUDE_INSTALL_URL="file://$TMP_ROOT/missing.sh" run_bash_tools "$TMP_ROOT/bt-noclaude" "$FIX/image:$BASE_PATH"); then
    fail "bash-tools without Claude Code's install script succeeded: $out"
  fi
  assert_contains "$out" "cannot install Claude Code" "a failed Claude Code download is not reported: $out"

  home="$TMP_ROOT/bt-noagy"
  if out=$(ANTIGRAVITY_INSTALL_URL="file://$TMP_ROOT/missing.sh" run_bash_tools "$home" "$FIX/image:$BASE_PATH"); then
    fail "bash-tools without Antigravity's install script succeeded: $out"
  fi
  assert_contains "$out" "cannot download the Antigravity installer" "a failed Antigravity download is not reported: $out"
  [ -x "$home/.local/bin/claude" ] || fail "a failed Antigravity download stopped the other installers"

  home="$TMP_ROOT/bt-agyfail"
  if out=$(AGY_FAKE_FAIL=1 run_bash_tools "$home" "$FIX/image:$BASE_PATH"); then
    fail "a failing Antigravity installer was accepted: $out"
  fi
  assert_contains "$out" "Could not connect to the release server" "the Antigravity installer's own error is hidden: $out"
  assert_contains "$out" "the Antigravity installer from" "a failed Antigravity install is not reported: $out"
  assert_contains "$out" "failed: antigravity" "the failed step is not named: $out"
  pass "bash-tools reports each failed installer without stopping the others"
}

test_antigravity_scratch_home() {
  local home="$TMP_ROOT/agy" out scratch
  mkdir -p "$home"
  # The rc files Home Manager owns, which the real installer would append to.
  for rc in .zshrc .bashrc .profile; do echo "# mine" >"$home/$rc"; done
  : >"$NODE_TOOLS_LOG"
  out=$(TMPDIR="$TMP_ROOT" run_bash_tools "$home" "$FIX/image:$BASE_PATH") || fail "bash-tools failed: $out"
  scratch=$(cat "$NODE_TOOLS_LOG.agy-home")
  [ -n "$scratch" ] && [ "$scratch" != "$home" ] || fail "Antigravity's installer did not get a scratch HOME: $scratch"
  [ ! -e "$scratch" ] || fail "Antigravity's scratch HOME was not removed: $scratch"
  assert_contains "$(calls)" "antigravity-installer tty=no dir=$home/.local/bin" "Antigravity's installer did not run without a terminal into ~/.local/bin: $(calls)"
  [ "$("$home/.local/bin/agy" --version)" = agy-fake ] || fail "agy is not in the real ~/.local/bin"
  for rc in .zshrc .bashrc .profile; do
    [ "$(cat "$home/$rc")" = "# mine" ] || fail "Antigravity's installer changed $home/$rc"
  done
  pass "Antigravity's installer runs in a scratch HOME without a terminal with --dir ~/.local/bin: agy lands there and no real rc file changes"
}

# antigravity.google intermittently answers with a gzip-encoded body even when
# the request offered no gzip, and plain curl saves those bytes undecoded.
# A fake curl plays that server for one URL: without --compressed it saves the
# gzipped installer, with it the decoded script; any other URL goes to real curl.
test_antigravity_gzip_download() {
  local home="$TMP_ROOT/agy-gzip" real_curl out url=https://antigravity-gzip.invalid/cli/install.sh
  mkdir -p "$home" "$FIX/gzip-curl"
  real_curl=$(command -v curl)
  gzip -c <"$FIX/antigravity-install.sh" >"$FIX/gzip-curl/install.sh.gz"
  cat >"$FIX/gzip-curl/curl" <<CURL
#!/bin/bash
hit=no out= compressed=no prev=
for arg in "\$@"; do
  case "\$arg" in
    --compressed) compressed=yes ;;
    $url) hit=yes ;;
  esac
  [ "\$prev" != -o ] || out=\$arg
  prev=\$arg
done
[ "\$hit" = yes ] || exec "$real_curl" "\$@"
[ -n "\$out" ] || { echo "fake curl: expected -o" >&2; exit 2; }
if [ "\$compressed" = yes ]; then
  gzip -dc "$FIX/gzip-curl/install.sh.gz" >"\$out"
else
  cp "$FIX/gzip-curl/install.sh.gz" "\$out"
fi
CURL
  chmod +x "$FIX/gzip-curl/curl"
  : >"$NODE_TOOLS_LOG"
  out=$(ANTIGRAVITY_INSTALL_URL=$url run_bash_tools "$home" "$FIX/gzip-curl:$FIX/image:$BASE_PATH") \
    || fail "a gzip-encoded Antigravity installer was not installed: $out"
  [ "$("$home/.local/bin/agy" --version)" = agy-fake ] || fail "agy is missing after a gzip-encoded installer download"
  assert_contains "$(calls)" "antigravity-installer" "the decoded Antigravity installer did not run: $(calls)"
  pass "a gzip-encoded Antigravity installer download is decoded (curl --compressed) and installs agy"
}

# Installs package $2 (with optional flags $3...) with the fake pnpm into scratch
# pnpm home $1, after the allowBuilds file that the fake pnpm requires.
pnpm_seed() {
  local pnpm_home=$1 pkg=$2
  mkdir -p "$pnpm_home/global"
  printf 'allowBuilds:\n  better-sqlite3: true\n  esbuild: true\n  edgedriver: false\n  geckodriver: false\n' >"$pnpm_home/global/pnpm-workspace.yaml"
  PNPM_HOME="$pnpm_home" PATH="$pnpm_home/bin:$FIX/image:$BASE_PATH" pnpm add -g "$pkg"
}

test_migrate_pnpm_copies() {
  local home="$TMP_ROOT/migrate" out pnpm_bin
  mkdir -p "$home"
  pnpm_bin="$home/pnpm-home/bin"
  # What an older switch left: pnpm's Pi and Copilot, with a Windows pi on
  # WSL's PATH.
  pnpm_seed "$home/pnpm-home" @earendil-works/pi-coding-agent
  pnpm_seed "$home/pnpm-home" @github/copilot

  # Without Pi's installer, pnpm's Pi keeps working.
  : >"$NODE_TOOLS_LOG"
  if out=$(PI_INSTALL_URL="file://$TMP_ROOT/missing.sh" PNPM_HOME="$home/pnpm-home" \
    run_bash_tools "$home" "$FIX/image:$BASE_PATH"); then
    fail "an offline migration succeeded: $out"
  fi
  [ -x "$pnpm_bin/pi" ] || fail "an offline migration removed pnpm's Pi"
  assert_not_contains "$(calls)" "pnpm remove -g @earendil-works" "an offline migration removed pnpm's Pi: $(calls)"

  # The other installers ran anyway, so start over with both pnpm copies.
  rm -rf "$home/.local" "$home/.pi"
  pnpm_seed "$home/pnpm-home" @github/copilot
  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm-home" run_bash_tools "$home" "$FIX/image:$BASE_PATH:$WINDOWS_NPM") \
    || fail "migrating pnpm's Pi and Copilot failed: $out"
  [ "$(calls)" = "$HERDR_INSTALL
$PI_INSTALL
$PI_REMOVE
$COPILOT_INSTALL
$COPILOT_REMOVE
$CLAUDE_INSTALL
$(agy_install_line "$home")
$TREEHOUSE_INSTALL" ] || fail "migration did not remove pnpm's Pi and Copilot each right after its installer: $(calls)"
  for tool in pi copilot; do
    [ ! -e "$pnpm_bin/$tool" ] || fail "migration left pnpm's $tool"
    [ "$("$home/.local/bin/$tool" --version)" = "$tool-fake" ] || fail "$tool does not run from ~/.local/bin after migration"
  done
  pass "a container with pnpm's Pi and Copilot and a Windows pi ends with only the installers' copies in ~/.local/bin; an offline switch keeps pnpm's Pi"
}

test_pi_installer_failure() {
  local home="$TMP_ROOT/pi-fail" out pnpm_bin
  mkdir -p "$home"
  pnpm_bin="$home/pnpm/bin"
  pnpm_seed "$home/pnpm" @earendil-works/pi-coding-agent
  : >"$NODE_TOOLS_LOG"
  if out=$(PI_FAKE_FAIL=1 PNPM_HOME="$home/pnpm" run_bash_tools "$home" "$FIX/image:$BASE_PATH"); then
    fail "a failing Pi installer was accepted: $out"
  fi
  assert_contains "$out" "Pi requires Node.js 22.19.0" "the Pi installer's own error is hidden: $out"
  assert_contains "$out" "cannot install Pi from" "a failed Pi install is not reported: $out"
  [ "$("$pnpm_bin/pi")" = pnpm-pi-fake ] || fail "a failing Pi installer removed pnpm's Pi"
  assert_not_contains "$(calls)" "pnpm remove" "a failing Pi installer removed something: $(calls)"
  pass "a failing Pi installer shows its own output, fails the run, and keeps pnpm's Pi"
}

test_cli_must_run() {
  local tool home out url_var
  for tool in herdr claude agy; do
    home="$TMP_ROOT/$tool-broken"
    mkdir -p "$home"
    # An installer that leaves a binary which cannot run.
    cat >"$FIX/$tool-broken.sh" <<EOF
dir=\$HOME/.local/bin
[ "\${1-}" != --dir ] || dir=\$2
mkdir -p "\$dir"
printf '#!/bin/sh\\nexit 1\\n' >"\$dir/$tool"
chmod +x "\$dir/$tool"
EOF
    case "$tool" in
      agy) url_var=ANTIGRAVITY_INSTALL_URL ;;
      *) url_var="$(tr '[:lower:]' '[:upper:]' <<<"$tool")_INSTALL_URL" ;;
    esac
    if out=$(export "$url_var=file://$FIX/$tool-broken.sh"; PNPM_HOME="$home/pnpm" \
      run_bash_tools "$home" "$FIX/image:$BASE_PATH"); then
      fail "a $tool that does not run was accepted: $out"
    fi
    assert_contains "$out" "$tool --version fails after" "a broken $tool is not reported: $out"
  done
  pass "a herdr, Claude Code, or Antigravity that does not answer --version after it is installed fails the run"
}

# herdr's real installer, as a switch runs it, in a scratch HOME.
test_real_herdr_installer() {
  local home="$TMP_ROOT/herdr-real" latest out
  latest=$(curl -fsSL --connect-timeout 10 https://herdr.dev/latest.json 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
  [ -n "$latest" ] || { echo "skip: https://herdr.dev is unreachable"; return 0; }
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  out=$(HERDR_INSTALL_URL=https://herdr.dev/install.sh PNPM_HOME="$home/pnpm" \
    run_bash_tools "$home" "$FIX/image:$BASE_PATH") || fail "herdr's real installer failed: $out"
  [ "$(calls)" = "$PI_INSTALL
$COPILOT_INSTALL
$CLAUDE_INSTALL
$(agy_install_line "$home")
$TREEHOUSE_INSTALL" ] || fail "the real herdr install ran fakes other than the Pi, Copilot, Claude Code, Antigravity, and treehouse installers: $(calls)"
  [ "$(HOME=$home "$home/.local/bin/herdr" --version </dev/null)" = "herdr $latest" ] \
    || fail "$home/.local/bin/herdr is not herdr's latest release $latest"
  [ "$(HOME=$home HERDR_CONFIG_PATH="$ROOT/home/.config/herdr/config.toml" "$home/.local/bin/herdr" config check </dev/null)" = "config: ok" ] \
    || fail "herdr rejects home/.config/herdr/config.toml"
  for rc in .bashrc .bash_profile .profile .zshrc .zprofile .zshenv; do
    [ ! -e "$home/$rc" ] || fail "herdr's installer wrote $rc, which Home Manager owns"
  done

  : >"$NODE_TOOLS_LOG"
  out=$(HERDR_INSTALL_URL=https://herdr.dev/install.sh PNPM_HOME="$home/pnpm" \
    run_bash_tools "$home" "$FIX/image:$BASE_PATH") || fail "a re-run after the real herdr install failed: $out"
  [ -z "$(calls)$out" ] || fail "a re-run after the real herdr install was not a quiet no-op: $(calls) $out"
  pass "herdr's real installer puts herdr $latest at ~/.local/bin/herdr, which accepts the repo's herdr config; re-runs keep it and print nothing"
}

# --- Home Manager ---------------------------------------------------------------

have_linux_nix() {
  if [ "$(uname -s)" != Linux ] || ! command -v nix >/dev/null 2>&1; then
    echo "skip: needs Nix on Linux"
    return 1
  fi
}

SYSTEM=
WS=
CT=
profiles_init() {
  [ -n "$SYSTEM" ] && return 0
  SYSTEM=$(nix eval --impure --raw --expr builtins.currentSystem)
  WS="dev@$SYSTEM"
  CT="node@container-$SYSTEM"
}

hm_eval() {
  nix eval "$@" 2>/dev/null
}

# Runs profile $1's activation snippet $4 (nodeTools or bashTools) the way the
# activation script does (HM's run and warnEcho, errexit), with scratch HOME $2
# and PATH $3.
run_activation() {
  local profile=$1 home=$2 path=$3 name=$4 snippet
  snippet=$(hm_eval --raw "$ROOT#homeConfigurations.\"$profile\".config.home.activation.$name.data") \
    || fail "$profile: no $name activation"
  HOME=$home PATH=$path bash -c '
    set -eu -o pipefail
    run() { "$@"; }
    warnEcho() { echo "WARN: $*"; }
    eval "$1"
    echo "switch continues"' _ "$snippet" 2>&1
}

test_activation() {
  local out after empty home name
  have_linux_nix || return 0
  profiles_init
  # Realize the activation's tool PATH.
  nix build --no-link "$ROOT#homeConfigurations.\"$WS\".activationPackage" \
    "$ROOT#homeConfigurations.\"$CT\".activationPackage" 2>/dev/null || fail "activation packages do not build"
  for profile in "$WS" "$CT"; do
    after=$(hm_eval --json "$ROOT#homeConfigurations.\"$profile\".config.home.activation.nodeTools.after")
    [ "$after" = '["writeBoundary"]' ] || fail "$profile: nodeTools does not run after writeBoundary: $after"
    after=$(hm_eval --json "$ROOT#homeConfigurations.\"$profile\".config.home.activation.bashTools.after")
    [ "$after" = '["writeBoundary","nodeTools"]' ] || fail "$profile: bashTools does not run after writeBoundary and nodeTools: $after"
    empty=$(hm_eval --json "$ROOT#homeConfigurations.\"$profile\".config.home.emptyActivationPath")
    case "$profile" in
      *@container-*) [ "$empty" = false ] || fail "$profile: activation drops the image's PATH" ;;
      *) [ "$empty" = true ] || fail "$profile: workstation activation inherits the user's PATH" ;;
    esac
  done

  home="$TMP_ROOT/act-ws"
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  for name in nodeTools bashTools; do
    out=$(run_activation "$WS" "$home" "$BASE_PATH" $name) || fail "$WS: $name activation failed: $out"
    assert_not_contains "$out" "WARN" "$WS: a working $name activation warns: $out"
  done
  assert_contains "$(calls)" "nvm install --lts" "$WS: activation did not provision Node.js: $(calls)"
  assert_contains "$(calls)" "$NPM_ADD" "$WS: activation did not install the npm globals: $(calls)"
  assert_contains "$(calls)" "$HERDR_INSTALL" "$WS: activation did not install herdr: $(calls)"
  assert_contains "$(calls)" "$CLAUDE_INSTALL" "$WS: activation did not install Claude Code: $(calls)"
  assert_contains "$(calls)" "antigravity-installer" "$WS: activation did not install Antigravity: $(calls)"
  case "$(calls)" in
    *"npm install -g pnpm"*"antigravity-installer"*) ;;
    *) fail "$WS: Node.js did not come before the curl installers: $(calls)" ;;
  esac

  home="$TMP_ROOT/act-ct"
  mkdir -p "$home"
  out=$(PNPM_HOME="$home/pnpm" run_activation "$CT" "$home" "$BASE_PATH" nodeTools) \
    || fail "$CT: activation without pnpm failed the switch: $out"
  assert_contains "$out" "pnpm not found on PATH" "$CT: activation hides why it failed: $out"
  assert_contains "$out" "the FAB write lane is unsafe with this ARC-1 install: deny list is unproven because the policy check did not run" "$CT: activation hid the unproven FAB policy: $out"
  assert_contains "$out" "WARN: tools/node-tools.sh failed" "$CT: activation does not warn: $out"
  assert_contains "$out" "switch continues" "$CT: activation stopped the switch: $out"
  out=$(PNPM_HOME="$home/pnpm" HERDR_INSTALL_URL="file://$TMP_ROOT/missing.sh" run_activation "$CT" "$home" "$BASE_PATH" bashTools) \
    || fail "$CT: a failing bashTools activation failed the switch: $out"
  assert_contains "$out" "WARN: tools/bash-tools.sh failed" "$CT: the bashTools activation does not warn: $out"
  assert_contains "$out" "switch continues" "$CT: the bashTools activation stopped the switch: $out"
  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm" run_activation "$CT" "$home" "$FIX/image:$BASE_PATH" nodeTools) \
    || fail "$CT: activation with the image's pnpm failed: $out"
  [ "$(calls)" = "$NODE_INSTALLS" ] || fail "$CT: activation did not use the image's pnpm and npm: $(calls)"
  pass "nodeTools then bashTools run after writeBoundary in both profiles, use the container's own pnpm, and only warn on failure"
}

# --- shells ---------------------------------------------------------------------

TOOLS="herdr node npm pnpm claude pi copilot agy"

# Checks shell $2's report $3 (NAME=first match, rawpath=PATH, then path=DIR lines) for
# profile $1 in scratch HOME $4: herdr, claude, pi, copilot, and agy are the
# installers' launchers in ~/.local/bin, not the Nix-built herdr left in
# ~/.nix-profile/bin, node, npm, and pnpm are from $5 on the workstation, and
# ~/.local/bin, the nvm default bin (workstation) or ~/.npm-global/bin
# (container), and the pnpm dirs sit right
# before ~/.nix-profile/bin, once each, and PATH has no empty entry.
check_shell() {
  local profile=$1 shell=$2 out=$3 home=$4 node_dir=${5-} tool dir front path
  local pnpm_home="$home/.local/share/pnpm"
  for tool in herdr claude pi copilot agy; do
    grep -qxF "$tool=$home/.local/bin/$tool" <<<"$out" || fail "$profile $shell: $tool is not its installer's launcher: $out"
  done
  front="$pnpm_home/bin:$pnpm_home"
  case "$profile" in
    *@container-*)
      assert_not_contains "$out" "$home/.nvm" "$profile $shell: the container puts nvm on PATH: $out"
      front="$home/.npm-global/bin:$front"
      ;;
    *)
      for tool in node npm pnpm; do
        grep -qxF "$tool=$node_dir/$tool" <<<"$out" || fail "$profile $shell: $tool is not from $node_dir: $out"
      done
      front="$home/.nvm/default/bin:$front"
      ;;
  esac
  front="$home/.local/bin:$front"
  case "$(sed -n 's/^rawpath=//p' <<<"$out")" in
    "" | :* | *: | *::*) fail "$profile $shell: PATH is empty or has an empty entry: $out" ;;
  esac
  path=":$(sed -n 's/^path=//p' <<<"$out" | tr '\n' ':')"
  assert_contains "$path" ":$front:$home/.nix-profile/bin:" "$profile $shell: $front is not right before ~/.nix-profile/bin: $path"
  for dir in ${front//:/ }; do
    [ "$(grep -cxF "path=$dir" <<<"$out")" = 1 ] || fail "$profile $shell: $dir is not on PATH exactly once: $path"
  done
}

test_shell_path() {
  local files home out profile tool win start node_default
  have_linux_nix || return 0
  command -v zsh >/dev/null 2>&1 || { echo "skip: zsh not found"; return 0; }
  profiles_init
  # WSL appends the Windows PATH, which can hold extensionless npm shims.
  win="$TMP_ROOT/mnt/c/Users/dev/AppData/Roaming/npm"
  mkdir -p "$win"
  for tool in $TOOLS; do
    printf '#!/bin/sh\necho windows-%s\n' "$tool" >"$win/$tool"
    chmod +x "$win/$tool"
  done
  for profile in "$WS" "$CT"; do
    files=$(nix build --no-link --print-out-paths "$ROOT#homeConfigurations.\"$profile\".config.home-files" 2>/dev/null) \
      || fail "$profile: home-files build failed"
    home="$TMP_ROOT/sh-${profile//[@\/]/-}"
    # The Nix-built herdr an older switch installed.
    mkdir -p "$home/.nix-profile/bin"
    printf '#!/bin/sh\necho nix-herdr\n' >"$home/.nix-profile/bin/herdr"
    chmod +x "$home/.nix-profile/bin/herdr"
    case "$profile" in
      *@container-*)
        PNPM_HOME="$home/.local/share/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH" >/dev/null \
          && PNPM_HOME="$home/.local/share/pnpm" run_bash_tools "$home" "$FIX/image:$BASE_PATH" >/dev/null
        ;;
      *)
        run_tools "$home" workstation "$BASE_PATH" >/dev/null && run_bash_tools "$home" "$BASE_PATH" >/dev/null
        ;;
    esac || fail "$profile: could not lay out the fake tools"
    # shellcheck disable=SC2016 # expanded by the scratch zsh, not here
    { cat "$files/.zshrc"; echo 'HISTFILE="$HOME/.zsh_history"'; } >"$home/.zshrc"
    cp -L "$files/.zshenv" "$home/.zshenv"
    cp -L "$files/.bash_profile" "$home/.bash_profile"
    start="$home/.nix-profile/bin:$BASE_PATH:$win"
    node_default="$home/.nvm/default/bin"

    # A fresh environment, as a new terminal or `wsl.exe -e` gets, then one
    # from a process started before this config (a herdr or tmux server) that
    # marks Home Manager's session variables as sourced but has no PNPM_HOME
    # or NVM_DIR. zsh -d and bash --noprofile skip the host's global rc files
    # (a devcontainer's set their own NVM_DIR and PATH), leaving only the
    # generated ones; the bash login shell then reads ~/.bash_profile as it
    # would without them.
    for stale in "" "__HM_SESS_VARS_SOURCED=1 __HM_ZSH_SESS_VARS_SOURCED=1"; do
      # shellcheck disable=SC2016,SC2086 # expanded by the scratch zsh; $stale splits into assignments
      out=$(env -i $stale HOME="$home" ZDOTDIR="$home" TERM=xterm PATH="$start" zsh -d -i -c \
        'for c in '"$TOOLS"'; do print -r -- "$c=$(whence -p $c)"; done; print -r -- "rawpath=$PATH"; for p in $path; do print -r -- "path=$p"; done; print -r -- "herdr-completion=${_comps[herdr]-}"' \
        </dev/null 2>/dev/null)
      check_shell "$profile" "interactive zsh${stale:+ ($stale)}" "$out" "$home" "$home/.nvm/versions/node/$FAKE_NODE/bin"
      grep -qxF "herdr-completion=_herdr" <<<"$out" || fail "$profile interactive zsh${stale:+ ($stale)}: herdr's completions are not loaded: $out"
      # shellcheck disable=SC2016,SC2086 # expanded by the scratch zsh; $stale splits into assignments
      out=$(env -i $stale HOME="$home" ZDOTDIR="$home" PATH="$start" zsh -d -c \
        'for c in '"$TOOLS"'; do print -r -- "$c=$(whence -p $c)"; done; print -r -- "rawpath=$PATH"; for p in $path; do print -r -- "path=$p"; done' \
        </dev/null 2>/dev/null)
      check_shell "$profile" "zsh -c${stale:+ ($stale)}" "$out" "$home" "$node_default"
      # shellcheck disable=SC2016,SC2086 # expanded by the scratch bash; $stale splits into assignments
      out=$(env -i $stale HOME="$home" PATH="$start" bash --noprofile -l -c \
        '. "$HOME/.bash_profile"; for c in '"$TOOLS"'; do echo "$c=$(type -P $c)"; done; echo "rawpath=$PATH"; IFS=:; for p in $PATH; do echo "path=$p"; done' \
        </dev/null 2>/dev/null)
      check_shell "$profile" "bash login${stale:+ ($stale)}" "$out" "$home" "$node_default"
    done
  done
  pass "in both profiles every zsh and a bash login shell, fresh or from an environment that already sourced the session variables, run herdr, claude, pi, copilot, and agy from ~/.local/bin, with pnpm's global bins, right before ~/.nix-profile/bin and ahead of its leftover herdr and of system and Windows copies, once each; the workstation adds nvm's default node, npm, and pnpm there and the container ~/.npm-global/bin, and its interactive zsh loads nvm; the interactive zsh loads herdr's completions"
}

test_workstation_fresh_then_quiet
test_only_missing_is_installed
test_container_and_failures
test_step_failures_do_not_block
test_smoke_checks_warn
test_axi_tools
test_lavish_skill
test_backpass_tools
test_paseo
test_axi_hooks
test_treehouse
test_arc1_policy_check
test_pnpm_policy
test_skill_pin_retries
test_bash_tools_failures
test_antigravity_scratch_home
test_antigravity_gzip_download
test_migrate_pnpm_copies
test_pi_installer_failure
test_cli_must_run
test_real_herdr_installer
test_activation
test_shell_path
