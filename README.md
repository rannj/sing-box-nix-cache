# sing-box Nix binary cache

This repository builds a custom `sing-box` package for `x86_64-linux`, uploads
its runtime closure to `rannj-nixos.cachix.org`, and exposes a NixOS module that
selects the exact cached derivation.

The package currently enables these build tags:

```text
with_quic
with_utls
with_ebpf
with_gvisor
with_tailscale
with_naive_outbound
with_clash_api
with_connection_history
badlinkname
tfogo_checklinkname0
```

This is a Linux glibc build with `CGO_ENABLED=1`. Naive outbound uses the
prebuilt `libcronet.a` from the exact `cronet-go/lib/linux_amd64` module pinned
by the selected reF1nd commit's `go.mod` and `go.sum`. The eBPF objects are
compiled with Nix-provided Clang; the backend uses direct BPF syscalls and does
not require libbpf. The musl, pure-Go, and static-musl paths are intentionally
not used.

## Automation

The `Update and build sing-box cache` workflow runs only when manually
dispatched and supports two selection modes:

- Leave the commit SHA empty to select the current head of `reF1nd/sing-box`
  branch `reF1nd-testing`.
- Enter a 7-to-40-character commit SHA to build that commit. It is resolved
  through the GitHub API, and its message is not checked.

The updater reads the version from `docs/changelog.md`. It recalculates the
source and complete Go module proxy hashes, then performs a real package build
before keeping any metadata changes. Cronet wrapper and prebuilt library
versions come directly from the selected commit's `go.mod` and `go.sum`. The
update is transactional: an API, hash, or build failure restores the original
`source.json`.

CI then smoke-tests `sing-box version`, synchronously pushes the verified
runtime closure to Cachix, and only afterward starts a separate minimal
write-permission job to commit `source.json`. The commit is rejected if the
default branch moved while the build was running.

Each manual run selects its source independently. Leaving the input empty after
a pinned run returns to the current `reF1nd-testing` head.

## Client usage

Add this repository as an independent flake input. Do not make its `nixpkgs`
input follow the client's `nixpkgs`: using this repository's locked Nixpkgs is
what preserves the exact derivation uploaded by CI.

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sing-box-cache.url = "github:rannj/sing-box-nix-cache";
  };

  outputs = {
    nixpkgs,
    sing-box-cache,
    ...
  }: {
    nixosConfigurations.HOSTNAME = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        sing-box-cache.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

The module:

- sets `services.sing-box.package` with `lib.mkDefault`, so an explicit client
  package definition can still override it;
- registers the Cachix substituter and trusted public key;
- rejects non-`x86_64-linux` hosts.

On the first rebuild, the module's Nix settings are not active in the currently
running daemon yet. Supply the cache explicitly once to avoid a local build:

```bash
sudo nixos-rebuild switch --flake .#HOSTNAME -L \
  --option extra-substituters https://rannj-nixos.cachix.org \
  --option extra-trusted-public-keys \
  'rannj-nixos.cachix.org-1:gpiOHG8mVVoIvgYtTf5cGj3pykTxCcGEM9ErtS5xkqI='
```

The client flake lock pins this input. Pull a newly published sing-box version
before rebuilding:

```bash
nix flake update sing-box-cache
sudo nixos-rebuild switch --flake .#HOSTNAME -L
```

## Local development

Enter the development shell and run all package, updater, ShellCheck, and
workflow checks:

```bash
nix develop
nix flake check -L --no-update-lock-file
```

Select the latest `reF1nd-testing` commit locally:

```bash
GITHUB_TOKEN="$(gh auth token)" ./scripts/update-sing-box.sh
```

Select any upstream commit without checking its message:

```bash
GITHUB_TOKEN="$(gh auth token)" \
  ./scripts/update-sing-box.sh --commit COMMIT_SHA
```

Use `--force` to recalculate both hashes even if the selected commit already
builds successfully. The script can be launched from any working directory and
requires the committed `flake.lock`.

Update the pinned Nixpkgs input separately from upstream sing-box updates:

```bash
nix flake update nixpkgs
nix flake check -L --no-update-lock-file
```

Keeping Nixpkgs updates separate makes cache derivations reproducible and
ensures changes to the build environment receive their own validation.

## Fork configuration

This repository is already configured for `rannj-nixos`. A fork should replace:

- `CACHE_NAME` in `.github/workflows/update-cache.yml`;
- `cacheUrl` and `cachePublicKey` in `flake.nix`;
- the repository URL and first-build commands in this README.

Add the Cachix write token as the repository Actions secret
`CACHIX_AUTH_TOKEN`. The cache is public, so treat every uploaded Nix store path
as public data and never place plaintext credentials in the package derivation.

GitHub Actions are pinned to full commit SHAs. Dependabot checks monthly for
new action releases so these security pins do not become permanently stale.
