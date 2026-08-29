{
  description = "xcross Linux development environment";

  inputs = {
    nixpkgs.url = "github:r-ryantm/nixpkgs/376b94add7951eb8c87c6670e72ac4f35a1368d3";

    xcross-linux-x64 = {
      url = "https://github.com/arxdeus/xcross/releases/download/v1.3.2/xcross-linux-x64.tar.gz";
      flake = false;
    };

    xcross-linux-arm64 = {
      url = "https://github.com/arxdeus/xcross/releases/download/v1.3.2/xcross-linux-arm64.tar.gz";
      flake = false;
    };
  };

  outputs = inputs@{ nixpkgs, ... }:
    let
      version = "1.3.2";
      swiftVersion = "6.3.3";
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      releaseFor = system:
        if system == "x86_64-linux"
        then inputs.xcross-linux-x64
        else inputs.xcross-linux-arm64;
      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [
          (final: prev: {
            python313 = prev.python313.override {
              packageOverrides = pyFinal: pyPrev: {
                pyimg4 = pyPrev.pyimg4.overridePythonAttrs (old: {
                  pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "asn1" ];
                  doCheck = false;
                  meta = old.meta // { broken = false; };
                });
              };
            };
            python313Packages = final.python313.pkgs;
          })
        ];
      };
      outputsFor = system:
        let
          pkgs = pkgsFor system;
          swiftToolchainSource = {
            x86_64-linux = {
              url = "https://download.swift.org/swift-${swiftVersion}-release/ubuntu2404/swift-${swiftVersion}-RELEASE/swift-${swiftVersion}-RELEASE-ubuntu24.04.tar.gz";
              hash = "sha256-2oJypf3czWWxUp7Q5S4EUm4urdQjfVjWIg7+uXPGzRk=";
            };
            aarch64-linux = {
              url = "https://download.swift.org/swift-${swiftVersion}-release/ubuntu2404-aarch64/swift-${swiftVersion}-RELEASE/swift-${swiftVersion}-RELEASE-ubuntu24.04-aarch64.tar.gz";
              hash = "sha256-RxJjlUKWU/p2jTcGVYduwbaPapXHiE9eTxeXABQcm38=";
            };
          }.${system};
          swiftToolchain = pkgs.stdenv.mkDerivation {
            pname = "swift-toolchain";
            version = swiftVersion;
            src = pkgs.fetchurl { inherit (swiftToolchainSource) url hash; };
            nativeBuildInputs = [ pkgs.autoPatchelfHook ];
            buildInputs = with pkgs; [
              stdenv.cc.cc.lib
              zlib
              ncurses
              libxml2_13
              libedit
              curl
              libuuid
              python312
              sqlite
            ];
            dontConfigure = true;
            dontBuild = true;
            autoPatchelfIgnoreMissingDeps = [ "libedit.so.2" ];
            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              cp -r usr/* "$out/"
              runHook postInstall
            '';
          };
          swiftRuntimeLibraryPath = "${swiftToolchain}/lib/swift/linux";
          runtimeDeps = with pkgs; [
            flutter
            swiftToolchain
            python313
            python313Packages.pymobiledevice3
            usbmuxd
            libimobiledevice
            usbutils
            pkg-config
            gnupg
          ];
          xcross = pkgs.stdenvNoCC.mkDerivation {
            pname = "xcross";
            inherit version;
            src = releaseFor system;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            dontBuild = true;
            dontFixup = true;

            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin" "$out/lib/xcross" "$out/share/licenses/xcross"
              cp -r bin lib "$out/lib/xcross/"
              install -m 0644 ${./LICENSE} "$out/share/licenses/xcross/LICENSE"
              install -m 0644 ${./packages/apple_developer_kit/ADI_LICENSE} \
                "$out/share/licenses/xcross/provision-dart.txt"

              for executable in xcross xcrun; do
                makeWrapper "$out/lib/xcross/bin/$executable" "$out/bin/$executable" \
                  --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps} \
                  --prefix LD_LIBRARY_PATH : ${swiftRuntimeLibraryPath}
                cmp "$src/bin/$executable" "$out/lib/xcross/bin/$executable"
              done
              runHook postInstall
            '';

            meta = {
              description = "Build, run, and hot-reload Flutter iOS apps from Linux";
              homepage = "https://github.com/arxdeus/xcross";
              license = pkgs.lib.licenses.mit;
              mainProgram = "xcross";
              platforms = systems;
            };
          };
          userPackages = [ xcross ] ++ runtimeDeps;
          contributorPackages = userPackages ++ (with pkgs; [
            dart
            cmake
            ninja
            git
            unzip
            xz
          ]);
          flutterShellHook = ''
            export LD_LIBRARY_PATH=${swiftRuntimeLibraryPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
            export FLUTTER_ROOT="''${XDG_CACHE_HOME:-$HOME/.cache}/xcross/flutter-${pkgs.flutter.version}"
            if [ ! -x "$FLUTTER_ROOT/bin/flutter" ]; then
              rm -rf "$FLUTTER_ROOT"
              mkdir -p "$FLUTTER_ROOT"
              cp -rL ${pkgs.flutter.sdk or pkgs.flutter}/. "$FLUTTER_ROOT/"
              chmod -R u+w "$FLUTTER_ROOT"
            fi
          '';
          smokeCheck = pkgs.runCommand "xcross-smoke-check" {
            nativeBuildInputs = [ xcross ];
          } ''
            test -x ${xcross}/bin/xcross
            test -x ${xcross}/bin/xcrun
            test -d ${xcross}/lib/xcross/lib
            cmp ${releaseFor system}/bin/xcross ${xcross}/lib/xcross/bin/xcross
            cmp ${releaseFor system}/bin/xcrun ${xcross}/lib/xcross/bin/xcrun
            touch "$out"
          '';
        in {
          inherit pkgs xcross userPackages contributorPackages flutterShellHook smokeCheck;
        };
    in {
      packages = forAllSystems (system:
        let output = outputsFor system;
        in {
          inherit (output) xcross;
          default = output.xcross;
        });

      apps = forAllSystems (system:
        let output = outputsFor system;
        in {
          xcross = {
            type = "app";
            program = "${output.xcross}/bin/xcross";
          };
          default = {
            type = "app";
            program = "${output.xcross}/bin/xcross";
          };
        });

      devShells = forAllSystems (system:
        let output = outputsFor system;
        in {
          default = output.pkgs.mkShell {
            packages = output.userPackages;
            shellHook = output.flutterShellHook;
          };
          contributor = output.pkgs.mkShell {
            packages = output.contributorPackages;
            shellHook = output.flutterShellHook;
          };
        });

      checks = forAllSystems (system: {
        smoke = (outputsFor system).smokeCheck;
      });
    };
}
