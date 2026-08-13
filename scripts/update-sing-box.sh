#!/usr/bin/env bash
set -Eeuo pipefail

readonly upstream_repo="${UPSTREAM_REPO:-reF1nd/sing-box}"
readonly upstream_branch="${UPSTREAM_BRANCH:-reF1nd-testing}"
readonly api_base_url="https://api.github.com"
readonly fake_hash="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly metadata_file="${repo_root}/source.json"

requested_rev=""
force_refresh=false
work_dir=""
metadata_backup=""
metadata_temp=""
metadata_backup_ready=false
transaction_complete=false

usage() {
  cat <<'EOF'
Usage: scripts/update-sing-box.sh [--commit SHA] [--force]
       scripts/update-sing-box.sh [SHA]

Without a SHA, select the current head commit of the upstream reF1nd-testing
branch. With a SHA, use that commit without checking its message. --force
recalculates all fixed-output hashes even when the selected commit already
builds successfully.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --commit)
        (($# >= 2)) || die "--commit requires a SHA."
        [[ -z "${requested_rev}" ]] || die "A commit SHA was provided more than once."
        requested_rev="$2"
        shift 2
        ;;
      --force)
        force_refresh=true
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        [[ -z "${requested_rev}" ]] || die "Unexpected extra argument: $1"
        requested_rev="$1"
        shift
        ;;
    esac
  done
}

require_commands() {
  local command_name

  for command_name in curl jq nix sed awk sort tee mktemp; do
    command -v "${command_name}" >/dev/null 2>&1 ||
      die "Required command not found: ${command_name}"
  done
}

is_commit_sha() {
  [[ "$1" =~ ^[0-9A-Fa-f]{7,40}$ ]]
}

is_full_commit_sha() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

github_get() {
  local url="$1"
  local -a headers=(
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  curl \
    --fail-with-body \
    --silent \
    --show-error \
    --location \
    --connect-timeout 15 \
    --max-time 120 \
    --retry 4 \
    --retry-all-errors \
    --retry-delay 2 \
    "${headers[@]}" \
    "${url}"
}

resolve_commit() {
  local requested="$1"
  local response rev

  is_commit_sha "${requested}" ||
    die "Manual commit SHA must contain 7 to 40 hexadecimal characters."

  response="$(github_get "${api_base_url}/repos/${upstream_repo}/commits/${requested}")"
  rev="$(jq -er '.sha | select(type == "string")' <<<"${response}")" ||
    die "GitHub returned invalid commit metadata for ${requested}."
  is_full_commit_sha "${rev}" ||
    die "GitHub did not resolve ${requested} to a full commit SHA."

  printf '%s\n' "${rev}"
}

resolve_branch_head() {
  local response rev

  response="$(github_get "${api_base_url}/repos/${upstream_repo}/commits/${upstream_branch}")"
  rev="$(jq -er '.sha | select(type == "string")' <<<"${response}")" ||
    die "GitHub returned invalid branch metadata for ${upstream_branch}."
  is_full_commit_sha "${rev}" ||
    die "GitHub did not resolve ${upstream_branch} to a full commit SHA."
  printf '%s\n' "${rev}"
}

fetch_changelog() {
  local rev="$1"

  curl \
    --fail-with-body \
    --silent \
    --show-error \
    --location \
    --connect-timeout 15 \
    --max-time 120 \
    --retry 4 \
    --retry-all-errors \
    --retry-delay 2 \
    "https://raw.githubusercontent.com/${upstream_repo}/${rev}/docs/changelog.md"
}

extract_version() {
  sed -nE '
    s/^#### ([0-9][0-9A-Za-z.+-]*)[[:space:]]*$/\1/
    t found
    b
    :found
    p
    q
  '
}

validate_metadata() {
  jq -e '
    type == "object"
    and (.version | type == "string" and length > 0)
    and (.rev | type == "string" and test("^[0-9a-f]{40}$"))
    and (.srcHash | type == "string" and startswith("sha256-"))
    and (.vendorHash | type == "string" and startswith("sha256-"))
  ' "${metadata_file}" >/dev/null ||
    die "${metadata_file} does not match the expected schema."
}

nix_build() {
  local target="${1:-.#sing-box}"
  nix build \
    --no-link \
    --print-build-logs \
    --no-update-lock-file \
    "${target}"
}

extract_fixed_output_hash() {
  local expected_hash="$1"
  local log_file="$2"
  local -a candidates=()

  mapfile -t candidates < <(
    awk -v expected="${expected_hash}" '
      $1 == "specified:" {
        specified = $2
        next
      }
      $1 == "got:" {
        if (specified == expected) {
          print $2
        }
        specified = ""
      }
    ' "${log_file}" | sort -u
  )

  ((${#candidates[@]} == 1)) || return 1
  [[ "${candidates[0]}" =~ ^sha256-[A-Za-z0-9+/=]+$ ]] || return 1
  printf '%s\n' "${candidates[0]}"
}

extract_expected_hash() {
  local label="$1"
  local target="${2:-.#sing-box}"
  local log_file="${work_dir}/${label}.log"
  local status got_hash

  if nix_build "${target}" 2>&1 | tee "${log_file}" >&2; then
    status=0
  else
    status=$?
  fi

  if ((status == 0)); then
    echo "Build unexpectedly succeeded while ${label} used the fake hash." >&2
    return 1
  fi

  got_hash="$(extract_fixed_output_hash "${fake_hash}" "${log_file}")" || {
    echo "The ${label} build failed without one unambiguous fake-hash mismatch." >&2
    return "${status}"
  }

  printf '%s\n' "${got_hash}"
}

write_metadata() {
  local filter="$1"
  shift

  metadata_temp="$(mktemp "${metadata_file}.tmp.XXXXXX")"
  if ! jq "$@" "${filter}" "${metadata_file}" >"${metadata_temp}"; then
    return 1
  fi
  chmod --reference="${metadata_file}" "${metadata_temp}"
  mv -- "${metadata_temp}" "${metadata_file}"
  metadata_temp=""
}

cleanup() {
  local status=$?
  trap - EXIT

  if [[ "${metadata_backup_ready}" == true && "${transaction_complete}" != true ]]; then
    if mv -f -- "${metadata_backup}" "${metadata_file}"; then
      metadata_backup_ready=false
      echo "Restored ${metadata_file} after the unsuccessful update." >&2
    else
      echo "Failed to restore ${metadata_file} from ${metadata_backup}." >&2
    fi
  fi

  [[ -z "${metadata_temp}" ]] || rm -f -- "${metadata_temp}"
  [[ "${metadata_backup_ready}" != true ]] || rm -f -- "${metadata_backup}"
  [[ -z "${work_dir}" ]] || rm -rf -- "${work_dir}"
  exit "${status}"
}

begin_transaction() {
  work_dir="$(mktemp -d)"
  trap cleanup EXIT
  metadata_backup="$(mktemp "${metadata_file}.backup.XXXXXX")"
  if ! cp -- "${metadata_file}" "${metadata_backup}"; then
    rm -f -- "${metadata_backup}"
    metadata_backup=""
    return 1
  fi
  chmod --reference="${metadata_file}" "${metadata_backup}"
  metadata_backup_ready=true
}

main() {
  local rev changelog version current_version current_rev source_hash vendor_hash

  parse_args "$@"
  require_commands
  cd -- "${repo_root}"
  [[ -f "flake.lock" ]] || die "flake.lock is required for reproducible builds."
  validate_metadata

  if [[ -n "${requested_rev}" ]]; then
    rev="$(resolve_commit "${requested_rev}")"
    echo "Using manually selected commit ${rev}; commit message is not checked."
  else
    rev="$(resolve_branch_head)"
    echo "Using branch head ${rev} from ${upstream_branch}."
  fi

  changelog="$(fetch_changelog "${rev}")"
  version="$(extract_version <<<"${changelog}")"
  [[ -n "${version}" ]] ||
    die "Could not extract the version from docs/changelog.md at ${rev}."
  current_version="$(jq -r '.version' "${metadata_file}")"
  current_rev="$(jq -r '.rev' "${metadata_file}")"

  if [[ "${current_rev}" == "${rev}" && "${current_version}" == "${version}" && "${force_refresh}" != true ]]; then
    echo "Already tracking sing-box ${version} (${rev}); validating existing hashes."
    if nix_build; then
      echo "Existing metadata builds successfully."
      return 0
    fi
    echo "Existing metadata failed to build; recalculating fixed-output hashes." >&2
  else
    echo "Updating sing-box ${current_version} -> ${version}"
    echo "Upstream commit: ${rev}"
  fi

  begin_transaction
  # These are jq variables, not shell expansions.
  # shellcheck disable=SC2016
  write_metadata \
    '.version = $version | .rev = $rev | .srcHash = $hash | .vendorHash = $hash' \
    --arg version "${version}" \
    --arg rev "${rev}" \
    --arg hash "${fake_hash}"

  source_hash="$(extract_expected_hash "source")"
  # shellcheck disable=SC2016
  write_metadata '.srcHash = $hash' --arg hash "${source_hash}"
  echo "Source hash: ${source_hash}"

  vendor_hash="$(extract_expected_hash "Go module vendor output")"
  # shellcheck disable=SC2016
  write_metadata '.vendorHash = $hash' --arg hash "${vendor_hash}"
  echo "Vendor hash: ${vendor_hash}"

  echo "Validating the package with both resolved hashes."
  nix_build
  transaction_complete=true
  echo "Validated sing-box ${version} (${rev})."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
