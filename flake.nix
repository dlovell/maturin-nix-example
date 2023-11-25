# From https://github.com/litchipi/nix-build-templates/blob/6e4961dc56a9bbfa3acf316d81861f5bd1ea37ca/rust/maturin.nix
# See also https://discourse.nixos.org/t/pyo3-maturin-python-native-dependency-management-vs-nixpkgs/21739/2
{
  # Build Pyo3 package
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.05";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = { self, nixpkgs, flake-utils, crane, rust-overlay, ... }:
    flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
      };

      pythonVersion = "310";
      rustVersion = "1.70.0";
      cargoToml = ./Cargo.toml;
      src = ./.;

      python = pkgs.${"python" + pythonVersion};
      wheelTail = "cp${pythonVersion}-cp${pythonVersion}-manylinux_2_34_x86_64";
      wheelName = "${commonArgs.pname}-${commonArgs.version}-${wheelTail}.whl";
      craneLib = (crane.mkLib pkgs).overrideToolchain pkgs.rust-bin.stable.${rustVersion}.default;

      commonArgs = {
        pname = (builtins.fromTOML (builtins.readFile cargoToml)).lib.name;
        inherit (craneLib.crateNameFromCargoToml { inherit cargoToml; }) version;
      };
      crateWheel = (craneLib.buildPackage (commonArgs // {
        src = craneLib.cleanCargoSource (craneLib.path src);
        nativeBuildInputs = [ python ];
      })).overrideAttrs (old: {
        nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.maturin ];
        buildPhase = old.buildPhase + ''
          maturin build --offline --target-dir target
        '';
        installPhase = old.installPhase + ''
          cp target/wheels/${wheelName} $out/
        '';
      });
      maturin-init-script = pkgs.writeShellScriptBin "maturin-init" ''
        set -xeu
        ${pkgs.maturin}/bin/maturin init "''${@}"
        ${pkgs.cargo}/bin/cargo update
      '';
      maturin-init-pyo3-script = pkgs.writeShellScriptBin "maturin-init-pyo3" ''
        set -xeu
        ${pkgs.maturin}/bin/maturin init --bindings pyo3 "''${@}"
        ${pkgs.cargo}/bin/cargo update
      '';
    in rec {
      packages = {
        default = crateWheel;
        pythonEnv = python.withPackages (ps: [
          (lib.pythonPackage ps)
          ps.ipython
        ]);
      };
      lib = {
        pythonPackage = ps:
          ps.buildPythonPackage (commonArgs // rec {
            format = "wheel";
            src = "${crateWheel}/${wheelName}";
            doCheck = false;
            pythonImportsCheck = [ commonArgs.pname ];
          });
        };
      devShells = rec {
        rust = pkgs.mkShell {
          name = "rust-env";
          inherit src;
          nativeBuildInputs = with pkgs; [
            pkg-config
            rust-analyzer
            maturin
            maturin-init-script
            maturin-init-pyo3-script
          ];
        };
        python = pkgs.mkShell {
          name = "python-env";
          inherit src;
          nativeBuildInputs = [ packages.pythonEnv ];
        };
        default = python;
      };
      apps = rec {
        ipython = flake-utils.lib.mkApp {
          drv = packages.pythonEnv;
          name = "ipython";
        };
        maturin-init = flake-utils.lib.mkApp {
          drv = maturin-init-script;
        };
        maturin-init-pyo3 = flake-utils.lib.mkApp {
          drv = maturin-init-pyo3-script;
        };
        default = ipython;
      };
      templates.default = ./flake.nix;
      defaultTemplate = self.templates.default;
    });
}
