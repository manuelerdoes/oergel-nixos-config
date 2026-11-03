# Home Manager: your user's dotfiles.
{
  config,
  pkgs,
  username,
  repo, # where this repo lives, set in flake.nix
  ...
}:
let
  link = path: config.lib.file.mkOutOfStoreSymlink "${repo}/${path}";

  # `publish-ip`: writes the current IP address to
  # ~/polybox/aktuell/current-ip.txt. Runs every 30 minutes (timer below).
  publish-ip = pkgs.writeShellScriptBin "publish-ip" ''
    export PATH=${
      pkgs.lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnused
        pkgs.iproute2
      ]
    }:$PATH
    exec ${pkgs.bash}/bin/bash ${./scripts/publish-ip.sh} "$@"
  '';
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
  xdg.configFile."mango/config.conf".source = link "mango/config.conf";
  xdg.configFile."mango/settings.conf".source = link "mango/settings.conf";

  # Noctalia's settings stay in ~/.config/noctalia/ and are changed from its
  # settings GUI. To manage them from Nix later, see the Home Manager section
  # of https://docs.noctalia.dev/noctalia/getting-started/nixos/

  home.packages = [
    # `import-bookmarks FILE.html`: add exported bookmarks to Chromium and Zen.
    (pkgs.writeShellScriptBin "import-bookmarks" ''
      exec ${pkgs.python3}/bin/python3 ${./scripts/import-bookmarks.py} "$@"
    '')
    # `remote-desktop start|resize|stop|status`: a separate desktop over VNC, for SSH.
    (pkgs.writeShellScriptBin "remote-desktop" ''
      WLR_RANDR=${pkgs.wlr-randr}/bin/wlr-randr exec ${pkgs.bash}/bin/bash ${./scripts/remote-desktop.sh} "$@"
    '')
    publish-ip
  ];

  # The notebook's IP address changes now and then. This keeps the current
  # one in polybox (synced by the Nextcloud client), so you can find it from
  # home. It also runs while nobody is logged in (linger in
  # configuration.nix), but the sync only happens once someone logs in.
  systemd.user.services.publish-ip = {
    Unit.Description = "Write the IP address to polybox";
    Service = {
      Type = "oneshot";
      ExecStart = "${publish-ip}/bin/publish-ip";
    };
  };
  systemd.user.timers.publish-ip = {
    Unit.Description = "Write the IP address to polybox every 30 minutes";
    Timer = {
      OnStartupSec = "1min"; # shortly after boot (or login)
      OnUnitActiveSec = "30min";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  programs.bash = {
    enable = true;
    shellAliases = {
      # --impure lets the build read the git-ignored private/work.nix.
      rebuild = "sudo nixos-rebuild switch --impure --flake ${repo}";
      update = "nix flake update --flake ${repo} && sudo nixos-rebuild switch --impure --flake ${repo}";
    };
  };
}
