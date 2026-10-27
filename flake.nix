{
  description = "NixOS with Umbriel / Mango + Noctalia";

  inputs = {
    # Rolling release. Umbriel and Noctalia are only packaged in unstable.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Zen Browser is not in nixpkgs, so it comes from this community flake.
    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs =
    { nixpkgs, home-manager, ... }@inputs:
    let
      # Must be the user you created during the NixOS install (setup.sh sets it).
      username = "merdoes";

      # Where this repo lives, relative to your home folder (setup.sh sets it).
      # Home Manager links the compositor configs here, so don't move it.
      repoDir = "oergel-nixos-config";
      repo = "/home/${username}/${repoDir}";

      # Private settings for this machine (work domain, file shares), written
      # by setup.sh. private/ is git-ignored, so it never goes to GitHub. A
      # flake can only read untracked files with --impure; the rebuild and
      # update aliases and setup.sh pass it.
      privateFile = "${repo}/private/work.nix";
      private =
        if !(builtins ? currentSystem) then
          nixpkgs.lib.warn "private/work.nix not loaded: rebuild with --impure (the `rebuild` alias does)." { }
        else if builtins.pathExists privateFile then
          import privateFile
        else
          { };

      # Every folder in hosts/ is one machine, and the folder name is its
      # hostname. So `sudo nixos-rebuild switch --flake .` picks the right one.
      hosts = builtins.attrNames (
        nixpkgs.lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./hosts)
      );

      mkHost =
        name:
        nixpkgs.lib.nixosSystem {
          specialArgs = {
            inherit
              inputs
              username
              repo
              private
              ;
          };
          modules = [
            ./configuration.nix
            ./hosts/${name}
            { networking.hostName = name; }
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.backupFileExtension = "backup";
              home-manager.extraSpecialArgs = { inherit inputs username repo; };
              home-manager.users.${username} = import ./home.nix;
            }
          ];
        };
    in
    {
      nixosConfigurations = nixpkgs.lib.genAttrs hosts mkHost;
    };
}
