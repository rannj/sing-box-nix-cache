{
  lib,
  buildGoModule,
  buildPackages,
  fetchFromGitHub,
  gn,
  ninja,
  python3,
  stdenvNoCC,
  symlinkJoin,
}: let
  source = builtins.fromJSON (builtins.readFile ./source.json);
  llvmCcAndBintools = symlinkJoin {
    name = "llvm-cc-and-bintools";
    paths = [
      buildPackages.rustc.llvmPackages.llvm
      buildPackages.rustc.llvmPackages.stdenv.cc
    ];
  };
in
  stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "cronet-go";
    version = "0-unstable-${builtins.substring 0 12 source.cronetRev}";

    src = fetchFromGitHub {
      owner = "SagerNet";
      repo = "cronet-go";
      rev = source.cronetRev;
      fetchSubmodules = true;
      hash = source.cronetSrcHash;
    };

    patches = [
      ./patches/cronet-build-naive.patch
      ./patches/cronet-cflags.patch
    ];

    postPatch = ''
      substituteInPlace naiveproxy/src/.gn \
        --replace-fail "expand_directory_allowlist = build_dotfile_settings.expand_directory_allowlist" ""
      substituteInPlace naiveproxy/src/build/config/compiler/BUILD.gn \
        --replace-fail '[ "{{target_out_dir}}/{{label_name}}/{{source_name_part}}.dwo" ]' \
          $'[ "{{target_out_dir}}/{{label_name}}/{{source_name_part}}.dwo" ]\n    not_needed(c_additional_outputs)'
    '';

    nativeBuildInputs = [
      buildPackages.rustc.llvmPackages.bintools
      ninja
      python3
    ];

    buildPhase = ''
      runHook preBuild
      ${lib.getExe finalAttrs.passthru.build-naive} build
      ${lib.getExe finalAttrs.passthru.build-naive} package --local
      ${lib.getExe finalAttrs.passthru.build-naive} package
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -r lib include include_cgo.go "$out/"
      runHook postInstall
    '';

    passthru.build-naive = buildGoModule {
      pname = "cronet-go-build-naive";
      inherit (finalAttrs) version src;
      vendorHash = source.cronetVendorHash;
      patches = [./patches/cronet-build-naive.patch];
      postPatch = ''
        substituteInPlace cmd/build-naive/cmd_build.go \
          --replace-fail "@gn@" "${lib.getExe gn}" \
          --replace-fail "@clang_base_path@" "${llvmCcAndBintools}"
      '';
      subPackages = ["cmd/build-naive"];
      meta.mainProgram = "build-naive";
    };

    strictDeps = true;
    meta = {
      description = "Go bindings and matching static Chromium Cronet library for naiveproxy";
      homepage = "https://github.com/SagerNet/cronet-go";
      license = lib.licenses.gpl3Plus;
      platforms = ["x86_64-linux"];
    };
  })
