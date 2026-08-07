{
  lib,
  buildGoModule,
  fetchFromGitHub,
  installShellFiles,
  coreutils,
}:
let
  source = builtins.fromJSON (builtins.readFile ./source.json);
in
buildGoModule (finalAttrs: {
  pname = "sing-box";
  inherit (source) version;

  src = fetchFromGitHub {
    owner = "SagerNet";
    repo = "sing-box";
    rev = source.rev;
    hash = source.srcHash;
  };

  vendorHash = source.vendorHash;

  tags = [
    "with_quic"
    "with_gvisor"
    "with_tailscale"
    "badlinkname"
    "tfogo_checklinkname0"
  ];

  subPackages = [
    "cmd/sing-box"
  ];

  env.CGO_ENABLED = 0;

  nativeBuildInputs = [installShellFiles];

  ldflags = [
    "-X=github.com/sagernet/sing-box/constant.Version=${finalAttrs.version}"
    "-X=internal/godebug.defaultGODEBUG=multipathtcp=0"
    "-checklinkname=0"
  ];

  postInstall = ''
    installShellCompletion release/completions/sing-box.{bash,fish,zsh}

    substituteInPlace release/config/sing-box{,@}.service \
      --replace-fail "/usr/bin/sing-box" "$out/bin/sing-box" \
      --replace-fail "/bin/kill" "${coreutils}/bin/kill"
    install -Dm444 -t "$out/lib/systemd/system/" release/config/sing-box{,@}.service

    install -Dm444 release/config/sing-box.rules "$out/share/polkit-1/rules.d/sing-box.rules"
    install -Dm444 release/config/sing-box-split-dns.xml "$out/share/dbus-1/system.d/sing-box-split-dns.conf"

    if [[ ! -x "$out/bin/sing-box" ]]; then
      echo "sing-box build did not install $out/bin/sing-box" >&2
      exit 1
    fi
  '';

  meta = {
    homepage = "https://sing-box.sagernet.org";
    changelog = "https://github.com/SagerNet/sing-box/blob/${source.rev}/docs/changelog.md";
    description = "Universal proxy platform";
    license = lib.licenses.gpl3Plus;
    mainProgram = "sing-box";
    platforms = [ "x86_64-linux" ];
  };
})
