#!/usr/bin/env bash
# =============================================================================
# 葉藝 · ComfyUI 云端一键部署（T4 16GB 适用）
#   腾讯云 Cloud Studio（国内，ModelScope 直连）：  MIRROR=cn bash install-comfyui-t4.sh
#   Google Colab（国际，HuggingFace 直连）：        MIRROR=global bash install-comfyui-t4.sh
#
# 装什么：
#   · ComfyUI（最新版）
#   · ComfyUI_IPAdapter_plus 自定义节点
#   · SDXL base 1.0 + 像素 LoRA + 两个 Q 版 LoRA
#   · IPAdapter plus SDXL(ViT-H) + CLIP-ViT-H 视觉编码器
# 总共约 10 GB 下载；装完即可跑 workflows/ 里的三个工作流。
# =============================================================================
set -euo pipefail

MIRROR="${MIRROR:-cn}"          # cn | global
ROOT="${ROOT:-$HOME/ye-comfyui}"
PORT="${PORT:-8188}"
PY="${PY:-python3}"

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

# ---- 下载地址按镜像切换 -----------------------------------------------------
if [ "$MIRROR" = "cn" ]; then
  GH="https://gh-proxy.com/https://github.com"
  HF="https://hf-mirror.com"
  # ModelScope 的 IPAdapter 仓库（国内速度好）
  MS_IPADAPTER="https://modelscope.cn/api/v1/models/AI-ModelScope/IP-Adapter/repo?Revision=master&FilePath="
else
  GH="https://github.com"
  HF="https://huggingface.co"
  MS_IPADAPTER=""
fi

say "0/6 环境检查（镜像=$MIRROR，目录=$ROOT）"
command -v git >/dev/null || { apt-get update -qq && apt-get install -y -qq git; }
$PY -m venv --help >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq python3-venv; }
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader || true
mkdir -p "$ROOT"

say "1/6 拉取 ComfyUI"
if [ ! -d "$ROOT/ComfyUI/.git" ]; then
  git clone --depth 1 "$GH/comfyanonymous/ComfyUI.git" "$ROOT/ComfyUI"
else
  echo "已存在，跳过"
fi

say "2/6 建 venv 并安装依赖（T4 → cu121）"
cd "$ROOT/ComfyUI"
if [ ! -d "$ROOT/venv" ]; then
  $PY -m venv "$ROOT/venv"
fi
# shellcheck disable=SC1091
source "$ROOT/venv/bin/activate"
pip install -q --upgrade pip
pip install -q torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install -q -r requirements.txt

say "3/6 安装 IPAdapter 节点"
if [ ! -d "$ROOT/ComfyUI/custom_nodes/ComfyUI_IPAdapter_plus" ]; then
  git clone --depth 1 "$GH/cubiq/ComfyUI_IPAdapter_plus.git" "$ROOT/ComfyUI/custom_nodes/ComfyUI_IPAdapter_plus"
fi

say "4/6 下载模型（约 10 GB，慢的话去喝杯茶）"
M="$ROOT/ComfyUI/models"
mkdir -p "$M/checkpoints" "$M/loras" "$M/ipadapter" "$M/clip_vision"

dl() { # dl <url> <目标文件> <预期 MB>
  local url="$1" out="$2" mb="$3"
  if [ -f "$out" ] && [ "$(du -m "$out" | cut -f1)" -gt $((mb * 9 / 10)) ]; then
    echo "  已存在：$(basename "$out")"; return
  fi
  echo "  ↓ $(basename "$out")（约 ${mb} MB）"
  curl -L --retry 5 --retry-delay 3 -C - -sS -o "$out.part" "$url"
  mv "$out.part" "$out"
}

# SDXL 底模
if [ "$MIRROR" = "cn" ]; then
  dl "https://modelscope.cn/api/v1/models/AI-ModelScope/stable-diffusion-xl-base-1.0/repo?Revision=master&FilePath=sd_xl_base_1.0.safetensors" \
     "$M/checkpoints/sd_xl_base_1.0.safetensors" 6500
else
  dl "$HF/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors" \
     "$M/checkpoints/sd_xl_base_1.0.safetensors" 6500
fi

# 风格 LoRA
dl "$HF/nerijs/pixel-art-xl/resolve/main/pixel-art-xl.safetensors" \
   "$M/loras/pixel-art-xl.safetensors" 160
dl "$HF/K666K/SDXL_chibi_flat/resolve/main/SDXL_styl-z-000004.safetensors" \
   "$M/loras/chibi-flat-2d-xl.safetensors" 210
dl "$HF/trappy/ChibiArtStyle/resolve/main/output/chibiArtstyle_10.safetensors" \
   "$M/loras/chibi-artstyle-xl.safetensors" 35

# IPAdapter（SDXL ViT-H）
if [ "$MIRROR" = "cn" ]; then
  dl "${MS_IPADAPTER}sdxl_models%2Fip-adapter-plus_sdxl_vit-h.safetensors" \
     "$M/ipadapter/ip-adapter-plus_sdxl_vit-h.safetensors" 808
  dl "${MS_IPADAPTER}models%2Fimage_encoder%2Fmodel.safetensors" \
     "$M/clip_vision/CLIP-ViT-H-14-laion2B.safetensors" 2411
else
  dl "$HF/h94/IP-Adapter/resolve/main/sdxl_models/ip-adapter-plus_sdxl_vit-h.safetensors" \
     "$M/ipadapter/ip-adapter-plus_sdxl_vit-h.safetensors" 808
  dl "$HF/h94/IP-Adapter/resolve/main/models/image_encoder/model.safetensors" \
     "$M/clip_vision/CLIP-ViT-H-14-laion2B.safetensors" 2411
fi

say "5/6 放入工作流与参考图"
mkdir -p "$M/../input"
if [ -d "$(dirname "$0")/workflows" ]; then
  mkdir -p "$ROOT/workflows"
  cp -f "$(dirname "$0")"/workflows/*.json "$ROOT/workflows/" 2>/dev/null || true
fi
if [ -d "$(dirname "$0")/refs" ]; then
  cp -f "$(dirname "$0")"/refs/* "$M/../input/" 2>/dev/null || true
fi
echo "  工作流在 $ROOT/workflows，参考图在 ComfyUI/input"

say "6/6 启动"
echo "  前台启动： cd $ROOT/ComfyUI && source $ROOT/venv/bin/activate && $PY main.py --listen 0.0.0.0 --port $PORT"
echo "  16GB 显存不需要 --lowvram；要外网访问就再开一个隧道（见 README）"
echo
echo "  ✓ 装完了。想让我从 DSH 直接驱动，把 DSH 的 ComfyUI 地址改成你的公网隧道地址即可。"
