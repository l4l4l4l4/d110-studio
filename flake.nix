{
  description = "D110 Studio development environment";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca";
  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      config = {
        allowUnfree = true;
        android_sdk.accept_license = true;
      };
    };
    flutter = pkgs.flutter.override { extraPkgConfigPackages = [ pkgs.bluez ]; };
    basePackages = [ flutter.sdk pkgs.dart pkgs.bluez pkgs.git pkgs.gh ];
    androidSdk = (pkgs.androidenv.composeAndroidPackages {
      platformVersions = [ "36" ];
      buildToolsVersions = [ "35.0.0" "36.0.0" ];
      cmakeVersions = [ "3.22.1" ];
      includeCmake = true;
      cmdLineToolsVersion = "13.0";
      includeNDK = true;
      ndkVersions = [ "28.2.13676358" ];
      includeEmulator = false;
    }).androidsdk;
  in {
    devShells.${system} = {
      default = pkgs.mkShell {
        packages = basePackages;
      };
      android = pkgs.mkShell {
        packages = basePackages ++ [ pkgs.jdk17 androidSdk ];
        ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
        ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
        JAVA_HOME = "${pkgs.jdk17}";
      };
    };
  };
}
