# NixOS: Umbriel / Mango + Noctalia

```
setup.sh                interactive setup for a new machine (step 4)
flake.nix               entry point: inputs (nixpkgs, home-manager, zen); finds machines in hosts/
configuration.nix       shared by all machines: desktop, apps, audio, login screen, SSH
hosts/<name>/default.nix                one folder per machine (name = hostname):
hosts/<name>/hardware-configuration.nix   bootloader, VM tools, stateVersion, disks
home.nix                Home Manager: your user's dotfiles
umbriel/config.toml     Umbriel config and keybinds (reloads on save)
mango/config.conf       Mango config and keybinds (reloads on save)
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
| Keyboard | Written to `configuration.nix`, `umbriel/config.toml` and `mango/config.conf` |
| VM only | Guest tools for the hypervisor it detects, plus the graphics workarounds |

It also copies `hardware-configuration.nix`, checks the free disk space, runs
`git add -A` (flakes ignore files git doesn't know), and then offers to build
and reboot. Running it again is safe: old files are kept as `*.bak`.

For a VMware VM, also check these settings in VMware Workstation Player:

- **Display:** *Accelerate 3D graphics* on, with as much graphics memory as it allows.
  If it stays off, add `mks.enable3d = "TRUE"` to the VM's `.vmx` file (VM powered off).
- **Options → Guest Isolation:** drag-and-drop and copy-paste enabled.

## 5. After the first build

From now on, `rebuild` (an alias) rebuilds. `sudo nixos-rebuild switch --flake ~/oergel-nixos-config`
works too, and picks this machine by its hostname.

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

- **Compositor configs:** edit `~/oergel-nixos-config/umbriel/config.toml` or `~/oergel-nixos-config/mango/config.conf`. They apply when you save, with no rebuild.
- **Everything else:** edit the `.nix` files, then `git add -A && rebuild`.
- **Update all software:** `update`. It runs `nix flake update` and then rebuilds.
- **Undo:** every rebuild is a *generation*. Pick an older one in the boot menu, or run `sudo nixos-rebuild switch --rollback`.
- **Find packages:** https://search.nixos.org/packages (channel *unstable*). Add them to `environment.systemPackages`.

## Troubleshooting

- **Black screen or back at the login screen:** press `Ctrl+Alt+F2` for a text console. Then read the logs.
  Umbriel: `~/.cache/umbriel/umbriel.log` and `journalctl --user -b -u umbriel`. Mango: run `mango` from
  the console to see its errors. If there is no 3D acceleration, uncomment `WLR_RENDERER_ALLOW_SOFTWARE`
  in `hosts/<name>/default.nix` and rebuild.
- **Noctalia or terminal windows vanish right after opening (VM):** uncomment `LIBGL_ALWAYS_SOFTWARE`
  in `hosts/<name>/default.nix` and rebuild, then log in again.
- **Remote login:** the SSH server is on. From another machine: `ssh <user>@<ip>` (IP from `ip -br a`).
- **Super does nothing:** Windows or the VM app is catching the Windows key. Fix it in the hypervisor's
  keyboard settings. Otherwise, for now, set `mod_key = "Alt"` in `umbriel/config.toml`, or replace
  `SUPER` with `ALT` in `mango/config.conf`.
- **Invisible mouse pointer:** `WLR_NO_HARDWARE_CURSORS` is already set for the VM. Make sure the guest tools are enabled.
- **Copy-paste with Windows doesn't work:** VMware's clipboard helper is an X11 program. Here it runs through
  Xwayland, which works only partly or not at all on Wayland. Use a shared folder or `git push`/`pull` instead.
- **Resolution doesn't follow the VMware window:** set it by hand. Umbriel: `[output.Virtual-1] mode = "1920x1080"`
  in `umbriel/config.toml` (get the name from `umbriel outputs`). Mango: `monitor_rule=name:Virtual-1,width:1920,height:1080,refresh:60`
  in `mango/config.conf` (get the name from `mmsg get all-monitors`).

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
