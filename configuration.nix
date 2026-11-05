# Settings shared by every machine (VM now, notebook later).
# Machine-specific things (bootloader, hostname, hardware) live in hosts/<name>/.
{
  config,
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
in
{
  imports = [
    ./work.nix # file shares, Kerberos, VPN
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

  # Local LLMs for AI spell checking in Thunderbird (e.g. the ThunderAI add-on,
  # pointed at http://localhost:11434). The Vulkan build uses the Radeon 860M;
  # ROCm doesn't properly support its chip (gfx1152). Check that the GPU was
  # picked up with: journalctl -u ollama | grep -iE 'vulkan|igpu'
  services.ollama = {
    enable = true;
    package = pkgs.ollama-vulkan;
    # Downloaded in the background after a rebuild (ollama-model-loader service).
    loadModels = [
      "gemma3:12b" # good German, ~8 GB
      "gemma3:4b" # faster, for quick checks
    ];
    environmentVariables = {
      # Thunderbird add-ons call Ollama from a moz-extension:// origin.
      OLLAMA_ORIGINS = "moz-extension://*";
      # Ollama skips integrated GPUs by default and would run on the CPU only.
      OLLAMA_IGPU_ENABLE = "1";
    };
  };

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
    (inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
      extraPrefs = ''defaultPref("general.autoScroll", true);'';
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
    thunderbird
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
}
