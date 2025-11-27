# Base image
FROM nvidia/cuda:12.8.0-devel-ubuntu22.04

# Set working directory
WORKDIR /app

# Install git and other dependencies
RUN apt-get update && apt-get install -y git wget libgl1 libglib2.0-0

# Install Miniconda
RUN wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O miniconda.sh && \
    bash miniconda.sh -b -p /opt/conda && \
    rm miniconda.sh
ENV PATH=/opt/conda/bin:$PATH

# Create a conda environment with Python 3.12
RUN conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main 
RUN conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
RUN conda create -n comfyui python=3.13 -y
SHELL ["conda", "run", "-n", "comfyui", "/bin/bash", "-c"]

# Install PyTorch
RUN pip install torch==2.7.1 torchvision==0.22.1 torchaudio==2.7.1 --index-url https://download.pytorch.org/whl/cu128


RUN git clone https://github.com/comfyanonymous/ComfyUI.git

WORKDIR /app/ComfyUI
RUN pip install -r requirements.txt

WORKDIR /app/ComfyUI/custom_nodes
COPY vertex-ai-comfyui-nodes/ ./vertex-ai-comfyui-nodes
RUN cd vertex-ai-comfyui-nodes && pip install -r requirements.txt
WORKDIR /app/ComfyUI/custom_nodes
RUN git clone https://github.com/ltdrdata/ComfyUI-Manager comfyui-manager
RUN cd comfyui-manager && pip install -r requirements.txt

WORKDIR /app/ComfyUI
COPY start.sh .
COPY user-watch.py .
# CMD ["conda", "run", "--no-capture-output", "-n", "comfyui", "python", "/app/ComfyUI/main.py", "--listen", "0.0.0.0"]
# CMD ["conda", "run", "--no-capture-output", "-n", "comfyui", "python", "/app/ComfyUI/main.py". "--cpu", "--listen", "0.0.0.0"]
CMD ["tail", "-f", "/dev/null"]