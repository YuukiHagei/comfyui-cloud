#!/usr/bin/env bash
# =============================================================================
# 葉藝 · ComfyUI 云端部署（T4 16GB）
#   Cloud Studio / 国内：  MIRROR=cn bash install-comfyui-t4.sh
#   Colab / 国际：         MIRROR=global bash install-comfyui-t4.sh
#
# 特性：
#   · 分步可重入 —— 任何一步失败，修好再跑同一条命令即可（不会重复下载已完成的）
#   · pip 用国内镜像（tsinghua），torch 失败时自动回退官方源
#   · 模型下载断点续传
#
# 常用开关（环境变量）：
#   PIP_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple
#   SKIP_PIP=1        跳过 python 依赖（只补模型）
#   SKIP_MODELS=1     跳过模型（只装环境）
#   MODELS_ONLY=1     等于 SKIP_PIP=1（只下模型）
#   SKIP_PIXEL=1      不装像素 LoRA（省 160 MB）
#   SKIP_CHIBI2=1     不装第二个 Q 版 LoRA（省 35 MB）
#   ROOT=/workspace/ye-comfyui   安装位置
# =============================================================================
set -uo pipefail

MIRROR="${MIRROR:-cn}"
if [ -z "${ROOT:-}" ]; then
  if [ -d /workspace ]; then ROOT=/workspace/ye-comfyui; else ROOT="$HOME/ye-comfyui"; fi
fi
PORT="${PORT:-8188}"
PY="${PY:-python3}"
PIP_INDEX="${PIP_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}"

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()  { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[1;31m✗\033[0m %s\n' "$*"; }
FAILED=()

# ---- 镜像 ----------------------------------------------------------------
if [ "$MIRROR" = "cn" ]; then
  GH="https://gh-proxy.com/https://github.com"
  HF="https://hf-mirror.com"
  MS="https://modelscope.cn/api/v1/models"
else
  GH="https://github.com"
  HF="https://huggingface.co"
  MS=""
fi

say "0/7 环境检查（镜像=$MIRROR  目录=$ROOT）"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo "  ⚠ 看不到 GPU（nvidia-smi 不可用）"
command -v git >/dev/null || { apt-get update -qq && apt-get install -y -qq git; }
$PY -m venv --help >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq python3-venv; }
mkdir -p "$ROOT"

say "1/7 拉取 ComfyUI"
if [ -d "$ROOT/ComfyUI/.git" ]; then
  ok "已存在：$ROOT/ComfyUI"
else
  git clone --depth 1 "$GH/comfyanonymous/ComfyUI.git" "$ROOT/ComfyUI" \
    && ok "克隆完成" || { bad "克隆失败"; FAILED+=("clone"); }
fi

if [ "${SKIP_PIP:-0}" != "1" ] && [ "${MODELS_ONLY:-0}" != "1" ]; then
  say "2/7 安装 Python 依赖（pip 源：$PIP_INDEX）"
  [ -d "$ROOT/venv" ] || $PY -m venv "$ROOT/venv"
  # shellcheck disable=SC1091
  source "$ROOT/venv/bin/activate"
  pip install -q --upgrade pip -i "$PIP_INDEX" 2>/dev/null || pip install -q --upgrade pip

  # torch：先走国内 PyPI（Linux 的 torch 轮子自带 CUDA 运行库）
  if python -c "import torch" 2>/dev/null; then
    ok "torch 已安装：$(python -c 'import torch;print(torch.__version__)')"
  else
    echo "  正在安装 torch（约 800 MB–2 GB，耐心等）…"
    if pip install -q torch torchvision torchaudio -i "$PIP_INDEX"; then
      ok "torch（国内源）安装完成"
    else
      bad "国内源失败，改用官方 cu121 源重试"
      pip install -q torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121 \
        && ok "torch（官方源）安装完成" || FAILED+=("torch")
    fi
  fi

  echo "  正在安装 ComfyUI 依赖…"
  if pip install -q -r "$ROOT/ComfyUI/requirements.txt" -i "$PIP_INDEX"; then
    ok "requirements 安装完成"
  else
    bad "requirements 失败，改用默认源重试"
    pip install -q -r "$ROOT/ComfyUI/requirements.txt" && ok "requirements 安装完成" || FAILED+=("requirements")
  fi

  # 关键包自检
  for mod in yaml torch aiohttp; do
    if python -c "import $mod" 2>/dev/null; then ok "import $mod"; else bad "import $mod 失败"; FAILED+=("import:$mod"); fi
  done
fi

say "3/7 安装 IPAdapter 节点"
NODE="$ROOT/ComfyUI/custom_nodes/ComfyUI_IPAdapter_plus"
if [ -d "$NODE" ]; then ok "已存在"; else
  git clone --depth 1 "$GH/cubiq/ComfyUI_IPAdapter_plus.git" "$NODE" \
    && ok "已安装" || { bad "节点安装失败"; FAILED+=("ipadapter-node"); }
fi

if [ "${SKIP_MODELS:-0}" != "1" ]; then
  say "4/7 下载模型（约 10 GB，断点续传）"
  M="$ROOT/ComfyUI/models"
  mkdir -p "$M/checkpoints" "$M/loras" "$M/ipadapter" "$M/clip_vision"
  dl() { # dl <url> <目标> <预期MB> <名称>
    local url="$1" out="$2" mb="$3" name="$4" have
    if [ -f "$out" ] && [ "$(du -m "$out" | cut -f1)" -gt $((mb * 9 / 10)) ]; then
      ok "$name 已存在"; return 0
    fi
    echo "  ↓ $name（约 ${mb} MB）"
    if curl -fL --retry 5 --retry-delay 3 -C - --progress-bar -o "$out.part" "$url"; then
      mv "$out.part" "$out"; ok "$name 完成"
    else
      bad "$name 下载失败"; rm -f "$out.part"; FAILED+=("model:$name")
    fi
  }

  if [ "$MIRROR" = "cn" ]; then
    dl "$MS/AI-ModelScope/stable-diffusion-xl-base-1.0/repo?Revision=master&FilePath=sd_xl_base_1.0.safetensors" \
       "$M/checkpoints/sd_xl_base_1.0.safetensors" 6617 "SDXL base 1.0"
    dl "$MS/AI-ModelScope/IP-Adapter/repo?Revision=master&FilePath=sdxl_models%2Fip-adapter-plus_sdxl_vit-h.safetensors" \
       "$M/ipadapter/ip-adapter-plus_sdxl_vit-h.safetensors" 808 "IPAdapter plus SDXL"
    dl "$MS/AI-ModelScope/IP-Adapter/repo?Revision=master&FilePath=models%2Fimage_encoder%2Fmodel.safetensors" \
       "$M/clip_vision/CLIP-ViT-H-14-laion2B.safetensors" 2411 "CLIP-ViT-H"
  else
    dl "$HF/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors" \
       "$M/checkpoints/sd_xl_base_1.0.safetensors" 6617 "SDXL base 1.0"
    dl "$HF/h94/IP-Adapter/resolve/main/sdxl_models/ip-adapter-plus_sdxl_vit-h.safetensors" \
       "$M/ipadapter/ip-adapter-plus_sdxl_vit-h.safetensors" 808 "IPAdapter plus SDXL"
    dl "$HF/h94/IP-Adapter/resolve/main/models/image_encoder/model.safetensors" \
       "$M/clip_vision/CLIP-ViT-H-14-laion2B.safetensors" 2411 "CLIP-ViT-H"
  fi
  [ "${SKIP_PIXEL:-0}" = "1" ] || \
  dl "$HF/nerijs/pixel-art-xl/resolve/main/pixel-art-xl.safetensors" \
     "$M/loras/pixel-art-xl.safetensors" 160 "像素 LoRA"
  dl "$HF/K666K/SDXL_chibi_flat/resolve/main/SDXL_styl-z-000004.safetensors" \
     "$M/loras/chibi-flat-2d-xl.safetensors" 210 "Q版 LoRA（flat2d）"
  [ "${SKIP_CHIBI2:-0}" = "1" ] || \
  dl "$HF/trappy/ChibiArtStyle/resolve/main/output/chibiArtstyle_10.safetensors" \
     "$M/loras/chibi-artstyle-xl.safetensors" 35 "Q版 LoRA（artstyle）"
else
  say "4/7 跳过模型下载（SKIP_MODELS=1）"
fi

say "5/7 放入工作流与参考图"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M="$ROOT/ComfyUI/models"
mkdir -p "$ROOT/workflows" "$ROOT/ComfyUI/input"
[ -d "$SELF_DIR/workflows" ] && cp -f "$SELF_DIR"/workflows/*.json "$ROOT/workflows/" 2>/dev/null
[ -d "$SELF_DIR/refs" ] && cp -f "$SELF_DIR"/refs/* "$ROOT/ComfyUI/input/" 2>/dev/null
ok "工作流 → $ROOT/workflows；参考图 → $ROOT/ComfyUI/input"

say "6/7 自检"
for f in \
  "$M/checkpoints/sd_xl_base_1.0.safetensors" \
  "$M/ipadapter/ip-adapter-plus_sdxl_vit-h.safetensors" \
  "$M/clip_vision/CLIP-ViT-H-14-laion2B.safetensors" ; do
  if [ -s "$f" ]; then ok "$(basename "$f") $(du -m "$f" | cut -f1) MB"; else bad "缺 $(basename "$f")"; FAILED+=("missing:$(basename "$f")"); fi
done
ls -1 "$M/loras" 2>/dev/null | sed 's/^/  LoRA: /' || true

say "7/7 结果"
if [ "${#FAILED[@]}" -eq 0 ]; then
  printf '  \033[1;32m全部完成 ✓\033[0m\n\n'
  echo "  启动：cd $ROOT/ComfyUI && $ROOT/venv/bin/python main.py --listen 0.0.0.0 --port $PORT"
else
  printf '  \033[1;31m有失败项：%s\033[0m\n' "${FAILED[*]}"
  echo "  修好后重跑本脚本即可（已完成的会跳过）：MIRROR=$MIRROR ROOT=$ROOT bash $0"
fi
