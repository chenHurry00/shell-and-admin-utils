# shell-and-admin-utils

轻量级脚本集合仓库，当前包含的独立工具：

- `conda_menu_helper.sh`：为 shell 提供 conda 环境数字菜单
- `dkr.sh`：终端 Docker 容器管理工具
- `gpu_monitor.py`：GPU/CPU/内存实时监控页面
- `nvidia-gpu-tui.sh`：NVIDIA GPU 的 PowerMizer、功耗上限和开机应用管理

## 快速使用

### conda_menu_helper.sh

```bash
bash conda_menu_helper.sh --install
source ~/.bashrc
cx
```

该脚本会把运行状态写到用户目录，而不是仓库内：

- `~/.local/share/conda-menu/`
- `~/.local/state/conda-menu/`

### dkr.sh

```bash
bash dkr.sh
```

需要本机已安装并启动 Docker。

### gpu_monitor.py

```bash
python3 -m pip install flask psutil
python3 gpu_monitor.py
```

默认访问地址：`http://localhost:8082`

### nvidia-gpu-tui.sh

用于逐卡配置 NVIDIA GPU 的 PowerMizer 模式和功耗上限，并可安装 systemd 服务、GNOME 自启动、查看状态与日志，或卸载已安装内容。

运行前需要已安装并正常工作的 NVIDIA 驱动（提供 `nvidia-smi`），建议在 Ubuntu/Debian 桌面环境中使用：

```bash
chmod +x nvidia-gpu-tui.sh
./nvidia-gpu-tui.sh
```

请以普通桌面用户直接运行，不要在命令前加 `sudo`；脚本会在需要执行管理员操作时自行请求权限。首次运行若未找到 `dialog` 或 `whiptail`，脚本会尝试使用 `apt-get` 安装 `dialog`。
