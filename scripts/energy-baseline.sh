#!/bin/bash
# 清风能效基线量具（R94）——fanctld 稳态运行成本的系统级采样。
#
# 两层互补：
#   1) 进程级（无需 root）：ps 采样 fanctld 的 CPU%/RSS（60s，5s 一点）
#   2) 系统级（root）：powermetrics tasks+cpu_power 采样——fanctld 的 CPU ms/s 与
#      唤醒次数/分（wakeups）、整机 CPU 封装功耗。提权走 osascript（GUI 密码框），
#      用户不需要手动开终端。用户取消授权则如实报错退出（不假装完成）。
#
# 用法：scripts/energy-baseline.sh [powermetrics 总秒数，默认 360（6 分钟 × 60s 一档）]
# 产物：stdout 汇总（可直接贴 EVOLUTION）+ 原始采样 /tmp/fanctld-powermetrics.txt
# 配套：进程内半边（SMC 读数/分）在 fanctltests 的"真机规模 SMC 读数量具（R94）"，
#       两边数字互证（读数/秒 vs wakeups/秒应同数量级）。
set -euo pipefail

PM_SECONDS="${1:-360}"
RAW="/tmp/fanctld-powermetrics.txt"

# —— 前置：daemon 必须在跑（测的是稳态，不是冷启动）——
PID="$(pgrep -x fanctld | head -1 || true)"
if [ -z "${PID}" ]; then
    echo "ERROR: fanctld 未在运行（pgrep 无命中）——先装机并让 daemon 进入稳态再采样" >&2
    exit 1
fi

echo "== 清风能效基线（R94）=="
echo "机器: $(uname -m) · $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '?')"
echo "daemon: PID ${PID} · 累计 CPU $(ps -o time= -p ${PID} | tr -d ' ') · 启动于 $(ps -o lstart= -p ${PID})"

# daemon 自报上下文（status.json 组可读）
python3 - <<'PY'
import json
try:
    with open('/Library/Application Support/FanCtl/status.json') as f:
        s = json.load(f)
    hp = s.get('hardwareProfile') or {}
    print(f"自报: daemonVersion={s.get('daemonVersion')} · loopInterval={s.get('loopInterval')}s · mode={s.get('mode')}")
    print(f"画像: {hp.get('chipName')} · fanCount={hp.get('fanCount')} · 传感器键={hp.get('sensorCounts')}")
except Exception as e:
    print(f"自报: 读 status.json 失败（{e}）——继续采样，上下文缺失")
PY

# —— 1) 进程级：ps 采样 60s ——
echo "—— 进程级采样（ps × 60s，每 5s 一点）——"
CPUS=(); RSSS=()
for _ in $(seq 1 12); do
    read -r CPU RSS <<EOF
$(ps -o %cpu=,rss= -p ${PID} | awk '{print $1, $2}')
EOF
    CPUS+=("${CPU}"); RSSS+=("${RSS}")
    sleep 5
done
python3 - "${CPUS[@]}" -- "${RSSS[@]}" <<'PY'
import sys
args = sys.argv[1:]
dash = args.index('--')
cpus = [float(x) for x in args[:dash]]
rsss = [float(x) for x in args[dash+1:]]
print(f"CPU%: avg {sum(cpus)/len(cpus):.2f} · min {min(cpus):.2f} · max {max(cpus):.2f}（12 点 × 5s）")
print(f"RSS: {sum(rsss)/len(rsss)/1024:.1f} MB（min {min(rsss)/1024:.1f} · max {max(rsss)/1024:.1f}）")
PY

# —— 2) 系统级：powermetrics（root，osascript 提权）——
INTERVAL=60000            # 60s 一档
N=$(( PM_SECONDS / 60 ))
[ "${N}" -lt 1 ] && N=1
echo "—— 系统级采样（powermetrics tasks+cpu_power，${N} 档 × 60s，授权后开始）——"
# 本机 powermetrics 无 --process-filter（退出 64）：全任务采样，解析层按名字挑 fanctld。
# 输出走 -o（不经 shell 重定向，引号层更干净）
INNER="powermetrics -i ${INTERVAL} -n ${N} -s tasks,cpu_power -o '${RAW}'"
# AppleScript 字符串字面量必须双引号（prompt 单引号是语法错误）；shell 层转义嵌入
OSA="do shell script \"${INNER}\" with administrator privileges with prompt \"清风能效基线采样（约 ${PM_SECONDS} 秒，授权后请勿合盖）\""
if ! osascript -e "${OSA}" ; then
    echo "ERROR: powermetrics 授权被取消/失败——系统级采样未完成（进程级数字仍有效）" >&2
    exit 1
fi

# —— 解析（格式随 macOS 版本有差异，宽松解析 + 保底打印原始块）——
# 本机（macOS 26B123）tasks 列序：Name ID CPU_ms/s User% Deadlines(<2ms,2-5ms) Wakeups(Intr,Pkg idle)
python3 - "${RAW}" <<'PY'
import re, sys
raw = open(sys.argv[1]).read()
# cpu_power 段：各 "XXX Power: N mW" 行取均值
powers = {}
for m in re.finditer(r'^\s*([A-Za-z0-9 ]+Power):\s+([\d.]+)\s*mW', raw, re.M):
    powers.setdefault(m.group(1).strip(), []).append(float(m.group(2)))
for k, v in sorted(powers.items()):
    print(f"{k}: avg {sum(v)/len(v):.0f} mW（{len(v)} 档）")
# tasks 段：fanctld 行（CPU ms/s=第 3 列；Wakeups Intr=第 7 列、Pkg idle=第 8 列）
rows = [l.split() for l in raw.splitlines() if l.split() and l.split()[0] == 'fanctld']
if rows:
    cpu_ms = [float(r[2]) for r in rows if len(r) > 2 and r[2].replace('.', '', 1).replace('-', '', 1).isdigit()]
    wake_i = [float(r[6]) for r in rows if len(r) > 6 and r[6].replace('.', '', 1).replace('-', '', 1).isdigit()]
    wake_p = [float(r[7]) for r in rows if len(r) > 7 and r[7].replace('.', '', 1).replace('-', '', 1).isdigit()]
    if cpu_ms:
        print(f"fanctld CPU: avg {sum(cpu_ms)/len(cpu_ms):.1f} ms/s（{len(cpu_ms)} 档，min {min(cpu_ms):.1f} · max {max(cpu_ms):.1f}）")
    if wake_i:
        print(f"fanctld 唤醒(Intr): avg {sum(wake_i)/len(wake_i):.2f} 次/s（{len(wake_i)} 档）")
    if wake_p:
        print(f"fanctld 唤醒(Pkg idle): avg {sum(wake_p)/len(wake_p):.2f} 次/s（{len(wake_p)} 档）")
else:
    print("（tasks 段未匹配到 fanctld 行——原始输出保留在文件里，可人工核对）")
PY
echo "原始采样: ${RAW}"
