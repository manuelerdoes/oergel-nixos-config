# Home Manager: your user's dotfiles.
{ config, username, ... }:
let
  repo = "${config.home.homeDirectory}/nixos-config";
  link = path: config.lib.file.mkOutOfStoreSymlink "${repo}/${path}";
in
{
  home.username = username;
  home.homeDirectory = "/home/${username}";

  # Same rule as system.stateVersion: set once, never change.
  home.stateVersion = "26.05";

  programs.home-manager.enable = true;

  # Link the compositor configs straight to the files in this repo.
  # Usually Home Manager copies files into the read-only /nix/store. With an
  # out-of-store link you can edit the repo file and the compositor reloads it
  # as soon as you save, with no rebuild.
  xdg.configFile."umbriel/config.toml".source = link "umbriel/config.toml";
  xdg.configFile."mango/config.conf".source = link "mango/config.conf";

  # Noctalia's settings stay in ~/.config/noctalia/ and are changed from its
  # settings GUI. To manage them from Nix later, see the Home Manager section
  # of https://docs.noctalia.dev/noctalia/getting-started/nixos/

  programs.bash = {
    enable = true;
    shellAliases = {
      rebuild = "sudo nixos-rebuild switch --flake ~/nixos-config";
      update = "nix flake update --flake ~/nixos-config && sudo nixos-rebuild switch --flake ~/nixos-config";
    };
  };
}
