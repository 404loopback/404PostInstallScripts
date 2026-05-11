#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Ubuntu Bootstrap
# ==============================================================================
#
# Purpose:
#   Prepare a fresh Ubuntu server/device with a sensible baseline:
#     - system update
#     - common admin tools
#     - UFW firewall
#     - Fail2ban
#     - unattended security upgrades
#     - optional SSH hardening
#     - basic sysctl network hardening
#
# Intended usage:
#   This script is designed to be published on GitHub and called with a one-liner.
#
# Safer usage, recommended:
#   curl -fsSLO https://raw.githubusercontent.com/ORG/REPO/main/bootstrap.sh
#   less bootstrap.sh
#   sudo bash bootstrap.sh
#
# One-line usage:
#   curl -fsSL https://raw.githubusercontent.com/ORG/REPO/main/bootstrap.sh | sudo bash
#
# One-line usage with options:
#   curl -fsSL https://raw.githubusercontent.com/ORG/REPO/main/bootstrap.sh \
#     | sudo SSH_USER=inad ALLOW_HTTP=true ALLOW_HTTPS=true bash
#
# More aggressive usage after SSH key login has been tested:
#   curl -fsSL https://raw.githubusercontent.com/ORG/REPO/main/bootstrap.sh \
#     | sudo SSH_USER=inad DISABLE_PASSWORD_SSH=true bash
#
# VERY IMPORTANT WARNINGS:
#   1. Running remote scripts with curl | sudo bash is convenient but risky.
#      Review the script before using it on important machines.
#
#   2. Do NOT set DISABLE_PASSWORD_SSH=true unless you have already tested that
#      SSH key authentication works from a separate terminal.
#
#   3. If SSH_USER is wrong, SSH hardening may lock out other users.
#
#   4. If SSH_PORT is changed, make sure your provider/firewall allows that port.
#
#   5. UFW is enabled by default and will deny inbound traffic except SSH, and
#      optionally HTTP/HTTPS if ALLOW_HTTP/ALLOW_HTTPS are enabled.
#
#   6. This script is a baseline, not a complete security solution.
#
# Environment variables:
#   SSH_USER                     User allowed to connect through SSH.
#   SSH_PORT                     SSH port. Default: 22.
#   ENABLE_UPDATE                Update and upgrade packages. Default: true.
#   ENABLE_COMMON_TOOLS          Install common tools. Default: true.
#   ENABLE_UFW                   Enable UFW firewall. Default: true.
#   ENABLE_FAIL2BAN              Enable Fail2ban. Default: true.
#   ENABLE_UNATTENDED_UPGRADES   Enable automatic security upgrades. Default: true.
#   ENABLE_SSH_HARDENING         Apply SSH hardening. Default: true.
#   DISABLE_PASSWORD_SSH         Disable SSH password login. Default: false.
#   DISABLE_ROOT_SSH             Disable root SSH login. Default: true.
#   ALLOW_HTTP                   Open port 80. Default: false.
#   ALLOW_HTTPS                  Open port 443. Default: false.
#   ENABLE_SYSCTL_HARDENING      Apply basic sysctl hardening. Default: true.
#   DRY_RUN                      Print selected config and exit. Default: false.
#
# ==============================================================================n
# -----------------------------
# Configurable options
# -----------------------------

SSH_USER="${SSH_USER:-${SUDO_USER:-}}"
SSH_PORT="${SSH_PORT:-22}"

ENABLE_UPDATE="${ENABLE_UPDATE:-true}"
ENABLE_COMMON_TOOLS="${ENABLE_COMMON_TOOLS:-true}"
ENABLE_UFW="${ENABLE_UFW:-true}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"
ENABLE_UNATTENDED_UPGRADES="${ENABLE_UNATTENDED_UPGRADES:-true}"
ENABLE_SSH_HARDENING="${ENABLE_SSH_HARDENING:-true}"
ENABLE_SYSCTL_HARDENING="${ENABLE_SYSCTL_HARDENING:-true}"

# Sensitive options.
DISABLE_PASSWORD_SSH="${DISABLE_PASSWORD_SSH:-false}"
DISABLE_ROOT_SSH="${DISABLE_ROOT_SSH:-true}"

# Network service ports.
ALLOW_HTTP="${ALLOW_HTTP:-false}"
ALLOW_HTTPS="${ALLOW_HTTPS:-false}"

# Debug/helper mode.
DRY_RUN="${DRY_RUN:-false}"

# -----------------------------
# Display helpers
# -----------------------------

log() {
  printf '\n\033[1;32m[+] %s\033[0m\n' "$*"
}

warn() {
  printf '\n\033[1;33m[!] %s\033[0m\n' "$*"
}

error() {
  printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2
}

die() {
  error "$*"
  exit 1
}

# -----------------------------
# Validation helpers
# -----------------------------

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "This script must be run as root. Try: sudo bash bootstrap.sh"
  fi
}

is_true_or_false() {
  case "$1" in
    true|false) return 0 ;;
    *) return 1 ;;
  esac
}

validate_bool() {
  local name="$1"
  local value="$2"

  if ! is_true_or_false "$value"; then
    die "$name must be either 'true' or 'false'. Current value: $value"
  fi
}

validate_port() {
  case "$SSH_PORT" in
    ''|*[!0-9]*) die "SSH_PORT must be a number. Current value: $SSH_PORT" ;;
  esac

  if [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    die "SSH_PORT must be between 1 and 65535. Current value: $SSH_PORT"
  fi
}

backup_file() {
  local file="$1"

  if [ -f "$file" ]; then
    cp -a "$file" "${file}.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

print_config() {
  cat <<EOF

Ubuntu Bootstrap configuration
------------------------------
SSH_USER=$SSH_USER
SSH_PORT=$SSH_PORT
ENABLE_UPDATE=$ENABLE_UPDATE
ENABLE_COMMON_TOOLS=$ENABLE_COMMON_TOOLS
ENABLE_UFW=$ENABLE_UFW
ENABLE_FAIL2BAN=$ENABLE_FAIL2BAN
ENABLE_UNATTENDED_UPGRADES=$ENABLE_UNATTENDED_UPGRADES
ENABLE_SSH_HARDENING=$ENABLE_SSH_HARDENING
ENABLE_SYSCTL_HARDENING=$ENABLE_SYSCTL_HARDENING
DISABLE_PASSWORD_SSH=$DISABLE_PASSWORD_SSH
DISABLE_ROOT_SSH=$DISABLE_ROOT_SSH
ALLOW_HTTP=$ALLOW_HTTP
ALLOW_HTTPS=$ALLOW_HTTPS
DRY_RUN=$DRY_RUN

EOF
}

# -----------------------------
# Preflight checks
# -----------------------------

require_root

if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
else
  die "/etc/os-release not found. Cannot detect distribution."
fi

if [ "${ID:-}" != "ubuntu" ]; then
  warn "This script is designed for Ubuntu. Detected: ${PRETTY_NAME:-unknown}. Continuing anyway."
else
  log "Detected ${PRETTY_NAME:-Ubuntu}"
fi

# Try to detect the invoking user if SSH_USER was not passed.
if [ -z "$SSH_USER" ]; then
  SSH_USER="$(logname 2>/dev/null || true)"
fi

if [ -z "$SSH_USER" ]; then
  die "Cannot detect SSH_USER. Run with: sudo SSH_USER=youruser bash bootstrap.sh"
fi

if ! id "$SSH_USER" >/dev/null 2>&1; then
  die "SSH_USER '$SSH_USER' does not exist on this system."
fi

validate_port
validate_bool ENABLE_UPDATE "$ENABLE_UPDATE"
validate_bool ENABLE_COMMON_TOOLS "$ENABLE_COMMON_TOOLS"
validate_bool ENABLE_UFW "$ENABLE_UFW"
validate_bool ENABLE_FAIL2BAN "$ENABLE_FAIL2BAN"
validate_bool ENABLE_UNATTENDED_UPGRADES "$ENABLE_UNATTENDED_UPGRADES"
validate_bool ENABLE_SSH_HARDENING "$ENABLE_SSH_HARDENING"
validate_bool ENABLE_SYSCTL_HARDENING "$ENABLE_SYSCTL_HARDENING"
validate_bool DISABLE_PASSWORD_SSH "$DISABLE_PASSWORD_SSH"
validate_bool DISABLE_ROOT_SSH "$DISABLE_ROOT_SSH"
validate_bool ALLOW_HTTP "$ALLOW_HTTP"
validate_bool ALLOW_HTTPS "$ALLOW_HTTPS"
validate_bool DRY_RUN "$DRY_RUN"

print_config

if [ "$DRY_RUN" = "true" ]; then
  log "DRY_RUN=true, exiting without making changes."
  exit 0
fi

if [ "$DISABLE_PASSWORD_SSH" = "true" ]; then
  warn "DISABLE_PASSWORD_SSH=true was requested."
  warn "Make sure SSH key authentication already works, otherwise you may lock yourself out."
fi

if [ "$ENABLE_UFW" = "true" ]; then
  warn "UFW will be enabled and inbound traffic will be denied except explicitly allowed ports."
  warn "Allowed inbound ports: SSH/${SSH_PORT}${ALLOW_HTTP:+, HTTP/80}${ALLOW_HTTPS:+, HTTPS/443}"
fi

# -----------------------------
# System update
# -----------------------------

if [ "$ENABLE_UPDATE" = "true" ]; then
  log "Updating package lists and upgrading installed packages"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
  DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y
  apt-get autoclean -y
fi

# -----------------------------
# Common tools
# -----------------------------

if [ "$ENABLE_COMMON_TOOLS" = "true" ]; then
  log "Installing common administration tools"
  apt_install \
    ca-certificates \
    curl \
    wget \
    gnupg \
    lsb-release \
    software-properties-common \
    vim \
    nano \
    htop \
    ncdu \
    lsof \
    unzip \
    zip \
    rsync \
    git \
    dnsutils \
    net-tools \
    jq \
    tmux \
    tree
fi

# -----------------------------
# UFW firewall
# -----------------------------

if [ "$ENABLE_UFW" = "true" ]; then
  log "Installing and configuring UFW"
  apt_install ufw

  ufw default deny incoming
  ufw default allow outgoing

  # Always allow SSH before enabling UFW to avoid immediate lockout.
  ufw allow "${SSH_PORT}/tcp" comment "SSH"

  if [ "$ALLOW_HTTP" = "true" ]; then
    ufw allow 80/tcp comment "HTTP"
  fi

  if [ "$ALLOW_HTTPS" = "true" ]; then
    ufw allow 443/tcp comment "HTTPS"
  fi

  ufw --force enable
  ufw status verbose
fi

# -----------------------------
# Fail2ban
# -----------------------------

if [ "$ENABLE_FAIL2BAN" = "true" ]; then
  log "Installing and configuring Fail2ban for SSH"
  apt_install fail2ban

  cat >/etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
bantime = 1h
findtime = 10m
maxretry = 5
EOF

  systemctl enable --now fail2ban
  systemctl restart fail2ban
fi

# -----------------------------
# Unattended security upgrades
# -----------------------------

if [ "$ENABLE_UNATTENDED_UPGRADES" = "true" ]; then
  log "Installing and enabling unattended security upgrades"
  apt_install unattended-upgrades apt-listchanges

  cat >/etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

  systemctl enable --now unattended-upgrades || true
fi

# -----------------------------
# SSH hardening
# -----------------------------

if [ "$ENABLE_SSH_HARDENING" = "true" ]; then
  log "Applying SSH hardening"
  apt_install openssh-server

  mkdir -p /etc/ssh/sshd_config.d
  SSH_CONF="/etc/ssh/sshd_config.d/99-bootstrap-hardening.conf"
  backup_file "$SSH_CONF"

  # Notes:
  #   - AllowUsers restricts SSH logins to the selected user.
  #   - PasswordAuthentication stays enabled by default for safety.
  #   - To fully harden SSH, rerun with DISABLE_PASSWORD_SSH=true after testing keys.
  {
    echo "# Managed by ubuntu-bootstrap"
    echo "Port ${SSH_PORT}"
    echo "PubkeyAuthentication yes"
    echo "X11Forwarding no"
    echo "ClientAliveInterval 300"
    echo "ClientAliveCountMax 2"
    echo "MaxAuthTries 3"
    echo "LoginGraceTime 30"
    echo "AllowUsers ${SSH_USER}"

    if [ "$DISABLE_ROOT_SSH" = "true" ]; then
      echo "PermitRootLogin no"
    else
      echo "PermitRootLogin prohibit-password"
    fi

    if [ "$DISABLE_PASSWORD_SSH" = "true" ]; then
      echo "PasswordAuthentication no"
      echo "KbdInteractiveAuthentication no"
      echo "ChallengeResponseAuthentication no"
    else
      echo "PasswordAuthentication yes"
    fi
  } > "$SSH_CONF"

  # Validate before applying, to avoid breaking SSH with invalid syntax.
  sshd -t

  systemctl enable ssh
  systemctl reload ssh || systemctl restart ssh
fi

# -----------------------------
# SSH file permissions
# -----------------------------

log "Fixing SSH permissions for $SSH_USER"

USER_HOME="$(getent passwd "$SSH_USER" | cut -d: -f6)"

if [ -d "$USER_HOME/.ssh" ]; then
  chown -R "$SSH_USER:$SSH_USER" "$USER_HOME/.ssh"
  chmod 700 "$USER_HOME/.ssh"

  if [ -f "$USER_HOME/.ssh/authorized_keys" ]; then
    chmod 600 "$USER_HOME/.ssh/authorized_keys"
  fi
fi

# -----------------------------
# Basic sysctl hardening
# -----------------------------

if [ "$ENABLE_SYSCTL_HARDENING" = "true" ]; then
  log "Applying basic sysctl hardening"

  cat >/etc/sysctl.d/99-bootstrap-security.conf <<EOF
# Managed by ubuntu-bootstrap

# Ignore ICMP redirects.
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Do not send ICMP redirects.
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Ignore source-routed packets.
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Enable reverse path filtering.
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore broadcast ping and bogus ICMP errors.
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Enable address space layout randomization.
kernel.randomize_va_space = 2
EOF

  sysctl --system >/dev/null || true
fi

# -----------------------------
# Final summary
# -----------------------------

log "Bootstrap complete"

echo
echo "Summary"
echo "-------"
echo "User allowed through SSH: $SSH_USER"
echo "SSH port: $SSH_PORT"
echo "Password SSH disabled: $DISABLE_PASSWORD_SSH"
echo "Root SSH disabled: $DISABLE_ROOT_SSH"
echo

echo "UFW status:"
ufw status verbose 2>/dev/null || true

echo
echo "Fail2ban SSH status:"
fail2ban-client status sshd 2>/dev/null || true

echo
echo "SSH config test:"
sshd -t && echo "sshd config OK"

if [ "$DISABLE_PASSWORD_SSH" != "true" ]; then
  warn "SSH password authentication is still enabled."
  warn "After confirming SSH key login works, rerun with: DISABLE_PASSWORD_SSH=true"
fi

warn "A reboot is recommended if the kernel or critical packages were upgraded."
