# Settings shared by every machine (VM now, notebook later).
# Machine-specific things (bootloader, hostname, hardware) live in hosts/<name>/.
{
  config,
  lib,
  pkgs,
  inputs,
  username,
  repo,
  ...
}:
let
  # `rebuild` and `update` are real commands (not shell aliases), so they work
  # with and without sudo. --impure lets the build read the git-ignored
  # private/work.nix.
  rebuild = pkgs.writeShellScriptBin "rebuild" ''
    exec sudo nixos-rebuild switch --impure --flake ${repo} "$@"
  '';
  update = pkgs.writeShellApplication {
    name = "update";
    runtimeInputs = [ pkgs.util-linux ];
    text = ''
      # Anything root ever created in the repo (e.g. from a `sudo git ...`)
      # makes `nix flake update` fail with "permission denied", so fix it first.
      if [ -n "$(find ${repo} ! -user ${username} -print -quit)" ]; then
        echo "Giving files in ${repo} back to ${username} ..."
        sudo chown -R ${username}: ${repo}
      fi

      # flake.lock and git belong to ${username}, so never update them as root.
      if [ "$(id -u)" -eq 0 ]; then
        runuser -u ${username} -- nix flake update --flake ${repo}
      else
        nix flake update --flake ${repo}
      fi

      exec ${rebuild}/bin/rebuild "$@"
    '';
  };

  # wayvnc always captures with ext-image-copy-capture when the compositor
  # offers it. Mango 0.18 answers that with a 0x0 image and wayvnc crashes,
  # so this variant uses the older wlr-screencopy protocol instead. The patch
  # disables both ext checks (screen and cursor), so wayvnc behaves as on a
  # compositor without the new protocol. Only Mango starts it (as
  # wayvnc-screencopy); Umbriel uses the normal wayvnc.
  wayvnc-screencopy = pkgs.writeShellScriptBin "wayvnc-screencopy" ''
    exec ${
      pkgs.wayvnc.overrideAttrs (old: {
        pname = "wayvnc-screencopy";
        postPatch = (old.postPatch or "") + ''
          substituteInPlace src/screencopy-interface.c \
            --replace-fail "if (wayland->ext_image_copy_capture_manager_v1 &&" \
                           "if (0 && wayland->ext_image_copy_capture_manager_v1 &&"
        '';
      })
    }/bin/wayvnc "$@"
  '';

  # The LanguageTool add-ons for Zen and Thunderbird, installed through
  # policies and pointed at the local server, only with
  # features.languagetool.enable (writing-tools.nix). Their German variant
  # can't be set this way: set it to "Switzerland" once in each add-on's
  # settings, otherwise they suggest "ß".
  languagetool = config.features.languagetool.enable;
  languagetoolAddon = id: url: {
    ExtensionSettings.${id} = {
      install_url = url;
      installation_mode = "normal_installed";
    };
    "3rdparty".Extensions.${id} = {
      apiServerUrl = "http://localhost:8081/v2";
      disablePrivacyConfirmation = true; # texts stay on this machine
    };
  };
in
{
  imports = [
    ./work.nix # file shares, Kerberos, VPN
    ./writing-tools.nix # optional: Ollama proofreading, LanguageTool
  ];

  # ---------------------------------------------------------------- Nix itself
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;
  };

  # Delete old generations weekly so the disk doesn't fill up.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  # VS Code is not open source.
  nixpkgs.config.allowUnfree = true;

  # ---------------------------------------------------------- Locale & keyboard
  time.timeZone = "Europe/Zurich";
  i18n.defaultLocale = "en_US.UTF-8";
  # Programs stay in English, but dates and times use the Swiss format:
  # 24-hour clock (14:05:33) and day.month.year (09.11.2026).
  # Weekday and month names, where a program spells them out, are German.
  i18n.extraLocaleSettings.LC_TIME = "de_CH.UTF-8";
  # Swiss German. The compositors set their own layout in
  # umbriel/config.toml and mango/settings.conf (setup.sh keeps all three in sync).
  services.xserver.xkb = {
    layout = "ch";
    variant = ""; # standard, with dead keys
  };
  console.useXkbConfig = true; # text console (TTY) uses the same layout

  # ---------------------------------------------------------------------- User
  users.users.${username} = {
    isNormalUser = true;
    # Keep your user's systemd running while you're logged out, so the
    # remote-desktop session survives a dropped SSH connection.
    linger = true;
    extraGroups = [
      "wheel" # sudo
      "networkmanager"
      "video"
      "audio"
    ];
  };

  # ------------------------------------------------------ Desktop: compositors
  # Both are installed; pick one on the login screen.
  programs.umbriel.enable = true;
  programs.mango.enable = true;

  # -------------------------------------------------------- Desktop: the shell
  programs.noctalia = {
    enable = true;
    # NetworkManager, Bluetooth, UPower and power-profiles-daemon, which
    # Noctalia's wifi/bluetooth/battery/power widgets need.
    recommendedServices.enable = true;
  };

  # ------------------------------------------------------------- Login screen
  # A small text greeter. F3 picks the session (Umbriel or Mango), and it
  # remembers your last choice. Without a choice it starts Umbriel.
  services.greetd = {
    enable = true;
    settings.default_session.command = builtins.concatStringsSep " " [
      "${pkgs.tuigreet}/bin/tuigreet"
      "--time --remember --remember-session --asterisks"
      "--sessions ${config.services.displayManager.sessionData.desktops}/share/wayland-sessions"
      "--cmd start-umbriel"
    ];
  };

  # Keyring, unlocked at login. VS Code needs it to remember GitHub logins.
  services.gnome.gnome-keyring.enable = true;
  security.pam.services.greetd.enableGnomeKeyring = true;
  security.polkit.enable = true;

  # ------------------------------------------------------------ Remote access
  # SSH: log in from another machine with `ssh <user>@<ip>`. Port 22 is opened
  # in the firewall automatically.
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      # Passwords are fine to start with. Once your SSH key is in
      # ~/.ssh/authorized_keys, set this to false (keys only, much safer).
      PasswordAuthentication = true;
    };
  };

  # SSH client: your own ~/.ssh/config (not managed here) and keys. The SSH
  # agent is GNOME's gcr-ssh-agent, which comes with gnome-keyring. It can
  # store a key's passphrase in the keyring, which your login unlocks, so
  # `ssh <server>` doesn't ask again. Programs find the agent through
  # SSH_AUTH_SOCK; an agent forwarded with `ssh -A` keeps priority.
  environment.extraInit = ''
    if [ -z "$SSH_AUTH_SOCK" ] && [ -n "$XDG_RUNTIME_DIR" ]; then
      export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/gcr/ssh"
    fi
  '';

  # Remote desktop: wayvnc (in the package list below) shares the running
  # desktop. The compositors start it, listening on 127.0.0.1 only, so it's
  # reached through an SSH tunnel (see README, "Remote desktop"). Port 5900
  # is not opened in the firewall.

  # `remote-desktop attach` (scripts/remote-desktop.sh) takes over the office
  # session from home, like RDP. While it's active, this service blocks the
  # notebook's physical keyboards, mice, touchpads and touchscreen
  # (scripts/input-block.py), so nobody at the desk can use the session.
  # Holding Ctrl+Alt+Backspace for 3 s at the desk ends it. It is never started
  # at boot (no wantedBy), ends itself after 12 hours, and whenever it stops,
  # for any reason, the stop hook detaches: the session is locked and the
  # screens come back on.
  systemd.services.remote-input-block = {
    description = "Block the physical input while remote-desktop is attached";
    serviceConfig = {
      ExecStart = "${pkgs.python3.withPackages (ps: [ ps.evdev ])}/bin/python3 -I ${./scripts/input-block.py}";
      ExecStopPost = pkgs.writeShellScript "remote-input-block-stopped" ''
        uid=$(${pkgs.coreutils}/bin/id -u ${username})
        exec ${pkgs.util-linux}/bin/runuser -u ${username} -- ${pkgs.coreutils}/bin/env \
          XDG_RUNTIME_DIR=/run/user/$uid \
          DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
          PATH=/etc/profiles/per-user/${username}/bin:/run/current-system/sw/bin \
          remote-desktop _hook
      '';
      RuntimeMaxSec = "12h";
      Restart = "no";
    };
  };
  # Your user may start and stop only this unit, without a password (attach
  # runs over SSH, where nothing could ask for one).
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          action.lookup("unit") == "remote-input-block.service" &&
          subject.user == "${username}") {
        var verb = action.lookup("verb");
        if (verb == "start" || verb == "stop") {
          return polkit.Result.YES;
        }
      }
    });
  '';

  # Plugged in, a closed lid doesn't suspend, so the notebook stays reachable
  # in the office. On battery it still suspends as usual.
  services.logind.settings.Login.HandleLidSwitchExternalPower = "ignore";

  # -------------------------------------------------------------------- Audio
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
    wireplumber.enable = true;
  };

  # Trash, USB drives and network shares in the file manager.
  services.gvfs.enable = true;

  # BIOS and device firmware updates (Lenovo publishes them on LVFS):
  # fwupdmgr refresh && fwupdmgr get-updates && fwupdmgr update
  # With Secure Boot on (Lanzaboote), BIOS updates need fwupd's EFI helper to be
  # signed with your keys; it isn't, so do those from Windows instead.
  services.fwupd.enable = true;

  # File-chooser dialogs. Umbriel's own portal handles screen sharing on
  # Umbriel; on Mango it's xdg-desktop-portal-wlr (added by programs.mango).
  xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];

  # Run Chromium, VS Code and other Electron apps as native Wayland apps.
  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  # ----------------------------------------------------------------- Programs
  environment.systemPackages = with pkgs; [
    rebuild # sudo nixos-rebuild switch for this repo
    update # nix flake update, then rebuild
    # Apps
    # Both browsers: middle-click on a page for Windows-style autoscroll
    # (move the mouse to scroll, click again to stop).
    # Zen and Thunderbird: use_os_locales makes them show dates in the
    # system's Swiss format (LC_TIME above) instead of the American one.
    (inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
      extraPrefs = ''
        defaultPref("general.autoScroll", true);
        defaultPref("intl.regional_prefs.use_os_locales", true);
      '';
      # Not extraPolicies: the Zen flake hands those to the inner package, and
      # the outer wrapper then replaces its policies.json with an empty one.
      extraPoliciesFiles = lib.optionals languagetool [
        (pkgs.writeText "zen-languagetool-policies.json" (
          builtins.toJSON {
            policies = languagetoolAddon "languagetool-webextension@languagetool.org"
              "https://addons.mozilla.org/firefox/downloads/latest/languagetool/latest.xpi";
          }
        ))
      ];
    }) # binary: zen-beta
    (chromium.override {
      commandLineArgs = "--enable-blink-features=MiddleClickAutoscroll";
    })
    vscode
    kitty # terminal
    nautilus # file manager

    # X11 apps on Wayland
    xwayland

    # Tools
    git
    vim
    nano
    wget
    curl
    wl-clipboard
    brightnessctl
    playerctl
    slurp # screen picker for screen sharing on Mango
    wayvnc # remote desktop (VNC), see "Remote access" above
    wayvnc-screencopy # the same for Mango, see the top of this file
    python3
    htop

    # Work
    teams-for-linux
    nextcloud-client
    (thunderbird.override {
      extraPrefs = ''defaultPref("intl.regional_prefs.use_os_locales", true);'';
      extraPolicies = lib.optionalAttrs languagetool (
        languagetoolAddon "languagetool-mailextension@languagetool.org"
          "https://addons.thunderbird.net/thunderbird/downloads/latest/grammar-and-spell-checker/latest.xpi"
      );
    })
    libreoffice
    claude-code
  ];

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-color-emoji
    nerd-fonts.jetbrains-mono
  ];

  programs.nix-ld.enable = true;
  programs.direnv.enable = true;
  programs.evolution = {
    enable = true;
    plugins = [ pkgs.evolution-ews ];
};
}
