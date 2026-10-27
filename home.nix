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
    # `remote-desktop start|stop|status`: a separate desktop over VNC, for SSH.
    (pkgs.writeShellScriptBin "remote-desktop" ''
      exec ${pkgs.bash}/bin/bash ${./scripts/remote-desktop.sh} "$@"
    '')
  ];

  programs.bash = {
    enable = true;
    shellAliases = {
      # --impure lets the build read the git-ignored private/work.nix.
      rebuild = "sudo nixos-rebuild switch --impure --flake ${repo}";
      update = "nix flake update --flake ${repo} && sudo nixos-rebuild switch --impure --flake ${repo}";
    };
  };
}
