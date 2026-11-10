# Writing tools, both optional and off unless a machine turns them on.
# setup.sh asks about them and writes the answers to hosts/<name>/default.nix:
#
#   features.ollama.enable = true;        # local AI proofreading, Super+C (window)
#                                         # and Super+Ctrl+C (instant)
#   features.languagetool.enable = true;  # LanguageTool, Super+Alt+C
#
# The hotkeys are in mango/settings.conf and umbriel/config.toml for every
# machine; where a feature is off, its key just does nothing.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.features;

  # A small GTK4/libadwaita app from one Python script in scripts/.
  gtkApp =
    name: script: tools:
    pkgs.stdenv.mkDerivation {
      inherit name;
      dontUnpack = true;
      nativeBuildInputs = with pkgs; [
        wrapGAppsHook4
        gobject-introspection
      ];
      buildInputs = with pkgs; [
        gtk4
        libadwaita
      ];
      installPhase = ''
        mkdir -p $out/bin
        { echo "#!${pkgs.python3.withPackages (ps: [ ps.pygobject3 ])}/bin/python3 -I"
          tail -n +2 ${script}
        } > $out/bin/${name}
        chmod +x $out/bin/${name}
      '';
      preFixup = ''
        gappsWrapperArgs+=(--prefix PATH : ${lib.makeBinPath tools})
      '';
    };

  # Select text, press Super+C: a window with a chat on the left, where the
  # local AI proofreads the text and takes further instructions, and the
  # changes on the right, to accept or keep one by one (scripts/proofread.py).
  # "Replace selection" pastes the result with ydotool, not wtype: GTK3 apps
  # such as Evolution ignore wtype's Ctrl+V because of its private keymap.
  proofread = gtkApp "proofread" ./scripts/proofread.py (
    with pkgs;
    [
      wl-clipboard
      libnotify
      ydotool
    ]
  );

  # Super+Ctrl+C: the same without a window. Corrects the selected text and
  # pastes it over the selection right away (scripts/proofread-quick.sh).
  proofread-quick = pkgs.writeShellApplication {
    name = "proofread-quick";
    runtimeInputs = with pkgs; [
      wl-clipboard
      ydotool
      jq
      curl
      libnotify
    ];
    text = builtins.readFile ./scripts/proofread-quick.sh;
  };

  # Select text, press Super+Alt+C: a window lists what LanguageTool finds,
  # lets you accept a suggestion or keep the text for each problem, and
  # copies the result (scripts/languagetool-check.py).
  languagetool-check = gtkApp "languagetool-check" ./scripts/languagetool-check.py (
    with pkgs;
    [
      wl-clipboard
      libnotify
      ydotool
    ]
  );

  # LanguageTool's cloud services. The browser add-ons send usage statistics
  # there, and text for features like synonyms, rephrasing and translation.
  # Grammar checking itself goes to the local server; blocking these names
  # makes sure nothing else does. languagetool.org itself (the website, the
  # add-on's config and version ping) stays reachable.
  languagetoolCloud = [
    "analytics.languagetoolplus.com"
    "api.languagetoolplus.com"
    "languagetoolplus.com"
    "rewriting.languagetoolplus.com"
    "api.languagetool.org"
    "api-fallback.languagetool.org"
    "synonyms.languagetool.org"
    "prod-translator.languagetool.org"
    "qb-grammar-en.languagetool.org"
    "cerberus.languagetool.org"
  ];
in
{
  options.features = {
    ollama.enable = lib.mkEnableOption ''
      Ollama with the Gemma 3 models (local AI, also the backend for ThunderAI
      in Thunderbird), the `proofread` window (Super+C) and `proofread-quick`
      (Super+Ctrl+C). Downloads about
      11 GB of models and wants 16 GB of RAM or more'';
    languagetool.enable = lib.mkEnableOption ''
      the LanguageTool server (about 1 GB of RAM), the `languagetool-check`
      hotkey (Super+Alt+C), and LanguageTool in LibreOffice, Zen and
      Thunderbird (the browser add-ons are set up in configuration.nix)'';
  };

  config = lib.mkMerge [
    # ------------------------------------------------------- both: pasting
    (lib.mkIf (cfg.ollama.enable || cfg.languagetool.enable) {
      # Virtual keyboard at kernel level (uinput), so simulated keys look
      # exactly like the real keyboard to every app. "Replace selection" in
      # both windows and `proofread-quick` use it to press Ctrl+V. Only
      # members of the ydotool group can use it.
      programs.ydotool.enable = true;
      users.users.${username}.extraGroups = [ "ydotool" ];
    })

    # ---------------------------------------------------------------- Ollama
    (lib.mkIf cfg.ollama.enable {
      # Local LLMs for the `proofread` hotkey and for AI add-ons like ThunderAI
      # in Thunderbird (pointed at http://localhost:11434). The Vulkan build
      # uses the Radeon 860M; ROCm doesn't properly support its chip
      # (gfx1152). Without a usable GPU it runs on the CPU, much slower.
      # Check that the GPU was picked up with:
      #   journalctl -u ollama | grep -iE 'vulkan|igpu'
      services.ollama = {
        enable = true;
        package = pkgs.ollama-vulkan;
        # Downloaded in the background after a rebuild (ollama-model-loader service).
        loadModels = [
          "gemma3:12b" # good German, ~8 GB; used by `proofread`
          "gemma3:4b" # faster, for quick checks
        ];
        environmentVariables = {
          # Thunderbird add-ons call Ollama from a moz-extension:// origin.
          OLLAMA_ORIGINS = "moz-extension://*";
          # Ollama skips integrated GPUs by default and would run on the CPU only.
          OLLAMA_IGPU_ENABLE = "1";
        };
      };

      environment.systemPackages = [
        proofread
        proofread-quick
      ];
    })

    # ---------------------------------------------------------- LanguageTool
    (lib.mkIf cfg.languagetool.enable {
      # Rule-based grammar and spell checking, very good for German. Runs at
      # http://localhost:8081 (only reachable from this machine). Starts at
      # boot; stop it until the next boot with `sudo systemctl stop languagetool`.
      services.languagetool = {
        enable = true;
        # The browser add-ons call it from their own moz-extension:// origin.
        allowOrigin = "*";
        # Without a cap, Java may grow up to a quarter of the RAM (seen: 1.7 GB
        # and rising). With 768 MB the service stays at about 1 GB in total
        # and checks just as fast; 512 MB made it several times slower.
        jvmOptions = [ "-Xmx768m" ];
      };
      # Datenschutz: the server may talk to this machine only, so no text can
      # leave through it, whatever it might try.
      systemd.services.languagetool.serviceConfig = {
        IPAddressDeny = "any";
        IPAddressAllow = "localhost";
      };
      # ...and the add-ons can't reach LanguageTool's cloud (see above).
      networking.hosts = {
        "0.0.0.0" = languagetoolCloud;
        "::" = languagetoolCloud;
      };

      environment.systemPackages = [ languagetool-check ];

      # LibreOffice's built-in LanguageTool checker uses the local server. Its
      # settings file is also written by LibreOffice itself, so the script
      # only updates two entries.
      home-manager.users.${username} =
        { lib, ... }:
        {
          home.activation.libreofficeLanguagetool = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
            run ${pkgs.python3}/bin/python3 -I ${./scripts/libreoffice-languagetool.py} http://localhost:8081/v2
          '';
        };
    })
  ];
}
