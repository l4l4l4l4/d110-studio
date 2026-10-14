{
  description = "D110 Studio development environment";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca";
  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
    flutter = pkgs.flutter.override { extraPkgConfigPackages = [ pkgs.bluez ]; };
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = [ flutter.sdk pkgs.dart pkgs.bluez pkgs.git pkgs.gh ];
    };
  };
}
