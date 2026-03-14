#!/bin/bash
# Installation script for MASt3R-SLAM
# Run from the MASt3R-SLAM directory

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== MASt3R-SLAM Installation ==="

# Check if conda is available
if ! command -v conda &> /dev/null; then
    echo "Error: conda not found. Please install miniconda/anaconda first."
    exit 1
fi

# Check CUDA version
if command -v nvcc &> /dev/null; then
    CUDA_VERSION=$(nvcc --version | grep "release" | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p')
    echo "Detected CUDA version: $CUDA_VERSION"
else
    echo "Warning: nvcc not found. Defaulting to CUDA 12.1"
    CUDA_VERSION="12.1"
fi

# Determine pytorch-cuda version
# NOTE: MASt3R-SLAM requires CUDA 12.4+ for libcu++ headers (cuda/std/limits)
case "$CUDA_VERSION" in
    11.8*) PYTORCH_CUDA="12.4" ; echo "Warning: System CUDA is 11.8 but using PyTorch CUDA 12.4 (required for libcu++)" ;;
    12.1*) PYTORCH_CUDA="12.4" ; echo "Warning: System CUDA is 12.1 but using PyTorch CUDA 12.4 (required for libcu++)" ;;
    12.4*) PYTORCH_CUDA="12.4" ;;
    12.*) PYTORCH_CUDA="12.4" ;;  # Default for other 12.x
    *) PYTORCH_CUDA="12.4" ;;      # Default fallback - use 12.4 for libcu++ headers
esac
echo "Using pytorch-cuda=$PYTORCH_CUDA"

# Create conda environment
ENV_NAME="mast3r-slam"
if conda env list | grep -q "^${ENV_NAME} "; then
    echo "Environment '$ENV_NAME' already exists."
    echo "To start fresh, run: conda env remove -n $ENV_NAME"
    echo "Then re-run this script."
    echo ""
    echo "Continuing with existing environment..."
else
    echo "Creating conda environment '$ENV_NAME'..."
    conda create -n $ENV_NAME python=3.11 -y
fi

# Activate environment
eval "$(conda shell.bash hook)"
conda activate $ENV_NAME

# Install PyTorch with CUDA nvcc (needed for building CUDA extensions)
echo "Installing PyTorch with CUDA $PYTORCH_CUDA and nvcc..."
conda install pytorch==2.5.1 torchvision==0.20.1 torchaudio==2.5.1 pytorch-cuda=$PYTORCH_CUDA cuda-nvcc=$PYTORCH_CUDA cuda-cudart-dev=$PYTORCH_CUDA -c pytorch -c nvidia -y

# Set CUDA environment variables for building extensions
# These must be explicitly passed to pip install for CUDA extension builds
export CUDA_HOME=$CONDA_PREFIX
export CPATH=$CONDA_PREFIX/targets/x86_64-linux/include:$CPATH
export LIBRARY_PATH=$CONDA_PREFIX/lib:$LIBRARY_PATH
export LD_LIBRARY_PATH=$CONDA_PREFIX/lib:$LD_LIBRARY_PATH

# Force system GCC for CUDA compatibility (avoids issues with conda-forge GCC 12+)
export CUDAHOSTCXX=/usr/bin/gcc
export CXX=/usr/bin/g++
export CC=/usr/bin/gcc

echo "CUDA_HOME set to: $CUDA_HOME"
echo "Using GCC: $(which gcc) (version: $(/usr/bin/gcc --version | head -1))"

# Create symlinks for CUDA headers needed by CUDA extensions
# nv/ headers (needed for cuda_bf16.hpp)
if [ -d "$CONDA_PREFIX/targets/x86_64-linux/include/nv" ] && [ ! -e "$CONDA_PREFIX/include/nv" ]; then
    echo "Creating symlink for nv/ headers..."
    ln -sf $CONDA_PREFIX/targets/x86_64-linux/include/nv $CONDA_PREFIX/include/nv
fi

# cuda/ headers from CCCL (needed for cuda/std/limits in libcu++)
if [ -d "$CONDA_PREFIX/targets/x86_64-linux/include/cccl/cuda" ] && [ ! -e "$CONDA_PREFIX/include/cuda" ]; then
    echo "Creating symlink for CCCL cuda/ headers (libcu++)..."
    ln -sf $CONDA_PREFIX/targets/x86_64-linux/include/cccl/cuda $CONDA_PREFIX/include/cuda
fi

# Initialize submodules
echo "Initializing submodules..."
git submodule update --init --recursive

# Install dependencies
# Use --no-build-isolation to allow access to torch during build (needed for curope)
# CRITICAL: Pass CUDA_HOME and CPATH explicitly to pip install for CUDA extension builds
echo "Installing thirdparty/mast3r (with curope CUDA extension)..."
CUDA_HOME=$CONDA_PREFIX CPATH=$CONDA_PREFIX/targets/x86_64-linux/include pip install --no-build-isolation -e thirdparty/mast3r

# Install imgui from PyPI first (the local pyimgui in thirdparty/in3d fails to build)
# This provides pre-built binaries that work correctly
echo "Installing imgui from PyPI (pre-built)..."
pip install imgui[glfw]

# Install in3d without dependencies (to avoid the broken local imgui)
# Then install the remaining dependencies manually
echo "Installing thirdparty/in3d (skipping broken local imgui)..."
pip install --no-deps -e thirdparty/in3d

# Install in3d dependencies (except imgui which is already installed)
echo "Installing in3d dependencies..."
pip install PyOpenGL PyOpenGL_accelerate glfw pyglm trimesh pillow moderngl==5.12.0 moderngl-window==2.4.6 msgpack

# Install MASt3R-SLAM (includes lietorch CUDA extension)
echo "Installing MASt3R-SLAM..."
CUDA_HOME=$CONDA_PREFIX CPATH=$CONDA_PREFIX/targets/x86_64-linux/include pip install --no-build-isolation -e .

# Optional: torchcodec for faster mp4 loading
echo "Installing torchcodec (optional)..."
pip install torchcodec==0.1 || echo "Warning: torchcodec installation failed (optional)"

# Download checkpoints
echo "Downloading checkpoints..."
mkdir -p checkpoints/

CHECKPOINT_BASE="https://download.europe.naverlabs.com/ComputerVision/MASt3R"
CHECKPOINTS=(
    "MASt3R_ViTLarge_BaseDecoder_512_catmlpdpt_metric.pth"
    "MASt3R_ViTLarge_BaseDecoder_512_catmlpdpt_metric_retrieval_trainingfree.pth"
    "MASt3R_ViTLarge_BaseDecoder_512_catmlpdpt_metric_retrieval_codebook.pkl"
)

for ckpt in "${CHECKPOINTS[@]}"; do
    if [ -f "checkpoints/$ckpt" ]; then
        echo "  $ckpt already exists, skipping..."
    else
        echo "  Downloading $ckpt..."
        wget -q --show-progress "$CHECKPOINT_BASE/$ckpt" -P checkpoints/
    fi
done

echo ""
echo "=== Installation Complete ==="
echo "To use MASt3R-SLAM:"
echo "  conda activate mast3r-slam"
echo "  python main.py --dataset <path/to/folder> --config config/base.yaml"
