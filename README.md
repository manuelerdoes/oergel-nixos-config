# NixOS: Umbriel / Mango + Noctalia

```
setup.sh                interactive setup for a new machine (step 4)
flake.nix               entry point: inputs (nixpkgs, home-manager, zen); finds machines in hosts/
configuration.nix       shared by all machines: desktop, apps, audio, login screen, SSH
hosts/<name>/default.nix                one folder per machine (name = hostname):
hosts/<name>/hardware-configuration.nix   bootloader, VM tools, stateVersion, disks
home.nix                Home Manager: your user's dotfiles
work.nix                work: file shares (SMB + Kerberos), Cisco VPN
private/work.nix        your domain and shares; git-ignored, written by setup.sh
umbriel/config.toml     Umbriel config and keybinds (reloads on save)
mango/config.conf       Mango: what starts at login; loads settings.conf
mango/settings.conf     Mango settings and keybinds (both reload on save)
```

Both compositors are installed. You pick one on the login screen, and Noctalia runs in either.


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

From now on, `rebuild` (an alias) rebuilds. The long form is
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
remote-desktop start            # or e.g. remote-desktop start 2560x1440
remote-desktop status
remote-desktop stop             # closes all of its windows
```

Connect the VNC viewer to `localhost:5901`. The desktop keeps running if the SSH connection drops.
Reconnect and connect the viewer again.

- **Browsers allow one copy per profile.** If an office session is still running with Zen or Chromium
  open, they won't start in the remote desktop. Log out at the office, or close them there.
- **If it doesn't start**, it prints the last log lines. More in `journalctl --user -u remote-desktop`.
- **The size** (`remote-desktop start 2560x1440`) is set with a `monitor_rule`. If the picture stays
  at 1920x1080, Mango ignores the rule for virtual screens.

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
