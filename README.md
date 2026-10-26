# NixOS: Umbriel / Mango + Noctalia

```
flake.nix               entry point: inputs (nixpkgs, home-manager, zen) and machines
configuration.nix       shared by all machines: desktop, apps, audio, login screen
hosts/vm/default.nix    VM only: bootloader, guest tools, stateVersion
hosts/vm/hardware-configuration.nix   copied from the VM (step 4)
home.nix                Home Manager: your user's dotfiles
umbriel/config.toml     Umbriel config and keybinds (reloads on save)
mango/config.conf       Mango config and keybinds (reloads on save)
```

Both compositors are installed. You pick one on the login screen, and Noctalia runs in either.

## 0. VM settings (on Windows)

Umbriel and Mango both draw with the GPU, so the VM needs 3D acceleration.

- **VMware Workstation** (free for personal use): the most reliable choice. Enable *Accelerate 3D graphics*.
- **VirtualBox**: graphics controller *VMSVGA* with *Enable 3D Acceleration*. Works sometimes.
- **Hyper-V**: has no 3D acceleration for Linux guests. Umbriel will most likely fail or crawl.

Also give the VM at least 4 GB RAM (8 is better), 2+ CPUs and a 40+ GB disk.

## 1. Put this folder on GitHub (on Windows)

Create an empty repository (private is fine) called `nixos-config`, then:

```powershell
cd C:\Users\merdoes\Documents\oergel-nixos-config
git init
git add .
git commit -m "Initial NixOS config"
git branch -M main
git remote add origin https://github.com/<you>/nixos-config.git
git push -u origin main
```

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

The path matters, because `home.nix` links to `~/nixos-config/umbriel/config.toml`.

```sh
git clone https://github.com/<you>/nixos-config.git ~/nixos-config
cd ~/nixos-config
```

A private repo asks for a username and a GitHub personal access token as the password.

## 4. Adapt it to the VM

```sh
cp /etc/nixos/hardware-configuration.nix hosts/vm/
cat /etc/nixos/configuration.nix      # compare with the values below
```

Compare the installer's file with these and fix ours where they differ:

| What | Where in this repo |
|---|---|
| Your username (`users.users.<name>`) | `username = ...` in `flake.nix` |
| `boot.loader...` lines | `hosts/vm/default.nix` |
| `system.stateVersion` | `hosts/vm/default.nix` and `home.stateVersion` in `home.nix` |
| `console.keyMap` / keyboard layout | `configuration.nix`, `[input.keyboard]` in `umbriel/config.toml`, `xkb_rules_layout` in `mango/config.conf` |

> **The username must match the user that already exists.** If it doesn't,
> NixOS creates a new user with no password and you can't log in.

VMware Tools (open-vm-tools) are already switched on in `hosts/vm/default.nix`.
For another hypervisor, swap in its line there.

In VMware Workstation Player, check these VM settings:

- **Display:** *Accelerate 3D graphics* on, with as much graphics memory as it allows.
- **Options → Guest Isolation:** drag-and-drop and copy-paste enabled.
- **Options → VMware Tools** (if present): *Synchronize guest time with host*.

## 5. Build

Flakes only see files that git knows about. Always `git add` new files first.

```sh
git add -A
sudo nixos-rebuild switch --flake ~/nixos-config#nixos-vm
```

The first build downloads a lot and takes a while. After that the hostname is
`nixos-vm`, so later builds don't need `#nixos-vm`. The `rebuild` alias does it:
`rebuild`.

Commit the generated `flake.lock` and push it. It pins the exact versions of everything.

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

- **Compositor configs:** edit `~/nixos-config/umbriel/config.toml` or `~/nixos-config/mango/config.conf`. They apply when you save, with no rebuild.
- **Everything else:** edit the `.nix` files, then `git add -A && rebuild`.
- **Update all software:** `update`. It runs `nix flake update` and then rebuilds.
- **Undo:** every rebuild is a *generation*. Pick an older one in the boot menu, or run `sudo nixos-rebuild switch --rollback`.
- **Find packages:** https://search.nixos.org/packages (channel *unstable*). Add them to `environment.systemPackages`.

## Troubleshooting

- **Black screen or back at the login screen:** press `Ctrl+Alt+F2` for a text console. Then read the logs.
  Umbriel: `~/.cache/umbriel/umbriel.log` and `journalctl --user -b -u umbriel`. Mango: run `mango` from
  the console to see its errors. If there is no 3D acceleration, uncomment `WLR_RENDERER_ALLOW_SOFTWARE`
  in `hosts/vm/default.nix` and rebuild.
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
| `Mod+Shift+c` kill | same | same |
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
