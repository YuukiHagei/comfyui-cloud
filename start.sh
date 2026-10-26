#!/usr/bin/env bash
# =============================================================================
# 容器入口：按需下载模型 → 启动 ComfyUI
#
# 环境变量：
#   PORT=8188              监听端口（Cloud Studio 会注入它自己的 PORT）
#   SKIP_PIXEL=1           跳过像素 LoRA（省 160 MB）
#   SKIP_CHIBI2=1          跳过第二个 Q 版 LoRA（省 35 MB）
#   FORCE_MODELS=1         即使文件存在也重新下载
#   HF_ENDPOINT            LoRA 下载源，默认 hf-mirror.com
# =============================================================================
set -uo pipefail

MS="https://modelscope.cn/api/v1/models"
HF="${HF_ENDPOINT:-https://hf-mirror.com}"
M="/app/ComfyUI/models"
PORT="${PORT:-8188}"

log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
dl() { # dl <url> <目标> <预期MB> <名称>
  local url="$1" out="$2" mb="$3" name="$4"
  if [ "${FORCE_MODELS:-0}" != "1" ] && [ -f "$out" ]; then
    local have; have=$(du -m "$out" | cut -f1 2>/dev/null || echo 0)
    if [ "$have" -gt $((mb * 90 / 100)) ]; then log "$name 已就绪（${have} MB）"; return 0; fi
  fi
  log "下载 $name（约 ${mb} MB）"
  curl -fL --retry 5 --retry-delay 3 -C - --progress-bar -o "$out.part" "$url" \
    && mv "$out.part" "$out" || { rm -f "$out.part"; log "✗ $name 下载失败，继续（缺模型时出图会报错）"; }
}

mkdir -p "$M"/{checkpoints,loras,ipadapter,clip_vision}

log "1/2 模型检查"
dl "$MS/AI-ModelScope/stable-diffusion-xl-base-1.0/repo?Revision=master&FilePath=sd_xl_base_1.0.safetensors" \
   "$M/checkpoints/sd_xl_base_1.0.safetensors" 6617 "SDXL base 1.0"
dl "$MS/AI-ModelScope/IP-Adapter/repo?Revision=master&FilePath=sdxl_models%2Fip-adapter-plus_sdxl_vit-h.safetensors" \
   "$M/ipadapter/ip-adapter-plus_sdxl_vit-h.safetensors" 808 "IPAdapter plus SDXL (ViT-H)"
dl "$MS/AI-ModelScope/IP-Adapter/repo?Revision=master&FilePath=models%2Fimage_encoder%2Fmodel.safetensors" \
   "$M/clip_vision/CLIP-ViT-H-14-laion2B.safetensors" 2411 "CLIP-ViT-H 视觉编码器"
[ "${SKIP_PIXEL:-0}" = "1" ] || \
dl "$HF/nerijs/pixel-art-xl/resolve/main/pixel-art-xl.safetensors" \
   "$M/loras/pixel-art-xl.safetensors" 160 "像素 LoRA"
dl "$HF/K666K/SDXL_chibi_flat/resolve/main/SDXL_styl-z-000004.safetensors" \
   "$M/loras/chibi-flat-2d-xl.safetensors" 210 "Q版 LoRA（flat 2d）"
[ "${SKIP_CHIBI2:-0}" = "1" ] || \
dl "$HF/trappy/ChibiArtStyle/resolve/main/output/chibiArtstyle_10.safetensors" \
   "$M/loras/chibi-artstyle-xl.safetensors" 35 "Q版 LoRA（artstyle）"

if [ ! -s "$M/checkpoints/sd_xl_base_1.0.safetensors" ]; then
  log "⚠ 没有 SDXL 底模 —— 服务照常起来，但出图会失败。检查网络后重启容器即可（支持续传）"
fi

log "2/2 启动 ComfyUI :$PORT"
cd /app/ComfyUI
exec python main.py --listen 0.0.0.0 --port "$PORT"
