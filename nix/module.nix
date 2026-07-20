# Placeholder; real module in Phase 4. Must stay flake-agnostic.
{ config, lib, pkgs, ... }:
{
  options.services.asmltr.enable = lib.mkEnableOption "asmltr";
  config = { };
}
