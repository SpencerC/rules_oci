#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

# A wrapper for crane. It starts a registry instance by calling start_registry function exported by %registry_launcher_path%.
# Then invokes crane with arguments provided after substituting `oci:registry` with REGISTRY variable exported by start_registry.
# NB: --output argument is an option only understood by this wrapper and will pull artifact image into a oci layout.

readonly REGISTRY_LAUNCHER="{{registry_launcher_path}}"
readonly CRANE="{{crane_path}}"
readonly JQ="{{jq_path}}"
readonly STORAGE_DIR="{{storage_dir}}"

readonly STDERR=$(mktemp)

on_exit() {
    local last_cmd_exit_code=$?
    set +o errexit
    stop_registry ${STORAGE_DIR}
    local stop_registry_exit_code=$?
    if [[ $last_cmd_exit_code != 0 ]] || [[ $stop_registry_exit_code != 0 ]]; then
        cat "${STDERR}" >&1
    fi
}

function get_option() {
    local name=$1
    shift
    for ARG in "$@"; do
        case "$ARG" in
            ($name=*) echo ${ARG#$name=};; 
        esac
    done
}


function empty_base() {
    local registry=$1
    local ref="$registry/oci/empty_base:latest"
    ref="$("${CRANE}" append --oci-empty-base -t "${ref}" -f {{empty_tar}})"
    ref=$("${CRANE}" config "${ref}" | "${JQ}"  ".rootfs.diff_ids = [] | .history = []" | "${CRANE}" edit config "${ref}")
    ref=$("${CRANE}" manifest "${ref}" | "${JQ}"  ".layers = []" | "${CRANE}" edit manifest "${ref}")

    local raw_platform=$(get_option --platform $@)
    IFS='/' read -r -a platform <<< "$raw_platform"

    local filter='.os = $os | .architecture = $arch'
    local -a args=( "--arg" "os" "${platform[0]}" "--arg" "arch" "${platform[1]}" )

    if [ -n "${platform[2]:-}" ]; then
        filter+=' | .variant = $variant'
        args+=("--arg" "variant" "${platform[2]}")
    fi
    "${CRANE}" config "${ref}" | "${JQ}" ${args[@]} "${filter}" | "${CRANE}" edit config "${ref}"
}

function base_from_layout() {
    # TODO: https://github.com/google/go-containerregistry/issues/1514
    local refs=$(mktemp)
    local output=$(mktemp)
    local oci_layout_path=$1
    local registry=$2

    "${CRANE}" push "${oci_layout_path}" "${registry}/image:latest" --image-refs "${refs}" > "${output}" 2>&1

    if grep -q "MANIFEST_INVALID" "${output}"; then
    cat >&2 << EOF

zot registry does not support docker manifests. 

crane registry does support both oci and docker images, but is more memory hungry.

If you want to use the crane registry, remove "zot_version" from "oci_register_toolchains". 

EOF

        exit 1
    fi

    cat "${refs}"
}

# Redirect stderr to the $STDERR temp file for the rest of the script.
exec 2>>"${STDERR}"

# Upon exiting, stop the registry and print STDERR on non-zero exit code.
trap "on_exit" EXIT

source "${REGISTRY_LAUNCHER}" 
REGISTRY=
REGISTRY=$(start_registry "${STORAGE_DIR}" "${STDERR}")

OUTPUT=""
FIXED_ARGS=()
ENV_EXPANSIONS=()

for ARG in "$@"; do
    case "$ARG" in
        (oci:registry*) FIXED_ARGS+=("${ARG/oci:registry/$REGISTRY}") ;;
        (oci:empty_base) FIXED_ARGS+=("$(empty_base $REGISTRY $@)") ;;
        (oci:layout*) FIXED_ARGS+=("$(base_from_layout ${ARG/oci:layout\/} $REGISTRY)") ;;
        (--output=*) OUTPUT="${ARG#--output=}" ;;
        (--env-file=*)
          # NB: the '|| [-n $in]' expression is needed to process the final line, in case the input
          # file doesn't have a trailing newline.
          while IFS= read -r in || [ -n "$in" ]; do
            if [[ "${in}" = *\$* ]]; then
              ENV_EXPANSIONS+=( "${in}" )
            else
              FIXED_ARGS+=( "--env=${in}" )
            fi
          done <"${ARG#--env-file=}"
          ;;
        (--labels-file=*)
          # NB: the '|| [-n $in]' expression is needed to process the final line, in case the input
          # file doesn't have a trailing newline.
          while IFS= read -r in || [ -n "$in" ]; do
            FIXED_ARGS+=("--label=$in")
          done <"${ARG#--labels-file=}"
          ;;
          # NB: the '|| [-n $in]' expression is needed to process the final line, in case the input
          # file doesn't have a trailing newline.
        (--annotations-file=*)
          while IFS= read -r in || [ -n "$in" ]; do
            FIXED_ARGS+=("--annotation=$in")
          done <"${ARG#--annotations-file=}"
          ;;
        (--cmd-file=*)
          while IFS= read -r in || [ -n "$in" ]; do
            FIXED_ARGS+=("--cmd=$in")
          done <"${ARG#--cmd-file=}"
          ;;
        (--entrypoint-file=*)
          while IFS= read -r in || [ -n "$in" ]; do
            FIXED_ARGS+=("--entrypoint=$in")
          done <"${ARG#--entrypoint-file=}"
          ;;
	(--exposed-ports-file=*)
	  while IFS= read -r in || [ -n "$in" ]; do
            FIXED_ARGS+=("--exposed-ports=$in")
          done <"${ARG#--exposed-ports-file=}"
          ;;
        (*) FIXED_ARGS+=( "${ARG}" )
    esac
done

REF=$("${CRANE}" "${FIXED_ARGS[@]}")

if [ ${#ENV_EXPANSIONS[@]} -ne 0 ]; then 
    env_expansion_filter=\
'[$raw | match("\\${?([a-zA-Z0-9_]+)}?"; "gm")] | reduce .[] as $match (
    {parts: [], prev: 0}; 
    {parts: (.parts + [$raw[.prev:$match.offset], $envs[$match.captures[0].string]]), prev: ($match.offset + $match.length)}
) | .parts + [$raw[.prev:]] | join("")'
    base_config=$("${CRANE}" config "${REF}")
    base_env=$("${JQ}" -r '.config.Env | map(. | split("=") | {"key": .[0], "value": .[1]}) | from_entries' <<< "${base_config}")
    environment_args=()
    for expansion in "${ENV_EXPANSIONS[@]}"
    do
        IFS="=" read -r key value <<< "${expansion}"
        value_from_base=$("${JQ}" -nr --arg raw "${value}" --argjson envs "${base_env}" "${env_expansion_filter}")
        environment_args+=( --env "${key}=${value_from_base}" )
    done
    REF=$("${CRANE}" mutate "${REF}" ${environment_args[@]})
fi

if [ -n "$OUTPUT" ]; then
    "${CRANE}" pull "${REF}" "./${OUTPUT}" --format=oci --annotate-ref
    mv "${OUTPUT}/index.json" "${OUTPUT}/temp.json"
    "${JQ}" --arg ref "${REF}" '.manifests |= map(select(.annotations["org.opencontainers.image.ref.name"] == $ref)) | del(.manifests[0].annotations)' "${OUTPUT}/temp.json" >  "${OUTPUT}/index.json"
    rm "${OUTPUT}/temp.json"
    "${CRANE}" layout gc "./${OUTPUT}"
fi
