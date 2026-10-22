#!/usr/bin/env bash
# =============================================================================
# SASIN - Zorin OS bootstrap
# Chuẩn bị máy Zorin mới cài để Ansible (SS01-Ansible01) quản lý được.
#
# Yêu cầu: lúc cài Zorin đã đặt hostname chuẩn và tạo user "zorin-it".
#
# Chạy:
#   curl -fsSL https://raw.githubusercontent.com/script-vn/zorin-setup/main/zorin-bootstrap.sh | sudo bash
#
# Tuỳ chọn (truyền qua biến môi trường):
#   curl -fsSL <URL> | sudo SSH_PORT=22 ENABLE_XRDP=no bash
#
# Script chạy lại nhiều lần vẫn an toàn (idempotent).
# KHÔNG đưa mật khẩu / private key vào file này - repo là public.
# =============================================================================
set -euo pipefail

# ----------------------------- Cấu hình -------------------------------------
ADMIN_USER="${ADMIN_USER:-zorin-it}"                 # user Ansible SSH vào
SSH_PORT="${SSH_PORT:-22}"
LAN_ALLOW_FROM="${LAN_ALLOW_FROM:-192.168.1.0/24}"   # dải được SSH / RDP (ufw)
TIMEZONE="${TIMEZONE:-Asia/Ho_Chi_Minh}"
INSTALL_CHROME="${INSTALL_CHROME:-yes}"
INSTALL_UNIKEY="${INSTALL_UNIKEY:-yes}"
ENABLE_XRDP="${ENABLE_XRDP:-yes}"
ENABLE_UFW="${ENABLE_UFW:-yes}"

# Public key của Ansible server (SS01-Ansible01). Public key, đưa lên git được.
ANSIBLE_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBrfh31PIk+Ld1uchVbUMobJHMegcq2AS7RJ/F/Rkdvh ansible@SS01-Ansible01"

BASE_PACKAGES=(openssh-server python3 python3-apt sudo curl wget ca-certificates gnupg vim htop net-tools chrony ufw)

# ----------------------------- Helpers --------------------------------------
log()  { printf '\n\e[1;32m==> %s\e[0m\n' "$*"; }

# Zorin vừa cài xong tự chạy kiểm tra cập nhật nền (packagekitd / unattended-upgrades) và giữ khoá apt
# -> chờ cho xong thay vì báo lỗi "Could not get lock /var/lib/apt/lists/lock".
APT_LOCKS=(/var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock)
apt_wait() {
  local i=0
  systemctl stop packagekit 2>/dev/null || true
  while fuser "${APT_LOCKS[@]}" >/dev/null 2>&1; do
    (( i == 0 )) && echo "   Zorin đang tự cập nhật nền - chờ xong (tối đa 10 phút)..."
    (( ++i > 120 )) && { echo "[x] Quá 10 phút vẫn bận - khởi động lại máy rồi chạy lại script" >&2; exit 1; }
    sleep 5
  done
}
apt_get() { apt_wait; apt-get -o DPkg::Lock::Timeout=300 "$@"; }
warn() { printf '\e[1;33m[!] %s\e[0m\n' "$*"; }
die()  { printf '\e[1;31m[x] %s\e[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Hãy chạy bằng sudo: curl -fsSL <URL> | sudo bash"
. /etc/os-release
[[ "${ID:-}" == "zorin" || "${ID_LIKE:-}" == *ubuntu* ]] || die "Script chỉ dành cho Zorin OS / Ubuntu."
id "$ADMIN_USER" &>/dev/null || die "Chưa có user '$ADMIN_USER'. Hãy tạo user này lúc cài OS (hoặc chạy với ADMIN_USER=<tên>)."

export DEBIAN_FRONTEND=noninteractive
DESKTOP_USER="${SUDO_USER:-}"

# ----------------------------- 1. Timezone ----------------------------------
log "Timezone -> $TIMEZONE"
timedatectl set-timezone "$TIMEZONE"

# ----------------------------- 2. Package cơ bản ----------------------------
log "Cập nhật apt & cài package cơ bản"
apt_get update
apt_get install -y "${BASE_PACKAGES[@]}"
systemctl enable --now chrony

# ----------------------------- 3. User Ansible ------------------------------
log "User quản trị: $ADMIN_USER (sudo + key Ansible)"
id -nG "$ADMIN_USER" | grep -qw sudo || usermod -aG sudo "$ADMIN_USER"

ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ADMIN_HOME/.ssh"
AUTH_KEYS="$ADMIN_HOME/.ssh/authorized_keys"
touch "$AUTH_KEYS"
KEY_BODY="$(awk '{print $2}' <<< "$ANSIBLE_PUBKEY")"
grep -qF "$KEY_BODY" "$AUTH_KEYS" || echo "$ANSIBLE_PUBKEY" >> "$AUTH_KEYS"
chown "$ADMIN_USER:$ADMIN_USER" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

# ----------------------------- 4. SSH server --------------------------------
log "Cấu hình SSH (port $SSH_PORT)"
cat > /etc/ssh/sshd_config.d/10-sasin.conf <<EOF
# Managed by zorin-bootstrap.sh
Port $SSH_PORT
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication yes
EOF
# Với ssh.socket, /run/sshd chỉ được tạo khi có kết nối đầu tiên -> tạo trước để sshd -t chạy được
install -d -m 755 /run/sshd
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

# ----------------------------- 5. Remote Desktop (xrdp) ---------------------
if [[ "$ENABLE_XRDP" == "yes" ]]; then
  log "Cài Remote Desktop (xrdp, port 3389)"
  apt_get install -y xrdp xorgxrdp
  id -nG xrdp | grep -qw ssl-cert || usermod -aG ssl-cert xrdp

  # Mở đúng giao diện Zorin trong phiên RDP (thay vì desktop trống / màn hình đen)
  cat > /etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
# Managed by zorin-bootstrap.sh
if [ -r /etc/default/locale ]; then
  . /etc/default/locale
  export LANG LANGUAGE
fi
# Giữ XDG_RUNTIME_DIR: Xsession dùng nó để tìm user bus /run/user/<uid>/bus
unset DBUS_SESSION_BUS_ADDRESS

DESKTOP_FILE=$(ls /usr/share/xsessions/zorin*.desktop 2>/dev/null | head -n1)
if [ -n "$DESKTOP_FILE" ]; then
  XDG_CURRENT_DESKTOP=$(sed -n 's/^DesktopNames=//p' "$DESKTOP_FILE" | head -n1 | tr ';' ':' | sed 's/:$//')
  XDG_SESSION_DESKTOP=$(basename "$DESKTOP_FILE" .desktop)
  XDG_SESSION_TYPE=x11
  export XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE
  SESSION_CMD=$(sed -n 's/^Exec=//p' "$DESKTOP_FILE" | head -n1)
  exec /etc/X11/Xsession "$SESSION_CMD"
fi
exec /etc/X11/Xsession
EOF
  chmod 755 /etc/xrdp/startwm.sh

  # Tắt popup "Authentication required to create a color managed device" khi RDP
  if [[ -d /etc/polkit-1/rules.d ]]; then
    cat > /etc/polkit-1/rules.d/45-allow-colord.rules <<'EOF'
// Managed by zorin-bootstrap.sh
polkit.addRule(function(action, subject) {
  if (action.id.indexOf("org.freedesktop.color-manager.") == 0) {
    return polkit.Result.YES;
  }
});
EOF
  fi
  if [[ -d /etc/polkit-1/localauthority ]]; then
    install -d /etc/polkit-1/localauthority/50-local.d
    cat > /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla <<'EOF'
[Allow Colord all Users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.*
ResultAny=no
ResultInactive=no
ResultActive=yes
EOF
  fi

  # Cert tự ký (snakeoil) được tạo lúc cài OS với hostname cũ -> tạo lại theo hostname hiện tại
  if ! openssl x509 -in /etc/ssl/certs/ssl-cert-snakeoil.pem -noout -subject 2>/dev/null \
       | grep -qiE "CN *= *$(hostname)\$"; then
    make-ssl-cert generate-default-snakeoil --force-overwrite
  fi

  systemctl enable xrdp
  systemctl restart xrdp
  systemctl is-active --quiet xrdp || warn "xrdp chưa chạy - kiểm tra: journalctl -u xrdp"
fi

# ----------------------------- 6. Firewall ----------------------------------
if [[ "$ENABLE_UFW" == "yes" ]]; then
  log "UFW: chỉ cho SSH/RDP từ $LAN_ALLOW_FROM"
  ufw allow from "$LAN_ALLOW_FROM" to any port "$SSH_PORT" proto tcp comment 'SSH SASIN' >/dev/null
  [[ "$ENABLE_XRDP" == "yes" ]] && \
    ufw allow from "$LAN_ALLOW_FROM" to any port 3389 proto tcp comment 'RDP SASIN' >/dev/null
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
    apt_get install -y "$TMP_DEB"
    rm -f "$TMP_DEB"
  else
    log "Google Chrome đã có - bỏ qua"
  fi
fi

# ----------------------------- 8. Fcitx5 + Unikey --------------------------
if [[ "$INSTALL_UNIKEY" == "yes" ]]; then
  log "Cài fcitx5-unikey"
  apt_get install -y fcitx5 fcitx5-unikey fcitx5-config-qt \
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
IFACE="$(ip -4 route show default | awk '{print $5; exit}')"
IP4="$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
MAC="$(cat "/sys/class/net/$IFACE/address" 2>/dev/null | tr 'a-f' 'A-F')"
GW="$(ip -4 route show default | awk '{print $3; exit}')"
HOST="$(hostname)"

log "HOÀN TẤT"
cat <<EOF

  ┌──────────────────────────────────────────────────────────┐
     Hostname  : $HOST
     Interface : ${IFACE:-?}
     IP        : ${IP4:-?}
     MAC       : ${MAC:-?}
     Gateway   : ${GW:-?}
  └──────────────────────────────────────────────────────────┘

  [Bước 3] MikroTik - cố định IP hiện tại (Terminal Winbox):
    /ip dhcp-server lease make-static [find mac-address=$MAC]
    /ip dhcp-server lease set [find mac-address=$MAC] comment="$HOST"

  [Bước 4-6] Trên SS01-Ansible01 (join AD + áp toàn bộ chính sách):
    cd ~/ansible-sasin && ./add-zorin.sh ${IP4:-<IP>}
    -> cuối lệnh có BÁO CÁO PHẦN CỨNG: xử lý mục ❌ / ⚠️ (khởi động lại nếu được yêu cầu)

  [Checklist tại máy] sau bước 4-6:
    Wi-Fi | loa + tai nghe + mic | webcam | màn hình ngoài HDMI + USB-C (không chớp)
    gập máy -> mở lại | phím sáng/âm lượng, touchpad | in thử | user AD: NAS, shortcut, Unikey

  [SSH]  ssh $ADMIN_USER@${IP4:-<IP>}$( [[ "$SSH_PORT" != 22 ]] && echo " -p $SSH_PORT")
EOF
if [[ "$ENABLE_XRDP" == "yes" ]]; then
cat <<EOF
  [RDP]  Windows: mstsc -> ${IP4:-<IP>}  (đăng nhập bằng user Linux / AD)
         Lưu ý: user đó phải ĐĂNG XUẤT trên máy thật trước khi RDP.
EOF
fi
cat <<EOF

  Đăng xuất / khởi động lại để bộ gõ Unikey có hiệu lực (Ctrl+Space bật/tắt).
EOF
