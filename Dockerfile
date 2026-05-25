# MASt3R-SLAM Podman image
# Built and run by SAL's runtime-stress framework via MASt3RSLAMAlgorithm
# wrapper at src/algorithms/mast3rslam.py. See docs/MAST3R_SLAM_PODMAN.md
# for the operator-side build / run / troubleshooting guide.
#
# Notes for future maintainers:
# - MASt3R-SLAM compiles native CUDA extensions in three places:
#     * mast3r_slam_backends (root setup.py, gn_kernels.cu + matching_kernels.cu)
#     * lietorch (git dep from princeton-vl; compiles SE3/Sim3 CUDA kernels)
#     * thirdparty/mast3r/dust3r/croco/models/curope (rotary-position-embedding CUDA kernels)
#   The base image must be -devel (provides nvcc) and the strip step below
#   wipes prebuilt artifacts so the in-container PyTorch ABI is the one used.
# - CUDA 11.8 matches DROID-SLAM and Photo-SLAM (which both build HAMi-bindable
#   images on this host) and is the first option upstream MASt3R-SLAM lists in
#   its README. The `install_all.sh` script bumps to CUDA 12.4 to grab CCCL's
#   libcu++ headers, but the actual CUDA sources (curope/kernels.cu,
#   mast3r_slam/backend/src/*.cu) only #include <cuda.h>/<cuda_runtime.h>;
#   they do not reference cuda::std/limits or any libcu++ feature.
# - The MASt3R foundation-model checkpoints (~2.9 GB) are NOT copied into
#   the image. They live in deps/slam-algorithms/MASt3R-SLAM/checkpoints
#   on the host and are bind-mounted read-only at runtime by the wrapper.
#   Bundling them would balloon the image from ~12 GB to ~15 GB with no
#   functional gain.
# - Build time: ~25-35 minutes on a typical host; one-time per host.
#   Dominated by the lietorch + curope + mast3r_slam_backends CUDA compiles.
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    TORCH_CUDA_ARCH_LIST="7.0;7.5;8.0;8.6;8.9;9.0"

# Python 3.11 (required by MASt3R-SLAM's pyproject.toml; PyTorch 2.5.1
# cu118 wheels are available for cp311 on PyPI's PyTorch index).
# OpenGL libs (libglfw3 / mesa / GL) are needed at *import time* because
# main.py top-imports mast3r_slam.visualization which pulls in moderngl
# and moderngl-window. Without these libs, ``python main.py --no-viz``
# crashes at the first import even though no window is opened.
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3.11 python3.11-venv python3.11-dev python3-pip \
        git build-essential cmake ninja-build pkg-config \
        libeigen3-dev libsuitesparse-dev libopencv-dev \
        libglfw3 libglfw3-dev \
        libgl1-mesa-glx libegl1 libgles2-mesa libxrandr2 libxinerama1 \
        libxcursor1 libxi6 libxxf86vm1 libosmesa6 \
        wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN ln -sf /usr/bin/python3.11 /usr/bin/python && \
    ln -sf /usr/bin/python3.11 /usr/bin/python3

# pip for python3.11 (the apt python3-pip uses /usr/bin/python3 which is
# already symlinked, but ensure the pip module path is current).
RUN python -m ensurepip --upgrade && \
    python -m pip install --no-cache-dir --upgrade pip setuptools wheel

# PyTorch 2.5.1 + torchvision 0.20.1 + torchaudio 2.5.1 from the CUDA
# 11.8 wheel index. Matches the first option in upstream MASt3R-SLAM's
# README install table.
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cu118 \
        torch==2.5.1 torchvision==0.20.1 torchaudio==2.5.1

WORKDIR /mast3r-slam
COPY . /mast3r-slam

# Strip prebuilt CUDA artifacts from the host build (they are tied to
# the host's CUDA / glibc / PyTorch ABI and would conflict with the
# in-container compile against PyTorch 2.5.1+cu118). The bundled
# mast3r_slam_backends.cpython-311-x86_64-linux-gnu.so is removed so
# `pip install -e .` rebuilds against the in-container PyTorch.
RUN rm -rf build *.so mast3r_slam_backends*.so \
        thirdparty/in3d/build thirdparty/in3d/*.egg-info \
        thirdparty/mast3r/build thirdparty/mast3r/*.egg-info \
        thirdparty/mast3r/asmk/build thirdparty/mast3r/asmk/*.egg-info \
        thirdparty/mast3r/dust3r/croco/models/curope/build \
        thirdparty/mast3r/dust3r/croco/models/curope/*.egg-info

# Install thirdparty/mast3r first (carries the curope CUDA extension +
# asmk Cython package). --no-build-isolation lets the curope build
# script import torch during compile.
RUN pip install --no-cache-dir --no-build-isolation -e thirdparty/mast3r

# Install imgui from PyPI (the local pyimgui in thirdparty/in3d fails
# to build in the container the same way it does on the host).
# Then install in3d without deps so it picks up the PyPI imgui.
RUN pip install --no-cache-dir 'imgui[glfw]'

RUN pip install --no-cache-dir --no-deps -e thirdparty/in3d

# in3d's deps explicitly minus the broken imgui.
RUN pip install --no-cache-dir \
        PyOpenGL PyOpenGL_accelerate glfw pyglm trimesh pillow \
        moderngl==5.12.0 moderngl-window==2.4.6 msgpack

# Patch root setup.py: upstream uses ``torch.cuda.is_available()`` to gate
# the CUDA-extension definition, but that returns False inside a Podman
# build (no GPU exposed during build). Force-enable so the extension is
# always defined; the actual compile only needs nvcc, not a live device.
RUN sed -i 's|has_cuda = torch.cuda.is_available()|has_cuda = True  # SAL patch: GPU-less container build|' setup.py

# Install MASt3R-SLAM root: brings in the lietorch git dep (compiles
# its own CUDA extension) + the mast3r_slam_backends CUDA extension
# from the root setup.py. --no-build-isolation lets the setup.py
# import torch during ext compile.
RUN pip install --no-cache-dir --no-build-isolation -e .

# torchcodec is upstream-optional (used for faster mp4 loading); skip
# the install so the image doesn't fail on the pin (torchcodec==0.1
# binds to specific torch/ffmpeg combos and isn't published for all
# torch builds). MASt3R-SLAM falls back to opencv for video reads.

# The mast3r_slam_backends .so links against PyTorch's libc10/libtorch.
# Python's extension loader doesn't auto-add torch's lib dir to
# LD_LIBRARY_PATH at import time, so set it here so the import chain
# (mast3r_slam_backends → lietorch → torch) resolves cleanly.
ENV LD_LIBRARY_PATH=/usr/local/lib/python3.11/dist-packages/torch/lib:${LD_LIBRARY_PATH}

# Provide a writable cache dir for moderngl-window's resource loader.
RUN mkdir -p /root/.cache/torch/hub /mast3r-slam/logs

CMD ["python", "main.py", "--help"]
