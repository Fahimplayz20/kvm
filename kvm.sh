#!/usr/bin/env bash
# RF KVM Manager v1.0
# Creates and manages real KVM/libvirt virtual machines using cloud images.

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="RF KVM MANAGER"
APP_VERSION="1.0"
BASE_DIR="/var/lib/libvirt/images/rfrs-vms"
CACHE_DIR="/var/lib/libvirt/images/rfrs-cache"
LOG_FILE="/var/log/rfrs-kvm-manager.log"

# ---------- Terminal UI ----------
if [[ -t 1 ]]; then
  RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; CYAN=$'\033[36m'; MAGENTA=$'\033[35m'
else
  RESET=""; BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""
  BLUE=""; CYAN=""; MAGENTA=""
fi

clear_screen() { printf '\033[2J\033[H'; }
pause() { echo; read -r -p "  Press Enter to continue..." _; }
msg() { printf "%b\n" "$*"; }
ok() { msg "  ${GREEN}✔${RESET} $*"; }
warn() { msg "  ${YELLOW}!${RESET} $*"; }
err() { msg "  ${RED}✖${RESET} $*" >&2; }
line() { printf '%s\n' "  ${DIM}────────────────────────────────────────────────────────${RESET}"; }

header() {
  clear_screen
  msg "${CYAN}${BOLD}"
  cat <<'EOF'
   ____  _____ ____  ____   __  __
  |  _ \|  ___|  _ \|  ___| |  \/  |
  | |_) | |_  | |_) | |     | |\/| |
  |  _ <|  _| |  __/| |___  | |  | |
  |_| \_\_|   |_|    \____| |_|  |_|
EOF
  msg "${RESET}${BOLD}              KVM VIRTUAL MACHINE MANAGER${RESET}"
  msg "${DIM}                         Version ${APP_VERSION}${RESET}"
  line
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Run this script as root: sudo bash $0"
    exit 1
  fi
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Required command '$1' is missing. Select Install/Check Dependencies first."
    return 1
  }
}

valid_name() {
  [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_-]{1,29}$ ]]
}

# ---------- Host / dependency checks ----------
install_dependencies() {
  header
  msg "${BOLD}Dependency installation${RESET}"
  if ! command -v apt-get >/dev/null 2>&1; then
    err "This installer currently supports Ubuntu/Debian hosts with apt."
    pause; return
  fi

  msg "  Installing QEMU/KVM, libvirt, virt-install and cloud-image tools..."
  export DEBIAN_FRONTEND=noninteractive
  if apt-get update >>"$LOG_FILE" 2>&1 &&
     apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients \
       virtinst cloud-image-utils qemu-utils curl ca-certificates openssl \
       >>"$LOG_FILE" 2>&1; then
    systemctl enable --now libvirtd 2>/dev/null || true
    systemctl enable --now virtqemud 2>/dev/null || true
    ok "Dependencies installed."
  else
    err "Package installation failed. Check $LOG_FILE"
  fi
  pause
}

check_host() {
  header
  msg "${BOLD}Host capability check${RESET}"
  local failed=0
  for c in virsh virt-install qemu-img cloud-localds curl; do
    if command -v "$c" >/dev/null 2>&1; then ok "$c is installed"; else err "$c is missing"; failed=1; fi
  done

  if [[ -e /dev/kvm ]]; then
    ok "/dev/kvm exists"
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then ok "KVM device is accessible"; else warn "KVM device permissions may prevent VM creation"; fi
  else
    err "/dev/kvm is missing. This host may not support KVM or nested virtualization may be disabled."
    failed=1
  fi

  if command -v virsh >/dev/null 2>&1; then
    if virsh -c qemu:///system list >/dev/null 2>&1; then
      ok "libvirt system connection is available"
    else
      warn "libvirt is not responding. Try installing dependencies or starting libvirt."
      failed=1
    fi
  fi

  if (( failed )); then
    warn "Some checks failed. A normal VPS often cannot create KVM VMs unless its provider enables nested virtualization."
  else
    ok "Host looks ready for KVM."
  fi
  pause
}

ensure_libvirt() {
  need_command virsh
  need_command virt-install
  need_command qemu-img
  need_command cloud-localds
  [[ -e /dev/kvm ]] || { err "/dev/kvm not found; KVM is unavailable on this host."; return 1; }

  mkdir -p "$BASE_DIR" "$CACHE_DIR"
  chmod 750 "$BASE_DIR" "$CACHE_DIR"

  if ! virsh -c qemu:///system list >/dev/null 2>&1; then
    systemctl start libvirtd 2>/dev/null || systemctl start virtqemud 2>/dev/null || true
  fi
  virsh -c qemu:///system list >/dev/null 2>&1 || {
    err "Cannot connect to libvirt system daemon."
    return 1
  }

  if ! virsh net-info default >/dev/null 2>&1; then
    warn "The default libvirt NAT network is missing. Create it before deploying VMs."
    return 1
  fi
  if ! virsh net-info default | grep -q 'Active:.*yes'; then
    virsh net-start default >/dev/null 2>&1 || true
  fi
  virsh net-autostart default >/dev/null 2>&1 || true
}

# ---------- VM helpers ----------
vm_exists() {
  virsh -c qemu:///system dominfo "$1" >/dev/null 2>&1
}

choose_os() {
  echo
  msg "${BOLD}  Select operating system${RESET}"
  echo "  1) Ubuntu 24.04 LTS"
  echo "  2) Debian 12"
  echo "  3) Debian 13"
  read -r -p "  OS choice [1-3]: " os_choice
  case "$os_choice" in
    1) OS_ID="ubuntu-2404"; IMAGE_NAME="ubuntu-24.04-server-cloudimg-amd64.img"
       IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
       DEFAULT_USER="ubuntu" ;;
    2) OS_ID="debian-12"; IMAGE_NAME="debian-12-genericcloud-amd64.qcow2"
       IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
       DEFAULT_USER="debian" ;;
    3) OS_ID="debian-13"; IMAGE_NAME="debian-13-genericcloud-amd64.qcow2"
       IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
       DEFAULT_USER="debian" ;;
    *) err "Invalid OS choice."; return 1 ;;
  esac
}

download_image() {
  local target="$CACHE_DIR/$IMAGE_NAME"
  if [[ -s "$target" ]]; then
    ok "Using cached image: $IMAGE_NAME" >&2
  else
    msg "  Downloading $IMAGE_NAME (this may take a while)..." >&2
    if ! curl -fL --retry 3 --connect-timeout 20 "$IMAGE_URL" -o "$target"; then
      rm -f "$target"
      err "Image download failed."
      return 1
    fi
    ok "Base image downloaded." >&2
  fi
  printf '%s' "$target"
}

create_vm() {
  header
  msg "${BOLD}Create a new KVM virtual machine${RESET}"
  ensure_libvirt || { pause; return; }

  local name ram vcpus disk_gb username password password_hash base disk seed user_data meta
  read -r -p "  VM name (letters/numbers/_/-): " name
  if [[ ! "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]{1,29}$ ]]; then
    err "Use 2-30 characters; start with a letter."
    pause; return
  fi
  if vm_exists "$name" || [[ -e "$BASE_DIR/$name.qcow2" ]]; then
    err "A VM or disk with that name already exists."
    pause; return
  fi

  choose_os || { pause; return; }

  read -r -p "  RAM in MiB (example 2048): " ram
  [[ "$ram" =~ ^[0-9]+$ ]] && (( ram >= 512 && ram <= 1048576 )) || {
    err "RAM must be between 512 and 1048576 MiB."; pause; return;
  }

  read -r -p "  CPU cores (example 2): " vcpus
  [[ "$vcpus" =~ ^[0-9]+$ ]] && (( vcpus >= 1 && vcpus <= 256 )) || {
    err "CPU cores must be between 1 and 256."; pause; return;
  }

  read -r -p "  Disk size in GiB (example 20): " disk_gb
  [[ "$disk_gb" =~ ^[0-9]+$ ]] && (( disk_gb >= 5 && disk_gb <= 4096 )) || {
    err "Disk size must be between 5 and 4096 GiB."; pause; return;
  }

  read -r -p "  Linux username [${DEFAULT_USER}]: " username
  username="${username:-$DEFAULT_USER}"
  [[ "$username" =~ ^[a-z_][a-z0-9_-]{1,30}$ ]] || {
    err "Invalid Linux username."; pause; return;
  }

  read -r -s -p "  Password for ${username}: " password; echo
  (( ${#password} >= 8 )) || { err "Use a password with at least 8 characters."; pause; return; }
  read -r -s -p "  Confirm password: " password2; echo
  [[ "$password" == "$password2" ]] || { err "Passwords do not match."; pause; return; }

  msg
  msg "${BOLD}  VM Summary${RESET}"
  echo "  Name:       $name"
  echo "  OS:         $OS_ID"
  echo "  RAM:        ${ram} MiB"
  echo "  CPU:        ${vcpus} core(s)"
  echo "  Disk:       ${disk_gb} GiB"
  echo "  User:       $username"
  echo "  Network:    libvirt default NAT"
  echo
  read -r -p "  Create this VM? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { warn "Creation cancelled."; pause; return; }

  base="$(download_image)" || { pause; return; }
  disk="$BASE_DIR/$name.qcow2"
  seed="$BASE_DIR/$name-seed.iso"
  user_data="$BASE_DIR/$name-user-data"
  meta="$BASE_DIR/$name-meta-data"

  password_hash="$(openssl passwd -6 "$password")" || {
    err "Could not hash password. Is openssl installed?"
    rm -f "$disk" "$seed" "$user_data" "$meta"; pause; return;
  }
  unset password password2

  cat >"$user_data" <<EOF
#cloud-config
hostname: ${name}
manage_etc_hosts: true
users:
  - default
  - name: ${username}
    groups: [sudo]
    shell: /bin/bash
    sudo: ["ALL=(ALL) ALL"]
    lock_passwd: false
    passwd: '${password_hash}'
ssh_pwauth: true
disable_root: true
chpasswd:
  expire: false
package_update: true
EOF
  cat >"$meta" <<EOF
instance-id: ${name}
local-hostname: ${name}
EOF
  chmod 600 "$user_data" "$meta"

  msg "  Preparing virtual disk..."
  if ! cp --reflink=auto "$base" "$disk" 2>>"$LOG_FILE"; then
    err "Could not copy base image. Check disk space and $LOG_FILE"
    rm -f "$user_data" "$meta"; pause; return
  fi
  if ! qemu-img resize "$disk" "${disk_gb}G" >>"$LOG_FILE" 2>&1; then
    err "Disk resize failed."
    rm -f "$disk" "$user_data" "$meta"; pause; return
  fi
  if ! cloud-localds "$seed" "$user_data" "$meta" >>"$LOG_FILE" 2>&1; then
    err "Could not create cloud-init seed ISO."
    rm -f "$disk" "$seed" "$user_data" "$meta"; pause; return
  fi

  msg "  Creating VM with libvirt..."
  if virt-install \
      --connect qemu:///system \
      --name "$name" \
      --memory "$ram" \
      --vcpus "$vcpus" \
      --cpu host-passthrough \
      --os-variant generic \
      --import \
      --disk "path=$disk,format=qcow2,bus=virtio" \
      --disk "path=$seed,device=cdrom" \
      --network network=default,model=virtio \
      --graphics none \
      --console pty,target_type=serial \
      --noautoconsole >>"$LOG_FILE" 2>&1; then
    rm -f "$user_data" "$meta"
    ok "VM '$name' was created and started."
    msg "  Login user: ${username}"
    msg "  Find its IP with: virsh domifaddr ${name}"
    msg "  Console: virsh console ${name}"
    msg "  Note: cloud-init may need a few minutes on first boot."
  else
    err "VM creation failed. See $LOG_FILE"
    virsh destroy "$name" >/dev/null 2>&1 || true
    virsh undefine "$name" >/dev/null 2>&1 || true
    rm -f "$disk" "$seed" "$user_data" "$meta"
  fi
  pause
}

list_vms() {
  header
  ensure_libvirt || { pause; return; }
  msg "${BOLD}Virtual machines${RESET}"
  virsh -c qemu:///system list --all
  echo
  pause
}

select_vm() {
  read -r -p "  VM name: " VM_NAME
  if ! vm_exists "$VM_NAME"; then
    err "VM '$VM_NAME' was not found."
    return 1
  fi
}

start_vm() {
  header; ensure_libvirt || { pause; return; }
  select_vm || { pause; return; }
  if virsh start "$VM_NAME"; then ok "VM started."; else err "Could not start VM."; fi
  pause
}

stop_vm() {
  header; ensure_libvirt || { pause; return; }
  select_vm || { pause; return; }
  warn "A graceful shutdown is requested."
  if virsh shutdown "$VM_NAME"; then
    ok "Shutdown signal sent. It may take a short time."
  else
    err "Could not request shutdown."
  fi
  pause
}

restart_vm() {
  header; ensure_libvirt || { pause; return; }
  select_vm || { pause; return; }
  if virsh reboot "$VM_NAME"; then ok "Reboot signal sent."; else err "Could not reboot VM."; fi
  pause
}

vm_details() {
  header; ensure_libvirt || { pause; return; }
  select_vm || { pause; return; }
  virsh dominfo "$VM_NAME"
  echo
  msg "${BOLD}Network addresses${RESET}"
  virsh domifaddr "$VM_NAME" 2>/dev/null || warn "IP may not be available yet; guest agent or DHCP lease information may be needed."
  echo
  msg "${BOLD}Disk information${RESET}"
  virsh domblklist "$VM_NAME"
  pause
}

vm_console() {
  header; ensure_libvirt || { pause; return; }
  select_vm || { pause; return; }
  msg "  Opening console. Press Ctrl+] to exit."
  virsh console "$VM_NAME" || true
  pause
}

delete_vm() {
  header; ensure_libvirt || { pause; return; }
  select_vm || { pause; return; }
  echo
  warn "This permanently deletes the VM and its virtual disk."
  read -r -p "  Type DELETE-$VM_NAME to confirm: " confirm
  [[ "$confirm" == "DELETE-$VM_NAME" ]] || { warn "Deletion cancelled."; pause; return; }

  local state
  state="$(virsh domstate "$VM_NAME" 2>/dev/null || true)"
  if [[ "$state" == "running" ]]; then
    virsh destroy "$VM_NAME" || { err "Could not stop VM."; pause; return; }
  fi
  if virsh undefine "$VM_NAME" --nvram >/dev/null 2>&1 || virsh undefine "$VM_NAME" >/dev/null 2>&1; then
    rm -f "$BASE_DIR/$VM_NAME.qcow2" "$BASE_DIR/$VM_NAME-seed.iso"
    ok "VM definition and managed disk deleted."
  else
    err "Could not undefine VM. Disk was not removed."
  fi
  pause
}

# ---------- Main menu ----------
main_menu() {
  while true; do
    header
    msg "${BOLD}  Main Menu${RESET}"
    echo
    echo "   1)  Create a new VM"
    echo "   2)  List all VMs"
    echo "   3)  Start a VM"
    echo "   4)  Gracefully stop a VM"
    echo "   5)  Restart a VM"
    echo "   6)  VM details and IP"
    echo "   7)  Open VM console"
    echo "   8)  Delete a VM"
    echo "   9)  Check KVM host"
    echo "  10)  Install/check dependencies"
    echo "   0)  Exit"
    echo
    line
    read -r -p "  🎯 [INPUT] Enter your choice: " choice
    case "$choice" in
      1) create_vm ;;
      2) list_vms ;;
      3) start_vm ;;
      4) stop_vm ;;
      5) restart_vm ;;
      6) vm_details ;;
      7) vm_console ;;
      8) delete_vm ;;
      9) check_host ;;
      10) install_dependencies ;;
      0) msg "  ${GREEN}Goodbye!${RESET}"; exit 0 ;;
      *) warn "Invalid choice."; sleep 1 ;;
    esac
  done
}

need_root
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
main_menu
