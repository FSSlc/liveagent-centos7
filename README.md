# LiveAgent CentOS 7

自包含的 LiveAgent v1.3.0 CentOS 7 兼容包。

将 [LiveAgent](https://github.com/Stack-Cairn/LiveAgent) AppImage 的所有依赖（包括 Ubuntu 24.04 glibc 2.39）打包，使其可以在 CentOS 7 (glibc 2.17, kernel 3.10) 上运行。

## 技术方案

综合两种技术：

### 1. ld-linux Bootstrap

LiveAgent 的 GTK/WebKit 等库构建于 Ubuntu 24.04，需要 GLIBC_2.34-2.38 符号。CentOS 7 只有 glibc 2.17。

**方案：** 打包 Ubuntu 24.04 的 `ld-linux-x86-64.so.2` + `libc.so.6` 配对，通过 `ld-linux --library-path` 直接调用，绕过系统 glibc。

### 2. patchelf（参考 opencode-centos7）

使用 `patchelf --set-interpreter` 和 `--set-rpath` 修改所有 ELF 二进制文件，使其使用自带的动态链接器和库。

参考：[opencode-centos7](https://github.com/FSSlc/opencode-centos7)

## 构建

**前提：** Ubuntu 24.04（Docker 或本地）

```bash
# 方式 1: 直接构建
bash build.sh

# 方式 2: Docker 构建
docker build -t liveagent-centos7 .
docker create --name tmp liveagent-centos7
docker cp tmp:/output/liveagent-centos7-x86_64.tar.gz .
docker rm tmp
```

产物：`output/liveagent-centos7-x86_64.tar.gz` (~305MB, 236 个库)

## 使用

### 直接安装（tar.gz）

```bash
tar -xzf liveagent-centos7-x86_64.tar.gz -C /opt/liveagent
/opt/liveagent/liveagent-centos7.sh
```

### Conda 安装

```bash
# 构建 conda 包
conda build conda/ -c conda-forge

# 安装
conda install -c ./output/conda-channel liveagent
liveagent
```

### 通过 Constructor 构建独立安装器

```bash
# 构建 .sh 安装器
bash conda/build-conda.sh

# 安装
bash output/liveagent-1.3.0-Linux-x86_64.sh -b -p ~/liveagent
~/liveagent/bin/liveagent
```

## 验证

```bash
# 自动功能验证（需要 Docker）
bash verify-centos7.sh
```

## 文件结构

```
liveagent-centos7/
├── build.sh              # 主构建脚本
├── verify-centos7.sh     # 功能验证脚本
├── Dockerfile            # 独立 Docker 构建
├── construct.yaml        # Conda constructor 配置
├── conda/
│   ├── meta.yaml         # Conda 配方
│   ├── build.sh          # Conda 构建脚本
│   ├── post-install.sh   # 安装后脚本（patchelf + 创建启动器）
│   ├── patch-bundle.sh   # 独立 patchelf 脚本（等同于 post-install.sh）
│   └── build-conda.sh    # 全流程：bundle → conda → constructor
├── .github/workflows/
│   └── liveagent-centos7.yml  # CI/CD 流水线
└── output/               # 构建产物（已 gitignore）
```

## GitHub Actions

触发 `workflow_dispatch`，自动：
1. **Build** — 在 ubuntu-24.04 上构建 bundle（CONDA_BUILD=1，不 patchelf）
2. **Conda Constructor** — 构建 conda 包 + .sh 安装器
3. **Verify** — 在 centos:7 上验证（库解析 + Xvfb 功能测试）
4. **Release** — 上传到 GitHub Release

## 已验证

- ld-linux 2.39 在 CentOS 7 (kernel 3.10) 上独立运行
- 所有 236 个库正确加载（GLIBC_2.34-2.38 符号全部解析）
- MCP Bridge 插件在 9223 端口初始化
- WebSocket 服务器启动
- GTK 后端初始化（X11 显示）
- WebKit 子进程（WebKitNetworkProcess）成功启动

## 已知问题

- **EGL/DRI 警告**：无 GPU 的容器环境中 `egl: failed to create dri2 screen`（预期，使用软件渲染）
- **D-Bus session**：部分功能需要 D-Bus session bus
- **浏览器扩展**：内置浏览器扩展可能无法加载（不影响功能）