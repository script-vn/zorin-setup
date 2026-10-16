#!/usr/bin/env bash
# =============================================================================
# SASIN - Zorin OS bootstrap
# Chuẩn bị máy Zorin mới cài để Ansible (SS01-Ansible01) quản lý được.
#
# Chạy:
#   curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/zorin-bootstrap.sh | sudo bash
#
# Tuỳ chọn (truyền qua biến môi trường):
#   curl -fsSL <URL> | sudo NEW_HOSTNAME=SS01-ZORIN01 SSH_PORT=22 bash
#
# Script chạy lại nhiều lần vẫn an toàn (idempotent).
# KHÔNG đưa mật khẩu / private key vào file này - repo là public.
# =============================================================================
set -euo pipefail

# ----------------------------- Cấu hình -------------------------------------
ADMIN_USER="${ADMIN_USER:-zorin-it}"            # user Ansible SSH vào
SSH_PORT="${SSH_PORT:-22}"
SSH_ALLOW_FROM="${SSH_ALLOW_FROM:-192.168.1.0/24}"   # dải được phép SSH (ufw)
TIMEZONE="${TIMEZONE:-Asia/Ho_Chi_Minh}"
NEW_HOSTNAME="${NEW_HOSTNAME:-}"                 # để trống = hỏi / giữ nguyên
INSTALL_CHROME="${INSTALL_CHROME:-yes}"
INSTALL_UNIKEY="${INSTALL_UNIKEY:-yes}"
ENABLE_UFW="${ENABLE_UFW:-yes}"

# Public key của Ansible server (SS01-Ansible01). Public key, đưa lên git được.
ANSIBLE_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBrfh31PIk+Ld1uchVbUMobJHMegcq2AS7RJ/F/Rkdvh ansible@SS01-Ansible01"

BASE_PACKAGES=(openssh-server python3 python3-apt sudo curl wget ca-certificates gnupg vim htop net-tools chrony ufw)

# ----------------------------- Helpers --------------------------------------
log()  { printf '\n\e[1;32m==> %s\e[0m\n' "$*"; }
warn() { printf '\e[1;33m[!] %s\e[0m\n' "$*"; }
die()  { printf '\e[1;31m[x] %s\e[0m\n' "$*" >&2; exit 1; }

# Đọc input từ bàn phím kể cả khi script chạy qua "curl | bash"
ask() { local __v; read -r -p "$1" __v < /dev/tty || true; printf '%s' "$__v"; }

[[ $EUID -eq 0 ]] || die "Hãy chạy bằng sudo: curl -fsSL <URL> | sudo bash"
. /etc/os-release
[[ "${ID:-}" == "zorin" || "${ID_LIKE:-}" == *ubuntu* ]] || die "Script chỉ dành cho Zorin OS / Ubuntu."

export DEBIAN_FRONTEND=noninteractive
DESKTOP_USER="${SUDO_USER:-}"

# ----------------------------- 1. Hostname ----------------------------------
log "Hostname hiện tại: $(hostname)"
if [[ -z "$NEW_HOSTNAME" && -e /dev/tty ]]; then
  NEW_HOSTNAME="$(ask 'Nhập hostname mới theo chuẩn SASIN (Enter = giữ nguyên): ')"
fi
if [[ -n "$NEW_HOSTNAME" && "$NEW_HOSTNAME" != "$(hostname)" ]]; then
  hostnamectl set-hostname "$NEW_HOSTNAME"
  if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $NEW_HOSTNAME/" /etc/hosts
  else
    echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
  fi
  log "Đã đổi hostname -> $NEW_HOSTNAME"
fi

# ----------------------------- 2. Timezone ----------------------------------
log "Timezone -> $TIMEZONE"
timedatectl set-timezone "$TIMEZONE"

# ----------------------------- 3. Package cơ bản ----------------------------
log "Cập nhật apt & cài package cơ bản"
apt-get update
apt-get install -y "${BASE_PACKAGES[@]}"
systemctl enable --now chrony

# ----------------------------- 4. User Ansible ------------------------------
log "User quản trị: $ADMIN_USER"
if ! id "$ADMIN_USER" &>/dev/null; then
  useradd -m -s /bin/bash -c "SASIN IT (Ansible)" "$ADMIN_USER"
  log "Đặt mật khẩu cho $ADMIN_USER (dùng cho sudo / --ask-become-pass)"
  until passwd "$ADMIN_USER" < /dev/tty; do warn "Thử lại"; done
fi
usermod -aG sudo "$ADMIN_USER"

ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ADMIN_HOME/.ssh"
AUTH_KEYS="$ADMIN_HOME/.ssh/authorized_keys"
touch "$AUTH_KEYS"
KEY_BODY="$(awk '{print $2}' <<< "$ANSIBLE_PUBKEY")"
grep -qF "$KEY_BODY" "$AUTH_KEYS" || echo "$ANSIBLE_PUBKEY" >> "$AUTH_KEYS"
chown "$ADMIN_USER:$ADMIN_USER" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

# ----------------------------- 5. SSH server --------------------------------
log "Cấu hình SSH (port $SSH_PORT)"
cat > /etc/ssh/sshd_config.d/10-sasin.conf <<EOF
# Managed by zorin-bootstrap.sh
Port $SSH_PORT
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication yes
EOF
sshd -t || die "Cấu hình sshd lỗi"

# Ubuntu 24.04+ dùng ssh.socket: port do socket quyết định.
# Bản mới có sshd-socket-generator tự đọc "Port" trong sshd_config -> chỉ cần reload.
# Bản cũ không có generator -> tự viết override cho socket.
GEN=/usr/lib/systemd/system-generators/sshd-socket-generator
if systemctl is-enabled ssh.socket &>/dev/null && [[ ! -x "$GEN" ]]; then
  mkdir -p /etc/systemd/system/ssh.socket.d
  cat > /etc/systemd/system/ssh.socket.d/10-sasin.conf <<EOF
[Socket]
ListenStream=
ListenStream=$SSH_PORT
EOF
fi
systemctl daemon-reload
if systemctl is-enabled ssh.socket &>/dev/null; then
  systemctl restart ssh.socket
else
  systemctl enable --now ssh
  systemctl restart ssh
fi

# ----------------------------- 6. Firewall ----------------------------------
if [[ "$ENABLE_UFW" == "yes" ]]; then
  log "UFW: chỉ cho SSH từ $SSH_ALLOW_FROM"
  ufw allow from "$SSH_ALLOW_FROM" to any port "$SSH_PORT" proto tcp comment 'SSH SASIN' >/dev/null
  ufw default deny incoming  >/dev/null
  ufw default allow outgoing >/dev/null
  ufw --force enable
fi

# ----------------------------- 7. Google Chrome -----------------------------
if [[ "$INSTALL_CHROME" == "yes" ]]; then
  if ! dpkg -s google-chrome-stable &>/dev/null; then
    log "Cài Google Chrome"
    # Dùng .deb chính thức: gói tự thêm repo Google để apt cập nhật sau này
    # (tự thêm repo bằng tay dễ xung đột Signed-By với repo gói tự tạo).
    TMP_DEB="$(mktemp --suffix=.deb)"
    curl -fsSL -o "$TMP_DEB" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    chmod 644 "$TMP_DEB"
    apt-get install -y "$TMP_DEB"
    rm -f "$TMP_DEB"
  else
    log "Google Chrome đã có - bỏ qua"
  fi
fi

# ----------------------------- 8. Fcitx5 + Unikey --------------------------
if [[ "$INSTALL_UNIKEY" == "yes" ]]; then
  log "Cài fcitx5-unikey"
  apt-get install -y fcitx5 fcitx5-unikey fcitx5-config-qt \
    fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 fcitx5-frontend-qt5 im-config

  # Mặc định input method cho mọi user
  if [[ -f /etc/default/im-config ]]; then
    sed -i 's/^IM_CONFIG_DEFAULT_MODE=.*/IM_CONFIG_DEFAULT_MODE=fcitx5/' /etc/default/im-config
  fi

  # Profile mặc định: English + Unikey. Đặt vào /etc/skel để user mới
  # (kể cả user AD tạo home qua pam_mkhomedir) tự có.
  write_profile() {
    local dir="$1"
    install -d -m 755 "$dir"
    cat > "$dir/profile" <<'EOF'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=unikey

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=unikey
Layout=

[GroupOrder]
0=Default
EOF
  }
  write_profile /etc/skel/.config/fcitx5

  # User đang đăng nhập (người chạy sudo) - chỉ tạo nếu chưa có profile
  if [[ -n "$DESKTOP_USER" && "$DESKTOP_USER" != "root" ]]; then
    U_HOME="$(getent passwd "$DESKTOP_USER" | cut -d: -f6)"
    if [[ ! -f "$U_HOME/.config/fcitx5/profile" ]]; then
      write_profile "$U_HOME/.config/fcitx5"
      chown -R "$DESKTOP_USER:$DESKTOP_USER" "$U_HOME/.config"
    fi
    sudo -u "$DESKTOP_USER" im-config -n fcitx5 || true
  fi
fi

# ----------------------------- Kết quả --------------------------------------
IP4="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
log "HOÀN TẤT"
cat <<EOF
  Hostname : $(hostname)
  IP       : ${IP4:-?}
  SSH      : port $SSH_PORT, user $ADMIN_USER (key Ansible đã được thêm)

  Dòng inventory cho Ansible server:
    $(hostname | tr 'A-Z' 'a-z') ansible_host=${IP4:-<IP>} ansible_user=$ADMIN_USER$( [[ "$SSH_PORT" != 22 ]] && echo " ansible_port=$SSH_PORT")

  Đăng xuất / khởi động lại để bộ gõ Unikey có hiệu lực (Ctrl+Space để bật/tắt).
EOF
