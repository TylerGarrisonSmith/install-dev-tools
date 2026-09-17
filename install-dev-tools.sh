#!/usr/bin/env bash
#
# install-dev-tools.sh
#
# Installs on Ubuntu (20.04+ / Debian-based):
#   - git
#   - Node.js (NodeSource LTS)
#   - GitHub CLI (gh)
#   - Google Cloud CLI (gcloud)
#   - uv (Astral Python package manager)
#   - Claude Code CLI (claude)
#
# Usage:
#   ./install-dev-tools.sh                  # install everything
#   ./install-dev-tools.sh git node uv      # install only what you name
#   ./install-dev-tools.sh --force          # reinstall even if present
#   ./install-dev-tools.sh --list           # show available components
#
# Pinning (set these to make rebuilds reproducible):
#   NODE_MAJOR=24        Node.js major version
#   UV_VERSION=0.9.2     exact uv version, or "latest"
#   CLAUDE_CHANNEL=stable  "stable", "latest", or an exact version
#
# On success the resolved versions are written to ~/.dev-tools-versions so
# you can copy them back into this file and pin a known-good combination.
#
# Run as a normal user with sudo rights. Do NOT run with sudo:
# uv and claude install into $HOME/.local and must not be owned by root.

set -euo pipefail

NODE_MAJOR="${NODE_MAJOR:-24}"          # Node.js 24 "Krypton" is the active LTS line
UV_VERSION="${UV_VERSION:-latest}"      # exact version, or "latest"
CLAUDE_CHANNEL="${CLAUDE_CHANNEL:-stable}"  # stable | latest | exact version

KEYRINGS_DIR="/etc/apt/keyrings"
LOCAL_BIN="${HOME}/.local/bin"
VERSION_RECORD="${HOME}/.dev-tools-versions"
FORCE=0
APT_UPDATED=0

ALL_COMPONENTS=(git node gh gcloud uv claude)

# Single scratch dir, removed on any exit path.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------- helpers ---

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; RESET=$'\033[0m'

log()   { printf '%s==>%s %s\n' "$BLUE"   "$RESET" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$GREEN"  "$RESET" "$*"; }
warn()  { printf '%swarn%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()   { printf '%serr %s %s\n' "$RED"    "$RESET" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Install a component only if its binary is missing (or --force was passed).
needs() {
  local bin="$1"
  if have "$bin" && [[ $FORCE -eq 0 ]]; then
    ok "$bin already installed ($(command -v "$bin")) — skipping"
    return 1
  fi
  return 0
}

apt_update_once() {
  if [[ $APT_UPDATED -eq 0 ]]; then
    sudo apt-get update -qq
    APT_UPDATED=1
  fi
}

apt_install() {
  apt_update_once
  local extra=()
  # Without --reinstall, apt is a no-op on an already-installed package,
  # so --force would silently do nothing for the apt-based tools.
  [[ $FORCE -eq 1 ]] && extra+=(--reinstall)
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${extra[@]+"${extra[@]}"}" "$@"
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

install_node() {
  # Bare presence is not enough here: Ubuntu's own nodejs package is often
  # several majors behind, and a presence-only check would silently leave it.
  if have node && [[ $FORCE -eq 0 ]]; then
    local current
    current="$(node -v 2>/dev/null | sed 's/^v//; s/\..*//')"
    if [[ "$current" == "$NODE_MAJOR" ]]; then
      ok "node ${current}.x already installed — skipping"
      return 0
    fi
    warn "node ${current}.x present but ${NODE_MAJOR}.x requested — upgrading"
  fi

  log "Installing Node.js ${NODE_MAJOR}.x from NodeSource"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
  APT_UPDATED=1   # the NodeSource script runs apt-get update itself
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
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

ensure_path() {
  [[ -d "$LOCAL_BIN" ]] || return 0
  case ":${PATH}:" in
    *":${LOCAL_BIN}:"*) return 0 ;;
  esac

  # shellcheck disable=SC2016  # written literally into the rc file, must not expand
  local line='export PATH="$HOME/.local/bin:$PATH"'
  local rc="${HOME}/.bashrc"
  [[ -n "${ZSH_VERSION:-}" || "${SHELL##*/}" == "zsh" ]] && rc="${HOME}/.zshrc"

  if ! grep -qsF "$line" "$rc"; then
    printf '\n# added by install-dev-tools.sh\n%s\n' "$line" >> "$rc"
    log "Added ~/.local/bin to PATH in ${rc}"
  fi
  export PATH="${LOCAL_BIN}:${PATH}"
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

  preflight

  for c in "${requested[@]}"; do
    case "$c" in
      git)    install_git ;;
      node|nodejs) install_node ;;
      gh|github-cli) install_gh ;;
      gcloud|google-cloud-cli) install_gcloud ;;
      uv)     install_uv ;;
      claude|claude-code) install_claude ;;
      *)      die "unknown component: $c (try --list)" ;;
    esac
  done

  ensure_path
  verify

  cat <<'EOF'

Next steps (each needs an interactive login):
  gh auth login
  gcloud init
  claude            # first run opens a browser to sign in

Open a new shell (or: source ~/.bashrc) so PATH changes take effect.
EOF
}

main "$@"
