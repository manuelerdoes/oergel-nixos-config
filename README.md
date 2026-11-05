# NixOS: Umbriel / Mango + Noctalia

```
setup.sh                interactive setup for a new machine (step 4)
flake.nix               entry point: inputs (nixpkgs, home-manager, zen); finds machines in hosts/
configuration.nix       shared by all machines: desktop, apps, audio, login screen, SSH
hosts/<name>/default.nix                one folder per machine (name = hostname):
hosts/<name>/hardware-configuration.nix   bootloader, VM tools, stateVersion, disks
hosts/<name>/custom.nix                 your own settings for that machine (optional;
                                          setup.sh never touches it, default.nix loads it)
home.nix                Home Manager: your user's dotfiles
work.nix                work: file shares (SMB + Kerberos), Cisco VPN
private/work.nix        your domain and shares; git-ignored, written by setup.sh
umbriel/config.toml     Umbriel config and keybinds (reloads on save)
mango/config.conf       Mango: what starts at login; loads settings.conf
mango/settings.conf     Mango settings and keybinds (both reload on save)
```

Both compositors are installed. You pick one on the login screen, and Noctalia runs in either.

## 1. Installing next to Windows (dual boot)

Skip this for a VM or a machine without Windows. Do the steps in this order:

1. **In Windows, as local admin:**
   - **Save the BitLocker recovery key** somewhere outside this machine.
   - **Turn off Fast Startup:** *Control Panel → Power Options → Choose what the power buttons do*,
     then untick *Turn on fast startup*. Otherwise Windows only half shuts down, which confuses the other system.
   - **Shrink `C:`:** *Disk Management*, right-click `C:`, then *Shrink Volume*. Free 60 GB or more and
     leave it *unallocated*.
   - **Suspend BitLocker for one restart:** *Control Panel → BitLocker → Suspend protection*.
     That way the next step doesn't trigger the recovery key prompt.
2. **In the BIOS** (`F1` or `Enter` at boot on Lenovo): turn **Secure Boot off**, then start Windows once.
   It turns BitLocker back on by itself and adapts to the new setting.
3. **Boot the NixOS installer** from USB (`F12` for the boot menu on Lenovo). When partitioning,
   choose **Manual partitioning**:
   - **The free space:** create a partition with mount point `/`, file system ext4.
   - **The existing EFI partition** (FAT32, the one with the *boot* flag): set its mount point to `/boot`.
     **Don't format it.** Windows' bootloader lives on it.
   - **Don't touch** Windows' partitions (NTFS, and the small *Microsoft reserved* one).
4. **Continue with step 2 below.** `setup.sh` notices Windows. It then asks whether the clock should
   run in local time like Windows, which keeps Kerberos working, and puts Windows in the boot menu.

The first Windows start after installing may still ask for the BitLocker recovery key, once.

### Later: Secure Boot (Lanzaboote)

Once everything runs, NixOS can boot with Secure Boot on. That keeps Windows "compliant", and
BitLocker stops asking for the recovery key. Lanzaboote signs NixOS with keys of your own and
enrolls them in the firmware **next to Microsoft's**, so Windows keeps booting.

1. **Run `bash setup.sh` again** and answer *yes* at "Use Secure Boot with Lanzaboote?". It
   creates your keys in `/var/lib/sbctl` and builds the system. Don't reboot yet.
2. **Check** that the bootloader and the `nixos-generation-*.efi` files are signed: `sudo sbctl verify`.
   It's normal that the `kernel-*` files aren't.
3. **In Windows:** *Control Panel → BitLocker → Suspend protection*, for one restart.
4. **In the BIOS** (`systemctl reboot --firmware-setup` gets you there): *Security → Secure Boot*.
   Turn it **on**, choose **Reset to Setup Mode**, and press F10.
   **Not** *Clear All Secure Boot Keys*: that also deletes the list of known-bad bootloaders.
5. **Back in NixOS:** `sudo sbctl enroll-keys --microsoft`. The `--microsoft` keeps Microsoft's keys.
   Windows and some hardware need them; without them the machine may not start at all.
6. **Reboot.** `bootctl status` should show `Secure Boot: enabled (user)`. Windows may ask for the
   recovery key once more.

Good to know:
- **Keep `/var/lib/sbctl`**: it holds your keys. Without them, new NixOS builds can't be signed.
- **USB sticks** (the NixOS installer, other Linux systems) don't boot while Secure Boot is on. For
  a rescue, turn Secure Boot off in the BIOS for that time.
- **BIOS updates:** do them in Windows with the Lenovo tool. `fwupd`'s EFI helper isn't signed with
  your keys.
- **Going back:** turn Secure Boot off in the BIOS *first*, then run `setup.sh` again and answer *no*.

**Removing NixOS later:** in Windows, delete the NixOS partition in *Disk Management*, extend `C:`
into the freed space, and delete the `EFI\systemd`, `EFI\nixos` and `loader` folders from the EFI
partition. Then Windows' boot manager is the only one left. If the firmware still shows a
"Linux Boot Manager" entry, remove it in the BIOS boot settings.


## 2. Turn on flakes and git in the minimal VM

Log in on the text console and run:

```sh
sudo nano /etc/nixos/configuration.nix
```

Add these two lines before the final `}`:

```nix
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  environment.systemPackages = [ pkgs.git ];
```

Save (Ctrl+O, Enter, Ctrl+X), then apply:

```sh
sudo nixos-rebuild switch
```

## 3. Clone the repo

The path matters, because `home.nix` links to `~/oergel-nixos-config/umbriel/config.toml`.

```sh
git clone https://github.com/<you>/oergel-nixos-config.git ~/oergel-nixos-config
cd ~/oergel-nixos-config
```

A private repo asks for a username and a GitHub personal access token as the password.

## 4. Run the setup script

```sh
bash setup.sh
```

It asks a few questions, suggests an answer for each (press Enter to accept),
and shows a summary before changing anything:

| Question | What it does |
|---|---|
| Machine name | Becomes the hostname, and `hosts/<name>/` holds this machine's settings |
| Username | Must be the user from the install. Otherwise NixOS creates a new one *without* a password |
| Bootloader | Detected: systemd-boot on UEFI, GRUB on BIOS (asks which disk) |
| Dual boot | If Windows is installed: Windows in the boot menu, clock in local time |
| stateVersion | Taken from the installer's `/etc/nixos/configuration.nix` |
| Keyboard | Written to `configuration.nix`, `umbriel/config.toml` and `mango/settings.conf` |
| VM only | Guest tools for the hypervisor it detects, plus the graphics workarounds |

It also copies `hardware-configuration.nix`, checks the free disk space, runs
`git add -A` (flakes ignore files git doesn't know), and then offers to build
and reboot. Running it again is safe: old files are kept as `*.bak`.

For a VMware VM, also check these settings in VMware Workstation Player:

- **Display:** *Accelerate 3D graphics* on, with as much graphics memory as it allows.
  If it stays off, add `mks.enable3d = "TRUE"` to the VM's `.vmx` file (VM powered off).
- **Options → Guest Isolation:** drag-and-drop and copy-paste enabled.

## 5. After the first build

From now on, `rebuild` rebuilds (a command from `configuration.nix`, so it also works under `sudo`). The long form is
`sudo nixos-rebuild switch --impure --flake ~/oergel-nixos-config`, and it picks this machine by its hostname.
`--impure` lets the build read `private/work.nix`, which git doesn't track. Without it, the build prints a
warning and leaves out the work shares.

Commit and push, including `flake.lock`, which pins the exact versions of everything:

```sh
git commit -am "Set up <name>" && git push
```

To change settings later, edit the files directly or run `bash setup.sh` again.

## 6. Reboot and log in

```sh
reboot
```

On the login screen (tuigreet), press **F3** to choose **Umbriel** or **Mango**.
It remembers your last choice, and starts Umbriel when there is none. Noctalia
starts with either one. Things to try first:

- `Super+Shift+Return` opens a terminal.
- `Super+P` opens the launcher. On Umbriel, tapping `Super` alone also works.
- **Check the config.** Umbriel: `umbriel config validate`. Mango: `mango -c ~/.config/mango/config.conf -p`.
- **Monitor names.** Umbriel: `umbriel outputs`. Mango: `mmsg get all-monitors`.

To switch compositors, log out (`Super+Escape` → Logout, or `Super+Shift+Q`) and pick the other one.

## Daily use

- **Compositor configs:** edit `~/oergel-nixos-config/umbriel/config.toml` or `~/oergel-nixos-config/mango/settings.conf`. They apply when you save, with no rebuild.
- **Everything else:** edit the `.nix` files, then `git add -A && rebuild`.
- **Update all software:** `update`. It runs `nix flake update` and then rebuilds.
- **Undo:** every rebuild is a *generation*. Pick an older one in the boot menu, or run `sudo nixos-rebuild switch --rollback`.
- **Find packages:** https://search.nixos.org/packages (channel *unstable*). Add them to `environment.systemPackages`.
- **Import bookmarks:** export them as HTML from your old browser, then close Chromium and Zen and run
  `import-bookmarks ~/Downloads/bookmarks.html`. Chromium gets them right away. Zen imports them the next
  time it starts. Existing bookmarks are kept, and duplicates (same URL) are skipped. Keep the HTML file out
  of the repo (`*.html` is git-ignored anyway). Each browser needs to have been started once before.

## Updates

### Software

```sh
update
```

It runs `nix flake update`, which writes the newest versions of nixpkgs, Home Manager and Zen to
`flake.lock`, and then `rebuild`. It works with or without `sudo`. If root ever left files in the repo
(e.g. after a `sudo git ...`), it gives them back to you first, since those make `nix flake update` fail
with "permission denied". Afterwards:

- **Commit and push `flake.lock`**, so every machine uses exactly the same versions.
- **Reboot if the kernel changed.** Everything else applies immediately.
- **If something broke**, pick the previous generation in the boot menu, or run
  `sudo nixos-rebuild switch --rollback`.

Useful extras:
```sh
nix flake update zen-browser --flake ~/oergel-nixos-config        # update only one input
nix store diff-closures /run/booted-system /run/current-system    # what changed since boot
```

### BIOS and firmware

`fwupd` does what the Lenovo tool does on Windows. Lenovo publishes BIOS updates for most
ThinkPads and ThinkCentres on LVFS, and for docks and other devices too.

```sh
fwupdmgr refresh         # fetch the list of available updates
fwupdmgr get-updates     # show what's available for this machine
fwupdmgr update          # install; BIOS updates are applied during the next reboot
```

- **Keep the notebook plugged in.** BIOS updates refuse to run on battery.
- **The updates need the EFI partition** at `/boot`. That's the normal layout on a UEFI install.
- **If `get-updates` finds nothing for the BIOS,** check your model at https://fwupd.org/lvfs/devices.
  Lenovo also offers a bootable BIOS-update ISO for every model on its support site.
- **In a VM** it finds nothing, because the virtual hardware has no firmware updates.

## Work: file shares and VPN

You keep a normal local user. Kerberos logs you in to the domain's services
without joining the machine to the domain.

- **`work.nix`** (public) holds the setup: Kerberos, how shares are mounted, and the VPN.
- **`private/work.nix`** holds your domain and share paths. It is git-ignored, so it stays on the machine.

### Set up once

1. **Collect two things on your Windows work PC** (in `cmd`):
   - `echo %USERDNSDOMAIN%` prints the domain.
   - `net use` lists your network drives as `\\server\share`.
2. **Run `bash setup.sh`** and answer *yes* at "Set up work file shares?". Enter the domain,
   then each share: a name and the path, which you can paste exactly as `net use` shows it.
   Each share appears as `~/shares/<name>`. Running `setup.sh` again shows the current
   shares and lets you keep them and add more.
3. **Set up the VPN** (for off campus): run `nm-connection-editor`, click **+**, and choose
   *Cisco AnyConnect or openconnect*. As *Gateway*, enter the server you use in Cisco Secure Client
   on Windows. Save.

### Every day

1. **Off campus, connect the VPN** from Noctalia's network menu, or with
   `nmcli connection up <name> --ask`.
2. **Get a Kerberos ticket**, valid for about 10 hours:
   ```sh
   kinit yourname        # your Windows username, asks for your Windows password
   klist                 # shows the ticket
   ```
   If your Linux username is the same as your Windows one, a plain `kinit` is enough.
3. **Open `~/shares/<name>`** in the terminal, Nautilus or VS Code. It connects on first access.

### If it doesn't work

- **`Required key not available` or `Permission denied` on a share:** usually no valid ticket. Run `klist`,
  then `kinit` again.
- **`kinit: Cannot find KDC for realm`:** you're not in the work network. Connect the VPN, or check the domain
  in `private/work.nix` (it must be in capitals; `bash setup.sh` can change it).
- **`Clock skew too great`:** Kerberos needs the clock to be within about 5 minutes. Check it with `date`.
- **A share hangs or fails:** `journalctl -b | grep -i cifs` shows the real error.
- **The VPN asks for a browser or MFA login:** the NetworkManager dialog shows the login page. If that
  doesn't work, try it from the terminal: `sudo openconnect --protocol=anyconnect <gateway>`.
- **Quick one-off access without any setup:** in Nautilus, go to *Other Locations → Connect to Server* and
  enter `smb://server/share`.

## SSH to your servers

Put your own `~/.ssh/config` and keys in `~/.ssh/`. 

**Remembering the key passphrase:** GNOME's SSH agent, which comes with the keyring, keeps it.

1. Add this at the top of `~/.ssh/config`:
   ```
   Host *
       AddKeysToAgent yes
   ```
2. The first time you `ssh` somewhere, a window asks for the key's passphrase. Tick
   *Automatically unlock this key whenever I'm logged in*.

From then on it doesn't ask again. The passphrase is stored in your keyring, which your login
unlocks.

**When copying keys and config over**, SSH refuses files that others can read:
```sh
chmod 700 ~/.ssh
chmod 600 ~/.ssh/config ~/.ssh/id_*
chmod 644 ~/.ssh/*.pub
```

**Check:** `echo $SSH_AUTH_SOCK` should show `/run/user/<uid>/gcr/ssh`, and `ssh-add -l` lists the
loaded keys.

## Remote desktop (VNC)

`wayvnc` shares the running desktop. It listens only on the notebook itself
(`127.0.0.1`), so nobody can reach it over the network directly. You get to it
through an SSH tunnel. SSH encrypts everything and does the login.

```
home PC --(work VPN)--> notebook:22 (SSH) --tunnel--> wayvnc on 127.0.0.1:5900
```

### Set up once

1. **Note the notebook's address.** Run `ip -br a` on the notebook. If it changes from day to day,
   ask IT for a fixed address or a DNS name for it.
2. **On your home PC (Windows), install a VNC viewer**, e.g. *TigerVNC Viewer* or *RealVNC Viewer*.
   SSH is already part of Windows.
3. **Recommended: log in with an SSH key instead of a password.** In PowerShell on the home PC:
   ```powershell
   ssh-keygen -t ed25519
   type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh <user>@<notebook> "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
   ```
   When `ssh <user>@<notebook>` no longer asks for a password, set `PasswordAuthentication = false`
   in `configuration.nix` and run `rebuild`.

### Every time

1. **On the home PC, connect Cisco Secure Client** (the work VPN).
2. **Open the tunnel** in PowerShell and leave the window open:
   ```powershell
   ssh -L 5900:localhost:5900 <user>@<notebook>
   ```
3. **In the VNC viewer, connect to `localhost:5900`.**

### A separate desktop instead (recommended for working from home)

Instead of sharing the office screen, `remote-desktop` starts a second, invisible desktop: Mango
without a monitor, with Noctalia and your normal Mango settings (`mango/settings.conf`). Nobody has
to be logged in at the notebook, and its screen shows nothing of what you do. It uses port **5901**:

```powershell
ssh -L 5901:localhost:5901 <user>@<notebook>
```
```sh
remote-desktop start            # or e.g. remote-desktop start 1470x956
remote-desktop resize 1470x956  # change the size while it runs; windows stay open
remote-desktop status
remote-desktop stop             # closes all of its windows
```

Connect the VNC viewer to `localhost:5901`. The desktop keeps running if the SSH connection drops.
Reconnect and connect the viewer again.

- **Browsers allow one copy per profile.** If Zen or Chromium is still open in the office session,
  starting it in the remote desktop just opens a new window in the running copy, on the office
  screen, where you can't see it. Close the browser at the office (or log out there) before you
  leave.
- **If it doesn't start**, it prints the last log lines. More in `journalctl --user -u remote-desktop`.
- **The size:** make it match the screen you connect from, or you have to scroll around. A 13"
  MacBook Air is 1470x956 by default, a 15" one 1710x1112 (macOS: System Settings → Displays). With
  the menu bar and the viewer's title bar, a bit less height fits better unless the viewer is full
  screen (on a 13" Air with TigerVNC in a window, 1440x900 fits). If the viewer doesn't follow a
  `resize`, reconnect it.
- **Two wayvncs:** the office session's wayvnc owns the default control socket, so the one for the
  remote desktop gets its own (`-S`). Without it, it refuses to start.

### Finding the notebook's address from home

The address changes now and then (e.g. after a restart). Under Windows, `lib747` worked because
Windows updates its entry `lib747.d.ethz.ch` in the AD DNS. NixOS can't (only the Windows computer
account may change it), so that name points to the last Windows address. Don't use it.

Instead, the notebook writes its address to **`~/polybox/aktuell/current-ip.txt`** every 30 minutes
and shortly after a restart. The Nextcloud client syncs it, so you see it in polybox at home.

- **After a restart**, the Nextcloud client only runs once someone logs in. Until then polybox shows
  the old address.
- `publish-ip` writes it right away. Log: `journalctl --user -u publish-ip`.
- Only lib747 does this (set in `hosts/lib747/custom.nix`).

The proper fix is a fixed address or DNS name from IT (MAC of the dock: `a8:2b:dd:3c:c1:e0`).

### What the notebook needs (for sharing the office screen)

- **You're logged in.** VNC shares a running desktop. After a reboot, someone has to log in at the
  notebook first. (Automatic login would solve that, but anyone at your desk would then get your desktop.)
- **It's plugged in.** On power, closing the lid doesn't suspend it. On battery it still does.
- **No auto-suspend.** If Noctalia is set to suspend when idle, turn that off in its settings.
- **The lock screen:** test once whether you can unlock it through VNC. If not, turn auto-lock off
  while you work remotely.
- **People in the office see the screen.** Whatever you do remotely is visible on the notebook's display.

### If it doesn't work

- **`ssh` times out:** the work network may block SSH from the VPN to office machines. Ask IT to allow
  port 22 to your notebook.
- **The viewer connects, but the picture is black or frozen:** check that `wayvnc` is running with
  `pgrep -a wayvnc` (over SSH). Start it by hand with `wayvnc 127.0.0.1 5900 &` to see its errors.
- **Mango:** it starts `wayvnc-screencopy`, a patched `wayvnc` (see the top of `configuration.nix`).
  Mango 0.18 has a bug in the newer capture protocol that crashes the normal `wayvnc` as soon as a viewer
  connects. Once Mango fixes it, the patch can go.
- **Several monitors:** wayvnc shows one. `wayvncctl output-cycle` switches to the next one.
- **Port 5900 is busy on the home PC:** use `ssh -L 5901:localhost:5900 ...` and connect to `localhost:5901`.

## Troubleshooting

- **Black screen or back at the login screen:** press `Ctrl+Alt+F2` for a text console. Then read the logs.
  Umbriel: `~/.cache/umbriel/umbriel.log` and `journalctl --user -b -u umbriel`. Mango: run `mango` from
  the console to see its errors. If there is no 3D acceleration, uncomment `WLR_RENDERER_ALLOW_SOFTWARE`
  in `hosts/<name>/default.nix` and rebuild.
- **Noctalia or terminal windows vanish right after opening (VM):** uncomment `LIBGL_ALWAYS_SOFTWARE`
  in `hosts/<name>/default.nix` and rebuild, then log in again.
- **Remote login:** the SSH server is on. From another machine: `ssh <user>@<ip>` (IP from `ip -br a`).
  For the remote desktop, see "Remote desktop (VNC)" above.
- **Super does nothing:** Windows or the VM app is catching the Windows key. Fix it in the hypervisor's
  keyboard settings. Otherwise, for now, set `mod_key = "Alt"` in `umbriel/config.toml`, or replace
  `SUPER` with `ALT` in `mango/settings.conf`.
- **Invisible mouse pointer:** `WLR_NO_HARDWARE_CURSORS` is already set for the VM. Make sure the guest tools are enabled.
- **Copy-paste with Windows doesn't work:** VMware's clipboard helper is an X11 program. Here it runs through
  Xwayland, which works only partly or not at all on Wayland. Use a shared folder or `git push`/`pull` instead.
- **Resolution doesn't follow the VMware window:** set it by hand. Umbriel: `[output.Virtual-1] mode = "1920x1080"`
  in `umbriel/config.toml` (get the name from `umbriel outputs`). Mango: `monitor_rule=name:Virtual-1,width:1920,height:1080,refresh:60`
  in `mango/settings.conf` (get the name from `mmsg get all-monitors`).

## Keybinds compared to dwm

Mango is based on dwl, which is dwm ported to Wayland, so it keeps dwm's model of
tags, layouts and master area. Umbriel uses workspaces, and some binds only
approximate dwm.

| dwm | Mango | Umbriel |
|---|---|---|
| `Mod+p` dmenu | Noctalia launcher | same, or tap `Mod` |
| `Mod+Shift+Return` term | kitty | kitty |
| `Mod+w` / `Mod+n` | Zen, Nautilus | Zen, Nautilus |
| `Mod+b` togglebar | Noctalia bar | Noctalia bar |
| `Mod+j/k` focusstack | same | same |
| `Mod+i/d` nmaster | same | same |
| `Mod+h/l` mfact | same | same in master; column width in scrolling |
| `Mod+Return` zoom | same | swaps with master (approximate) |
| `Mod+Tab` | previous tagset | previous workspace |
| `Mod+Shift+c` kill | **`Mod+Q`** | same |
| `Mod+t` tile | tile | master |
| `Mod+f` floating | floats all windows on the tag | floating layout |
| `Mod+m` monocle | monocle | **scrolling** (no monocle) |
| `Mod+space` | tile ↔ scroller | master ↔ scrolling |
| `Mod+Shift+space` | toggle floating | toggle floating |
| `Mod+0` view all | same | overview |
| `Mod+Shift+0` tag all | same | pin window |
| `Mod+,/.` and `Mod+Shift+,/.` | same (monitors) | same (monitors) |
| `Mod+1..9` / `Mod+Shift+1..9` | view / tag | switch / send to workspace |
| `Mod+Ctrl+(Shift+)1..9` | toggleview / toggletag | **none** |
| `Mod+Shift+q` quit | quits immediately | asks first |

Extras in both: `Mod+Shift+J/K` swap windows, `Mod+arrows` directional focus,
`Mod+Shift+arrows` move window, `Mod+Shift+F` fullscreen, `Mod+R` cycle width
(scroller/scrolling), `Mod+Ctrl+Left/Right` stack into neighbour column,
`Mod+Y` dwindle, `Mod+O` overview, `Mod+§` scratchpad (`Mod+Shift+§` sends a
window there), `Mod+S` control center, `Mod+V` clipboard, `Mod+Shift+S`
screenshot, `Mod+Escape` Noctalia power menu.
Umbriel only: `Mod+Shift+W` tabs, `Mod+F1` cheatsheet.
Mango only: `Mod+Ctrl+R` reload config.
