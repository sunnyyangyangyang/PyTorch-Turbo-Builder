#!/usr/bin/env bash

# =============================================================================
# Universal PyTorch Wheel Packager (v2.7 - /tmp fallback)
#
# This script is the final version, incorporating all fixes and improvements:
# 1. Correctly bundles libopenblas.so.0 in 'bundle' mode to ensure portability.
# 2. Creates PEP 427 compliant wheel filenames to work with modern installers.
# 3. Uses a robust associative array to handle dependency bundling.
# 4. Uses a faster, non-compressing zip command for the final packaging.
# 5. MODIFICATION: Uses /tmp for the temporary directory to handle large wheels
#    that do not fit in /dev/shm.
#
# Usage:
#   # Ensure BUILD_MODE is set (from your prepare script)
#   ./package_wheel.sh /path/to/your/torch-....whl
# =============================================================================

set -ex

# --- Pre-flight Checks ---
if [[ -z "$1" ]] || [[ ! -f "$1" ]]; then
    echo "Usage: $0 <path_to_wheel_file>" >&2
    exit 1
fi
WHEEL_PATH=$(realpath "$1")

export BUILD_MODE=${BUILD_MODE:-"bundle"} # Default to bundle if not set
if [[ -z "$CUDA_VERSION" ]]; then
    echo "Error: CUDA_VERSION env var not set. Please source prepare_build.sh" >&2
    exit 1
fi

if ! command -v patchelf &> /dev/null; then
    echo "Error: patchelf command not found. Please install it." >&2
    exit 1
fi

# --- Create a temporary directory in /tmp ---
# This provides more space for large wheel files than /dev/shm.
TMP_DIR=$(mktemp -d -p /tmp packaging_temp.XXXXXX)

# --- Robust Cleanup ---
# Set up a trap to automatically remove the temp directory on script exit.
trap 'echo "--- Cleaning up temporary directory ---"; rm -rf "$TMP_DIR"' EXIT ERR INT TERM


echo "--- Starting wheel packaging (Mode: ${BUILD_MODE}) ---"
echo "--- Using /tmp for temporary operations: ${TMP_DIR} ---"

# --- Common Helper Functions (from PyTorch CI) ---
make_wheel_record() {
    FPATH=$1
    if echo "$FPATH" | grep RECORD >/dev/null 2>&1; then
        echo "\"$FPATH\",,"
    else
        HASH=$(openssl dgst -sha256 -binary "$FPATH" | openssl base64 | sed -e 's/+/-/g' | sed -e 's/\//_/g' | sed -e 's/=//g')
        FSIZE=$(ls -nl "$FPATH" | awk '{print $5}')
        echo "\"$FPATH\",sha256=$HASH,$FSIZE"
    fi
}

fname_with_sha256() {
    HASH=$(sha256sum "$1" | cut -c1-8)
    DIRNAME=$(dirname "$1")
    BASENAME=$(basename "$1")
    # Per PyTorch CI: Do not rename critical CUDA libs that are loaded by name.
    if [[ $BASENAME == "libnvrtc-builtins.s"* || $BASENAME == "libcudnn"* || $BASENAME == "libcublas"* ]]; then
        echo "$1"
    else
        INITNAME=$(echo "$BASENAME" | cut -f1 -d".")
        ENDNAME=$(echo "$BASENAME" | cut -f 2- -d".")
        echo "$DIRNAME/$INITNAME-$HASH.$ENDNAME"
    fi
}

replace_needed_sofiles() {
    # $1: directory to search for .so files
    # $2: original library name
    # $3: new library name
    find "$1" -name '*.so*' -type f | while read -r sofile; do
        origname=$2
        patchedname=$3
        set +e
        # Use grep -q "^$origname$" to match the exact library name
        patchelf --print-needed "$sofile" | grep -q "^$origname$"
        ERRCODE=$?
        set -e
        if [ "$ERRCODE" -eq "0" ]; then
            echo "patching $sofile entry $origname -> $patchedname"
            patchelf --replace-needed "$origname" "$patchedname" "$sofile"
        fi
    done
}


# --- Main Packaging Logic ---
pushd "$TMP_DIR"

echo "Unpacking wheel: $WHEEL_PATH"
unzip -q "$WHEEL_PATH"

# --- Define correct output filename (PEP 427 compliant) ---
ORIGINAL_FILENAME=$(basename "$WHEEL_PATH")
# Separate the name/version part from the python/platform tags
# e.g., 'torch-2.9.0-cp313...' -> BASE='torch-2.9.0', TAGS='-cp313...'
BASE_PART="${ORIGINAL_FILENAME%%-cp[0-9]*.whl}"
TAG_PART="${ORIGINAL_FILENAME#$BASE_PART}"

# --- Centralized System Library Path Detection ---
OS_NAME=$(awk -F= '/^NAME/{print $2}' /etc/os-release)
if [[ "$OS_NAME" == *"AlmaLinux"* ]] || [[ "$OS_NAME" == *"Red Hat"* ]]; then
    LIBGOMP_PATH="/usr/lib64/libgomp.so.1"
    OPENBLAS_PATH="/usr/lib64/libopenblas.so.0"
elif [[ "$OS_NAME" == *"Ubuntu"* ]]; then
    LIBGOMP_PATH="/usr/lib/x86_64-linux-gnu/libgomp.so.1"
    OPENBLAS_PATH="/usr/lib/x86_64-linux-gnu/libopenblas.so.0"
else
    # Fallback search if OS not recognized
    LIBGOMP_PATH=$(find /usr/lib* -name "libgomp.so.1" | head -n1)
    OPENBLAS_PATH=$(find /usr/lib* -name "libopenblas.so.0" | head -n1)
fi


# REPLACE your old 'pypi' block with this new, corrected one

if [[ "$BUILD_MODE" == "pypi" ]]; then
    # ======================== PYPI MODE LOGIC ========================
    echo "--- Applying PyPI dependency packaging logic ---"
    
    BUILD_TAG="1pypi"
    REPACKAGED_WHEEL_NAME="$(dirname "$WHEEL_PATH")/${BASE_PART}-${BUILD_TAG}${TAG_PART}"

    # --- Step 1: Set RPATHs for external NVIDIA PyPI packages (This part is unchanged) ---
    cuda_version_nodot=$(echo "$CUDA_VERSION" | tr -d '.'); CUDA_RPATHS=('$ORIGIN/../../nvidia/cudnn/lib' '$ORIGIN/../../nvidia/nvshmem/lib' '$ORIGIN/../../nvidia/nccl/lib' '$ORIGIN/../../nvidia/cusparselt/lib' '$ORIGIN/../../nvidia/cublas/lib' '$ORIGIN/../../nvidia/cuda_cupti/lib' '$ORIGIN/../../nvidia/cuda_nvrtc/lib' '$ORIGIN/../../nvidia/cuda_runtime/lib' '$ORIGIN/../../nvidia/cufft/lib' '$ORIGIN/../../nvidia/curand/lib' '$ORIGIN/../../nvidia/cusolver/lib' '$ORIGIN/../../nvidia/cusparse/lib' '$ORIGIN/../../nvidia/nvtx/lib' '$ORIGIN/../../nvidia/cufile/lib' "\$ORIGIN/../../nvidia/cu${cuda_version_nodot}/lib"); CUDA_RPATHS_STR=$(IFS=: ; echo "${CUDA_RPATHS[*]}"); C_SO_RPATH="${CUDA_RPATHS_STR}:\$ORIGIN:\$ORIGIN/lib"; LIB_SO_RPATH="${CUDA_RPATHS_STR}:\$ORIGIN"

    find torch -maxdepth 1 -type f -name "*.so*" | while read -r sofile; do patchelf --set-rpath "${C_SO_RPATH}" --force-rpath "$sofile"; done
    find torch/lib -maxdepth 1 -type f -name "*.so*" | while read -r sofile; do patchelf --set-rpath "${LIB_SO_RPATH}" --force-rpath "$sofile"; done

    # --- Step 2: Bundle essential SYSTEM libraries for portability (The FIX) ---
    echo "--- Bundling essential system libraries into the PyPI wheel ---"
    SYSTEM_DEPS_LIST=(
        "$LIBGOMP_PATH"
        "$OPENBLAS_PATH"
        "/usr/lib64/libgfortran.so.5"
        "/usr/lib64/libquadmath.so.0"
    )
    SYSTEM_DEPS_SONAME=(
        "libgomp.so.1"
        "libopenblas.so.0"
        "libgfortran.so.5"
        "libquadmath.so.0"
    )

    declare -A soname_map
    for ((i=0; i < ${#SYSTEM_DEPS_LIST[@]}; ++i)); do
        filepath="${SYSTEM_DEPS_LIST[i]}"
        soname="${SYSTEM_DEPS_SONAME[i]}"
        if [[ -z "$filepath" || ! -f "$filepath" ]]; then
            echo "WARNING: System lib not found, skipping: ${soname} (Path: ${filepath})"
            continue
        fi

        destpath="torch/lib/$(basename "$filepath")"
        cp "$filepath" "$destpath"
        patchedpath=$(fname_with_sha256 "$destpath")
        patchedname=$(basename "$patchedpath")
        if [[ "$destpath" != "$patchedpath" ]]; then
            mv "$destpath" "$patchedpath"
        fi
        soname_map["$soname"]="$patchedname"
    done

    for origname in "${!soname_map[@]}"; do
        patchedname="${soname_map[$origname]}"
        if [[ "$origname" != "$patchedname" ]]; then
            replace_needed_sofiles "torch" "$origname" "$patchedname"
            replace_needed_sofiles "torch/lib" "$origname" "$patchedname"
        fi
    done

elif [[ "$BUILD_MODE" == "bundle" ]]; then
    # ======================= BUNDLE MODE LOGIC =======================
    echo "--- Applying self-contained bundle packaging logic ---"

    BUILD_TAG="1bundle"
    REPACKAGED_WHEEL_NAME="$(dirname "$WHEEL_PATH")/${BASE_PART}-${BUILD_TAG}${TAG_PART}"
    
    # === FINAL, DEFINITIVE DEPENDENCY LIST ===
    # This list is based on the final dependency scan.
    # We explicitly EXCLUDE libstdc++.so.6 as it's a core system library.
    DEPS_LIST=(
        "/usr/lib64/libgomp.so.1"
        "/usr/lib64/libopenblas.so.0"
        "/usr/lib64/libgfortran.so.5"
        "/usr/lib64/libquadmath.so.0"
    )
    DEPS_SONAME=(
        "libgomp.so.1"
        "libopenblas.so.0"
        "libgfortran.so.5"
        "libquadmath.so.0"
    )

    # Add all the CUDA libraries to the lists
    if [[ $CUDA_VERSION == 12* || $CUDA_VERSION == 13* ]]; then
        CUDA_LIB_DIR="/usr/local/cuda/lib64"
        CUPTI_LIB_DIR="/usr/local/cuda/extras/CUPTI/lib64"
        # Note: The scanner already found the essential CUDA libs, but we keep this
        # comprehensive list from PyTorch CI for maximum robustness.
        DEPS_LIST+=(
            "$CUDA_LIB_DIR/libcudnn_adv.so.9" "$CUDA_LIB_DIR/libcudnn_cnn.so.9" "$CUDA_LIB_DIR/libcudnn_graph.so.9" "$CUDA_LIB_DIR/libcudnn_ops.so.9"
            "$CUDA_LIB_DIR/libcudnn_engines_runtime_compiled.so.9" "$CUDA_LIB_DIR/libcudnn_engines_precompiled.so.9" "$CUDA_LIB_DIR/libcudnn_heuristic.so.9"
            "$CUDA_LIB_DIR/libcudnn.so.9" "$CUDA_LIB_DIR/libcublas.so.12" "$CUDA_LIB_DIR/libcublasLt.so.12" "$CUDA_LIB_DIR/libcusparseLt.so.0"
            "$CUDA_LIB_DIR/libcudart.so.12" "$CUDA_LIB_DIR/libnvrtc.so.12" "$CUDA_LIB_DIR/libnvrtc-builtins.so" "$CUDA_LIB_DIR/libcufile.so.0"
            "$CUDA_LIB_DIR/libcufile_rdma.so.1" "$CUDA_LIB_DIR/libnvshmem_host.so.3" "$CUPTI_LIB_DIR/libcupti.so.12" "$CUPTI_LIB_DIR/libnvperf_host.so"
        )
        DEPS_SONAME+=(
            "libcudnn_adv.so.9" "libcudnn_cnn.so.9" "libcudnn_graph.so.9" "libcudnn_ops.so.9" "libcudnn_engines_runtime_compiled.so.9"
            "libcudnn_engines_precompiled.so.9" "libcudnn_heuristic.so.9" "libcudnn.so.9" "libcublas.so.12" "libcublasLt.so.12"
            "libcusparseLt.so.0" "libcudart.so.12" "libnvrtc.so.12" "libnvrtc-builtins.so" "libcufile.so.0" "libcufile_rdma.so.1"
            "libnvshmem_host.so.3" "libcupti.so.12" "libnvperf_host.so"
        )
        if [[ $CUDA_VERSION != 12.9* ]]; then
            DEPS_LIST+=("$CUDA_LIB_DIR/libnvToolsExt.so.1")
            DEPS_SONAME+=("libnvToolsExt.so.1")
        fi
    fi

    # BUGFIX: Use a robust associative array to prevent index mismatch errors if a library is not found.
    declare -A soname_map
    for ((i=0; i < ${#DEPS_LIST[@]}; ++i)); do
        filepath="${DEPS_LIST[i]}"
        soname="${DEPS_SONAME[i]}"
        if [[ -z "$filepath" || ! -f "$filepath" ]]; then
            echo "WARNING: Lib not found or path is empty, skipping: ${soname} (Path: ${filepath})"
            continue
        fi

        destpath="torch/lib/$(basename "$filepath")"
        cp "$filepath" "$destpath"
        patchedpath=$(fname_with_sha256 "$destpath")
        patchedname=$(basename "$patchedpath")
        if [[ "$destpath" != "$patchedpath" ]]; then
            mv "$destpath" "$patchedpath"
        fi
        soname_map["$soname"]="$patchedname"
    done

    # Patch ELF headers using the safe map
    for origname in "${!soname_map[@]}"; do
        patchedname="${soname_map[$origname]}"
        if [[ "$origname" != "$patchedname" ]]; then
            replace_needed_sofiles "torch" "$origname" "$patchedname"
            replace_needed_sofiles "torch/lib" "$origname" "$patchedname"
        fi
    done

    # Set RPATHs for bundled libs
    find torch -maxdepth 1 -type f -name "*.so*" | while read -r sofile; do patchelf --set-rpath '$ORIGIN:$ORIGIN/lib' --force-rpath "$sofile"; done
    find torch/lib -maxdepth 1 -type f -name "*.so*" | while read -r sofile; do patchelf --set-rpath '$ORIGIN' --force-rpath "$sofile"; done
fi

# --- Common Final Steps ---
# Regenerate the RECORD file to account for added/changed files
RECORD_FILE=$(find . -name RECORD)
if [[ -n "$RECORD_FILE" ]]; then
    echo "Regenerating RECORD file: $RECORD_FILE"
    TMP_RECORD_FILE="${RECORD_FILE}.tmp"
    : > "$TMP_RECORD_FILE"
    # Find all files, sort them for consistent ordering, and generate records
    find * -type f | sort | while read -r fname; do
        if [[ "$fname" != "$TMP_RECORD_FILE" ]]; then
            make_wheel_record "$fname" >>"$TMP_RECORD_FILE"
        fi
    done
    mv "$TMP_RECORD_FILE" "$RECORD_FILE"
fi

# Zip the wheel back up using a faster, non-compressing method
echo "Creating final wheel: $REPACKAGED_WHEEL_NAME"
# The output path is an absolute path, so we don't need to popd first.
zip -rq0 "$REPACKAGED_WHEEL_NAME" .

popd
echo "--- Packaging Complete ---"
echo "Final wheel located at: $REPACKAGED_WHEEL_NAME"