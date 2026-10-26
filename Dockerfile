# syntax=docker/dockerfile:1
# 葉藝 · ComfyUI 云端镜像（T4 16GB 适用）
# 首次启动时才会下载模型（约 10 GB，走 ModelScope 国内源），不进镜像、不进 Git。

FROM pytorch/pytorch:2.6.0-cuda12.4-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HF_ENDPOINT=https://hf-mirror.com

RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl ca-certificates libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ComfyUI 本体
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /app/ComfyUI \
    && cd /app/ComfyUI && pip install -r requirements.txt

# IPAdapter 节点（国内走 gh-proxy，失败则回落官方）
RUN cd /app/ComfyUI/custom_nodes \
    && (git clone --depth 1 https://gh-proxy.com/https://github.com/cubiq/ComfyUI_IPAdapter_plus.git \
        || git clone --depth 1 https://github.com/cubiq/ComfyUI_IPAdapter_plus.git)

COPY start.sh /app/start.sh
COPY workflows /app/workflows
COPY refs /app/refs
RUN chmod +x /app/start.sh \
    && mkdir -p /app/ComfyUI/models/{checkpoints,loras,ipadapter,clip_vision} \
    && cp -f /app/refs/* /app/ComfyUI/input/ 2>/dev/null || true

EXPOSE 8188
CMD ["/app/start.sh"]
