# LiveAgent for CentOS 7

把 [LiveAgent](https://github.com/Stack-Cairn/LiveAgent) v1.3.0 AppImage 连同它需要的
Ubuntu 24.04 glibc 2.39 / GTK3 / WebKitGTK / Mesa 一起打包，使其能在 CentOS 7
（glibc 2.17、kernel 3.10、无 GPU 的真实 Xfce 桌面）直接安装、启动和使用。

## 原理

| 问题 | 方案 |
| --- | --- |
| CentOS 7 只有 glibc 2.17 | 打包 Ubuntu 24.04 的 `ld-linux` + `libc.so.6`，用 `ld-linux --library-path` 引导应用；再用 `patchelf` 改写 ELF 的 interpreter/RPATH，让 WebKit 子进程也走自带 loader |
| 无 GPU / VNC 桌面 | Mesa 软件渲染（`LIBGL_ALWAYS_SOFTWARE=1` + 自带 DRI/EGL），关闭 WebKit 合成与 DMABUF；**不要**设 `GALLIUM_DRIVER=swrast`（非法值会让 EGL 初始化失败→白屏） |
| GTK/GIO 环境不完整 | 复用 AppImage 自带的 `linuxdeploy-plugin-gtk.sh` hook，不手写 `GTK_PATH` |
| CentOS 7 没有 C.UTF-8 | 打包 glibc 2.39 的 `C.utf8`，启动器只对目标进程设置 `LC_ALL` + `LOCPATH` |

所有修正集中在唯一启动器 [`launcher.sh`](launcher.sh)（tar.gz / Docker / conda 共用）。

### 体积

AppImage 里同一个库存在多份：`lib64/` 的扁平副本与 `usr/lib/` 原文各一份，且 `cp -L`
把 `.so → .so.0 → .so.0.x` 的符号链接链展开成了多份完整文件。`build.sh` 在打包前
（Step 7b）把**字节完全相同**的文件改成硬链接，tar 只存一份：

| | 解包后 | tar.gz |
| --- | --- | --- |
| 去重前 | 901MB | 305MB |
| 去重后 | 496MB | **168MB** |

路径、文件数（624）和权限都不变，运行时行为没有差别（权限不同的文件会被跳过，
硬链接会共享 mode）；静态库/头文件/文档在 AppImage 里本来就没有，没有可删的死重量。

## 产物

| 文件 | 说明 |
| --- | --- |
| `liveagent-centos7-x86_64.tar.gz` | 自包含 bundle（168MB），配 `install.sh` 安装到 `/opt/liveagent` 并注册应用菜单 |
| `liveagent-1.3.0-centos7_0.conda` | conda 包（166MB），`conda install` 后自动 patchelf 到当前 prefix |
| `liveagent-1.3.0-Linux-x86_64.sh` | constructor 自解压安装器（218MB，含 conda 运行时） |

## 构建

```bash
# 1) tar.gz（Ubuntu 24.04，需要 patchelf / squashfs-tools）
bash build.sh

# 或全容器构建
docker build -t liveagent-centos7 . && \
docker create --name tmp liveagent-centos7 && \
docker cp tmp:/output/liveagent-centos7-x86_64.tar.gz . && docker rm tmp

# 2) conda 包 + constructor 安装器（需要 conda-build / conda-index / constructor）
#    先构建一份不做 patchelf 的 bundle：conda 在安装时按 prefix 打补丁
CONDA_BUILD=1 OUTPUT_DIR=output/conda-src bash build.sh
bash conda/build-conda.sh
```

## 安装（CentOS 7 桌面）

```bash
# a) tar.gz：解包到 /opt/liveagent + 应用菜单 + 桌面图标 + /usr/local/bin/liveagent
sudo bash install.sh liveagent-centos7-x86_64.tar.gz

# b) conda
conda install -c ./output/conda-channel liveagent && liveagent

# c) constructor 安装器
bash liveagent-1.3.0-Linux-x86_64.sh -b -p ~/liveagent && ~/liveagent/bin/liveagent
```

> `.desktop` 入口执行的是 `liveagent-centos7.sh`（启动器），**不是** AppImage 的
> `AppRun`——CentOS 7 上必须由启动器设置 glibc/Mesa/locale。

## 验证

```bash
docker build -f Dockerfile.desktop -t liveagent-centos7-desktop .   # 首次构建装完整 Xfce，较慢
bash verify-desktop.sh                        # 验证 tar.gz
bash verify-desktop.sh liveagent-1.3.0-Linux-x86_64.sh   # 验证 constructor 安装器
bash verify-desktop.sh --interactive          # 保留容器，按提示用 noVNC 手动体验
```

在真实的 CentOS 7.9 + Xvnc + Xfce4 + D-Bus 桌面里安装并启动，检查：

1. 安装（tar.gz 走 `install.sh`，`.sh` 走 constructor）与菜单项
2. `xfce4-session` 存活（只有 X server 不算桌面）
3. 主窗口以可用尺寸映射，截图非空白
4. `WebKitWebProcess` 存活、无 EGL/surfaceless abort
5. MCP Bridge + WebSocket 9223
6. 点击输入框→键入→OCR 读回文字（证明鼠标/键盘真的进入 UI）
7. 托盘图标嵌入 Xfce 面板；无 locale 警告

截图输出在 `output/desktop-verify/`。本次改动已在真实桌面跑过：tar.gz **17/17**、
constructor 安装器 **16/16**（安装器不注册菜单项，故少一项）。

> constructor 安装器要求文件名以 `.sh` 结尾，重命名后会被拒绝执行。安装是批处理模式：
> `bash liveagent-1.3.0-Linux-x86_64.sh -b -p ~/liveagent`。

## GitHub Actions

`.github/workflows/ci.yml`，`workflow_dispatch` 触发（填 `tag` 则发布 Release）：

1. **bundle** — 生成 tar.gz（patchelf 到 `/opt/liveagent`）和 conda 用的未打补丁 bundle
2. **conda** — 构建 `.conda` 包 + constructor 安装器，并用 `conda create` 冒烟测试安装钩子（校验 ELF 已按 prefix 打补丁）
3. **verify** — 构建 CentOS 7 桌面镜像，在真实桌面里分别安装并启动 tar.gz 与 `.sh`，上传截图
4. **release** — 上传 tar.gz、`.conda`、`.sh` 及 SHA256 到 Release

```bash
# 只构建 + 验证
gh workflow run build
# 构建 + 验证 + 发布到指定 tag
gh workflow run build -f tag=v1.3.0-centos7
```

## 目录结构

```
├── build.sh                 # bundle 构建（本地/Docker/CI 共用）
├── launcher.sh              # 唯一启动器（glibc/Mesa/locale 修正）
├── install.sh               # tar.gz 安装器（/opt/liveagent + 菜单项）
├── verify-desktop.sh        # 真实桌面端到端验证（tar.gz 或 .sh）
├── Dockerfile               # bundle 构建镜像
├── Dockerfile.desktop       # CentOS 7 桌面验证镜像（Xvnc + Xfce4 + noVNC）
├── docker-desktop-entrypoint.sh
├── desktop/                 # 面板配置 + 容器内启动 helper
├── conda/                   # meta.yaml / build.sh / post-link.sh / build-conda.sh
├── construct.yaml           # constructor 安装器配置
└── .github/workflows/ci.yml
```

## 已知问题

- `libEGL warning: egl: failed to create dri2 screen`：无 GPU 时的预期输出，已回退 llvmpipe，不影响使用
- 窗口标题为空，任务栏显示 "Untitled window"（上游未设置标题）
- `未找到内置浏览器扩展资源`：扩展不随 AppImage 分发，不影响核心功能
- 首次启动未配置模型供应商时是欢迎页，属产品行为
- conda / constructor 安装只提供 CLI（`liveagent`），应用菜单项仅 tar.gz + `install.sh` 提供
