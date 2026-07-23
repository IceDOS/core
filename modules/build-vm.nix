{ config, lib, ... }:

let
  inherit (lib)
    elemAt
    imap0
    listToAttrs
    optionals
    splitString
    toInt
    ;

  inherit (config.icedos.system) build-vm;

  resParts = splitString "x" build-vm.resolution;
in
{
  virtualisation.vmVariant.virtualisation = {
    memorySize = build-vm.memory;
    cores = build-vm.cores;
    diskSize = build-vm.diskSize;

    resolution = {
      x = toInt (elemAt resParts 0);
      y = toInt (elemAt resParts 1);
    };

    sharedDirectories = listToAttrs (
      imap0 (i: d: {
        name = "shared${toString i}";
        value = { inherit (d) source target; };
      }) build-vm.sharedDirectories
    );

    forwardPorts = optionals build-vm.ssh.enable [
      {
        from = "host";
        host.port = build-vm.ssh.hostPort;
        guest.port = build-vm.ssh.vmPort;
      }
    ];
  };
}
