{
  config,
  lib,
  pkgs,
  ...
}:

{
  # GRUB with efiInstallAsRemovable + an EF02 BIOS boot partition is the
  # known-working pattern on Hetzner. systemd-boot's NVRAM-only install
  # (and even its fallback path with canTouchEfiVariables=false) is
  # silently ignored by Hetzner UEFI. GRUB installs to both
  # /EFI/BOOT/BOOTX64.EFI (UEFI removable path) and the EF02 partition
  # (BIOS embed), so the firmware finds it either way.
  boot.loader = {
    grub = {
      enable = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
      zfsSupport = true;
      # disko auto-populates `devices` from disks with an EF02 partition.
    };
    efi.canTouchEfiVariables = false;
  };

  # Boot was hanging up to network-online.target timeout on Hetzner
  # hardware (per a known issue in josibake's other Hetzner config).
  systemd.network.wait-online.enable = false;
}
