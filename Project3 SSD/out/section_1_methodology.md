### 实验环境与方法学

硬件与系统：见 out/env.txt 摘要  
路径与介质：TARGET=/mnt/ssdtest/fiofile（文件系统/裸设备请据实描述；若为文件，已使用 direct=1 绕过页缓存）  
I/O 引擎：io_uring；运行策略：每点重复 5 次，runtime=30 s，ramp_time=5 s  
主机隔离：已尝试固定 CPU governor、停止部分后台定时服务  
健康观测：nvme-cli / smartctl 见 out/env.txt（若在 WSL，指标可能不完整）

