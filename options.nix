{
  icedosLib,
  lib,
  ...
}:

let
  inherit (lib) fileContents;

  inherit (icedosLib)
    mkBoolOption
    mkLinesOption
    mkNumberOption
    mkStrListOption
    mkStrOption
    mkSubmoduleAttrsOption
    mkSubmoduleListOption
    ;
in
{
  options = {
    icedos = {
      applications = {
        android-tools = mkBoolOption { };
        defaultBrowser = mkStrOption { };
        extraPackages = mkStrListOption { };
        gamescope = mkBoolOption { };
        insecurePackages = mkStrListOption { };

        kitty = {
          enable = mkBoolOption { };
          fontSize = mkNumberOption { };
          hideDecorations = mkBoolOption { };
        };

        mangohud = {
          enable = mkBoolOption { };
          maxFpsLimit = mkNumberOption { };
        };

        mission-center = mkBoolOption { };
        nautilus = mkBoolOption { };

        network-manager = {
          enable = mkBoolOption { };
          applet = mkBoolOption { };
        };

        proton-launch = mkBoolOption { };

        signal = {
          enable = mkBoolOption { };
          package = mkStrOption { };
        };

        steam = {
          enable = mkBoolOption { };
          beta = mkBoolOption { };
          downloadsWorkaround = mkBoolOption { };

          session = {
            enable = mkBoolOption { };

            autoStart = {
              enable = mkBoolOption { };
              desktopSession = mkStrOption { };
            };

            user = mkStrOption { };
          };
        };

        sunshine = {
          enable = mkBoolOption { };
          autostart = mkBoolOption { };
        };

        tailscale = {
          enable = mkBoolOption { };
          enableTrayscale = mkBoolOption { };
        };
      };

      bootloader = {
        grub = {
          enable = mkBoolOption { };
          device = mkStrOption { };
        };

        systemd-boot = {
          enable = mkBoolOption { };
          mountPoint = mkStrOption { };
        };
      };

      desktop = {
        accentColor = mkStrOption { };

        autologin = {
          enable = mkBoolOption { };
          user = mkStrOption { };
        };

        gdm = {
          enable = mkBoolOption { };
          autoSuspend = mkBoolOption { };
        };

        gnome = {
          enable = mkBoolOption { };
          accentColor = mkStrOption { };

          extensions = {
            arcmenu = mkBoolOption { };
            dashToPanel = mkBoolOption { };
          };

          clock = {
            date = mkBoolOption { };
            weekday = mkBoolOption { };
          };

          hotCorners = mkBoolOption { };
          powerButtonAction = mkStrOption { };
          titlebarLayout = mkStrOption { };

          workspaces = {
            dynamicWorkspaces = mkBoolOption { };
            maxWorkspaces = mkNumberOption { };
          };
        };

        hyprland = {
          enable = mkBoolOption { };

          plugins = {
            cs2fix = {
              enable = mkBoolOption { };
              width = mkNumberOption { };
              height = mkNumberOption { };
            };

            hyprspace = mkBoolOption { };

            hyproled = {
              enable = mkBoolOption { };
              startWidth = mkNumberOption { };
              startHeight = mkNumberOption { };
              endWidth = mkNumberOption { };
              endHeight = mkNumberOption { };
            };
          };

          settings = {
            animations = {
              enable = mkBoolOption { };
              bezierCurve = mkStrOption { };
              speed = mkNumberOption { };
            };

            followMouse = mkNumberOption { };
            secondsToLowerBrightness = mkNumberOption { };
            startupScript = mkStrOption { };
            windowRules = mkStrListOption { };
          };
        };
      };

      hardware = {
        bluetooth = mkBoolOption { };

        cpus = {
          ryzen = {
            enable = mkBoolOption { };

            undervolt = {
              enable = mkBoolOption { };
              value = mkStrOption { };
            };

            zenergy = mkBoolOption { };
          };

          intel = mkBoolOption { };
        };

        devices = {
          laptop = mkBoolOption { };
          server = mkBoolOption { };
          steamdeck = mkBoolOption { };
        };

        drivers = {
          rtl8821ce = mkBoolOption { };
          xpadneo = mkBoolOption { };
        };

        graphics = {
          enable = mkBoolOption { };

          radeon = {
            enable = mkBoolOption { };
            rocm = mkBoolOption { };
          };

          mesa.unstable = mkBoolOption { };

          nvidia = {
            enable = mkBoolOption { };
            beta = mkBoolOption { };
            cuda = mkBoolOption { };
            openDrivers = mkBoolOption { };

            powerLimit = {
              enable = mkBoolOption { };
              value = mkNumberOption { };
            };
          };
        };

        monitors = mkSubmoduleListOption { } {
          name = mkStrOption { };
          disable = mkBoolOption { };
          resolution = mkStrOption { };
          refreshRate = mkNumberOption { };
          position = mkStrOption { };
          scaling = mkNumberOption { };
          rotation = mkNumberOption { };
          tenBit = mkBoolOption { };
        };

        networking = {
          hostname = mkStrOption { };
          hosts = mkLinesOption { };
          ipv6 = mkBoolOption { };
          vpnExcludeIp = mkStrOption { };

          wg-quick = {
            enable = mkBoolOption { };
            interfaces = mkStrListOption { };
          };
        };

        mounts = mkSubmoduleListOption { } {
          path = mkStrOption { };
          device = mkStrOption { };
          fsType = mkStrOption { };
          flags = mkStrListOption { };
        };
      };

      system = {
        channels = mkStrListOption { };
        forceFirstBuild = mkBoolOption { };

        generations = {
          bootEntries = mkNumberOption { };

          garbageCollect = {
            automatic = mkBoolOption { };
            days = mkNumberOption { };
            generations = mkNumberOption { };
            interval = mkStrOption { };
          };
        };

        home = mkStrOption { };
        kernel = mkStrOption { };
        swappiness = mkNumberOption { };

        users = mkSubmoduleAttrsOption { } {
          description = mkStrOption { };
          type = mkStrOption { };

          applications = {
            git = {
              username = mkStrOption { };
              email = mkStrOption { };
            };
          };

          desktop = {
            gnome = {
              pinnedApps = {
                arcmenu = {
                  enable = mkBoolOption { };
                  list = mkStrListOption { };
                };

                shell = {
                  enable = mkBoolOption { };
                  list = mkStrListOption { };
                };
              };

              startupScript = mkStrOption { };
            };

            idle = {
              sd-inhibitor = {
                enable = mkBoolOption { };

                watchers = {
                  cpu = {
                    enable = mkBoolOption { };
                    threshold = mkNumberOption { };
                  };

                  disk = {
                    enable = mkBoolOption { };
                    threshold = mkNumberOption { };
                  };

                  network = {
                    enable = mkBoolOption { };
                    threshold = mkNumberOption { };
                  };

                  pipewire = {
                    enable = mkBoolOption { };
                    inputsToIgnore = mkStrListOption { };
                    outputsToIgnore = mkStrListOption { };
                  };
                };
              };

              lock = {
                enable = mkBoolOption { };
                seconds = mkNumberOption { };
              };

              disableMonitors = {
                enable = mkBoolOption { };
                seconds = mkNumberOption { };
              };

              suspend = {
                enable = mkBoolOption { };
                seconds = mkNumberOption { };
              };
            };
          };
        };

        virtualisation = {
          containerManager = {
            enable = mkBoolOption { };
            usePodman = mkBoolOption { };
            requireSudoForDocker = mkBoolOption { };
          };

          virtManager = mkBoolOption { };
          waydroid = mkBoolOption { };
        };

        version = mkStrOption { };
      };

      repositories = mkSubmoduleListOption { } {
        name = mkStrOption { };
        url = mkStrOption { };
        modules = mkStrListOption { };
      };
    };
  };

  config = fromTOML (fileContents ./config.toml);
}
