# 葉藝 · ComfyUI 云端镜像

给 **T4 16GB**（腾讯云 Cloud Studio 等）用的 ComfyUI 部署仓库：SDXL + IPAdapter + 像素/Q版 LoRA，
**模型在首次启动时下载**（约 10 GB，走 ModelScope 国内源），所以镜像本身只有基础环境。

## 里面有什么

| 路径 | 说明 |
|---|---|
| `Dockerfile` | 基于 `pytorch/pytorch:2.6.0-cuda12.4`，装 ComfyUI + IPAdapter 节点 |
| `start.sh` | 容器入口：缺模型就下载 → 启动 ComfyUI（监听 `$PORT`，默认 8188）|
| `install-comfyui-t4.sh` | 不走容器、在**工作空间**里直接装（`MIRROR=cn`）|
| `cloud-setup.sh` | 已有 ComfyUI（模板自带）时，只往里补模型和节点 |
| `workflows/*.api.json` | 三个工作流：Q版 / 像素化 / 插画（API 格式，可 POST 到 `/prompt`）|
| `refs/*` | 参考图：立绘（长边 1536）/ 插画 / 头像 / 惊讶表情 / 吧唧工程图 |

## 部署方式一：Cloud Studio「从 Git 仓库导入」

1. Cloud Studio → 创建应用 → **从 Git 仓库导入** → 填 `https://github.com/YuukiHagei/comfyui-cloud`
2. 应用标题随意；**实例规格务必选 GPU（T4 16GB）**
3. 首次构建约 10–15 分钟（拉 Python/CUDA 基础镜像 + ComfyUI 依赖）
4. 启动后容器会先下载 10 GB 模型（约 5–15 分钟），日志会逐项打印进度
5. 应用对外端口填 **8188**

> ⚠️ 免费额度是按「工作空间」还是「应用」扣，以你控制台为准；应用形态如果只给 CPU，SDXL 会慢到没法用。

## 部署方式二：工作空间（推荐，最可控）

新建 **Ubuntu 22.04 / PyTorch** 工作空间（别选 ComfyUI 模板），终端里：

```bash
git clone https://github.com/YuukiHagei/comfyui-cloud.git
cd comfyui-cloud
MIRROR=cn bash install-comfyui-t4.sh
# 装完启动
cd ~/ye-comfyui/ComfyUI && source ~/ye-comfyui/venv/bin/activate
python main.py --listen 0.0.0.0 --port 8188
```

工作空间有终端、有持久盘、T4 额度也是它的 —— 这条路最不容易踩坑。

## 接口与鉴权

ComfyUI 起来后是**裸接口**（没有登录）。两个选择：

- 只在 Cloud Studio 内网/自己看：保持裸接口
- 要暴露到公网：**务必**加一层鉴权（用 `comfyui-login` 之类节点，或在网关层加 Basic Auth）
- 若走带 `api_key` 的登录节点：请求时带 `x-api-key: <key>` 头即可（兼容 `Authorization: Bearer`）

## 三个工作流

| 文件 | 用途 | 关键参数 |
|---|---|---|
| `ye_chibi_ipadapter.api.json` | Q版（IPAdapter 锁人设）| LoRA 0.85 · IPAdapter 0.9 · 1024² |
| `ye_pixel_i2i.api.json` | 像素化（参考插画 img2img）| LoRA 0.9 · denoise 0.55 |
| `ye_illu_ipadapter.api.json` | 插画（IPAdapter）| IPAdapter 0.8 · 832×1216 |

提交方式（任意语言）：

```bash
curl -X POST "http://<host>:8188/prompt" \
  -H 'content-type: application/json' \
  -d "{\"prompt\": $(cat workflows/ye_chibi_ipadapter.api.json), \"client_id\": \"me\"}"
# 然后轮询 /history/<prompt_id>，用 /view?filename=... 取图
```

## 调参经验（本机 8GB 4060 实测）

- **颜色漂**：降 `denoise`（0.55 → 0.38）+ 降 LoRA 权重（0.9 → 0.7）
- **人设漂**：升 IPAdapter 权重（0.8 → 0.95），把「绿眼睛 / 棕外套」写进负向词
- **想要 100% 忠实颜色的像素图**：别用 AI，Pillow 降采样 + 限色（32 色）+ 整数放大，<1 秒
- **服装不准**：正向词里把服装放到最前面，或用真实立绘做 img2img（0.4–0.5）

## 注意

- 模型不进 Git（单文件 >100 MB 推不上去），全部运行时下载
- 免费实例被回收后，容器内模型会丢，重启会重新下载（`curl -C -` 支持续传）
- 别把公开地址贴出去，ComfyUI 默认无鉴权

---

## 人设基准（2026-10-26 定）

**基准参考图：`refs/ye_ref_illu.png`（参考插画，藕紫暖调）**

| 主色 | 值 |
|---|---|
| 藕紫 | `#866477` |
| 粉紫 | `#CBABC7` |
| 淡粉 | `#EAD0D0` |
| 米白 | `#F8E6D8` |
| 暖白 | `#FFF3E1` |

（参考立绘是**灰调** `#645D61/#8D8899`，与插画色板明显不同，只用它作结构参考。）

**关键经验：提示词里不要写服装/发色/瞳色。** 颜色交给 IPAdapter 从参考图带；
文字描述颜色会与参考图色板互相拉扯，实测反而更偏。

三套参数与实测色差（越小越贴基准）：

| 工作流 | 方式 | LoRA | IPAdapter | denoise | 色差 |
|---|---|---|---|---|---|
| `ye_pixel_i2i` | img2img（原图出发）| pixel 0.9 | — | 0.55 | **7.0** |
| `ye_illu_ipadapter` | 文生图 | — | 0.95 ease in | 1.0 | 16.0 |
| `ye_chibi_ipadapter` | 文生图 | chibi 0.75 | 1.05 ease in | 1.0 | 17.4 |

要 100% 保色：优先用 `ye_pixel_i2i`（img2img），或对生成图做调色板量化（quantize 到上表 5 色）。
