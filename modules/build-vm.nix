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

  inherit (config.icedos.system) buildVm;

  resParts = splitString "x" buildVm.resolution;
in
{
  virtualisation.vmVariant.virtualisation = {
    memorySize = buildVm.memory;
    cores = buildVm.cores;
    diskSize = buildVm.diskSize;

    resolution = {
      x = toInt (elemAt resParts 0);
      y = toInt (elemAt resParts 1);
    };

    sharedDirectories = listToAttrs (
      imap0 (i: d: {
        name = "shared${toString i}";
        value = { inherit (d) source target; };
      }) buildVm.sharedDirectories
    );

    forwardPorts = optionals buildVm.ssh.enable [
      {
        from = "host";
        host.port = buildVm.ssh.hostPort;
        guest.port = buildVm.ssh.vmPort;
      }
    ];
  };
}
