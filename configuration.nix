# Settings shared by every machine (VM now, notebook later).
# Machine-specific things (bootloader, hostname, hardware) live in hosts/<name>/.
{
  config,
  pkgs,
  inputs,
  username,
  ...
}:
{
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
  # umbriel/config.toml and mango/config.conf (setup.sh keeps all three in sync).
  services.xserver.xkb = {
    layout = "ch";
    variant = "de_nodeadkeys";
  };
  console.useXkbConfig = true; # text console (TTY) uses the same layout

  # ---------------------------------------------------------------------- User
  users.users.${username} = {
    isNormalUser = true;
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

  # ---------------------------------------------------------------- SSH server
  # Log in from another machine with `ssh <user>@<ip>`. Port 22 is opened in
  # the firewall automatically.
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      # Passwords are fine to start with. Once your SSH key is in
      # ~/.ssh/authorized_keys, set this to false (keys only, much safer).
      PasswordAuthentication = true;
    };
  };

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

  # File-chooser dialogs. Umbriel's own portal handles screen sharing on
  # Umbriel; on Mango it's xdg-desktop-portal-wlr (added by programs.mango).
  xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];

  # Run Chromium, VS Code and other Electron apps as native Wayland apps.
  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  # ----------------------------------------------------------------- Programs
  environment.systemPackages = with pkgs; [
    # Apps
    inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default # binary: zen-beta
    chromium
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
  ];

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-color-emoji
    nerd-fonts.jetbrains-mono
  ];
}
