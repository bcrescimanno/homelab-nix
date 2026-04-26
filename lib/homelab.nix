# Returns a NixOS module that declares a static user+group for a service using
# DynamicUser=true. sops-nix resolves secret ownership at eval time and needs
# the group present in config.users — DynamicUser services don't expose theirs.
#
# Usage: imports = [ (import ../lib/homelab.nix "atticd") ];
name: {
  users.users.${name} = { isSystemUser = true; group = name; };
  users.groups.${name} = {};
}
