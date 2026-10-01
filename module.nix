{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.flclashx;
  installer = pkgs.writeShellApplication {
    name = "install-flclashx";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./install.sh;
  };
in
{
  options.programs.flclashx = {
    enable = lib.mkEnableOption "FlClashX with TUN support";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "Prepared FlClashX binary bundle to install in /opt.";
    };
    autostart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install a system-wide XDG autostart entry.";
    };
    tunInterface = lib.mkOption {
      type = lib.types.str;
      default = "FlClashX";
      description = "TUN interface to trust in the NixOS firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Keep the bundle and its library closure rooted in the system generation.
    environment.systemPackages = [ cfg.package ];

    system.build.flclashxInstaller = installer;
    systemd.services.flclashx-install = {
      description = "Prepare the FlClashX bundle and setuid core in /opt";
      stopIfChanged = true;
      wantedBy = [ "multi-user.target" ];
      before = [
        "display-manager.service"
        "graphical.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${installer}/bin/install-flclashx ${cfg.package} /opt";
        ExecStop = "${installer}/bin/install-flclashx --remove /opt";
        UMask = "0022";
      };
    };

    environment.etc = lib.mkIf cfg.autostart {
      "xdg/autostart/FlClashX.desktop".source = "${cfg.package}/share/applications/flclashx.desktop";
    };

    networking.firewall.trustedInterfaces = [ cfg.tunInterface ];
  };
}
