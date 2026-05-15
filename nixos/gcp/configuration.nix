{ modulesPath, pkgs, ... }: {
  imports = [
    "${modulesPath}/virtualisation/google-compute-image.nix"
  ];

  # Basic configuration
  networking.hostName = "nixos-gcp";

  # Enable Python 3 and other useful tools
  environment.systemPackages = [ 
    pkgs.python3 
    pkgs.kubectl
    pkgs.git
  ];

  # Security: Allow members of 'wheel' to use sudo without a password.
  # This is helpful for automation.
  security.sudo.wheelNeedsPassword = false;

  # NixOS version
  system.stateVersion = "23.11";
}
