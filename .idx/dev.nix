{ pkgs, ... }: {
  channel = "stable-24.11";

  packages = [
    pkgs.qemu
    pkgs.htop
    pkgs.cloudflared
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.wget
    pkgs.git
    pkgs.python3
  ];

  idx.workspace.onStart = {
    qemu = ''
      set -e

      # =========================
      # One-time cleanup
      # =========================
      if [ ! -f /home/user/.cleanup_done ]; then
        echo "Cleaning up..."
        rm -rf /home/user/.gradle/* || true
        rm -rf /home/user/.emu/* || true
        rm -rf /home/user/.android/* || true
        find /home/user -mindepth 1 -maxdepth 1 \
          ! -name 'vps' \
          ! -name '.cleanup_done' \
          ! -name '.*' \
          -exec rm -rf {} + || true
        touch /home/user/.cleanup_done
        echo "Cleanup done."
      else
        echo "Cleanup already done, skipping."
      fi

      # =========================
      # Paths
      # =========================
      VM_DIR="$HOME/qemu"
      DISK="$VM_DIR/ubuntu.qcow2"
      SEED_ISO="$VM_DIR/seed.iso"
      NOVNC_DIR="$HOME/noVNC"

      mkdir -p "$VM_DIR"

      # =========================
      # Download Ubuntu 24.04 cloud image if missing
      # =========================
      if [ ! -f "$DISK" ]; then
        echo "Downloading Ubuntu 24.04 cloud image..."
        wget -O "$DISK" \
          https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
        echo "Resizing disk to 20G..."
        qemu-img resize "$DISK" 20G
      else
        echo "Ubuntu disk already exists, skipping download."
      fi

      # =========================
      # Create cloud-init seed ISO (pure Python)
      # =========================
      if [ ! -f "$SEED_ISO" ] || [ ! -s "$SEED_ISO" ]; then
        echo "Creating cloud-init seed ISO..."

        python3 << 'PYEOF'
import struct, os, time

def pad(data, size):
    return data + b'\x00' * (size - len(data))

def make_iso(output_path, files):
    SECTOR = 2048
    # files: list of (name, content_bytes)

    # Layout:
    # Sector 0-15: system area
    # Sector 16: PVD
    # Sector 17: Volume Descriptor Set Terminator
    # Sector 18: Root directory
    # Sector 19+: File data

    file_start_sector = 19
    file_sectors = []
    offset = file_start_sector
    for name, content in files:
        file_sectors.append(offset)
        sectors_needed = (len(content) + SECTOR - 1) // SECTOR
        offset += sectors_needed

    total_sectors = offset

    def lsb_msb_16(n):
        return struct.pack('<H', n) + struct.pack('>H', n)

    def lsb_msb_32(n):
        return struct.pack('<I', n) + struct.pack('>I', n)

    def date_field(t=None):
        if t is None:
            t = time.gmtime()
        return bytes([
            t.tm_year - 1900,
            t.tm_mon, t.tm_mday,
            t.tm_hour, t.tm_min, t.tm_sec, 0
        ])

    def dir_record(name_bytes, sector, size, is_dir=False):
        flags = 0x02 if is_dir else 0x00
        name_len = len(name_bytes)
        record_len = 33 + name_len
        if record_len % 2 != 0:
            record_len += 1
        rec = bytes([record_len, 0])
        rec += lsb_msb_32(sector)
        rec += lsb_msb_32(size)
        rec += date_field()
        rec += bytes([flags, 0, 0])
        rec += lsb_msb_16(1)
        rec += bytes([name_len]) + name_bytes
        if len(rec) % 2 != 0:
            rec += b'\x00'
        return rec

    # Build root directory sector
    root_dir = b''
    root_dir += dir_record(b'\x00', 18, SECTOR, is_dir=True)  # .
    root_dir += dir_record(b'\x01', 18, SECTOR, is_dir=True)  # ..
    for i, (name, content) in enumerate(files):
        root_dir += dir_record(name.upper().encode(), file_sectors[i], len(content))
    root_dir_padded = pad(root_dir, SECTOR)

    # Build PVD
    pvd = b'\x01'
    pvd += b'CD001\x01\x00'
    pvd += b' ' * 32  # system id
    pvd += pad(b'CIDATA', 32)  # volume id
    pvd += b'\x00' * 8
    pvd += lsb_msb_32(total_sectors)
    pvd += b'\x00' * 32
    pvd += lsb_msb_16(1)  # volume set size
    pvd += lsb_msb_16(1)  # volume sequence number
    pvd += lsb_msb_16(SECTOR)
    pvd += lsb_msb_32(total_sectors * SECTOR)  # path table size approx
    pvd += struct.pack('<I', 0)  # L path table
    pvd += struct.pack('<I', 0)
    pvd += struct.pack('>I', 0)  # M path table
    pvd += struct.pack('>I', 0)
    pvd += dir_record(b'\x00', 18, SECTOR, is_dir=True)  # root dir record (34 bytes)
    pvd += b' ' * 128  # volume set id
    pvd += b' ' * 128  # publisher
    pvd += b' ' * 128  # data preparer
    pvd += b' ' * 128  # application
    pvd += b' ' * 37   # copyright
    pvd += b' ' * 37   # abstract
    pvd += b' ' * 37   # bibliographic
    pvd += b'0001010000000000\x00'  # creation date
    pvd += b'0000000000000000\x00'  # modification
    pvd += b'0000000000000000\x00'  # expiration
    pvd += b'0000000000000000\x00'  # effective
    pvd += b'\x01\x00'
    pvd = pad(pvd, SECTOR)

    # Terminator
    term = pad(b'\xff' + b'CD001\x01', SECTOR)

    with open(output_path, 'wb') as f:
        # System area (sectors 0-15)
        f.write(b'\x00' * (16 * SECTOR))
        # PVD (sector 16)
        f.write(pvd)
        # Terminator (sector 17)
        f.write(term)
        # Root directory (sector 18)
        f.write(root_dir_padded)
        # File data
        for name, content in files:
            sectors_needed = (len(content) + SECTOR - 1) // SECTOR
            f.write(pad(content, sectors_needed * SECTOR))

    print(f"ISO created: {output_path} ({os.path.getsize(output_path)} bytes)")

meta_data = b"""instance-id: ubuntu-qemu-01
local-hostname: ubuntu-vm
"""

user_data = b"""#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: ""

chpasswd:
  expire: false
  list:
    - ubuntu:ubuntu

ssh_pwauth: true

package_update: true
package_upgrade: false

packages:
  - xfce4
  - xfce4-goodies
  - x11vnc
  - xvfb
  - dbus-x11
  - wget
  - curl
  - htop
  - nano
  - net-tools

runcmd:
  - passwd -d ubuntu
  - mkdir -p /home/ubuntu/.vnc
  - echo "ubuntu" | x11vnc -storepasswd - /home/ubuntu/.vnc/passwd
  - chown -R ubuntu:ubuntu /home/ubuntu/.vnc
  - |
    cat > /home/ubuntu/start-vnc.sh << 'VNCEOF'
    #!/bin/bash
    export DISPLAY=:0
    Xvfb :0 -screen 0 1280x800x24 &
    sleep 2
    startxfce4 &
    sleep 3
    x11vnc -display :0 -rfbport 5900 -passwd ubuntu -forever -shared -bg
    VNCEOF
  - chmod +x /home/ubuntu/start-vnc.sh
  - chown ubuntu:ubuntu /home/ubuntu/start-vnc.sh
  - |
    cat > /etc/systemd/system/xvnc.service << 'SVCEOF'
    [Unit]
    Description=XFCE + x11vnc Desktop
    After=network.target
    [Service]
    User=ubuntu
    Environment=DISPLAY=:0
    ExecStartPre=/bin/bash -c "Xvfb :0 -screen 0 1280x800x24 &"
    ExecStartPre=/bin/sleep 2
    ExecStart=/bin/bash -c "startxfce4 & sleep 3 && x11vnc -display :0 -rfbport 5900 -passwd ubuntu -forever -shared"
    Restart=on-failure
    [Install]
    WantedBy=multi-user.target
    SVCEOF
  - systemctl enable xvnc.service
  - systemctl start xvnc.service
"""

import os
make_iso(os.environ['HOME'] + '/qemu/seed.iso', [
    ('meta-data', meta_data),
    ('user-data', user_data),
])
PYEOF

        if [ -s "$SEED_ISO" ]; then
          echo "✅ Seed ISO created: $(ls -lh $SEED_ISO | awk '{print $5}')"
        else
          echo "❌ Seed ISO creation failed!"
          exit 1
        fi
      else
        echo "Seed ISO already exists, skipping."
      fi

      # =========================
      # Clone noVNC if missing
      # =========================
      if [ ! -d "$NOVNC_DIR/.git" ]; then
        echo "Cloning noVNC..."
        mkdir -p "$NOVNC_DIR"
        git clone https://github.com/novnc/noVNC.git "$NOVNC_DIR"
      else
        echo "noVNC already exists, skipping clone."
      fi

      # =========================
      # Start QEMU
      # =========================
      echo "Starting QEMU with Ubuntu..."
      nohup qemu-system-x86_64 \
        -enable-kvm \
        -cpu host \
        -smp 4,cores=4 \
        -m 8192 \
        -M q35 \
        -device qemu-xhci \
        -device usb-tablet \
        -vga virtio \
        -netdev user,id=n0,hostfwd=tcp::2222-:22 \
        -net nic,netdev=n0,model=virtio-net-pci \
        -drive file="$DISK",format=qcow2,if=virtio \
        -drive file="$SEED_ISO",format=raw,if=virtio,readonly=on \
        -vnc :0 \
        -display none \
        > /tmp/qemu.log 2>&1 &

      echo "QEMU started. Waiting for VM to boot..."
      sleep 5

      # =========================
      # Start noVNC on port 8888
      # =========================
      echo "Starting noVNC..."
      nohup "$NOVNC_DIR/utils/novnc_proxy" \
        --vnc 127.0.0.1:5900 \
        --listen 8888 \
        > /tmp/novnc.log 2>&1 &

      # =========================
      # Start Cloudflared tunnel
      # =========================
      echo "Starting Cloudflared tunnel..."
      nohup cloudflared tunnel \
        --no-autoupdate \
        --url http://localhost:8888 \
        > /tmp/cloudflared.log 2>&1 &

      sleep 15

      if grep -q "trycloudflare.com" /tmp/cloudflared.log; then
        URL=$(grep -o "https://[a-z0-9.-]*trycloudflare.com" /tmp/cloudflared.log | head -n1)
        echo "========================================="
        echo " 🐧 Ubuntu Server + XFCE ready:"
        echo "     $URL/vnc.html"
        echo "     VNC Password: ubuntu"
        echo "     SSH: ssh -p 2222 ubuntu@localhost"
        echo "========================================="
        mkdir -p /home/user/vps
        echo "$URL/vnc.html" > /home/user/vps/noVNC-URL.txt
        echo "✅ URL saved to ~/vps/noVNC-URL.txt"
      else
        echo "❌ Cloudflared tunnel failed. Check /tmp/cloudflared.log"
      fi

      # =========================
      # Keep workspace alive
      # =========================
      elapsed=0
      while true; do
        echo "⏱️  Time elapsed: $elapsed min | QEMU: $(pgrep qemu-system > /dev/null && echo running || echo STOPPED)"
        ((elapsed++))
        sleep 60
      done
    '';
  };

  idx.previews = {
    enable = true;
    previews = {
      qemu = {
        manager = "web";
        command = [
          "bash" "-lc"
          "echo 'noVNC running on port 8888'"
        ];
      };
      terminal = {
        manager = "web";
        command = [ "bash" ];
      };
    };
  };
}
