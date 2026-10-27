# Work: Windows file shares (SMB) with Kerberos login, and the Cisco VPN.
#
# The domain and the shares are private, so they're not in this file. setup.sh
# writes them to private/work.nix (git-ignored), which looks like this:
#
#   {
#     realm = "AD.EXAMPLE.ORG";
#     shares = {
#       "projects" = "//fileserver.example.org/projects";
#     };
#   }
#
# Without that file, only the VPN part below is active.
{
  lib,
  pkgs,
  username,
  private,
  ...
}:
let
  realm = private.realm or null;
  shares = private.shares or { };
  upcall = lib.getExe' pkgs.cifs-utils "cifs.upcall";
in
{
  config = lib.mkMerge [
    {
      # ------------------------------------------------------------------- VPN
      # Cisco Secure Client speaks the AnyConnect protocol, which openconnect
      # implements. The plugin makes it a normal NetworkManager VPN connection.
      networking.networkmanager.plugins = [ pkgs.networkmanager-openconnect ];

      environment.systemPackages = with pkgs; [
        cifs-utils # mount.cifs, cifs.upcall
        keyutils # request-key, used by the kernel for the ticket lookup
        openconnect # VPN from the terminal, as a fallback
        networkmanagerapplet # nm-connection-editor, to set up the VPN once
      ];
    }

    (lib.mkIf (realm != null) {
      # -------------------------------------------------------------- Kerberos
      # `kinit` once a day gets a ticket, and the shares log in with it, so no
      # password is stored anywhere.
      security.krb5 = {
        enable = true;
        settings.libdefaults = {
          default_realm = realm;
          dns_lookup_kdc = true; # find the domain controllers through DNS
          dns_lookup_realm = false;
          rdns = false;
          # A plain file in /tmp, where the share helper (cifs.upcall) looks for it.
          default_ccache_name = "FILE:/tmp/krb5cc_%{uid}";
        };
      };
    })

    (lib.mkIf (shares != { }) {
      # ----------------------------------------------------------- File shares
      # When a Kerberos share connects, the kernel asks cifs.upcall for the
      # ticket. -t trusts DNS for the server name, which DFS shares need.
      environment.etc."request-key.conf".text = ''
        create cifs.spnego  * * ${upcall} -t %k
        create dns_resolver * * ${upcall} %k
      '';

      # Each share appears as ~/shares/<name>.
      fileSystems = lib.mapAttrs' (
        name: device:
        lib.nameValuePair "/home/${username}/shares/${name}" {
          inherit device;
          fsType = "cifs";
          options = [
            "sec=krb5" # log in with the Kerberos ticket
            "cruid=${username}" # ... from this user
            "uid=${username}"
            "gid=users"
            "file_mode=0600"
            "dir_mode=0700"
            # Connect on first access, disconnect when idle; never block booting.
            "noauto"
            "x-systemd.automount"
            "x-systemd.idle-timeout=10min"
            "x-systemd.mount-timeout=15s"
            "_netdev"
            "nofail"
            # Hide it from Nautilus's sidebar: clicking there tries to mount it
            # as your user, which fails. Open ~/shares/<name> instead.
            "x-gvfs-hide"
          ];
        }
      ) shares;
    })
  ];
}
