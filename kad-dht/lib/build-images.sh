#!/usr/bin/env bash
# Build kad-dht Docker images with caching (mirrors transport/lib-image-building.sh)

set -euo pipefail

# Ensure shared image-building helpers are available
if ! type docker_image_exists &>/dev/null; then
  source "${SCRIPT_LIB_DIR}/lib-image-building.sh"
fi

# Populate vendored github source into a local build context (e.g. dotnet-libp2p/)
# Uses ${CACHE_DIR}/git-repos for clone caching; only refreshes when commit changes.
prepare_vendored_github_source() {
  local build_context="$1"
  local repo="$2"
  local commit="$3"
  local vendor_dir_name="$4"
  local patch_path="${5:-}"
  local patch_file="${6:-}"
  local force_rebuild="${7:-false}"

  local repo_name
  repo_name=$(basename "${repo}")
  local vendor_path="${build_context}/${vendor_dir_name}"
  local commit_marker="${vendor_path}/.kad-dht-source-commit"

  if [ "${force_rebuild}" != "true" ] \
     && [ -d "${vendor_path}" ] \
     && [ -f "${commit_marker}" ] \
     && [ "$(cat "${commit_marker}")" = "${commit}" ]; then
    print_success "Vendored source ${vendor_dir_name} @ ${commit:0:8} (cached in build context)"
    return 0
  fi

  print_message "Preparing vendored source ${vendor_dir_name} @ ${commit:0:8}..."

  local work_dir
  work_dir=$(clone_github_repo_with_submodules "${repo}" "${commit}" "${CACHE_DIR}") || return 1
  local cloned_dir="${work_dir}/${repo_name}"

  rm -rf "${vendor_path}"
  cp -r "${cloned_dir}" "${vendor_path}"
  echo "${commit}" > "${commit_marker}"

  if [ -n "${patch_path}" ] && [ "${patch_path}" != "null" ] \
     && [ -n "${patch_file}" ] && [ "${patch_file}" != "null" ]; then
    if ! apply_patch_if_specified "${vendor_path}" "${patch_path}" "${patch_file}"; then
      rm -rf "${work_dir}" "${vendor_path}"
      return 1
    fi
  fi

  rm -rf "${work_dir}"
  print_success "Vendored source ready: ${vendor_path}"
}

build_kad_dht_image() {
  local impl_id="$1"
  local force_rebuild="${2:-false}"

  local q=".implementations[] | select(.id == \"${impl_id}\")"
  local image_name build_context
  image_name=$(yq eval "${q} | .imageName" "${IMAGES_YAML}")
  build_context=$(yq eval "${q} | .buildContext // \"\"" "${IMAGES_YAML}")

  if [ "${force_rebuild}" != "true" ] && docker_image_exists "${image_name}"; then
    print_success "${image_name} (already built)"
    return 0
  fi

  local repo commit vendor_dir dockerfile patch_path patch_file
  repo=$(yq eval "${q} | .source.repo // \"\"" "${IMAGES_YAML}")
  commit=$(yq eval "${q} | .source.commit // \"\"" "${IMAGES_YAML}")
  vendor_dir=$(yq eval "${q} | .source.vendorDir // \"\"" "${IMAGES_YAML}")
  dockerfile=$(yq eval "${q} | .source.dockerfile // \"\"" "${IMAGES_YAML}")
  patch_path=$(yq eval "${q} | .source.patchPath // \"\"" "${IMAGES_YAML}")
  patch_file=$(yq eval "${q} | .source.patchFile // \"\"" "${IMAGES_YAML}")

  # Mode 1: github source with a Dockerfile inside the repo (no vendorDir) —
  # clone the repo and build its root, matching the transport/hole-punch model.
  if [ -n "${repo}" ] && [ "${repo}" != "null" ] \
     && [ -n "${dockerfile}" ] && [ "${dockerfile}" != "null" ] \
     && { [ -z "${vendor_dir}" ] || [ "${vendor_dir}" == "null" ]; }; then
    local work_dir cloned_dir
    work_dir=$(clone_github_repo_with_submodules "${repo}" "${commit}" "${CACHE_DIR}") || return 1
    cloned_dir="${work_dir}/$(basename "${repo}")"
    if [ -n "${patch_path}" ] && [ "${patch_path}" != "null" ] \
       && [ -n "${patch_file}" ] && [ "${patch_file}" != "null" ]; then
      apply_patch_if_specified "${cloned_dir}" "${patch_path}" "${patch_file}" || {
        rm -rf "${work_dir}"
        return 1
      }
    fi
    print_message "Building ${image_name} from ${repo}@${commit:0:8} (-f ${dockerfile})..."
    docker build -f "${cloned_dir}/${dockerfile}" -t "${image_name}" "${cloned_dir}" || {
      rm -rf "${work_dir}"
      return 1
    }
    rm -rf "${work_dir}"
    print_success "${image_name} built"
    return 0
  fi

  # Mode 2/3: github source vendored into the build context (dotnet), or a
  # plain self-contained build context (py).
  if [ -n "${repo}" ] && [ "${repo}" != "null" ]; then
    if [ -z "${vendor_dir}" ] || [ "${vendor_dir}" == "null" ]; then
      vendor_dir=$(basename "${repo}")
    fi
    prepare_vendored_github_source \
      "${build_context}" "${repo}" "${commit}" "${vendor_dir}" \
      "${patch_path}" "${patch_file}" "${force_rebuild}" || return 1
  fi

  print_message "Building ${image_name} from ${build_context}..."
  docker build -t "${image_name}" "${build_context}"
  print_success "${image_name} built"
}

build_kad_dht_images() {
  local force_rebuild="${1:-false}"
  local filter="${2:-}"

  print_header "Building Docker images..."
  indent

  readarray -t impl_ids < <(yq eval '.implementations[].id' "${IMAGES_YAML}")

  for impl_id in "${impl_ids[@]}"; do
    if [ -n "${filter}" ]; then
      local match_found=false
      IFS='|' read -ra FILTER_PATTERNS <<< "${filter}"
      for pattern in "${FILTER_PATTERNS[@]}"; do
        case "${impl_id}" in
          ${pattern}) match_found=true; break ;;
        esac
      done
      if [ "${match_found}" == "false" ]; then
        continue
      fi
    fi

    build_kad_dht_image "${impl_id}" "${force_rebuild}" || {
      unindent
      return 1
    }
  done

  unindent
}
