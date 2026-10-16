# zorin-setup

Script khởi tạo máy Zorin OS mới cài, để Ansible server quản lý được.

**Yêu cầu:** lúc cài Zorin đã đặt hostname theo chuẩn và tạo user `zorin-it`.

## Chạy

Trên máy Zorin, mở Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/script-vn/zorin-setup/main/zorin-bootstrap.sh | sudo bash
```

Truyền tuỳ chọn:

```bash
curl -fsSL https://raw.githubusercontent.com/script-vn/zorin-setup/main/zorin-bootstrap.sh | sudo ENABLE_XRDP=no bash
```

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `ADMIN_USER` | `zorin-it` | User Ansible SSH vào (phải có sẵn) |
| `SSH_PORT` | `22` | Port SSH |
| `LAN_ALLOW_FROM` | `192.168.1.0/24` | Dải IP được SSH / RDP (ufw) |
| `TIMEZONE` | `Asia/Ho_Chi_Minh` | Múi giờ |
| `INSTALL_CHROME` | `yes` | Cài Google Chrome |
| `INSTALL_UNIKEY` | `yes` | Cài fcitx5-unikey |
| `ENABLE_XRDP` | `yes` | Remote Desktop (RDP, port 3389) |
| `ENABLE_UFW` | `yes` | Bật firewall |

## Script làm gì
1. Timezone, chrony
2. Cài openssh-server, python3, ufw, công cụ cơ bản
3. Thêm `zorin-it` vào nhóm sudo + public key của Ansible server
4. Cấu hình SSH (port, cấm root login)
5. Cài xrdp – remote từ Windows bằng `mstsc`
6. Bật ufw, chỉ cho SSH/RDP từ LAN
7. Cài Google Chrome (repo chính thức)
8. Cài fcitx5 + Unikey, đặt làm bộ gõ mặc định cho mọi user
9. In ra Hostname / IP / MAC + lệnh MikroTik cố định IP (bước 3) + lệnh add-zorin.sh cho server (bước 4-6)

> Repo public: không bao giờ commit mật khẩu hay private key.
