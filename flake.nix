{
  description = "Neovim plugin for rendering various diagramming languages in norg buffers with integrations";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      overlays.default = final: prev: {
        mermaid-ascii = final.callPackage ./nix/mermaid-ascii.nix { };
        vimPlugins = prev.vimPlugins // {
          norg-diagram = final.callPackage ./nix/plugin.nix { };
        };
      };

      packages = forAll (pkgs: rec {
        mermaid-ascii = pkgs.callPackage ./nix/mermaid-ascii.nix { };
        norg-diagram = pkgs.callPackage ./nix/plugin.nix { };
        default = norg-diagram;
      });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [
            (pkgs.callPackage ./nix/mermaid-ascii.nix { })
            pkgs.d2
            pkgs.lua-language-server
            pkgs.stylua
          ];

          shellHook = ''
            export NORG_DIAGRAM_DEV="$PWD"
          '';
        };
      });

      formatter = forAll (pkgs: pkgs.nixfmt-tree);
    };
}
