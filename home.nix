# Home Manager: your user's dotfiles.
{
  config,
  lib,
  pkgs,
  username,
  repo, # where this repo lives, set in flake.nix
  ...
}:
let
  link = path: config.lib.file.mkOutOfStoreSymlink "${repo}/${path}";
in
{
  home.username = username;
  home.homeDirectory = "/home/${username}";
  # home.stateVersion is set per machine, in hosts/<name>/default.nix.

  programs.home-manager.enable = true;

  # Link the compositor configs straight to the files in this repo.
  # Usually Home Manager copies files into the read-only /nix/store. With an
  # out-of-store link you can edit the repo file and the compositor reloads it
  # as soon as you save, with no rebuild.
  xdg.configFile."umbriel/config.toml".source = link "umbriel/config.toml";
  xdg.configFile."umbriel/lid.sh".source = link "umbriel/lid.sh";
  xdg.configFile."mango/config.conf".source = link "mango/config.conf";
  xdg.configFile."mango/settings.conf".source = link "mango/settings.conf";
  xdg.configFile."mango/lid.sh".source = link "mango/lid.sh";

  # Noctalia reads this file first; its settings window saves changes to
  # ~/.local/state/noctalia/settings.toml, which overrides it. Settings worth
  # keeping for a fresh setup go in noctalia/config.toml.
  xdg.configFile."noctalia/config.toml".source = link "noctalia/config.toml";

  home.packages = [
    # `import-bookmarks FILE.html`: add exported bookmarks to Chromium and Zen.
    (pkgs.writeShellScriptBin "import-bookmarks" ''
      exec ${pkgs.python3}/bin/python3 ${./scripts/import-bookmarks.py} "$@"
    '')
    # `remote-desktop attach|detach|start|stop|resize|status`: work on the
    # notebook over VNC, from SSH. The input block it uses is in configuration.nix.
    (pkgs.writeShellScriptBin "remote-desktop" ''
      export PATH=${lib.makeBinPath [ pkgs.wlr-randr pkgs.jq pkgs.util-linux pkgs.procps ]}:/etc/profiles/per-user/${username}/bin:/run/current-system/sw/bin:$PATH
      exec ${pkgs.bash}/bin/bash ${./scripts/remote-desktop.sh} "$@"
    '')
    # `timetogo START [LUNCH_MINUTES]`: when an 8.2-hour workday started at
    # START ends (lunch break defaults to 30 minutes).
    (pkgs.writeShellScriptBin "ttg" ''
      exec ${pkgs.bash}/bin/bash ${./scripts/timetogo.sh} "$@"
    '')
  ];

  # Daily wallpaper: Bing's "image of the day" (the same kind of nature photos
  # as Windows Spotlight). Images are kept in ~/Pictures/Wallpapers/bing.
  # Run it by hand with `systemctl --user start bing-wallpaper`.
  systemd.user.services.bing-wallpaper = {
    Unit = {
      Description = "Set Bing image of the day as Noctalia wallpaper";
      After = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      Environment = [
        "PATH=${pkgs.lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils ]}:/run/current-system/sw/bin"
      ];
      ExecStart = "${pkgs.bash}/bin/bash ${./scripts/bing-wallpaper.sh}";
    };
  };
  systemd.user.timers.bing-wallpaper = {
    Unit.Description = "Fetch the Bing wallpaper daily";
    Timer = {
      OnStartupSec = "1min"; # shortly after login, once Noctalia is up
      OnCalendar = "hourly"; # catches the new image soon after Bing changes it
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  programs.kitty = {
    enable = true;
    # Close windows and tabs without asking, even if a program is still running.
    settings.confirm_os_window_close = 0;
  };

  # `rebuild` and `update` are commands defined in configuration.nix.
  programs.bash.enable = true;
  home.pointerCursor = {
    enable = true;
    package = pkgs.bibata-cursors;   # or adwaita-icon-theme, phinger-cursors, …
    name = "Bibata-Modern-Classic";
    size = 24;
    gtk.enable = true;
  };
}
