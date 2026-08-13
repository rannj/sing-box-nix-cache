#!/usr/bin/env bash
set -euo pipefail

test_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly test_root

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../scripts/update-sing-box.sh
source "${test_root}/scripts/update-sing-box.sh"

tests_run=0
test_temp_dirs=()

cleanup_tests() {
  local directory

  for directory in "${test_temp_dirs[@]}"; do
    rm -rf -- "${directory}"
  done
}

trap cleanup_tests EXIT

fail() {
  echo "not ok - $*" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local description="$3"

  ((tests_run += 1))
  if [[ "${actual}" != "${expected}" ]]; then
    fail "${description}: expected '${expected}', got '${actual}'"
  fi
  echo "ok ${tests_run} - ${description}"
}

assert_fails() {
  local description="$1"
  shift

  ((tests_run += 1))
  if "$@"; then
    fail "${description}: command unexpectedly succeeded"
  fi
  echo "ok ${tests_run} - ${description}"
}

test_version_extraction() {
  local changelog actual
  changelog=$'intro\n#### 1.14.0-beta.3\nnotes\n#### 1.14.0-beta.2\n'
  actual="$(extract_version <<<"${changelog}")"
  assert_equal "1.14.0-beta.3" "${actual}" "extracts the first changelog version"
}

test_sha_validation() {
  is_commit_sha "abcdef1" || fail "seven-character SHA should be accepted"
  is_commit_sha "0123456789abcdef0123456789abcdef01234567" ||
    fail "full SHA should be accepted"
  assert_fails "rejects a non-hex commit reference" is_commit_sha "testing"
  assert_fails "rejects a too-short SHA" is_commit_sha "abcdef"
}

test_hash_mismatch_extraction() {
  local fixture expected actual
  fixture="$(mktemp)"
  expected="${fake_hash}"
  cat >"${fixture}" <<EOF
error: hash mismatch in fixed-output derivation
         specified: ${expected}
            got:    sha256-1111111111111111111111111111111111111111111=
EOF
  actual="$(extract_fixed_output_hash "${expected}" "${fixture}")"
  rm -f -- "${fixture}"
  assert_equal \
    "sha256-1111111111111111111111111111111111111111111=" \
    "${actual}" \
    "extracts the hash paired with the configured fake hash"
}

test_ambiguous_hash_rejection() {
  local fixture
  fixture="$(mktemp)"
  cat >"${fixture}" <<EOF
specified: ${fake_hash}
got: sha256-1111111111111111111111111111111111111111111=
specified: ${fake_hash}
got: sha256-2222222222222222222222222222222222222222222=
EOF
  assert_fails \
    "rejects multiple fake-hash mismatch candidates" \
    extract_fixed_output_hash "${fake_hash}" "${fixture}"
  rm -f -- "${fixture}"
}

setup_mock_repository() {
  local fixture="$1"
  local mock_bin="${fixture}/mock-bin"

  mkdir -p -- "${fixture}/scripts" "${mock_bin}"
  cp -- "${test_root}/scripts/update-sing-box.sh" "${fixture}/scripts/update-sing-box.sh"
  cp -- "${test_root}/source.json" "${fixture}/source.json"
  cp -- "${fixture}/source.json" "${fixture}/source.json.original"
  chmod a-w "${fixture}/source.json"
  : >"${fixture}/flake.lock"

  printf '#!%s\n' "$(command -v bash)" >"${mock_bin}/curl"
  cat >>"${mock_bin}/curl" <<'EOF'
set -euo pipefail

url="${!#}"
case "${url}" in
  *"/commits/"*)
    printf '{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n'
    ;;
  *"raw.githubusercontent.com"*)
    printf '#### 9.9.9\n\nMock changelog.\n'
    ;;
  *)
    echo "Unexpected mock curl URL: ${url}" >&2
    exit 1
    ;;
esac
EOF

  printf '#!%s\n' "$(command -v bash)" >"${mock_bin}/nix"
  cat >>"${mock_bin}/nix" <<EOF
set -euo pipefail

src_hash="\$(jq -r '.srcHash' source.json)"
vendor_hash="\$(jq -r '.vendorHash' source.json)"
if [[ "\${src_hash}" == "${fake_hash}" ]]; then
  echo "specified: ${fake_hash}" >&2
  echo "got: sha256-1111111111111111111111111111111111111111111=" >&2
  exit 1
fi

if [[ "\${vendor_hash}" == "${fake_hash}" ]]; then
  echo "specified: ${fake_hash}" >&2
  echo "got: sha256-2222222222222222222222222222222222222222222=" >&2
  exit 1
fi

if [[ "\${MOCK_FINAL_STATUS:-0}" != 0 ]]; then
  echo "mock final build failure" >&2
  exit "\${MOCK_FINAL_STATUS}"
fi
EOF

  chmod +x \
    "${fixture}/scripts/update-sing-box.sh" \
    "${mock_bin}/curl" \
    "${mock_bin}/nix"
}

test_successful_transaction() {
  local fixture status version rev src_hash vendor_hash
  fixture="$(mktemp -d)"
  test_temp_dirs+=("${fixture}")
  setup_mock_repository "${fixture}"

  if PATH="${fixture}/mock-bin:${PATH}" \
    bash "${fixture}/scripts/update-sing-box.sh" --commit aaaaaaa \
    >"${fixture}/success.log" 2>&1; then
    status=0
  else
    status=$?
  fi
  assert_equal "0" "${status}" "successful transaction exits cleanly"

  version="$(jq -r '.version' "${fixture}/source.json")"
  rev="$(jq -r '.rev' "${fixture}/source.json")"
  src_hash="$(jq -r '.srcHash' "${fixture}/source.json")"
  vendor_hash="$(jq -r '.vendorHash' "${fixture}/source.json")"
  assert_equal "9.9.9" "${version}" "successful transaction stores the selected version"
  assert_equal \
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    "${rev}" \
    "successful transaction stores the resolved SHA"
  assert_equal \
    "sha256-1111111111111111111111111111111111111111111=" \
    "${src_hash}" \
    "successful transaction stores the source hash"
  assert_equal \
    "sha256-2222222222222222222222222222222222222222222=" \
    "${vendor_hash}" \
    "successful transaction stores the vendor hash"
}

test_failed_transaction_rollback() {
  local fixture status
  fixture="$(mktemp -d)"
  test_temp_dirs+=("${fixture}")
  setup_mock_repository "${fixture}"

  if PATH="${fixture}/mock-bin:${PATH}" MOCK_FINAL_STATUS=2 \
    bash "${fixture}/scripts/update-sing-box.sh" --commit aaaaaaa \
    >"${fixture}/failure.log" 2>&1; then
    status=0
  else
    status=$?
  fi

  assert_equal "2" "${status}" "failed final build preserves its exit status"
  cmp -- "${fixture}/source.json.original" "${fixture}/source.json" ||
    fail "failed transaction did not restore source.json"
  ((tests_run += 1))
  echo "ok ${tests_run} - failed transaction restores source.json"
}

main() {
  test_version_extraction
  test_sha_validation
  test_hash_mismatch_extraction
  test_ambiguous_hash_rejection
  test_successful_transaction
  test_failed_transaction_rollback
  echo "1..${tests_run}"
}

main "$@"
