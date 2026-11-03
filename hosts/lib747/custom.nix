# Your own settings for "lib747", only for this machine. setup.sh never
# touches this file (it only rewrites default.nix, which imports this one).
{ pkgs, username, ... }:
let
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
    exec ${pkgs.bash}/bin/bash ${../../scripts/publish-ip.sh} "$@"
  '';
in
{
  # ------------------------------------------------------------ Text console
  # The console (and tuigreet on it) is created once at boot, sized for the
  # laptop panel, before the dock's monitors show up; it never resizes. At
  # 2880x1800 the 1920x1200 external screens only showed a zoomed-in corner.
  # Running the panel at 1920x1200 for the console makes it fit the external
  # screens exactly; on the laptop it is upscaled (a bit soft, like scale 1.5).
  # Mango and Umbriel set their own resolutions, so this only affects the console.
  boot.kernelParams = [ "video=eDP-1:1920x1200" ];

  # -------------------------------------------------------- IP to polybox
  # The notebook's IP address changes now and then. This keeps the current
  # one in polybox (synced by the Nextcloud client), so you can find it from
  # home. It also runs while nobody is logged in (linger in
  # configuration.nix), but the sync only happens once someone logs in.
  home-manager.users.${username} = {
    home.packages = [ publish-ip ];
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
  };
}
