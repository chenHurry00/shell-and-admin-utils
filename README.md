# shell-and-admin-utils

轻量级脚本集合仓库，当前包含的独立工具：

- `conda_menu_helper.sh`：为 shell 提供 conda 环境数字菜单
- `dkr.sh`：终端 Docker 容器管理工具
- `gpu_monitor.py`：GPU/CPU/内存实时监控页面

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
