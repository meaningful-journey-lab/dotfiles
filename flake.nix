{
  description = "dotfiles";

  inputs = {
    # Use `github:NixOS/nixpkgs/nixpkgs-26.05-darwin` to use Nixpkgs 26.05.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    # Use `github:nix-darwin/nix-darwin/nix-darwin-26.05` to use Nixpkgs 26.05.
    nix-darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
  };

  outputs = inputs@{ self, nix-darwin, nix-homebrew, home-manager, nixpkgs }:
    let
      lib = nixpkgs.lib;

      # Primary identity for a personal macOS/WSL2 workstation.
      # bootstrap.sh offers to rewrite this if your workstation username differs.
      user = "dev";

      # Non-root users that only need the container profile - e.g. the
      # devcontainer base image's runtime user (CONTAINER_USER in the Dockerfile
      # of meaningful-journey-lab/agentic-devcontainer).
      # Listing them here lets a container select "<user>@container-<system>" by
      # its own `id -un`, so nothing has to sed-rewrite `user` above at runtime.
      containerUsers = [ "node" ];

      linuxSystems = [ "x86_64-linux" "aarch64-linux" ];

      # Standalone home-manager for Linux. nix-darwin is macOS-only, so on Linux
      # we apply just the user-level config (home.nix) instead. allowUnfree is
      # set here because it lives in configuration.nix, which Linux never loads.
      # `profile` selects between a full workstation and a devcontainer that
      # reuses the same shell/tools but no host SSH machinery.
      # The workstation records this for hm-update; README's Devcontainers
      # section describes revision following and its fallbacks.
      dotfilesRev = self.rev or self.dirtyRev or "unknown";

      mkLinuxHome = { system, user, profile ? "workstation" }:
        home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          extraSpecialArgs = { inherit user profile dotfilesRev; };
          modules = [ ./home.nix ];
        };

      # Workstation configs for the primary user, plus container configs for the
      # primary user and every container user. Keyed "<user>@<system>" and
      # "<user>@container-<system>" so rebuild.sh / post-create.sh (in
      # meaningful-journey-lab/agentic-devcontainer) can pick one from `id -un` +
      # `uname -m`.
      workstationConfigs = lib.listToAttrs (map (system: {
        name = "${user}@${system}";
        value = mkLinuxHome { inherit system user; };
      }) linuxSystems);
      containerConfigs = lib.listToAttrs (lib.concatMap (u:
        map (system: {
          name = "${u}@container-${system}";
          value = mkLinuxHome { inherit system; user = u; profile = "container"; };
        }) linuxSystems) (lib.unique ([ user ] ++ containerUsers)));
    in
    {
      darwinConfigurations."mac" = nix-darwin.lib.darwinSystem {
        specialArgs = { inherit user; };
        modules = [
          ./configuration.nix
          nix-homebrew.darwinModules.nix-homebrew
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            # macOS is always a workstation; the module system doesn't honor the
            # `profile ? ...` default in home.nix, so pass it explicitly here.
            home-manager.extraSpecialArgs = { inherit user; profile = "workstation"; };
            home-manager.users.${user} = import ./home.nix;
          }
        ];
      };

      # Workstation + container configs, keyed "<user>@[container-]<system>".
      # bootstrap.sh / rebuild.sh / post-create.sh (in
      # meaningful-journey-lab/agentic-devcontainer) select one by `id -un` + arch.
      homeConfigurations = workstationConfigs // containerConfigs;
    };
}
