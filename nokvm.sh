#!/usr/bin/env bash
# RF LXC MANAGER
# Creates and manages real LXC system containers on Linux hosts without KVM.

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="RF LXC MANAGER"
CONTAINER_DIR="/var/lib/lxc"
LOG_FILE="/var/log/rf-lxc-manager.log"

if [[ -t 1 ]]; then
  RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  CYAN=$'\033[36m'; BLUE=$'\033[34m'
else
  RESET=""; BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""
  CYAN=""; BLUE=""
fi

clear_screen() { printf '\033[2J\033[H'; }
msg() { printf "%b\n" "$*"; }
ok() { msg "  ${GREEN}✔${RESET} $*"; }
warn() { msg "  ${YELLOW}!${RESET} $*"; }
err() { msg "  ${RED}✖${RESET} $*" >&2; }
pause() { echo; read -r -p "  Press Enter to continue..." _; }
line() { msg "  ${DIM}────────────────────────────────────────────────────────${RESET}"; }

header() {
  clear_screen
  msg "${CYAN}${BOLD}"
  cat <<'EOF'
   ____  _____
  |  _ \|  ___|
  | |_) | |_
  |  _ <|  _|
  |_| \_\_|
EOF
  msg "${RESET}${BOLD}                 LXC CONTAINER MANAGER${RESET}"
  line
}

need_root() {
  if [[ "$EUID" -ne 0 ]]; then
    err "Run as root: sudo bash $0"
    exit 1
  fi
}

need_lxc() {
  command -v lxc-info >/dev/null 2>&1 || {
    err "LXC is not installed. Choose Install dependencies first."
    return 1
  }
  command -v lxc-create >/dev/null 2>&1 || {
    err "lxc-create is missing."
    return 1
  }
}

check_host() {
  header
  msg "${BOLD}No-KVM host capability check${RESET}"
  if [[ -e /dev/kvm ]]; then
    warn "/dev/kvm exists. This host may also support KVM."
  else
    ok "/dev/kvm is absent; this script will use LXC containers, not KVM VMs."
  fi

  for item in /proc/self/ns/user /proc/self/ns/pid /sys/fs/cgroup; do
    if [[ -e "$item" ]]; then ok "$item is available"; else warn "$item is missing"; fi
  done

  if command -v unshare >/dev/null 2>&1; then
    if unshare -Ur true >/dev/null 2>&1; then
      ok "Unprivileged user namespaces appear available"
    else
      warn "Unprivileged user namespaces are restricted (root-managed LXC may still work)."
    fi
  else
    warn "unshare command not found."
  fi

  if command -v lxc-checkconfig >/dev/null 2>&1; then
    echo
    lxc-checkconfig 2>&1 | head -n 35 || true
  fi
  echo
  warn "The VPS provider must allow containers, namespaces, cgroups and required kernel features."
  pause
}

install_dependencies() {
  header
  if ! command -v apt-get >/dev/null 2>&1; then
    err "This installer currently supports Ubuntu/Debian hosts using apt."
    pause; return
  fi

  msg "  Installing LXC and networking tools..."
  export DEBIAN_FRONTEND=noninteractive
  if apt-get update >>"$LOG_FILE" 2>&1 &&
     apt-get install -y lxc lxc-templates uidmap debootstrap \
       iproute2 iptables dnsmasq-base bridge-utils curl ca-certificates \
       >>"$LOG_FILE" 2>&1; then
    systemctl enable --now lxc-net 2>/dev/null || true
    ok "LXC packages installed."
    warn "If lxc-net is unavailable, containers may need host-provided networking."
  else
    err "Installation failed. Check $LOG_FILE"
  fi
  pause
}

ensure_lxc() {
  need_lxc || return 1
  mkdir -p "$CONTAINER_DIR"
  if [[ ! -d /sys/fs/cgroup ]]; then
    err "Cgroups are not mounted; LXC cannot run reliably."
    return 1
  fi
}

valid_name() {
  [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_-]{1,29}$ ]]
}

container_exists() {
  [[ -d "$CONTAINER_DIR/$1" ]]
}

choose_template() {
  echo
  msg "${BOLD}  Select container OS${RESET}"
  echo "  1) Ubuntu 24.04"
  echo "  2) Ubuntu 22.04"
  echo "  3) Debian 12"
  echo "  4) Debian 13"
  echo "  5) Alpine"
  read -r -p "  OS choice [1-5]: " os_choice
  case "$os_choice" in
    1) TEMPLATE_DIST="ubuntu"; TEMPLATE_RELEASE="noble"; TEMPLATE_ARCH="amd64" ;;
    2) TEMPLATE_DIST="ubuntu"; TEMPLATE_RELEASE="jammy"; TEMPLATE_ARCH="amd64" ;;
    3) TEMPLATE_DIST="debian"; TEMPLATE_RELEASE="bookworm"; TEMPLATE_ARCH="amd64" ;;
    4) TEMPLATE_DIST="debian"; TEMPLATE_RELEASE="trixie"; TEMPLATE_ARCH="amd64" ;;
    5) TEMPLATE_DIST="alpine"; TEMPLATE_RELEASE="3.20"; TEMPLATE_ARCH="amd64" ;;
    *) err "Invalid OS choice."; return 1 ;;
  esac
}

create_container() {
  header
  msg "${BOLD}Create a Linux LXC container${RESET}"
  ensure_lxc || { pause; return; }

  local name ram_mb cpu_limit disk_gb password
  read -r -p "  Container name: " name
  if ! valid_name "$name"; then
    err "Use 2-30 characters; start with a letter."
    pause; return
  fi
  if container_exists "$name"; then
    err "A container with that name already exists."
    pause; return
  fi

  choose_template || { pause; return; }

  read -r -p "  Memory limit in MiB (example 1024): " ram_mb
  [[ "$ram_mb" =~ ^[0-9]+$ ]] && (( ram_mb >= 128 && ram_mb <= 1048576 )) || {
    err "Memory must be between 128 and 1048576 MiB."; pause; return;
  }

  read -r -p "  CPU limit in cores (example 1): " cpu_limit
  [[ "$cpu_limit" =~ ^[0-9]+$ ]] && (( cpu_limit >= 1 && cpu_limit <= 256 )) || {
    err "CPU limit must be between 1 and 256."; pause; return;
  }

  read -r -p "  Root filesystem size in GiB (example 8): " disk_gb
  [[ "$disk_gb" =~ ^[0-9]+$ ]] && (( disk_gb >= 2 && disk_gb <= 2048 )) || {
    err "Disk size must be between 2 and 2048 GiB."; pause; return;
  }

  read -r -s -p "  Set root password for container: " password; echo
  (( ${#password} >= 8 )) || { err "Use at least 8 characters."; pause; return; }

  echo
  msg "${BOLD}  Container Summary${RESET}"
  echo "  Name:      $name"
  echo "  OS:        $TEMPLATE_DIST $TEMPLATE_RELEASE"
  echo "  Memory:    ${ram_mb} MiB"
  echo "  CPU:       ${cpu_limit} core(s) maximum"
  echo "  Root disk: ${disk_gb} GiB"
  echo "  Type:      LXC system container (shares host kernel)"
  echo
  read -r -p "  Create this container? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { warn "Creation cancelled."; pause; return; }

  msg "  Downloading and creating container root filesystem..."
  if ! lxc-create -n "$name" -t download -- \
      --dist "$TEMPLATE_DIST" --release "$TEMPLATE_RELEASE" --arch "$TEMPLATE_ARCH" \
      >>"$LOG_FILE" 2>&1; then
    err "Container creation failed. Check $LOG_FILE; host may restrict LXC."
    rm -rf "$CONTAINER_DIR/$name"
    pause; return
  fi

  local config="$CONTAINER_DIR/$name/config"
  cat >>"$config" <<EOF

# RF LXC Manager resource limits
lxc.cgroup2.memory.max = ${ram_mb}M
lxc.cgroup2.cpu.max = ${cpu_limit}00000 100000
EOF

  # Configure root password using the container's init system when possible.
  if ! lxc-start -n "$name" -d >>"$LOG_FILE" 2>&1; then
    err "Container was created but could not start. Check $LOG_FILE"
    warn "The host may block nested containers or required kernel features."
    pause; return
  fi

  sleep 3
  if printf '%s\n' "root:$password" | lxc-attach -n "$name" -- chpasswd >>"$LOG_FILE" 2>&1; then
    ok "Root password configured."
  else
    warn "Container started, but root password could not be set automatically."
  fi
  unset password

  ok "LXC container '$name' created and started."
  msg "  Login/console: lxc-attach -n $name"
  msg "  Stop:          lxc-stop -n $name"
  msg "  Status:        lxc-info -n $name"
  warn "The disk size is a requested allocation marker, not an enforced quota on every storage backend."
  pause
}

list_containers() {
  header
  ensure_lxc || { pause; return; }
  msg "${BOLD}LXC containers${RESET}"
  lxc-ls --fancy 2>/dev/null || {
    for d in "$CONTAINER_DIR"/*; do
      [[ -d "$d" ]] || continue
      lxc-info -n "$(basename "$d")" 2>/dev/null || true
    done
  }
  pause
}

get_container() {
  read -r -p "  Container name: " CT_NAME
  if ! container_exists "$CT_NAME"; then
    err "Container '$CT_NAME' not found."
    return 1
  fi
}

start_container() {
  header; ensure_lxc || { pause; return; }
  get_container || { pause; return; }
  if lxc-start -n "$CT_NAME" -d; then ok "Container started."; else err "Start failed; check host LXC support and $LOG_FILE"; fi
  pause
}

stop_container() {
  header; ensure_lxc || { pause; return; }
  get_container || { pause; return; }
  if lxc-stop -n "$CT_NAME" -t 60; then ok "Container stopped."; else err "Stop failed."; fi
  pause
}

restart_container() {
  header; ensure_lxc || { pause; return; }
  get_container || { pause; return; }
  if lxc-stop -n "$CT_NAME" -t 60 2>/dev/null || true; then
    if lxc-start -n "$CT_NAME" -d; then ok "Container restarted."; else err "Restart failed."; fi
  fi
  pause
}

container_details() {
  header; ensure_lxc || { pause; return; }
  get_container || { pause; return; }
  lxc-info -n "$CT_NAME" || true
  echo
  msg "${BOLD}Container configuration${RESET}"
  sed -n '1,180p' "$CONTAINER_DIR/$CT_NAME/config"
  pause
}

attach_container() {
  header; ensure_lxc || { pause; return; }
  get_container || { pause; return; }
  msg "  Opening container shell. Type 'exit' to return."
  lxc-attach -n "$CT_NAME" || true
  pause
}

delete_container() {
  header; ensure_lxc || { pause; return; }
  get_container || { pause; return; }
  warn "This permanently removes the container and its root filesystem."
  read -r -p "  Type DELETE-$CT_NAME to confirm: " confirm
  [[ "$confirm" == "DELETE-$CT_NAME" ]] || { warn "Deletion cancelled."; pause; return; }
  lxc-stop -n "$CT_NAME" -k 2>/dev/null || true
  if lxc-destroy -n "$CT_NAME"; then ok "Container deleted."; else err "Could not delete container."; fi
  pause
}

main_menu() {
  while true; do
    header
    msg "${BOLD}  Main Menu${RESET}"
    echo
    echo "   1)  Create a new LXC container"
    echo "   2)  List all containers"
    echo "   3)  Start a container"
    echo "   4)  Stop a container"
    echo "   5)  Restart a container"
    echo "   6)  Container details"
    echo "   7)  Open container shell"
    echo "   8)  Delete a container"
    echo "   9)  Check host support"
    echo "  10)  Install dependencies"
    echo "   0)  Exit"
    echo
    line
    read -r -p "  🎯 [INPUT] Enter your choice: " choice
    case "$choice" in
      1) create_container ;;
      2) list_containers ;;
      3) start_container ;;
      4) stop_container ;;
      5) restart_container ;;
      6) container_details ;;
      7) attach_container ;;
      8) delete_container ;;
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
