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
        rm -rf /home/user/.gradle/* /home/user/.emu/* || true
        find /home/user -mindepth 1 -maxdepth 1 \
          ! -name 'idx-linux-gui' \
          ! -name '.cleanup_done' \
          ! -name '.*' \
          -exec rm -rf {} + || true
        touch /home/user/.cleanup_done
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
      # Create cloud-init seed ISO
      # =========================
      if [ ! -f "$SEED_ISO" ]; then
        echo "Creating cloud-init seed ISO..."
        mkdir -p /tmp/cidata

        cat > /tmp/cidata/meta-data << 'EOF'
instance-id: ubuntu-qemu-01
local-hostname: ubuntu-vm
EOF

        cat > /tmp/cidata/user-data << 'EOF'
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: "ubuntu"

chpasswd:
  expire: false

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
EOF

        python3 << 'PYEOF'
import subprocess, shutil

try:
    subprocess.run(['dd', 'if=/dev/zero', 'of=/tmp/seed.img',
                    'bs=1k', 'count=2048'], check=True, capture_output=True)
    subprocess.run(['mkfs.vfat', '-n', 'cidata', '/tmp/seed.img'],
                   check=True, capture_output=True)
    subprocess.run(['mcopy', '-i', '/tmp/seed.img',
                    '/tmp/cidata/meta-data', '::meta-data'],
                   check=True, capture_output=True)
    subprocess.run(['mcopy', '-i', '/tmp/seed.img',
                    '/tmp/cidata/user-data', '::user-data'],
                   check=True, capture_output=True)
    shutil.copy('/tmp/seed.img', '/tmp/seed_final.img')
    print("Seed image created via vfat")
except Exception as e:
    print(f"vfat failed: {e}, trying genisoimage...")
    try:
        subprocess.run(
            ['genisoimage', '-output', '/tmp/seed_final.img',
             '-volid', 'cidata', '-joliet', '-rock',
             '/tmp/cidata/meta-data', '/tmp/cidata/user-data'],
            check=True, capture_output=True)
        print("Seed image created via genisoimage")
    except Exception as e2:
        print(f"Both methods failed: {e2}")
PYEOF

        if [ -f /tmp/seed_final.img ]; then
          cp /tmp/seed_final.img "$SEED_ISO"
          echo "Seed ISO created."
        else
          echo "⚠️ Seed ISO failed, booting without cloud-init."
          touch "$SEED_ISO"
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
