{ ... }:
{
  imports = [
    ../../modules/nixos/base.nix
    ../../modules/nixos/networking.nix
    ../../modules/nixos/security.nix
    ../../modules/nixos/desktop.nix
    ../../modules/nixos/users.nix
    ../../modules/nixos/virtualization.nix
  ];
}
