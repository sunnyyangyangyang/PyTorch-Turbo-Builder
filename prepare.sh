#!/usr/bin/env bash

# =============================================================================
# Universal PyTorch Build Environment Preparation Script
#
# This script ONLY sets environment variables. It can configure the build for
# two different packaging strategies:
#
# 1. BUILD_MODE="bundle" (default): Creates a large, self-contained wheel by
#    bundling libraries from your local CUDA installation.
# 2. BUILD_MODE="pypi": Creates a smaller wheel that depends on the official
#    NVIDIA packages from PyPI.
#
# Usage:
#   export BUILD_MODE="pypi"  # (Optional, defaults to "bundle")
#   source ./prepare_build.sh
# =============================================================================
export CUB_INCLUDE_DIR=$(pwd)/third_party/cub
# This script must be sourced.
if [ "$0" = "$BASH_SOURCE" ]; then
    echo "ERROR: This script should be sourced, not executed." >&2
    exit 1
fi

set -e

# --- Configuration: CHOOSE YOUR BUILD MODE HERE ---
if [[ -z "$BUILD_MODE" ]]; then
    echo "WARN: BUILD_MODE environment variable is not set." >&2
    echo "Please set the build mode before sourcing this script, for example:" >&2
    echo "  export BUILD_MODE=\"pypi\"" >&2
    echo "  export BUILD_MODE=\"bundle\"" >&2
    echo "Script will not continue." >&2
    return 0  # Use 'return' to stop a sourced script without closing the shell.
fi

# Validate that the set value is a valid one.
if [[ "$BUILD_MODE" != "pypi" && "$BUILD_MODE" != "bundle" ]]; then
    echo "ERROR: Invalid BUILD_MODE \"${BUILD_MODE}\". Must be 'bundle' or 'pypi'." >&2
    return 1 # Return a non-zero status to indicate failure.
fi


echo "--- Preparing PyTorch build environment (Mode: ${BUILD_MODE}) ---"

# --- Core Build Configuration ---
export MAX_JOBS=$(nproc)
export RELEASE=1
export DESIRED_PYTHON="cp313"

# --- BLAS/LAPACK Configuration (CRUCIAL FOR YOUR GOAL) ---
# Explicitly tell the build system to find and use OpenBLAS.
export BLAS=OpenBLAS

# --- GPU & Accelerator Support ---
export DESIRED_CUDA="12.9" # Set the CUDA version for build_cuda.sh
export CUDA_VERSION="12.9"
export USE_CUDA=1
export USE_CUDNN=1
# For NVIDIA Blackwell (RTX 5090). +PTX provides forward compatibility.
export TORCH_CUDA_ARCH_LIST="8.6;8.9;12.0+PTX"

# --- CPU Performance & Backends ---
# These are still beneficial. oneDNN can use OpenBLAS as its backend for BLAS calls.
export USE_OPENMP=1
export USE_MKLDNN=1 # oneDNN for convolutions, etc.
export USE_FBGEMM=1

# --- Distributed Training & Other Features ---
export USE_DISTRIBUTED=1
export USE_TENSORPIPE=1
export USE_GLOO=1
export USE_MPI=1
export BUILD_TEST=0
export USE_KINETO=1 # Keep this disabled as you intended


# --- Mode-Specific Configuration ---
BASE_DEPS=(
    "numpy"
    "triton"
)
if [[ "$BUILD_MODE" == "pypi" ]]; then
    # --- PYPI MODE ---
    echo "--- Configuring for PyPI dependency build ---"

    # Dynamically determine the CUDA package suffix (e.g., "cu12" from "12.9")
    CUDA_MAJOR_VERSION=$(echo "${CUDA_VERSION}" | cut -d'.' -f1)
    CUDA_PKG_SUFFIX="cu${CUDA_MAJOR_VERSION}"

    # In prepare_build.sh, inside the 'pypi' block...

    # Define the list of NVIDIA PyPI packages (FINAL, COMPLETE LIST)
    NVIDIA_PYPI_PACKAGES=(
        "nvidia-cublas"
        "nvidia-cuda-cupti"
        "nvidia-cuda-nvrtc"
        "nvidia-cuda-runtime"
        "nvidia-cudnn"
        "nvidia-cufile"      # Discovered from runtime error
        "nvidia-cufft"
        "nvidia-curand"
        "nvidia-cusolver"
        "nvidia-cusparse"
        "nvidia-cusparselt"  # Discovered from runtime error
        "nvidia-nccl"
        "nvidia-nvtx"
    )

    # Combine base dependencies with dynamically versioned CUDA dependencies
    ALL_DEPS=("${BASE_DEPS[@]}")
    for pkg in "${NVIDIA_PYPI_PACKAGES[@]}"; do
        ALL_DEPS+=("${pkg}-${CUDA_PKG_SUFFIX}")
    done

    # Join the array with '|' as required by setup.py
    DEPS_STRING=$(IFS='|'; echo "${ALL_DEPS[*]}")
    export PYTORCH_EXTRA_INSTALL_REQUIREMENTS="${DEPS_STRING}"

    # These flags are read by the upstream build scripts to switch to dynamic linking.
    export USE_STATIC_NCCL=0
    export ATEN_STATIC_CUDA=0
    export USE_CUDA_STATIC_LINK=0
    export USE_CUPTI_SO=1
    export USE_SYSTEM_NCCL=1

elif [[ "$BUILD_MODE" == "bundle" ]]; then
    # --- BUNDLE MODE ---
    DEPS_STRING=$(IFS='|'; echo "${BASE_DEPS[*]}")
    export PYTORCH_EXTRA_INSTALL_REQUIREMENTS="${DEPS_STRING}"

    export TORCH_NVCC_FLAGS="-Xfatbin -compress-all --threads 2"
    export NCCL_ROOT_DIR=/usr/local/cuda
    export USE_STATIC_CUDNN=0 # Still use shared cuDNN, but we will bundle it.
    export USE_STATIC_NCCL=1
    export ATEN_STATIC_CUDA=1
    export USE_CUDA_STATIC_LINK=1
    export USE_CUPTI_SO=0
    export USE_SYSTEM_NCCL=1
    export NCCL_INCLUDE_DIR="/usr/local/cuda/include/"
    export NCCL_LIB_DIR="/usr/local/cuda/lib64/"

else
    echo "ERROR: Invalid BUILD_MODE '${BUILD_MODE}'. Must be 'bundle' or 'pypi'." >&2
    # Return a non-zero status to indicate failure to the sourcing shell
    return 1
fi


# --- Set TORCH_CUDA_ARCH_LIST (can be common for both modes) ---
# You can customize this as needed.
export TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST:-"12.0+PTX"}


echo ""
echo "Environment is now set for a '${BUILD_MODE}' build."
echo "You can now run your custom build script."
echo "---"
