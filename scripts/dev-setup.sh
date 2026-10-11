#!/usr/bin/env bash
#
# Shared developer / CI toolchain bootstrap for insolvia-services.
#
# Installs the cross-cutting tools this repo needs (Terraform, tflint, AWS CLI,
# jq, Python 3.12) with Homebrew on BOTH macOS and Linux, and checks for
# Docker. Area-specific setup lives in that area's own script —
# services/mailer/scripts/dev-setup.sh (venv + pip) calls this one first.
#
# Homebrew details:
#   - macOS (developer machines): brew runs as the normal user.
#   - Linux (cloud sandbox / CI): Homebrew refuses to run as root, so it is
#     installed into the default prefix /home/linuxbrew/.linuxbrew owned by the
#     non-root `ubuntu` user, and every `brew` call is run as that user via
#     sudo. The prefix bin is added to PATH (this run + /etc/profile.d) so root
#     and CI agents can execute the installed tools.
#   - terraform and tflint are NOT in homebrew-core; they come from taps
#     (hashicorp/tap, terraform-linters/tap) on every platform.
#
# Toolchain pins (each is read from the file that owns it — update there, not
# here):
#   - Terraform: `>= 1.10` (native S3 state locking), required_version in every
#     root under infra/envs/; infra/CLAUDE.md owns the provider floor.
#   - Python:    3.12, matching services/mailer (pyproject `requires-python`
#     and the public.ecr.aws/lambda/python:3.12 base image).
#
# NOT INSTALLED, deliberately: Node and everything JavaScript. Nothing in this
# repo is JavaScript; the app, its toolchain and its npm workspace stayed in
# the insolvia repo, whose own scripts/dev-setup.sh installs them.
#
# IDEMPOTENT: every tool is checked with `command -v` (or an equivalent probe)
# before install, so re-running is a no-op once the toolchain is present.
#
# Usage:
#   ./scripts/dev-setup.sh            # install everything missing
#   ./scripts/dev-setup.sh --check    # report status only, install nothing
#
set -euo pipefail

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

log()  { printf '\033[1;34m[dev-setup]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
skip() { printf '\033[1;36m[skip]\033[0m %s already present: %s\n' "$1" "$2"; }

# Detect platform from the kernel name. `uname -s` is the kernel identifier: it
# is reliably "Darwin" on every macOS release (it does NOT track the macOS
# marketing version) and "Linux" on Linux. Match with a glob and treat anything
# else as unsupported rather than silently assuming Linux.
OS="$(uname -s)"
case "$OS" in
  Darwin*) PLATFORM="macos" ;;
  Linux*)  PLATFORM="linux" ;;
  *) printf 'Unsupported OS: %s (this repo supports macOS and Linux only).\n' "$OS" >&2; exit 1 ;;
esac
have() { command -v "$1" >/dev/null 2>&1; }
if [[ "$(id -u)" -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

# --- Linux Homebrew (installed & run as the non-root ubuntu user) ----------
LINUXBREW_PREFIX="/home/linuxbrew/.linuxbrew"
LINUX_BREW_USER="ubuntu"
BREW_ENV=(HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1)

# Run a brew command the right way for the platform.
brew_run() {
  if [[ "$PLATFORM" == "macos" ]]; then
    env "${BREW_ENV[@]}" brew "$@"
  else
    $SUDO -u "$LINUX_BREW_USER" env "${BREW_ENV[@]}" "$LINUXBREW_PREFIX/bin/brew" "$@"
  fi
}

apt_install() { $SUDO apt-get update -y >/dev/null && $SUDO apt-get install -y "$@"; }

ensure_brew() {
  if [[ "$PLATFORM" == "macos" ]]; then
    if have brew; then return 0; fi
    if [[ "$CHECK_ONLY" -eq 1 ]]; then warn "Homebrew is MISSING (required on macOS)"; return 1; fi
    log "installing Homebrew ..."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    return 0
  fi

  # ---- Linux ----
  if [[ ! -x "$LINUXBREW_PREFIX/bin/brew" ]]; then
    if [[ "$CHECK_ONLY" -eq 1 ]]; then warn "Homebrew (Linux) is MISSING (would install as user '$LINUX_BREW_USER')"; return 1; fi
    if ! id "$LINUX_BREW_USER" >/dev/null 2>&1; then
      warn "non-root user '$LINUX_BREW_USER' not found; Homebrew cannot run as root."
      return 1
    fi
    log "installing Homebrew prerequisites ..."
    apt_install build-essential procps curl file git unzip >/dev/null 2>&1 || \
      warn "could not apt-get prerequisites (continuing; they may already be present)"
    log "installing Homebrew into $LINUXBREW_PREFIX (owned by $LINUX_BREW_USER) ..."
    $SUDO mkdir -p "$LINUXBREW_PREFIX"
    $SUDO chown -R "$LINUX_BREW_USER:$LINUX_BREW_USER" "$(dirname "$LINUXBREW_PREFIX")"
    $SUDO -u "$LINUX_BREW_USER" git clone --depth=1 https://github.com/Homebrew/brew "$LINUXBREW_PREFIX/Homebrew"
    $SUDO -u "$LINUX_BREW_USER" mkdir -p "$LINUXBREW_PREFIX/bin"
    $SUDO -u "$LINUX_BREW_USER" ln -sf "$LINUXBREW_PREFIX/Homebrew/bin/brew" "$LINUXBREW_PREFIX/bin/brew"
  fi

  # Expose brew + its tools on PATH for this run and for future login shells.
  eval "$("$LINUXBREW_PREFIX/bin/brew" shellenv)"
  local profile="/etc/profile.d/homebrew.sh"
  if [[ "$CHECK_ONLY" -ne 1 && ! -f "$profile" ]]; then
    echo "eval \"\$($LINUXBREW_PREFIX/bin/brew shellenv)\"" | $SUDO tee "$profile" >/dev/null || true
  fi
  return 0
}

# brew_ensure <cli-name> <formula>  (formula may be tap-qualified)
brew_ensure() {
  local cli="$1" formula="$2"
  if have "$cli"; then skip "$cli" "$(command -v "$cli")"; return 0; fi
  if [[ "$CHECK_ONLY" -eq 1 ]]; then warn "$cli is MISSING (would: brew install $formula)"; return 0; fi
  log "installing $formula ..."
  brew_run install "$formula"
}

# ---------------------------------------------------------------------------
log "OS detected: $OS  (check-only: $CHECK_ONLY)"

if ! ensure_brew; then
  warn "Homebrew is not available; cannot continue. See messages above."
  exit 1
fi

brew_ensure terraform hashicorp/tap/terraform
brew_ensure tflint    terraform-linters/tap/tflint
brew_ensure aws       awscli
brew_ensure jq        jq
brew_ensure python3.12 python@3.12

# Docker is a daemon/GUI concern — check only, never auto-install. The
# mailer's local stack (docker compose: the dev server + Mailpit) and its
# Lambda image build both need it.
if have docker; then skip docker "$(command -v docker)"; else
  if [[ "$PLATFORM" == "macos" ]]; then
    warn "docker not found — install Docker Desktop: https://www.docker.com/products/docker-desktop/"
  else
    warn "docker not found — see https://docs.docker.com/engine/install/ubuntu/"
  fi
fi

log "shared toolchain ready. For the mailer's venv run its own script:"
log "    ./services/mailer/scripts/dev-setup.sh       # venv + pip"
[[ "$PLATFORM" == "linux" && "$CHECK_ONLY" -ne 1 ]] && log "Tools are on PATH via /etc/profile.d/homebrew.sh (new shells) or: eval \"\$($LINUXBREW_PREFIX/bin/brew shellenv)\""
ok "done."
