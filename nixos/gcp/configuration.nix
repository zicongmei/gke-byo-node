{ modulesPath, ... }: {
  imports = [
    "${modulesPath}/virtualisation/google-compute-image.nix"
  ];

  # Basic configuration
  networking.hostName = "nixos-gcp";

  # NixOS version
  system.stateVersion = "23.11"; # Adjust as needed
}
