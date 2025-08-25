# The PyTorch Build Accelerator

Tired of 90-minute PyTorch builds that crash with Out-of-Memory errors? This project provides a powerful, automated build system that reduces compilation time to under 30 minutes while ensuring stability.

It uses an intelligent adaptive governor and a two-phase build strategy, all running within the official PyTorch manylinux container for perfect reproducibility.

## Key Features & Highlights

🚀 **Fast & Stable Compilation**: An intelligent governor actively monitors system memory and CPU, dynamically adjusting parallel build jobs (-j) to maximize speed without crashing.

🧠 **Two-Phase Build Strategy**: The script identifies and pre-builds known memory-intensive targets (like FlashAttention) in a controlled, conservative phase, preventing the most common cause of build failures.

📦 **Flexible Packaging Modes**:
*   **`pypi` mode**: Creates a standard, portable wheel that correctly links against official NVIDIA packages from PyPI.
*   **`bundle` mode**: Creates a large, self-contained wheel with all CUDA libraries bundled directly.

💾 **Ultra-Low Disk I/O**: The entire process leverages a RAM disk (tmpfs) for temporary files, resulting in incredibly low SSD writes (~15 GB total).

## Prerequisites
### Hardware
*   **CPU**: A modern, high core-count CPU (16+ cores recommended).
*   **RAM**: 64 GB is required for the default settings. See the tuning section for 32 GB systems.
*   **Storage**: A fast NVMe SSD is highly recommended.
*   **GPU**: An NVIDIA GPU.

### Software
*   **Container Runtime**: Podman or Docker.

### Disclaimer
This process has been thoroughly tested for building PyTorch with CUDA 12.9 inside the specified builder image. While it may work for other versions, they are not officially supported by this guide.

## The Build Workflow: End-to-End

The entire build happens inside a container, ensuring a clean, isolated, and fully reproducible environment with no dependencies on the host.

### Step 1 (Host): Create and Start the Build Container

This command creates a persistent container with a dedicated RAM disk (tmpfs) and a memory limit. No local folders are mounted.

```bash
# Create the container using Podman (or replace 'podman' with 'docker')
podman create \
  --name pytorch_builder \
  --gpus all \
  --ipc=host \
  --memory=55g \
  --tmpfs /tmp:rw,size=30g,exec \
  docker.io/pytorch/manylinux2_28-builder

# Start the container and get an interactive shell
podman start -ai pytorch_builder
```*   `--memory=55g`: Limits the container's RAM usage.
*   `--tmpfs /tmp:rw,size=30g,exec`: Crucial. Creates a 30GB RAM disk for temporary files to maximize speed and minimize SSD wear.

You are now inside the container. To exit, type `exit`. To re-enter later, simply run `podman start -ai pytorch_builder` again.

### Step 2 (Container): Prepare Environment and Download Sources

Inside the container, install the necessary tools and download all source code.

```bash
# We are now INSIDE the container.
# The pytorch/manylinux2_28-builder image requires some development tools.

# Install Git and Python development headers (required by setup.py)
# This example uses Python 3.11. Adjust if you need a different version.
dnf install -y git python3.11-devel

# Create a working directory
mkdir /workspace && cd /workspace

# Download the PyTorch source (git clone or tarball)
git clone https://github.com/pytorch/pytorch.git
cd pytorch

# Check out the specific version you want to build (e.g., v2.3.1)
git checkout v2.8.0

# Initialize all third-party dependencies
git submodule update --init --recursive

# Clone this build accelerator repository into the source directory
git clone https://github.com/your-username/your-repo-name.git .
# Note: The "." clones the scripts directly into the /workspace/pytorch directory.
```

### Step 3 (Container): Build and Package the Wheel

Now you are ready to build.

**To build a PyPI-compatible wheel:**
```bash
# 1. Set the build mode
export BUILD_MODE="pypi"

# 2. Source the preparation script to configure the environment
source ./prepare.sh

# 3. Run the adaptive build (this will take ~26 mins on a 9950X)
./build.sh

# 4. Package the final, corrected wheel
INITIAL_WHEEL_PATH=$(find dist/ -name "torch-*-linux_x86_64.whl")
./package.sh "${INITIAL_WHEEL_PATH}"
```
**To build a self-contained (bundle) wheel:**

The process is the same, just change the `BUILD_MODE`.
```bash
export BUILD_MODE="bundle"
source ./prepare.sh
./build.sh
INITIAL_WHEEL_PATH=$(find dist/ -name "torch-*-linux_x86_64.whl")
./package.sh "${INITIAL_WHEEL_PATH}"
```
The packaged wheel is now located at `/workspace/pytorch/dist/` inside the container. Proceed to the final step to retrieve it.

### Step 4 (Host): Retrieve the Packaged Wheel

First, exit the container's interactive shell by typing `exit`. Then, from your host machine's terminal, copy the wheel file out of the container.

```bash
# Run this command on your HOST machine
podman cp pytorch_builder:/workspace/pytorch/dist/ ./
```

Done! Your final wheel is in the `dist` folder in your current directory on your host machine.

## Memory & CPU Tuning (Important!)
### Recommended: 64GB+ RAM (Default Settings)
The scripts are tuned for a system with 64GB of RAM or more, using up to 32 parallel jobs.

### Systems with 32GB RAM
If your host machine has 32GB of RAM, you **must** reduce the number of parallel jobs in `build.sh`.

Edit `build.sh` and make the following changes:
```diff
--- a/build.sh
+++ b/build.sh
@@ -17,11 +17,11 @@
 # The exact name of the memory-intensive ninja target.
 # Find this with `ninja -C build -t targets`.
 FLASH_ATTENTION_TARGET_NAME="flash_attention"
-# The safe number of jobs to use for building ONLY this target.
-FLASH_ATTENTION_CONSERVATIVE_JOBS=8
+# The safe number of jobs for 32GB RAM systems.
+FLASH_ATTENTION_CONSERVATIVE_JOBS=4
 
 # --- Governor Config ---
 CHECK_INTERVAL_FAST_SEC=15
@@ -30,7 +30,8 @@
 
 MEMORY_DOWNSHIFT_THRESHOLD_GB=47
 
-DEFAULT_JOBS_LEVELS=(32 16 8 4 2)
+# NOTE: Reduce job levels for 32GB RAM systems.
+DEFAULT_JOBS_LEVELS=(16 8 4 2 1)
 # NOTE: Flash Attention job levels are no longer needed here, as it's built separately.
 JOBS_LEVELS=("${DEFAULT_JOBS_LEVELS[@]}")
```

## Performance Benchmark
*   **Host CPU**: AMD Ryzen 9 9950X (16 Cores, 32 Threads)
*   **Host RAM**: 64 GB DDR5
*   **Host Storage**: NVMe SSD
*   **Environment**: `pytorch/manylinux2_28-builder:cuda12.1`
*   **Build Mode**: `pypi` with CUDA 12.9
*   **Parallel Jobs**: -j32
*   **Total Compile Time**: 26 minutes, 12.3 seconds

### **Acknowledgement**

This project's scripts, particularly `prepare.sh` and `package.sh`, are heavily inspired by and adapted from the official build scripts found in the PyTorch repository's `.ci/manywheel/` directory. Our goal was to expose their powerful, battle-tested logic in a more accessible, user-friendly, and optimized workflow. We extend our sincere gratitude to the PyTorch team for their foundational work.

### **License**

This project is licensed under the MIT License. See the `LICENSE` file for details.

The portions of this project adapted from PyTorch are subject to their original BSD-style license, a copy of which is included in the `LICENSE-PyTorch.md` file.

