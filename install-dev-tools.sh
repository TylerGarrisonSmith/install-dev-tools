#!/usr/bin/env bash
#
# install-dev-tools.sh
#
# Installs on Ubuntu (20.04+ / Debian-based):
#   - git
#   - Node.js (NodeSource, newest major by default)
#   - GitHub CLI (gh)
#   - Google Cloud CLI (gcloud)
#   - uv (Astral Python package manager)
#   - Claude Code CLI (claude)
#   - Claude Code config (claude-config), from the claude/ folder next to
#     this script:
#       CLAUDE.md         copied into ~/.claude
#       statusline-command.sh
#                         copied into ~/.claude (settings.json's statusLine
#                         runs it)
#       settings.json     merged into ~/.claude/settings.json: repo values win,
#                         keys Claude Code wrote itself (marketplaces, enabled
#                         plugins) are kept
#                         (any of these is backed up first if it would change)
#       marketplaces.txt  plugin marketplace sources to add (owner/repo or URL)
#       plugins.txt       plugin@marketplace ids to install
#       mcp-servers.json  {"name": {server config}} added at user scope
#     Any of these may be absent; missing ones are skipped.
#
# Usage:
#   ./install-dev-tools.sh                  # install everything
#   ./install-dev-tools.sh git node uv      # install only what you name
#   ./install-dev-tools.sh --force          # reinstall even if present
#   ./install-dev-tools.sh --list           # show available components
#
# Pinning (set these to make rebuilds reproducible):
#   NODE_MAJOR=24        Node.js major version, or "latest"
#   UV_VERSION=0.9.2     exact uv version, or "latest"
#   CLAUDE_CHANNEL=stable  "stable", "latest", or an exact version
#
# On success the resolved versions are written to ~/.dev-tools-versions so
# you can copy them back into this file and pin a known-good combination.
#
# Run as a normal user with sudo rights. Do NOT run with sudo:
# uv and claude install into $HOME/.local and must not be owned by root.

set -euo pipefail

NODE_MAJOR="${NODE_MAJOR:-latest}"      # major version number, or "latest"
UV_VERSION="${UV_VERSION:-latest}"      # exact version, or "latest"
CLAUDE_CHANNEL="${CLAUDE_CHANNEL:-latest}"  # stable | latest | exact version

KEYRINGS_DIR="/etc/apt/keyrings"
LOCAL_BIN="${HOME}/.local/bin"
VERSION_RECORD="${HOME}/.dev-tools-versions"
CLAUDE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude"
FORCE=0
APT_UPDATED=0
CONFIG_FAILURES=0
LOCAL_BIN_WAS_ON_PATH=0

ALL_COMPONENTS=(git node gh gcloud uv claude claude-config)

# Single scratch dir, removed on any exit path.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------- helpers ---

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; RESET=$'\033[0m'

log()   { printf '%s==>%s %s\n' "$BLUE"   "$RESET" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$GREEN"  "$RESET" "$*"; }
warn()  { printf '%swarn%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()   { printf '%serr %s %s\n' "$RED"    "$RESET" "$*" >&2; exit 1; }

# Under WSL the Windows PATH is appended by default, so a Windows tool (e.g. a
# scoop "gcloud" shim under /mnt/c) would otherwise count as installed.
have() {
  local path
  path="$(command -v "$1" 2>/dev/null)" || return 1
  [[ "$path" != /mnt/* ]]
}

# Install a component only if its binary is missing (or --force was passed).
needs() {
  local bin="$1"
  if have "$bin" && [[ $FORCE -eq 0 ]]; then
    ok "$bin already installed ($(command -v "$bin")) — skipping"
    return 1
  fi
  return 0
}

# Ubuntu's automatic updates (unattended-upgrades) hold the dpkg lock for a
# few minutes after the machine or WSL distro starts. apt-get fails at once on
# a held lock unless told to wait, and -qq hides the wait, so say why it's slow.
APT_WAIT=(-o DPkg::Lock::Timeout=600)

apt_wait_notice() {
  pgrep -f /usr/bin/unattended-upgrade >/dev/null \
    && log "Ubuntu's automatic updates are running — waiting for them to finish (up to 10 min)"
  return 0
}

apt_update_once() {
  if [[ $APT_UPDATED -eq 0 ]]; then
    apt_wait_notice
    sudo apt-get update -qq "${APT_WAIT[@]}"
    APT_UPDATED=1
  fi
}

apt_install() {
  apt_update_once
  local extra=()
  # Without --reinstall, apt is a no-op on an already-installed package,
  # so --force would silently do nothing for the apt-based tools.
  [[ $FORCE -eq 1 ]] && extra+=(--reinstall)
  apt_wait_notice
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${APT_WAIT[@]}" "${extra[@]+"${extra[@]}"}" "$@"
}

# Fetch an armored key, verify it is real OpenPGP data, and dearmor it.
add_keyring() {
  local url="$1" dest="$2"
  local tmp="${WORKDIR}/key.asc"
  curl -fsSL "$url" -o "$tmp" || die "could not download signing key from $url"
  gpg --show-keys --with-colons "$tmp" >/dev/null 2>&1 \
    || die "downloaded key from $url is not valid OpenPGP data"
  sudo install -d -m 0755 "$KEYRINGS_DIR"
  sudo gpg --dearmor --yes -o "$dest" "$tmp"
  sudo chmod a+r "$dest"
}

# --------------------------------------------------------------- installs ---

preflight() {
  [[ "$(id -u)" -ne 0 ]] || die "run this as a normal user, not root/sudo (uv and claude install into \$HOME)"
  have apt-get || die "this script targets Debian/Ubuntu (apt-get not found)"
  sudo -v || die "sudo access is required"

  log "Installing base dependencies"
  # apt-transport-https is not listed: it has been built into apt since 1.5.
  apt_install ca-certificates curl gnupg
}

install_git() {
  needs git || return 0
  log "Installing git"
  apt_install git
}

# Newest Node.js major version, from the official release index (newest first).
latest_node_major() {
  local index="${WORKDIR}/node-index.json" major
  curl -fsSL https://nodejs.org/dist/index.json -o "$index" \
    || die "could not download the Node.js release index"
  # sed -n reads all its input, so nothing upstream gets SIGPIPE under pipefail.
  major="$(grep -o '"version":"v[0-9]*' "$index" | sed -n '1s/.*v//p')"
  [[ -n "$major" ]] || die "could not find a version in the Node.js release index"
  printf '%s\n' "$major"
}

install_node() {
  local major="$NODE_MAJOR"
  [[ "$major" == "latest" ]] && major="$(latest_node_major)"

  # Bare presence is not enough here: Ubuntu's own nodejs package is often
  # several majors behind, and a presence-only check would silently leave it.
  if have node && [[ $FORCE -eq 0 ]]; then
    local current
    current="$(node -v 2>/dev/null | sed 's/^v//; s/\..*//')"
    if [[ "$current" == "$major" ]]; then
      ok "node ${current}.x already installed — skipping"
      return 0
    fi
    warn "node ${current}.x present but ${major}.x requested — upgrading"
  fi

  log "Installing Node.js ${major}.x from NodeSource"
  # NodeSource can lag a few days behind a brand-new major release.
  curl -fsSL "https://deb.nodesource.com/setup_${major}.x" | sudo -E bash - \
    || die "NodeSource setup for Node ${major}.x failed (new release not packaged yet?) — try NODE_MAJOR=$((major - 1))"
  APT_UPDATED=1   # the NodeSource script runs apt-get update itself
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${APT_WAIT[@]}" nodejs
}

install_gh() {
  needs gh || return 0
  log "Installing GitHub CLI"
  # GitHub publishes this key already dearmored, so it goes straight into place.
  sudo install -d -m 0755 "$KEYRINGS_DIR"
  local tmp; tmp="$(mktemp)"
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$tmp" \
    || die "could not download the GitHub CLI signing key"
  sudo install -m 0644 "$tmp" "${KEYRINGS_DIR}/githubcli-archive-keyring.gpg"
  rm -f "$tmp"

  echo "deb [arch=$(dpkg --print-architecture) signed-by=${KEYRINGS_DIR}/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null

  APT_UPDATED=0
  apt_install gh
}

install_gcloud() {
  # Google's cloud images often ship gcloud as a snap. The snap and the apt
  # package claim the same command aliases and will fight, so never layer
  # one on top of the other.
  if command -v snap >/dev/null 2>&1 && snap list google-cloud-cli >/dev/null 2>&1; then
    ok "gcloud already present as a snap — leaving it alone (apt package would conflict)"
    return 0
  fi

  needs gcloud || return 0
  log "Installing Google Cloud CLI"
  add_keyring "https://packages.cloud.google.com/apt/doc/apt-key.gpg" \
              "/usr/share/keyrings/cloud.google.gpg"

  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null

  APT_UPDATED=0
  apt_install google-cloud-cli
}

install_uv() {
  needs uv || return 0
  local url="https://astral.sh/uv/install.sh"
  [[ "$UV_VERSION" != "latest" ]] && url="https://astral.sh/uv/${UV_VERSION}/install.sh"
  log "Installing uv (${UV_VERSION})"
  curl -LsSf "$url" | sh
}

install_claude() {
  needs claude || return 0
  log "Installing Claude Code (${CLAUDE_CHANNEL})"
  # Native installer: drops the binary in ~/.local/bin, no root needed.
  # Note the pin is soft — Claude Code auto-updates in the background, so
  # this fixes the starting point, not the version you'll be on next week.
  curl -fsSL https://claude.ai/install.sh | bash -s "$CLAUDE_CHANNEL"
}

# Put new config content in place. The repo version wins, but a file that
# would change is backed up first rather than lost.
put_config_file() {
  local new="$1" dest="$2"
  if [[ -e "$dest" ]]; then
    local backup
    backup="${dest}.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$dest" "$backup"
    warn "${dest/#$HOME/\~} changed — old copy saved as ${backup/#$HOME/\~}"
  fi
  install -D -m 0644 "$new" "$dest"
  ok "updated ${dest/#$HOME/\~}"
}

# Copy claude/<name> to ~/.claude/<name> as-is.
copy_claude_file() {
  local src="${CLAUDE_SRC}/$1" dest="${HOME}/.claude/$1"
  [[ -f "$src" ]] || return 0
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    ok "${dest/#$HOME/\~} already matches the repo — skipping"
    return 0
  fi
  put_config_file "$src" "$dest"
}

# Claude Code writes to settings.json itself (marketplaces, enabled plugins),
# so a plain copy would wipe those and then differ again on every run.
# Deep-merge instead: repo values win, keys only present locally survive.
merge_settings() {
  local src="${CLAUDE_SRC}/settings.json" dest="${HOME}/.claude/settings.json"
  local merged="${WORKDIR}/settings.json"
  [[ -f "$src" ]] || return 0
  jq -e 'type == "object"' "$src" >/dev/null || die "$src must be a JSON object"
  if [[ -f "$dest" ]]; then
    jq -s '.[0] * .[1]' "$dest" "$src" > "$merged" \
      || die "could not merge into ~/.claude/settings.json (is it valid JSON?)"
    # Compare as JSON, so key order and whitespace alone don't count as a change.
    if jq -en --slurpfile a "$dest" --slurpfile b "$merged" '$a == $b' >/dev/null; then
      # shellcheck disable=SC2088  # display text, not a path
      ok "~/.claude/settings.json already has the repo settings — skipping"
      return 0
    fi
  else
    jq . "$src" > "$merged"
  fi
  put_config_file "$merged" "$dest"
}

# A failed plugin or MCP step shouldn't block the rest; it is counted and
# reported at the end, and the script exits non-zero.
config_step() {
  # </dev/null: claude must not eat the input of the loop calling this.
  "$@" </dev/null && return 0
  warn "failed: $*"
  CONFIG_FAILURES=$((CONFIG_FAILURES + 1))
}

# Non-comment, non-blank lines of a list file, whitespace stripped.
list_entries() {
  [[ -f "$1" ]] || return 0
  sed 's/#.*//; s/[[:space:]]//g; /^$/d' "$1"
}

install_claude_config() {
  have claude || die "claude-config needs Claude Code — install the 'claude' component first"
  [[ -d "$CLAUDE_SRC" ]] || { warn "no claude/ folder next to this script — skipping claude-config"; return 0; }
  log "Applying Claude Code config from ${CLAUDE_SRC}"
  apt_install jq

  copy_claude_file CLAUDE.md
  copy_claude_file statusline-command.sh
  merge_settings

  # Adding a marketplace that is already present is a no-op, so no check here.
  local source
  while read -r source; do
    config_step claude plugin marketplace add "$source"
  done < <(list_entries "${CLAUDE_SRC}/marketplaces.txt")

  local id installed
  installed="$(claude plugin list --json </dev/null | jq -r '.[].id')"
  while read -r id; do
    if grep -qxF "$id" <<<"$installed"; then
      ok "plugin $id already installed — skipping"
    else
      config_step claude plugin install --scope user "$id"
    fi
  done < <(list_entries "${CLAUDE_SRC}/plugins.txt")

  local name servers="${CLAUDE_SRC}/mcp-servers.json"
  if [[ -f "$servers" ]]; then
    jq -e 'type == "object"' "$servers" >/dev/null || die "$servers must be a JSON object of {name: server config}"
    while read -r name; do
      if claude mcp get "$name" </dev/null >/dev/null 2>&1; then
        ok "MCP server $name already configured — skipping"
      else
        config_step claude mcp add-json --scope user "$name" "$(jq -c --arg n "$name" '.[$n]' "$servers")"
      fi
    done < <(jq -r 'keys[]' "$servers")
  fi
}

# PATH for this run is set up front in main(); this only persists it.
ensure_path() {
  [[ -d "$LOCAL_BIN" && $LOCAL_BIN_WAS_ON_PATH -eq 0 ]] || return 0

  # shellcheck disable=SC2016  # written literally into the rc file, must not expand
  local line='export PATH="$HOME/.local/bin:$PATH"'
  local rc="${HOME}/.bashrc"
  [[ -n "${ZSH_VERSION:-}" || "${SHELL##*/}" == "zsh" ]] && rc="${HOME}/.zshrc"

  if ! grep -qsF "$line" "$rc"; then
    printf '\n# added by install-dev-tools.sh\n%s\n' "$line" >> "$rc"
    log "Added ~/.local/bin to PATH in ${rc}"
  fi
}

verify() {
  log "Verifying"
  local bin ver
  : > "$VERSION_RECORD"
  printf '# recorded %s\n' "$(date -Iseconds)" >> "$VERSION_RECORD"
  for bin in git node npm gh gcloud uv claude; do
    if have "$bin"; then
      ver="$("$bin" --version 2>/dev/null | head -n1 || echo '?')"
      printf '  %-8s %s\n' "$bin" "$ver"
      printf '%s\t%s\n' "$bin" "$ver" >> "$VERSION_RECORD"
    else
      warn "$bin not found on PATH"
    fi
  done
  log "Versions recorded in ${VERSION_RECORD}"
}

# ------------------------------------------------------------------- main ---

main() {
  local requested=()

  for arg in "$@"; do
    case "$arg" in
      --force|-f) FORCE=1 ;;
      --list|-l)  printf '%s\n' "${ALL_COMPONENTS[@]}"; exit 0 ;;
      # Print the header comment block: skip the shebang, stop at the first
      # non-comment line. Hardcoded line numbers go stale on every edit.
      --help|-h)  sed -n '2,${/^[^#]/q; s/^# \{0,1\}//p;}' "$0"; exit 0 ;;
      -*)         die "unknown option: $arg" ;;
      *)          requested+=("$arg") ;;
    esac
  done

  [[ ${#requested[@]} -gt 0 ]] || requested=("${ALL_COMPONENTS[@]}")

  # Put ~/.local/bin on PATH now, not at the end: claude-config needs the
  # claude it just installed, and a re-run after a failed run must see the
  # uv/claude that run already installed instead of reinstalling them.
  case ":${PATH}:" in
    *":${LOCAL_BIN}:"*) LOCAL_BIN_WAS_ON_PATH=1 ;;
    *) LOCAL_BIN_WAS_ON_PATH=0; export PATH="${LOCAL_BIN}:${PATH}" ;;
  esac

  preflight

  for c in "${requested[@]}"; do
    case "$c" in
      git)    install_git ;;
      node|nodejs) install_node ;;
      gh|github-cli) install_gh ;;
      gcloud|google-cloud-cli) install_gcloud ;;
      uv)     install_uv ;;
      claude|claude-code) install_claude ;;
      claude-config) install_claude_config ;;
      *)      die "unknown component: $c (try --list)" ;;
    esac
  done

  ensure_path
  verify

  cat <<'EOF'

Next steps (each needs an interactive login):
  gh auth login
  gcloud init
  claude            # first run opens a browser to sign in;
                    # then /mcp to sign in to MCP servers (e.g. Notion)

Open a new shell (or: source ~/.bashrc) so PATH changes take effect.
EOF

  [[ $CONFIG_FAILURES -eq 0 ]] || die "${CONFIG_FAILURES} Claude Code config step(s) failed — see 'failed:' warnings above"
}

main "$@"
