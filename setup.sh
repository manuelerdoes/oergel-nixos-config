#!/usr/bin/env bash
# Interactive setup for a new machine.
#
# Run it on the freshly installed NixOS, from inside this repo, as your normal
# user (not with sudo):
#
#   bash setup.sh
#
# It first asks all questions and shows a summary. Nothing is changed before
# you confirm. Running it again is safe: existing files are backed up (*.bak).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_CONFIG=/etc/nixos/configuration.nix

# ==============================================================================
# Helpers

step() { printf '\n\033[1;35m== %s\033[0m\n' "$*"; }
info() { printf '\033[36m::\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!! %s\033[0m\n' "$*"; }
die() {
  printf '\033[31mError: %s\033[0m\n' "$*" >&2
  exit 1
}

# ask "Question" "default"  -> prints the answer (prompt goes to stderr)
ask() {
  local reply prompt="$1: "
  [ -n "$2" ] && prompt="$1 [$2]: "
  read -r -p "$prompt" reply
  printf '%s' "${reply:-$2}"
}

# yes_no "Question" y|n  -> exit status 0 for yes
yes_no() {
  local reply hint="[Y/n]"
  [ "$2" = n ] && hint="[y/N]"
  read -r -p "$1 $hint: " reply
  [[ "${reply:-$2}" =~ ^[Yy] ]]
}

# ask_valid "Question" "default" 'regex' "what is allowed"
ask_valid() {
  local answer
  while true; do
    answer="$(ask "$1" "$2")"
    [[ "$answer" =~ $3 ]] && break
    warn "Not valid. Allowed: $4"
  done
  printf '%s' "$answer"
}

# first_line "text"  -> first line only (avoids `| head`, which trips pipefail)
first_line() { printf '%s' "${1%%$'\n'*}"; }

# installer_value some.option  -> value of `some.option = "value";` in the
# configuration.nix the installer wrote, or nothing
installer_value() {
  [ -r "$INSTALLER_CONFIG" ] || return 0
  local key="${1//./\\.}"
  first_line "$(sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$INSTALLER_CONFIG")"
}

# repo_value file 'sed regex with one (group)'  -> current value in a repo file
repo_value() {
  first_line "$(sed -n -E "s/$2/\1/p" "$REPO/$1")"
}

# set_value file 'sed regex: (prefix)old-value(suffix)' 'new value'
set_value() {
  local file="$REPO/$1"
  grep -q -E "$2" "$file" || die "Couldn't find the line to change in $1."
  sed -i -E "s|$2|\1$3\2|" "$file"
}

backup() {
  if [ -e "$1" ]; then
    cp "$1" "$1.bak"
    info "Old $(basename "$1") saved as $(basename "$1").bak"
  fi
}

git_cmd() {
  if command -v git >/dev/null 2>&1; then
    git -C "$REPO" "$@"
  else
    nix-shell -p git --run "git -C $(printf '%q' "$REPO") $(printf '%q ' "$@")"
  fi
}

# ==============================================================================
# Checks

[ -e /etc/NIXOS ] || die "This doesn't look like a NixOS system."
[ "$(id -u)" -ne 0 ] || die "Run this as your normal user, not as root or with sudo."
case "$REPO/" in
  "$HOME"/*) ;;
  *) die "The repo has to be inside your home folder (it is at $REPO)." ;;
esac
[ -f "$REPO/flake.nix" ] || die "flake.nix not found next to setup.sh."

cat <<EOF

  NixOS setup for this machine
  ----------------------------
  Repo: $REPO

  Press Enter to accept the suggestion in [brackets].
  Nothing is changed until you confirm the summary. Ctrl+C aborts.
EOF

# ==============================================================================
# Questions

virt="$(systemd-detect-virt 2>/dev/null || true)"
virt="${virt:-none}"

# ------------------------------------------------------------------ Machine name
step "Machine name"
existing_hosts="$(cd "$REPO/hosts" && ls -d -- */ 2>/dev/null | tr -d / | tr '\n' ' ' || true)"
info "Existing machines in hosts/: ${existing_hosts:-none}"
info "It becomes the hostname, and the folder hosts/<name>/ holds this machine's settings."
if [ -d "$REPO/hosts/$(hostname)" ]; then
  default_host="$(hostname)"
elif [ "$virt" != none ]; then
  default_host="nixos-vm"
else
  default_host="notebook"
fi
host="$(ask_valid "Name for this machine" "$default_host" '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' "lowercase letters, digits and -")"
host_dir="$REPO/hosts/$host"

# ---------------------------------------------------------------------- Username
step "User"
info "Must be the user you created during the NixOS install."
info "Currently set in flake.nix: $(repo_value flake.nix '^ *username = "([^"]*)";.*')"
username="$(ask_valid "Username" "$USER" '^[a-z_][a-z0-9_-]*$' "lowercase letters, digits, _ and -")"
if ! id "$username" >/dev/null 2>&1; then
  warn "User '$username' doesn't exist on this system."
  warn "NixOS would create it WITHOUT a password and you couldn't log in."
  yes_no "Use it anyway?" n || die "Aborted. Run again with the right username."
fi
if [ "$username" != "$USER" ]; then
  warn "You're logged in as '$USER', but the config will be for '$username'."
  warn "The repo should be in /home/$username/, or the config links won't work."
fi

# ----------------------------------------------------------------- Repo location
repo_rel="${REPO#"$HOME"/}"
[[ "$repo_rel" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Please use a repo path without spaces or special characters ($REPO)."
info "Home Manager links the Umbriel and Mango configs to ~/$repo_rel. Don't move the folder later."

# -------------------------------------------------------------------- Bootloader
step "Bootloader"
if [ -d /sys/firmware/efi ]; then
  boot_mode=uefi
  info "This machine boots with UEFI, so the bootloader will be systemd-boot."
  if [ -r "$INSTALLER_CONFIG" ] && grep -q 'boot\.loader\.grub' "$INSTALLER_CONFIG"; then
    warn "The installer set up GRUB. Switching to systemd-boot is normal on UEFI."
    yes_no "Use systemd-boot?" y || die "Aborted. Set up the bootloader in hosts/$host/default.nix by hand."
  fi
  efi_mount="$(installer_value boot.loader.efi.efiSysMountPoint)"
  efi_mount="${efi_mount:-/boot}"
else
  boot_mode=bios
  info "This machine boots the old way (BIOS), so the bootloader will be GRUB."
  grub_default="$(installer_value boot.loader.grub.device)"
  if [ -z "$grub_default" ]; then
    root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
    root_src="${root_src%%\[*}"
    root_disk="$(first_line "$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)")"
    grub_default="/dev/${root_disk:-sda}"
  fi
  info "GRUB goes onto the whole disk (e.g. /dev/sda, not /dev/sda1)."
  grub_device="$(ask_valid "Disk for GRUB" "$grub_default" '^/dev/[A-Za-z0-9/_-]+$' "a device path like /dev/sda")"
fi

# ----------------------------------------------------------------- stateVersion
step "stateVersion"
info "The NixOS version this machine was installed with. Set once, never changed."
state_default="$(installer_value system.stateVersion)"
if [ -z "$state_default" ]; then
  state_default="$(nixos-version | cut -c1-5)"
else
  info "Found in $INSTALLER_CONFIG: $state_default"
fi
state_version="$(ask_valid "stateVersion" "$state_default" '^[0-9]{2}\.[0-9]{2}$' "a version like 26.05")"

# ---------------------------------------------------------------------- Keyboard
step "Keyboard"
kb_layout_now="$(repo_value configuration.nix '^ *layout = "([^"]*)";.*')"
kb_variant_now="$(repo_value configuration.nix '^ *variant = "([^"]*)";.*')"
installer_kb="$(installer_value services.xserver.xkb.layout)"
installer_console="$(installer_value console.keyMap)"
[ -n "$installer_kb$installer_console" ] &&
  info "The installer used: layout '${installer_kb:-?}', console keymap '${installer_console:-?}'"
info "Examples: ch + de_nodeadkeys (Swiss German), ch + fr (Swiss French), us + (empty)"
kb_layout="$(ask_valid "Keyboard layout" "$kb_layout_now" '^[a-z]{2,3}(,[a-z]{2,3})*$' "codes like ch, us, de")"
kb_variant="$(ask_valid "Variant (type - for none)" "${kb_variant_now:--}" '^(-|[a-z0-9_]+(,[a-z0-9_]*)*)$' "names like de_nodeadkeys, or -")"
[ "$kb_variant" = "-" ] && kb_variant=""

# ------------------------------------------------------------------ VM settings
vm_block=""
if [ "$virt" != none ]; then
  step "Virtual machine ($virt)"
  case "$virt" in
    vmware)
      info "VMware: VMware Tools (open-vm-tools) will be enabled."
      info "In VMware, turn on 'Accelerate 3D graphics' (or mks.enable3d = \"TRUE\" in the .vmx)."
      guest='  virtualisation.vmware.guest = {
    enable = true;
    headless = false; # keep vmware-user (clipboard sharing)
  };'
      ;;
    oracle)
      info "VirtualBox: Guest Additions will be enabled."
      guest='  virtualisation.virtualbox.guest.enable = true;'
      ;;
    microsoft)
      info "Hyper-V: guest services will be enabled. Note: no 3D for Linux guests."
      guest='  virtualisation.hypervGuest.enable = true;'
      ;;
    kvm | qemu)
      info "QEMU/KVM: guest agent and SPICE will be enabled."
      guest='  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;'
      ;;
    *)
      warn "No guest tools known for '$virt'; skipping."
      guest=''
      ;;
  esac

  quirks=""
  if yes_no "Software mouse cursor? (fixes an invisible pointer, harmless otherwise)" y; then
    quirks+=$'\n  environment.sessionVariables.WLR_NO_HARDWARE_CURSORS = "1";'
  fi
  info "If Noctalia or terminal windows vanish right after opening, apps need to draw on the CPU."
  if yes_no "Let apps draw on the CPU (LIBGL_ALWAYS_SOFTWARE)?" n; then
    quirks+=$'\n  environment.sessionVariables.LIBGL_ALWAYS_SOFTWARE = "1";'
  fi
  info "Only if the compositor itself can't start because there is no 3D at all:"
  if yes_no "Let the compositor draw on the CPU too (WLR_RENDERER_ALLOW_SOFTWARE)?" n; then
    quirks+=$'\n  environment.sessionVariables.WLR_RENDERER_ALLOW_SOFTWARE = "1";'
  fi

  vm_block="  # -------------------------------------------------------------- Guest tools
${guest}"
  [ -n "$quirks" ] && vm_block+="

  # ------------------------------------------------------- VM graphics quirks${quirks}"
fi

# ------------------------------------------------------------------------ Work
step "Work file shares (optional)"
info "Windows file shares with Kerberos login. The domain and shares are saved in"
info "private/work.nix, which is git-ignored and never goes to GitHub."
info "On a Windows work PC, in cmd:  echo %USERDNSDOMAIN%  shows the domain,  net use  the shares."
private_file="$REPO/private/work.nix"
work_realm=""
share_names=()
share_paths=()
if [ -f "$private_file" ]; then
  work_realm="$(repo_value private/work.nix '^ *realm = "([^"]*)";.*')"
  while IFS=$'\t' read -r share_name share_path; do
    share_names+=("$share_name")
    share_paths+=("$share_path")
  done < <(sed -n -E 's/^ *"([^"]+)" = "([^"]*)";.*/\1\t\2/p' "$private_file")
fi

setup_work=no
work_default=n
[ -n "$work_realm" ] && work_default=y
if yes_no "Set up work file shares?" "$work_default"; then
  setup_work=yes
  work_realm="$(ask_valid "Domain" "$work_realm" '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' "a domain name like AD.EXAMPLE.ORG")"
  work_realm="${work_realm^^}" # Kerberos realms are written in capitals

  if [ ${#share_names[@]} -gt 0 ]; then
    info "Current shares:"
    for i in "${!share_names[@]}"; do
      info "  ~/shares/${share_names[$i]}  ->  ${share_paths[$i]}"
    done
    yes_no "Keep them?" y || {
      share_names=()
      share_paths=()
    }
  fi

  info "Add shares. Paste the path as 'net use' shows it (\\\\server\\share). Press Enter on an empty name to finish."
  share_re='^//[^/"$]+/[^"$]+$'
  while true; do
    share_name="$(ask "Name (it appears as ~/shares/<name>)" "")"
    [ -z "$share_name" ] && break
    if ! [[ "$share_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      warn "Use letters, digits, . _ and - only."
      continue
    fi
    if printf '%s\n' "${share_names[@]}" | grep -qx -- "$share_name"; then
      warn "'$share_name' already exists."
      continue
    fi
    share_path="$(ask "Path of '$share_name'" "")"
    share_path="${share_path//\\//}" # \\server\share -> //server/share
    if ! [[ "$share_path" =~ $share_re ]]; then
      warn "Expected something like \\\\server\\share or //server/share."
      continue
    fi
    share_names+=("$share_name")
    share_paths+=("$share_path")
  done
  work_summary="domain $work_realm, ${#share_names[@]} share(s)"
elif [ -f "$private_file" ]; then
  work_summary="unchanged (private/work.nix stays as it is)"
else
  work_summary="not set up"
fi

# ---------------------------------------------------------------- Disk space
avail_gb="$(df -BG --output=avail /nix 2>/dev/null | tail -n 1 | tr -dc '0-9')"
if [ -n "$avail_gb" ] && [ "$avail_gb" -lt 25 ]; then
  step "Disk space"
  warn "Only ${avail_gb} GB free. The first build needs about 15 GB, and old versions are kept."
  yes_no "Continue anyway?" n || die "Aborted. Make the disk bigger first."
fi

# ==============================================================================
# Summary

if [ "$boot_mode" = uefi ]; then
  boot_block="  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10; # keeps /boot from filling up
  boot.loader.efi.canTouchEfiVariables = true;"
  [ "$efi_mount" != /boot ] && boot_block+="
  boot.loader.efi.efiSysMountPoint = \"$efi_mount\";"
  boot_summary="systemd-boot (UEFI, EFI partition at $efi_mount)"
else
  boot_block="  boot.loader.grub.enable = true;
  boot.loader.grub.device = \"$grub_device\";
  boot.loader.grub.configurationLimit = 10; # keeps /boot from filling up"
  boot_summary="GRUB on $grub_device (BIOS)"
fi

step "Summary"
cat <<EOF
  Machine:       $host  (hosts/$host/)
  User:          $username
  Repo:          ~/$repo_rel
  Bootloader:    $boot_summary
  stateVersion:  $state_version
  Keyboard:      $kb_layout${kb_variant:+ ($kb_variant)}
  VM:            $virt
  Work shares:   $work_summary

  Files that will be written or changed:
    hosts/$host/default.nix
    hosts/$host/hardware-configuration.nix
    flake.nix                                  (user, repo path)
    configuration.nix, umbriel/config.toml,
    mango/config.conf                          (keyboard)
EOF
[ "$setup_work" = yes ] && echo "    private/work.nix                           (work; not uploaded)"
echo
yes_no "Apply this?" y || die "Aborted. Nothing was changed."

# ==============================================================================
# Apply

step "Writing files"
mkdir -p "$host_dir"

# Hardware configuration: what the installer detected (disks, kernel modules).
hw="$host_dir/hardware-configuration.nix"
if [ -r /etc/nixos/hardware-configuration.nix ]; then
  if ! cmp -s /etc/nixos/hardware-configuration.nix "$hw"; then
    backup "$hw"
    cp /etc/nixos/hardware-configuration.nix "$hw"
  fi
  info "hardware-configuration.nix copied from /etc/nixos/"
else
  info "No /etc/nixos/hardware-configuration.nix, generating one (needs sudo)."
  backup "$hw"
  sudo nixos-generate-config --show-hardware-config >"$hw"
fi

# Host file
host_file="$host_dir/default.nix"
backup "$host_file"
{
  cat <<EOF
# Machine-specific settings for "$host". The hostname is the folder name.
# Generated by setup.sh on $(date +%F). Edit freely, or run setup.sh again.
{ username, ... }:
{
  imports = [ ./hardware-configuration.nix ];

  # ---------------------------------------------------------------- Bootloader
$boot_block

EOF
  [ -n "$vm_block" ] && printf '%s\n\n' "$vm_block"
  cat <<EOF
  # Set once at install time; never change it, even when you update NixOS.
  system.stateVersion = "$state_version";
  home-manager.users.\${username}.home.stateVersion = "$state_version";
}
EOF
} >"$host_file"
info "hosts/$host/default.nix written"

# Shared files
set_value flake.nix '^( *username = ")[^"]*(";)' "$username"
set_value flake.nix '^( *repoDir = ")[^"]*(";)' "$repo_rel"
set_value configuration.nix '^( *layout = ")[^"]*(";)' "$kb_layout"
set_value configuration.nix '^( *variant = ")[^"]*(";)' "$kb_variant"
set_value umbriel/config.toml '^(layout = ")[^"]*(")' "$kb_layout"
set_value umbriel/config.toml '^(variant = ")[^"]*(")' "$kb_variant"
set_value mango/config.conf '^(xkb_rules_layout=)[^[:space:]]*()' "$kb_layout"
set_value mango/config.conf '^(xkb_rules_variant=)[^[:space:]]*()' "$kb_variant"
info "flake.nix, configuration.nix and the compositor configs updated"

# Private work settings. Plain data, read by work.nix.
if [ "$setup_work" = yes ]; then
  mkdir -p "$REPO/private"
  backup "$private_file"
  {
    echo "# Private work settings for this machine, written by setup.sh."
    echo "# private/ is git-ignored, so this never goes to GitHub."
    echo "{"
    echo "  realm = \"$work_realm\";"
    echo "  shares = {"
    for i in "${!share_names[@]}"; do
      printf '    "%s" = "%s";\n' "${share_names[$i]}" "${share_paths[$i]}"
    done
    echo "  };"
    echo "}"
  } >"$private_file"
  chmod 600 "$private_file"
  info "private/work.nix written (stays on this machine)"
fi

# Flakes only see files that git knows about.
git_cmd add -A
info "All files added to git (flakes ignore untracked files)"

# ==============================================================================
# Build

step "Build"
info "The first build downloads a lot and can take a while."
if yes_no "Build and switch to the new configuration now?" y; then
  # --impure lets the build read the git-ignored private/work.nix.
  if ! sudo nixos-rebuild switch --impure --flake "$REPO#$host"; then
    die "The build failed. The system is unchanged. Look for the first line starting with 'error:' above."
  fi
  info "Done. From now on, rebuild with:  sudo nixos-rebuild switch --impure --flake ~/$repo_rel"
  info "(after the next login also just:  rebuild)"
  info "Don't forget to commit and push your changes:  git commit -am 'Set up $host' && git push"
  if [ "$setup_work" = yes ]; then
    info "Work shares: run 'kinit <your Windows username>', then open ~/shares/<name>."
    info "VPN: set it up once with nm-connection-editor (see README, 'Work: file shares and VPN')."
  fi
  if yes_no "Reboot now to get the login screen?" y; then
    systemctl reboot
  fi
else
  info "Build later with:  sudo nixos-rebuild switch --impure --flake ~/$repo_rel#$host"
fi
