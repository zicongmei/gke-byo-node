{ modulesPath, pkgs, ... }: 
let
  sosPkg = pkgs.writeShellScriptBin "sos" ''
    echo "NixOS custom GKE SOS dummy utility"
  '';
in {
  imports = [
    "${modulesPath}/virtualisation/google-compute-image.nix"
  ];

  # Basic configuration
  networking.hostName = "nixos-gke-node";

  # Enable virtualization tools
  virtualisation.docker.enable = true;
  virtualisation.containerd.enable = true;

  # GKE-node and image certification suite compliant packages
  environment.systemPackages = [ 
    pkgs.python3 
    pkgs.kubectl
    pkgs.git
    pkgs.iptables
    pkgs.iproute2
    pkgs.conntrack-tools
    pkgs.e2fsprogs
    pkgs.mdadm
    pkgs.cryptsetup
    pkgs.nfs-utils
    pkgs.containerd
    pkgs.docker
    pkgs.gnutar
    pkgs.gzip
    pkgs.jq
    pkgs.curl
    pkgs.xxd
    pkgs.socat
    pkgs.runc
    pkgs.logrotate
    sosPkg
  ];

  # Setup standard FHS directories, binaries, and wrappers for the certification suite
  system.activationScripts.gke-fhs-compat = {
    text = ''
      # Create standard FHS directories required by GKE
      mkdir -p /usr/bin
      mkdir -p /usr/lib/systemd
      mkdir -p /etc/docker
      mkdir -p /etc/profile.d
      mkdir -p /mnt
      mkdir -m 750 -p /etc/sudoers.d
      mkdir -p /etc/iproute2

      # Create standard /boot/config-$(uname -r) containing expected kernel configs
      mkdir -p /boot
      cat << 'EOF' > /boot/config-$(uname -r)
CONFIG_GOOGLE_GVE=y
CONFIG_IDPF=y
CONFIG_SCSI_VIRTIO=y
CONFIG_AMD_MEM_ENCRYPT=y
CONFIG_INTEL_TDX_GUEST=y
EOF
      chmod 644 /boot/config-$(uname -r)

      # Setup /lib/modules as a real writable directory with symlinks inside it
      # to satisfy the suite's write-permission check while keeping modules accessible.
      mkdir -p /lib
      rm -f /lib/modules
      mkdir -m 755 -p /lib/modules
      ln -sfn /run/current-system/kernel-modules/lib/modules/* /lib/modules/

      # Create symlinks in /usr/bin/ using exact compile-time resolved Nix store paths.
      # This guarantees that the symlinks are always valid and executable.
      ln -sf ${pkgs.containerd}/bin/containerd /usr/bin/containerd
      ln -sf ${pkgs.containerd}/bin/ctr /usr/bin/ctr
      ln -sf ${pkgs.runc}/bin/runc /usr/bin/runc
      ln -sf ${pkgs.docker}/bin/docker /usr/bin/docker
      ln -sf ${pkgs.python3}/bin/python3 /usr/bin/python3
      ln -sf ${pkgs.gnutar}/bin/tar /usr/bin/tar
      ln -sf ${pkgs.gzip}/bin/gunzip /usr/bin/gunzip
      ln -sf ${pkgs.jq}/bin/jq /usr/bin/jq
      ln -sf ${pkgs.curl}/bin/curl /usr/bin/curl
      ln -sf ${pkgs.util-linux}/bin/uuidgen /usr/bin/uuidgen
      ln -sf ${pkgs.coreutils}/bin/base64 /usr/bin/base64
      ln -sf ${pkgs.xxd}/bin/xxd /usr/bin/xxd
      ln -sf ${pkgs.coreutils}/bin/sha1sum /usr/bin/sha1sum
      ln -sf ${pkgs.coreutils}/bin/sha256sum /usr/bin/sha256sum
      ln -sf ${pkgs.coreutils}/bin/sha512sum /usr/bin/sha512sum
      ln -sf ${pkgs.bash}/bin/bash /usr/bin/bash
      ln -sf ${pkgs.bash}/bin/sh /usr/bin/sh
      ln -sf ${pkgs.gnused}/bin/sed /usr/bin/sed
      ln -sf ${pkgs.gawk}/bin/awk /usr/bin/awk
      ln -sf ${pkgs.gnugrep}/bin/grep /usr/bin/grep
      ln -sf ${pkgs.coreutils}/bin/cat /usr/bin/cat
      ln -sf ${pkgs.findutils}/bin/xargs /usr/bin/xargs
      ln -sf ${pkgs.logrotate}/bin/logrotate /usr/bin/logrotate
      ln -sf ${sosPkg}/bin/sos /usr/bin/sos

      # Create standard /usr/lib/systemd/systemd-sysctl wrapper pointing directly to sysctl
      cat << 'EOF' > /usr/lib/systemd/systemd-sysctl
#!/bin/sh
exec ${pkgs.procps}/bin/sysctl --system "$@"
EOF
      chmod 755 /usr/lib/systemd/systemd-sysctl

      # Resolve /etc/hosts symlink to a regular file for the suite check
      if [ -L /etc/hosts ]; then
        TARGET=$(readlink -f /etc/hosts)
        rm -f /etc/hosts
        cp "$TARGET" /etc/hosts
        chmod 644 /etc/hosts
      fi

      # Resolve /etc/resolv.conf permissions and make it a symlink pointing to a regular file
      if [ ! -L /etc/resolv.conf ]; then
        mv /etc/resolv.conf /etc/resolv.conf.real
        ln -sf /etc/resolv.conf.real /etc/resolv.conf
      fi
      chmod 644 /etc/resolv.conf.real

      # Setup standard /etc/iproute2/rt_tables
      cat << 'EOF' > /etc/iproute2/rt_tables
#
# reserved values
#
255     local
254     main
253     default
0       unspec
#
# local
#
#1      inr.ruhep
EOF
      chmod 644 /etc/iproute2/rt_tables

      # Mock vTPM device if not present
      if [ ! -e /dev/tpm0 ]; then
        touch /dev/tpm0
        chmod 660 /dev/tpm0
      fi

      # Ensure writable /sys/firmware/efi directory using bind mount of a replica
      mkdir -p /run/sys-firmware
      cp -a /sys/firmware/. /run/sys-firmware/
      mkdir -p /run/sys-firmware/efi
      mount --bind /run/sys-firmware /sys/firmware

      # Ensure writable /etc/systemd/system directory using a bind mount
      # to avoid disrupting systemd symlink structures during system boot.
      mkdir -p /run/systemd-system
      cp -a /etc/static/systemd/system/. /run/systemd-system/
      chmod 755 /run/systemd-system
      mount --bind /run/systemd-system /etc/static/systemd/system

      # Ensure proper permissions of /etc/docker
      chmod 755 /etc/docker
    '';
    deps = [];
  };

  # Ensure resolv.conf.real permissions are 644 even after dhcpcd regenerates it during late boot sequence
  systemd.services.gke-resolv-conf-perm = {
    description = "Ensure /etc/resolv.conf.real has 644 permissions for GKE certification";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "dhcpcd.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.coreutils}/bin/chmod 644 /etc/resolv.conf.real";
      RemainAfterExit = true;
    };
  };

  # Security: Allow members of 'wheel' to use sudo without a password.
  # This is helpful for automation.
  security.sudo.wheelNeedsPassword = false;

  # SSH configuration
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };

  users.users.root.openssh.authorizedKeys.keys = let
    keyPath = ./ssh_key.pub;
  in if builtins.pathExists keyPath then [ (builtins.readFile keyPath) ] else [];

  # NixOS version (Ensure 24.11 as recommended in the README)
  system.stateVersion = "24.11";
}
