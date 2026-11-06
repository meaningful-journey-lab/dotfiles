#!/usr/bin/env bash
# The npm and pnpm tools that Home Manager installs at switch time on Linux
# (home.nix `home.activation.nodeTools`), outside the Nix store, unpinned
# (@latest), in both profiles (workstation and container). The curl-installer
# CLIs are installed by tools/bash-tools.sh, which runs after this script.
#
# Node.js and pnpm first:
# - workstation (WSL2): nvm from its official install script, then Node.js LTS
#   with npm as nvm's default, then pnpm, the way Microsoft's Node.js on WSL
#   guide does it
#   (https://learn.microsoft.com/en-us/windows/dev-environment/javascript/nodejs-on-wsl).
#   It also points $NVM_DIR/default at nvm's default Node.js, so shells that do
#   not load nvm (home.nix puts $NVM_DIR/default/bin on PATH) still find node,
#   npm, and pnpm;
# - container: the devcontainer image's own Node.js and pnpm.
#
# Then, each on that Node.js:
# - pnpm globals: see PNPM_PACKAGES for the install list and README.md's
#   "Upstream CLI tools" section for the devcontainer MCP launch contract.
#   pnpm's global directory gets a pnpm-workspace.yaml first, with allowBuilds
#   for packages whose build scripts may run (better-sqlite3, esbuild) or not
#   (edgedriver, geckodriver);
# - npm globals: mbt, mta, yo, generator-easy-ui5, @sap-ux/generator-adp,
#   @sap/generator-adaptation-project, @sap/generator-add-hdb-module,
#   @sap/generator-aicore, @sap/generator-base-mta-module,
#   @sap/generator-cap-project, @sap/generator-fiori, installed with
#   --allow-scripts=mbt,mta (only they run install scripts). They go to npm,
#   not pnpm, because yo only discovers generators under npm's global prefix.
#   On amd64 also @sap/cf-tools-local (--allow-scripts=@sap/cf-tools-local);
# - the AXI tools Firstmate uses: gh-axi, chrome-devtools-axi, lavish-axi,
#   tasks-axi, and quota-axi, also npm globals but installed at @latest when
#   missing or below the version floors in AXI_TOOLS (never downgraded or
#   pinned), and backpass with the acpx it needs, installed the same way
#   (BACKPASS_TOOLS). For the Paseo CLI's refresh policy, see README.md's "Upstream
#   CLI tools" section. Then `setup hooks`
#   for gh-axi, chrome-devtools-axi, and lavish-axi, which writes SessionStart
#   hooks for Claude Code, Codex, OpenCode (and, for lavish-axi, the Copilot
#   CLI). Claude Code's settings.json is Home Manager's (home/.claude/
#   settings.json declares those three hooks), so the script puts it back
#   exactly as it was;
# - agent skills for every agent (`npx --yes skills add ... --agent universal
#   --yes --global`, which fills ~/.agents/skills): arc-mcp/arc-1,
#   mattpocock/skills, vercel-labs/skills (find-skills only), and the
#   mattpocock resolving-merge-conflicts skill at a pinned commit, and the
#   no-mistakes skill at the release tag of the installed no-mistakes CLI
#   (byte-identical to what `no-mistakes init` writes for that release), again
#   whenever that version changes.
#   --agent universal is required (--yes alone targets 50+ agent config
#   directories), and the CLI reads owner/repo@X as a skill name, so there is
#   no @latest;
# - the bundled lavish skill (ensure_lavish_skill); see README.md's
#   "Upstream CLI tools" section for linking and refresh behavior.
#
# npm's global prefix: on the container $NPM_CONFIG_PREFIX, which the image
# sets to ~/.npm-global (home.nix and this script default to it too; its bin
# is on PATH); on the workstation nvm's default Node.js directory (nvm refuses
# NPM_CONFIG_PREFIX), whose bin is $NVM_DIR/default/bin on PATH. A later
# default Node.js has its own prefix, so the next switch installs the npm
# globals into it.
#
# For presence and pin checks, re-switch behavior, and refresh guidance, see
# README.md's "Upstream CLI tools" section.
#
# For smoke-check behavior and FAB policy warnings, see README.md's
# "Upstream CLI tools" section; arc1_policy_check handles policy isolation.
# A failing step does not stop the others; the script then exits non-zero with
# one message per failure, which the Home Manager activation turns into a
# warning so the switch still completes. Not having Node.js or pnpm stops it.
# Usage: tools/node-tools.sh workstation|container
# NVM_DIR (default ~/.nvm), PNPM_HOME (default ${XDG_DATA_HOME:-~/.local/share}/pnpm,
# as pnpm itself), NPM_CONFIG_PREFIX (container only, default ~/.npm-global),
# and NVM_INSTALL_URL can be overridden; the tests point them at local
# fixtures.
set -euo pipefail

NVM_VERSION=v0.40.8
NVM_INSTALL_URL=${NVM_INSTALL_URL:-https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh}
# home.nix sets the same defaults for the shells (nodePath).
export NVM_DIR=${NVM_DIR:-$HOME/.nvm}
export PNPM_HOME=${PNPM_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/pnpm}

PNPM_PACKAGES=(arc-1@latest npm-run-all eslint npm-check-updates @ui5/cli @sap/cds-dk @sap/cf-tools
  @sap/ux-ui5-tooling @sap/html5-app-deployer odata-openapi @wdio/cli
  @ui5/mcp-server @sap-ux/fiori-mcp-server @playwright/mcp sap-note-search-mcp)
NPM_PACKAGES=(mbt mta yo generator-easy-ui5 @sap-ux/generator-adp @sap/generator-adaptation-project
  @sap/generator-add-hdb-module @sap/generator-aicore @sap/generator-base-mta-module
  @sap/generator-cap-project @sap/generator-fiori)
# What `yo --generators` lists for each generator package above.
YO_NAMESPACES=(easy-ui5 @sap-ux/adp @sap/adaptation-project @sap/add-hdb-module @sap/aicore
  @sap/base-mta-module @sap/cap-project @sap/fiori)
MATTPOCOCK_RESOLVING_MERGE_CONFLICTS=https://github.com/mattpocock/skills/tree/153fc1b93de6584562765cdce299324e1ff9e661/skills/engineering/resolving-merge-conflicts
# The no-mistakes skill ships in the CLI's own repository, one tag per release;
# ensure_no_mistakes_skill installs the tag of the installed CLI and records it here.
NO_MISTAKES_SKILL_REPO=https://github.com/kunchenguid/no-mistakes
NO_MISTAKES_SKILL_MARKER=${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/no-mistakes-skill-version
SKILLS_DIR=$HOME/.agents/skills
# tool:minimum version.
AXI_TOOLS=(gh-axi:0.1.29 chrome-devtools-axi:0.1.23 lavish-axi:0.1.80 tasks-axi:0.2.6 quota-axi:0.1.51)
AXI_HOOK_TOOLS=(gh-axi chrome-devtools-axi lavish-axi)
# backpass (agent memory review) and the acpx it drives, tool:minimum version.
# For Node.js prerequisites and profile provisioning, see README.md's
# "Upstream CLI tools" section.
BACKPASS_TOOLS=(backpass:0.1.41 acpx:0.21.1)
# The Paseo CLI package and the oldest version the worker orchestration accepts.
PASEO_PACKAGE=@getpaseo/cli
PASEO_MIN=0.8.0

problems=()

say() {
  printf 'node-tools: %s\n' "$*"
}

die() {
  printf 'node-tools: %s\n' "$*" >&2
  warn "the FAB write lane is unsafe with this ARC-1 install: deny list is unproven because the policy check did not run"
  exit 1
}

# Reports a failed step on stderr and returns non-zero, so `step` records it.
oops() {
  printf 'node-tools: %s\n' "$*" >&2
  return 1
}

# Reports a smoke check that failed, without blocking anything.
warn() {
  printf 'node-tools: warning: %s\n' "$*" >&2
  case " ${problems[*]-} " in *" smoke_checks "*) ;; *) problems+=(smoke_checks) ;; esac
}

# Runs install step $1, keeps going after a failure, and remembers it.
step() {
  "$@" || problems+=("$1")
}

# nvm is written for interactive shells, not errexit/nounset: run it without them.
nvm_run() {
  local status=0
  set +eu
  nvm "$@"
  status=$?
  set -eu
  return "$status"
}

ensure_nvm() {
  [ ! -s "$NVM_DIR/nvm.sh" ] || return 0
  command -v curl >/dev/null 2>&1 || die "curl is required to install nvm"
  say "installing nvm $NVM_VERSION into $NVM_DIR"
  # The installer refuses a custom NVM_DIR that does not exist yet.
  mkdir -p "$NVM_DIR"
  # PROFILE=/dev/null keeps the installer out of the shell rc files; home.nix
  # sets NVM_DIR and PATH for every shell and loads nvm in the workstation zsh.
  curl -fsSL --proto-redir '=https' "$NVM_INSTALL_URL" | PROFILE=/dev/null bash >/dev/null \
    || die "cannot install nvm from $NVM_INSTALL_URL (offline?)"
  [ -s "$NVM_DIR/nvm.sh" ] || die "the nvm install script did not create $NVM_DIR/nvm.sh"
}

load_nvm() {
  set +eu
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh" --no-use
  set -eu
  command -v nvm >/dev/null 2>&1 || die "$NVM_DIR/nvm.sh did not define nvm"
}

# A default Node.js (Node.js LTS on a fresh install), active in this process
# and linked from $NVM_DIR/default.
ensure_node() {
  local default bin
  default=$(nvm_run version default 2>/dev/null || true)
  if [[ $default != v* ]]; then
    say "installing Node.js LTS with nvm"
    nvm_run install --lts --no-progress >/dev/null || die "nvm install --lts failed (offline?)"
    nvm_run alias default 'lts/*' >/dev/null || die "cannot make Node.js LTS nvm's default"
  fi
  nvm_run use --silent default || die "cannot switch to nvm's default Node.js"
  case "$(command -v npm || true)" in
    "$NVM_DIR"/*) ;;
    *) die "npm does not come from nvm's default Node.js (got '$(command -v npm || true)')" ;;
  esac
  bin=$(dirname "$(command -v npm)")
  ln -sfn "$(dirname "$bin")" "$NVM_DIR/default" || die "cannot link $NVM_DIR/default to nvm's default Node.js"
}

ensure_pnpm() {
  local prefix
  prefix=$(npm prefix -g) || die "npm prefix -g failed"
  [ ! -x "$prefix/bin/pnpm" ] || return 0
  say "installing pnpm with npm"
  npm install -g pnpm >/dev/null || die "npm install -g pnpm failed (offline?)"
  [ -x "$prefix/bin/pnpm" ] || die "npm installed pnpm without $prefix/bin/pnpm"
}

# Sets MISSING to the packages of "$@" (specs like name or name@latest) that
# the global package list on stdin lacks: one package path or name per line,
# ending in the package name.
missing_from_list() {
  local list spec name
  list=$(cat)
  MISSING=()
  for spec in "$@"; do
    name=${spec%@latest}
    grep -qE "(^|/node_modules/)${name//./\\.}\$" <<<"$list" || MISSING+=("$spec")
  done
}

write_pnpm_allow_builds() {
  local file=$1
  mkdir -p "$(dirname "$file")" || oops "cannot create $(dirname "$file")" || return 1
  node - "$file" <<'JS' || oops "warning: cannot safely set allowBuilds in $file; leaving it unchanged and skipping pnpm installs" || return 1
const fs = require('node:fs');
const file = process.argv[2];
const policy = { 'better-sqlite3': true, esbuild: true, edgedriver: false, geckodriver: false };
try {
  const original = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
  const lines = original.split('\n');
  if (lines.at(-1) === '') lines.pop();
  const topKeys = new Set();
  const buildKeys = new Set();
  let start = -1, end = lines.length, inBuilds = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/^\s*(#.*)?$/.test(line)) continue;
    if (!/^ /.test(line)) {
      const top = line.match(/^([A-Za-z][A-Za-z0-9_-]*):(?:\s.*)?$/);
      if (!top || topKeys.has(top[1])) throw new Error('unsupported mapping');
      topKeys.add(top[1]);
      if (inBuilds) { end = i; inBuilds = false; }
      if (top[1] === 'allowBuilds') {
        if (!/^allowBuilds:\s*(#.*)?$/.test(line)) throw new Error('unsupported allowBuilds');
        start = i;
        inBuilds = true;
      }
    } else if (topKeys.size === 0) {
      throw new Error('unsupported indentation');
    } else if (inBuilds) {
      const entry = line.match(/^  (?:([A-Za-z0-9_][A-Za-z0-9_@./*-]*)|'([^']+)'|"([^"\\]+)"):\s*(true|false)(\s*(?:#.*)?)$/);
      if (!entry) throw new Error('unsupported allowBuilds entry');
      const key = entry[1] ?? entry[2] ?? entry[3];
      if (buildKeys.has(key)) throw new Error('duplicate allowBuilds entry');
      buildKeys.add(key);
      if (Object.hasOwn(policy, key)) {
        lines[i] = line.slice(0, line.indexOf(':') + 1) + ' ' + policy[key] + entry[5];
      }
    }
  }
  const missing = Object.entries(policy).filter(([key]) => !buildKeys.has(key))
    .map(([key, value]) => `  ${key}: ${value}`);
  if (start === -1) lines.push('allowBuilds:', ...missing);
  else lines.splice(end, 0, ...missing);
  const updated = lines.join('\n') + '\n';
  if (updated !== original) fs.writeFileSync(file, updated);
} catch {
  process.exitCode = 1;
}
JS
}

ensure_pnpm_globals() {
  local global_dir listing
  global_dir=$(dirname "$(pnpm root -g)") || oops "pnpm root -g failed" || return 1
  listing=$(pnpm ls -g --depth=0 --parseable) || oops "pnpm ls -g failed" || return 1
  missing_from_list "${PNPM_PACKAGES[@]}" <<<"$listing"
  [ "${#MISSING[@]}" -gt 0 ] || return 0
  write_pnpm_allow_builds "$global_dir/pnpm-workspace.yaml" || return 1
  say "pnpm add -g ${MISSING[*]}"
  pnpm add -g "${MISSING[@]}" >/dev/null || oops "pnpm add -g ${MISSING[*]} failed (offline?)" || return 1
}

# Installs the npm globals "$@" that are missing, with install scripts
# allowed only for the packages in $ALLOW_SCRIPTS.
npm_install_missing() {
  local root names=() spec
  root=$(npm root -g) || oops "npm root -g failed" || return 1
  for spec in "$@"; do
    [ -f "$root/$spec/package.json" ] || names+=("$spec")
  done
  [ "${#names[@]}" -gt 0 ] || return 0
  say "npm install -g ${names[*]}"
  npm install -g "--allow-scripts=$ALLOW_SCRIPTS" "${names[@]}" >/dev/null \
    || oops "npm install -g ${names[*]} failed (offline?)" || return 1
}

ensure_npm_globals() {
  ALLOW_SCRIPTS=mbt,mta
  npm_install_missing "${NPM_PACKAGES[@]}"
}

# The first semver of `$1 --version`, including prerelease/build suffixes;
# fails when $1 is missing or prints none.
tool_version() {
  local out version
  command -v "$1" >/dev/null 2>&1 || return 1
  out=$("$1" --version 2>/dev/null </dev/null) || return 1
  version=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?' <<<"$out" | sed -n 1p)
  [ -n "$version" ] || return 1
  printf '%s\n' "$version"
}

# True when version $1 is at least $2.
version_at_least() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | sed -n 1p)" = "$2" ]
}

# True when tool $1 reports at least version $2;
# a version that cannot be read is below the floor.
axi_tool_current() {
  local have
  have=$(tool_version "$1") || return 1
  version_at_least "$have" "$2"
}

# Installs the npm globals named by the tool:minimum entries "$@" at @latest
# when missing or below their floor, then checks them against it.
ensure_npm_tools_at_floor() {
  local entry tool min names=()
  for entry in "$@"; do
    tool=${entry%%:*}
    min=${entry#*:}
    axi_tool_current "$tool" "$min" || names+=("$tool@latest")
  done
  [ "${#names[@]}" -gt 0 ] || return 0
  say "npm install -g ${names[*]}"
  npm install -g "${names[@]}" >/dev/null || oops "npm install -g ${names[*]} failed (offline?)" || return 1
  for entry in "$@"; do
    tool=${entry%%:*}
    min=${entry#*:}
    axi_tool_current "$tool" "$min" \
      || oops "$tool is still missing or below $min after npm install -g (is npm's global bin on PATH?)" || return 1
  done
}

# Firstmate's AXI tools, npm globals installed at @latest when missing or below
# their floor, then checked against it.
ensure_axi_tools() {
  ensure_npm_tools_at_floor "${AXI_TOOLS[@]}"
}

# backpass and acpx, installed the same way. Only the CLIs: nothing runs
# `backpass init` or configures a repository, the user scope, or SSH hosts.
ensure_backpass_tools() {
  ensure_npm_tools_at_floor "${BACKPASS_TOOLS[@]}"
}

# See README.md's "Upstream CLI tools" for Paseo's refresh policy.
# The runtime's minimum must also be checked after an offline fallback.
ensure_paseo() {
  local have latest
  have=$(tool_version paseo) || have=
  if latest=$(npm view "$PASEO_PACKAGE" version 2>/dev/null </dev/null) && [ -n "$latest" ]; then
    if [ "$have" != "$latest" ]; then
      say "npm install -g $PASEO_PACKAGE@latest"
      npm install -g "$PASEO_PACKAGE@latest" >/dev/null \
        || oops "npm install -g $PASEO_PACKAGE@latest failed (offline?)" || return 1
    fi
  elif [ -z "$have" ]; then
    oops "paseo is missing and npm cannot read the latest $PASEO_PACKAGE (offline?)" || return 1
  else
    printf 'node-tools: cannot read the latest %s from npm (offline?); keeping paseo %s\n' "$PASEO_PACKAGE" "$have" >&2
  fi
  axi_tool_current paseo "$PASEO_MIN" \
    || oops "paseo is still missing or below $PASEO_MIN after npm install -g (is npm's global bin on PATH?)" || return 1
}

# `<tool> setup hooks` for the AXI tools that have it, on every switch: it is
# idempotent, writes nothing when the hooks are current, and repairs them when
# they are stale. It writes to ~/.claude/settings.json (a Home Manager link
# into home/.claude/settings.json, which already declares all three hooks),
# ~/.codex, ~/.config/opencode/plugins, and the Copilot CLI's hooks directory.
# Home Manager owns the Claude file, and a switch that ran before its link
# existed would leave a plain file there for the next switch to collide with,
# so it is restored to what it was, or removed if it was not there.
ensure_axi_hooks() {
  local tool out settings=$HOME/.claude/settings.json saved="" now had=0 failed=0
  # The trailing x keeps the file's trailing newlines through $(...).
  if [ -e "$settings" ]; then
    had=1
    saved=$(cat "$settings"; printf x) || oops "cannot read $settings" || return 1
  fi
  for tool in "${AXI_HOOK_TOOLS[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      oops "$tool is not on PATH; cannot set up its agent hooks" || failed=1
      continue
    fi
    out=$("$tool" setup hooks 2>&1 </dev/null) || {
      printf '%s\n' "$out" >&2
      oops "$tool setup hooks failed" || failed=1
    }
  done
  if [ "$had" -eq 1 ]; then
    now=$(cat "$settings"; printf x) || oops "cannot read $settings" || return 1
    if [ "$now" != "$saved" ]; then
      printf '%s' "${saved%x}" >"$settings" || oops "cannot restore $settings" || failed=1
      say "kept $settings as Home Manager declares it"
    fi
  elif [ -f "$settings" ] && [ ! -L "$settings" ]; then
    rm -f "$settings" || oops "cannot remove $settings" || failed=1
  fi
  return "$failed"
}

# @sap/cf-tools-local only has an amd64 build.
ensure_cf_tools_local() {
  case "$(uname -m)" in
    x86_64 | amd64) ;;
    *) return 0 ;;
  esac
  ALLOW_SCRIPTS=@sap/cf-tools-local
  npm_install_missing @sap/cf-tools-local
}

# Runs the skills CLI to add $1, with the remaining arguments.
skills_add() {
  local source=$1
  shift
  say "npx skills add $source"
  npx --yes skills add "$source" "$@" --agent universal --yes --global >/dev/null \
    || oops "npx skills add $source failed (offline?)" || return 1
}

pinned_merge_conflicts_present() {
  [ -f "$SKILLS_DIR/resolving-merge-conflicts/SKILL.md" ] || return 1
  node - "$MATTPOCOCK_RESOLVING_MERGE_CONFLICTS" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const file = process.env.XDG_STATE_HOME
  ? path.join(process.env.XDG_STATE_HOME, 'skills', '.skill-lock.json')
  : path.join(process.env.HOME, '.agents', '.skill-lock.json');
try {
  const lock = JSON.parse(fs.readFileSync(file, 'utf8'));
  const entry = lock.skills?.['resolving-merge-conflicts'];
  const [repo, revisionPath] = process.argv[2].split('/tree/');
  process.exitCode = lock.version >= 3 && entry?.source === 'mattpocock/skills'
    && entry.sourceType === 'github' && entry.sourceUrl === `${repo}.git`
    && entry.ref === revisionPath.split('/')[0] ? 0 : 1;
} catch {
  process.exitCode = 1;
}
JS
}

# The installed no-mistakes CLI's release tag (v1.84.0, v1.99.1-rc.1, ...), or
# nothing when the CLI is absent or prints no such version. The CLI usually
# lives at ~/.local/bin/no-mistakes (a link into its own ~/.no-mistakes/bin).
no_mistakes_version() {
  local bin out
  bin=$(command -v no-mistakes 2>/dev/null) || bin=
  for bin in "$bin" "$HOME/.local/bin/no-mistakes" "$HOME/.no-mistakes/bin/no-mistakes"; do
    [ -n "$bin" ] && [ -x "$bin" ] || continue
    out=$("$bin" --version 2>/dev/null </dev/null) || continue
    out=$(printf '%s\n' "$out" | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*' | head -n 1) || true
    [ -z "$out" ] || { printf '%s\n' "$out"; return 0; }
  done
  return 0
}

# Keeps the no-mistakes skill at the release tag of the installed CLI: installs
# it when SKILL.md is missing or the recorded version differs, and otherwise
# does nothing. Without a CLI version it warns (without failing the run) and
# leaves any existing skill untouched. The CLI itself is never touched.
ensure_no_mistakes_skill() {
  local version have=
  version=$(no_mistakes_version)
  if [ -z "$version" ]; then
    printf 'node-tools: warning: no-mistakes is not on PATH or prints no version; leaving the no-mistakes skill as it is\n' >&2
    return 0
  fi
  [ ! -f "$NO_MISTAKES_SKILL_MARKER" ] || have=$(cat "$NO_MISTAKES_SKILL_MARKER" 2>/dev/null) || have=
  if [ -f "$SKILLS_DIR/no-mistakes/SKILL.md" ] && [ "$have" = "$version" ]; then return 0; fi
  skills_add "$NO_MISTAKES_SKILL_REPO/tree/$version/skills/no-mistakes" || return 1
  [ -f "$SKILLS_DIR/no-mistakes/SKILL.md" ] || oops "$SKILLS_DIR/no-mistakes/SKILL.md is missing after the skills install" || return 1
  mkdir -p "$(dirname "$NO_MISTAKES_SKILL_MARKER")" \
    && printf '%s\n' "$version" >"$NO_MISTAKES_SKILL_MARKER" \
    || oops "cannot record the no-mistakes skill version in $NO_MISTAKES_SKILL_MARKER" || return 1
}

# Links the skill that lavish-axi's npm package ships ($1 = its directory, the
# installed package's skills/lavish) as lavish into skills directory $2. The
# link points at the installed package, not at a copy, so a package upgrade
# updates it. Only a link of its own is ever replaced or removed: one that points
# at a lavish-axi/skills/lavish directory, which is stale after a Node.js prefix
# change. Anything else named lavish (a real directory, another skill, a link that
# reaches the same skill) stays; a different one is reported.
link_lavish_skill() {
  local source=$1 dir=$2 path=$2/lavish current
  if [ -L "$path" ]; then
    current=$(readlink -- "$path")
    [ "$current" != "$source" ] || return 0
    case $current in
      */lavish-axi/skills/lavish) ;;
      *)
        [ "$path" -ef "$source" ] \
          || printf 'node-tools: warning: %s already exists, not linking it to %s\n' "$path" "$source" >&2
        return 0
        ;;
    esac
  elif [ -e "$path" ]; then
    [ "$path" -ef "$source" ] || printf 'node-tools: warning: %s already exists, not linking it to %s\n' "$path" "$source" >&2
    return 0
  fi
  mkdir -p -- "$dir" || oops "cannot create $dir for the lavish skill" || return 1
  ln -sfn -- "$source" "$path" || oops "cannot link $path to $source" || return 1
  say "linked $path -> $source"
}

# Removes the link $1/lavish when it is one of our own (a link into a
# lavish-axi package) and its target is gone, so none stays dangling.
drop_dangling_lavish_link() {
  local path=$1/lavish
  [ -L "$path" ] && [ ! -e "$path" ] || return 0
  case $(readlink -- "$path") in
    */lavish-axi/skills/lavish) rm -f -- "$path" && say "removed $path: lavish-axi is no longer installed there" ;;
  esac
}

# The lavish skill for Pi (~/.agents/skills) and Claude Code, linked to the
# installed lavish-axi package. Without the package (not installed yet, or the
# package ships no skill) no link is made and a dangling one of ours goes.
ensure_lavish_skill() {
  local root source claude_dir=$HOME/.claude dir
  case ${CLAUDE_CONFIG_DIR:-} in /*) claude_dir=${CLAUDE_CONFIG_DIR%/} ;; esac
  root=$(npm root -g) || oops "npm root -g failed" || return 1
  source=$root/lavish-axi/skills/lavish
  for dir in "$SKILLS_DIR" "$claude_dir/skills"; do
    if [ -f "$source/SKILL.md" ]; then
      link_lavish_skill "$source" "$dir" || return 1
    else
      drop_dangling_lavish_link "$dir"
    fi
  done
}

ensure_skills() {
  command -v npx >/dev/null 2>&1 || oops "npx not found on PATH; cannot install the agent skills" || return 1
  [ -f "$SKILLS_DIR/explain-abap-code/SKILL.md" ] || skills_add arc-mcp/arc-1 || return 1
  if [ ! -f "$SKILLS_DIR/tdd/SKILL.md" ]; then
    skills_add mattpocock/skills || return 1
  fi
  [ -f "$SKILLS_DIR/find-skills/SKILL.md" ] || skills_add vercel-labs/skills --skill find-skills || return 1
  pinned_merge_conflicts_present || skills_add "$MATTPOCOCK_RESOLVING_MERGE_CONFLICTS" || return 1
  local skill
  for skill in find-skills resolving-merge-conflicts; do
    [ -f "$SKILLS_DIR/$skill/SKILL.md" ] || oops "$SKILLS_DIR/$skill/SKILL.md is missing after the skills install" || return 1
  done
  pinned_merge_conflicts_present || oops "resolving-merge-conflicts lock metadata does not identify the pinned source and revision" || return 1
  ensure_no_mistakes_skill
}

# Keep every ARC-1 invocation inside the scrubbed scratch environment: arc-1
# reads .env from its working directory, so env -i alone cannot isolate it.
# The deny check precedes argument validation and any HTTP call; unknown
# SAP_DENY_ACTIONS names abort startup (fail-fast). This lets us probe policy
# with dummy credentials and a dead local endpoint without contacting SAP.
# For check outcomes and warnings, see README.md's "Upstream CLI tools".
arc1_policy_check() {
  local dir out var status=0 keep=()
  local unsafe="the FAB write lane is unsafe with this ARC-1 install: deny list is unproven"
  command -v arc1-cli >/dev/null 2>&1 || { warn "$unsafe: arc1-cli is not on PATH"; return 0; }
  dir=$(mktemp -d) || { warn "$unsafe: cannot create a temp directory for the arc-1 policy check"; return 0; }
  # Only what node and the pnpm/nvm shims need survives the scrub.
  for var in NVM_DIR PNPM_HOME TMPDIR LANG; do
    [ -z "${!var:-}" ] || keep+=("$var=${!var}")
  done
  out=$(cd "$dir" && timeout -k 5 60 env -i PATH="$PATH" HOME="$HOME" ${keep[@]+"${keep[@]}"} \
    SAP_URL=http://127.0.0.1:9 SAP_USER=policy-check SAP_PASSWORD=policy-check \
    SAP_ALLOW_WRITES=true SAP_ALLOW_TRANSPORT_WRITES=true \
    SAP_ALLOWED_PACKAGES='/IQX/FAB*,/IQX/COMMON,/IQX/ONELIST_*' \
    SAP_DENY_ACTIONS='SAPTransport.release,SAPTransport.release_recursive,SAPTransport.delete,SAPTransport.reassign,SAPTransport.remove_object' \
    arc1-cli call SAPTransport --json '{"action":"release","transport":"POLICYCHECK"}' 2>&1 </dev/null) || status=$?
  rm -rf "$dir"
  case "$status:$out" in
    124:* | 137:*) warn "$unsafe: arc1-cli policy check timed out" ;;
    *"denied by server policy (SAP_DENY_ACTIONS)"*) ;;
    *) warn "$unsafe: arc1-cli did not answer 'denied by server policy (SAP_DENY_ACTIONS)' for SAPTransport release: $(tail -n 1 <<<"$out")" ;;
  esac
}

smoke_checks() {
  local out ns
  if command -v mbt >/dev/null 2>&1; then
    out=$(mbt --version 2>&1 </dev/null || true)
    case "$out" in *"Cloud MTA Build Tool version"*) ;; *) warn "mbt --version does not say 'Cloud MTA Build Tool version': $out" ;; esac
  else
    warn "mbt is not on PATH"
  fi
  if command -v mta >/dev/null 2>&1; then
    out=$(mta --version 2>&1 </dev/null || true)
    case "$out" in *"MTA version"*) ;; *) warn "mta --version does not say 'MTA version': $out" ;; esac
  else
    warn "mta is not on PATH"
  fi
  if command -v yo >/dev/null 2>&1; then
    out=$(yo --generators --no-insight 2>&1 </dev/null || true)
    for ns in "${YO_NAMESPACES[@]}"; do
      case "$out" in *"$ns"*) ;; *) warn "yo --generators does not list $ns (yo only finds generators under npm's global prefix $(npm prefix -g))" ;; esac
    done
  else
    warn "yo is not on PATH"
  fi
  case "$(uname -m)" in
    x86_64 | amd64)
      if command -v cf >/dev/null 2>&1; then
        out=$(cf plugins 2>&1 </dev/null || true)
        case "$out" in *ServiceInfo*) ;; *) warn "cf plugins does not list ServiceInfo" ;; esac
      else
        warn "ServiceInfo plugin could not be verified because cf is missing"
      fi
      ;;
  esac
  arc1_policy_check
}

main() {
  local npm_prefix
  case "${1:-}" in
    workstation | container) ;;
    *)
      echo "Usage: $0 workstation|container" >&2
      return 2
      ;;
  esac
  if [ "$1" = workstation ]; then
    ensure_nvm
    load_nvm
    ensure_node
    ensure_pnpm
  else
    command -v pnpm >/dev/null 2>&1 \
      || die "pnpm not found on PATH; the devcontainer image should provide Node.js and pnpm"
    command -v npm >/dev/null 2>&1 \
      || die "npm not found on PATH; the devcontainer image should provide Node.js and pnpm"
    # The image sets the same; home.nix does for the shells (nodePath).
    export NPM_CONFIG_PREFIX=${NPM_CONFIG_PREFIX:-$HOME/.npm-global}
    mkdir -p "$NPM_CONFIG_PREFIX"
  fi
  mkdir -p "$PNPM_HOME"
  # pnpm refuses global commands while its global bin directory is not on
  # PATH: $PNPM_HOME/bin for pnpm 11+, $PNPM_HOME for older pnpm. npm's global
  # bin is on PATH for the smoke checks and the cf plugin check.
  npm_prefix=$(npm prefix -g) || die "npm prefix -g failed"
  export PATH="$npm_prefix/bin:$PNPM_HOME/bin:$PNPM_HOME:$PATH"
  step ensure_pnpm_globals
  step ensure_skills
  step ensure_npm_globals
  step ensure_cf_tools_local
  step ensure_axi_tools
  step ensure_lavish_skill
  step ensure_backpass_tools
  step ensure_paseo
  step ensure_axi_hooks
  smoke_checks
  [ "${#problems[@]}" -eq 0 ] || {
    printf 'node-tools: %s did not complete (see above)\n' "$(IFS=,; echo "${problems[*]//ensure_/}")" >&2
    return 1
  }
}

main "$@"
