{
  description = "NixOS with Umbriel + Noctalia";

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
      # Must be the user you created during the NixOS install.
      username = "merdoes";

      mkHost =
        hostModule:
        nixpkgs.lib.nixosSystem {
          specialArgs = { inherit inputs username; };
          modules = [
            ./configuration.nix
            hostModule
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.backupFileExtension = "backup";
              home-manager.extraSpecialArgs = { inherit inputs username; };
              home-manager.users.${username} = import ./home.nix;
            }
          ];
        };
    in
    {
      # The name matches networking.hostName, so
      # `sudo nixos-rebuild switch --flake ~/nixos-config` picks it automatically.
      nixosConfigurations = {
        nixos-vm = mkHost ./hosts/vm;
        # notebook = mkHost ./hosts/notebook;
      };
    };
}
