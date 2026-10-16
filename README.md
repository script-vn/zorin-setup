# zorin-setup

Script khởi tạo máy Zorin OS mới cài, để Ansible server quản lý được.

## Chạy

Trên máy Zorin, mở Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/script-vn/zorin-setup/main/zorin-bootstrap.sh | sudo bash
```

Truyền sẵn tuỳ chọn (không bị hỏi):

```bash
curl -fsSL https://raw.githubusercontent.com/script-vn/zorin-setup/main/zorin-bootstrap.sh | sudo NEW_HOSTNAME=SS01-ZORIN01 bash
```

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `NEW_HOSTNAME` | (hỏi) | Hostname theo chuẩn |
| `ADMIN_USER` | `zorin-it` | User Ansible SSH vào |
| `SSH_PORT` | `22` | Port SSH |
| `SSH_ALLOW_FROM` | `192.168.1.0/24` | Dải IP được SSH (ufw) |
| `TIMEZONE` | `Asia/Ho_Chi_Minh` | Múi giờ |
| `INSTALL_CHROME` | `yes` | Cài Google Chrome |
| `INSTALL_UNIKEY` | `yes` | Cài fcitx5-unikey |
| `ENABLE_UFW` | `yes` | Bật firewall |

## Script làm gì
1. Đặt hostname, timezone
2. Cài openssh-server, python3, chrony, ufw, công cụ cơ bản
3. Tạo user `zorin-it` (sudo) + thêm public key của Ansible server
4. Cấu hình SSH (port, cấm root login)
5. Bật ufw, chỉ cho SSH từ LAN
6. Cài Google Chrome (repo chính thức)
7. Cài fcitx5 + Unikey, đặt làm bộ gõ mặc định cho mọi user

> Repo public: không bao giờ commit mật khẩu hay private key.
