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

  # Noctalia reads this file first; its settings window saves changes to
  # ~/.local/state/noctalia/settings.toml, which overrides it. Settings worth
  # keeping for a fresh setup go in noctalia/config.toml.
  xdg.configFile."noctalia/config.toml".source = link "noctalia/config.toml";

  home.packages = [
    # `import-bookmarks FILE.html`: add exported bookmarks to Chromium and Zen.
    (pkgs.writeShellScriptBin "import-bookmarks" ''
      exec ${pkgs.python3}/bin/python3 ${./scripts/import-bookmarks.py} "$@"
    '')
    # `remote-desktop start|resize|stop|status`: a separate desktop over VNC, for SSH.
    (pkgs.writeShellScriptBin "remote-desktop" ''
      WLR_RANDR=${pkgs.wlr-randr}/bin/wlr-randr exec ${pkgs.bash}/bin/bash ${./scripts/remote-desktop.sh} "$@"
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

  # LibreOffice's built-in LanguageTool checker uses the local server
  # (services.languagetool in configuration.nix). Its settings file is also
  # written by LibreOffice itself, so the script only updates two entries.
  home.activation.libreofficeLanguagetool = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.python3}/bin/python3 -I ${./scripts/libreoffice-languagetool.py} http://localhost:8081/v2
  '';

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
