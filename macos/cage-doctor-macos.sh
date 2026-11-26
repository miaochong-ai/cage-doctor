#!/usr/bin/env bash
# cage-doctor-macos.sh — Claude-Cage 环境体检（macOS / Apple Silicon & Intel）
#
# 用法：
#   bash cage-doctor-macos.sh          # 彩色表格输出
#   bash cage-doctor-macos.sh --json   # 机器可读输出
#
# 说明：全部为只读检查，不修改任何配置、不发送任何数据到外部服务器。

set -u

if [ -t 1 ]; then
  RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; BLD=$'\033[1m'; RST=$'\033[0m'
else
  RED=; YEL=; GRN=; DIM=; BLD=; RST=
fi

JSON=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
  esac
done

PASS=0; WARN=0; FAIL=0; TODO=0
NAMES=(); STATS=(); DETAILS=()

add() {
  NAMES+=("$1"); STATS+=("$2"); DETAILS+=("$3")
  case "$2" in
    通过) PASS=$((PASS+1)) ;;
    注意) WARN=$((WARN+1)) ;;
    不合格) FAIL=$((FAIL+1)) ;;
    *) TODO=$((TODO+1)) ;;
  esac
}

has() { command -v "$1" >/dev/null 2>&1; }

CAGE_APP="/Applications/Cage.app"
CAGE_HOME="$HOME/.claude-cage"
CAGE_BIN=""

# ---------- 1. 系统版本 ----------
OSV=$(sw_vers -productVersion 2>/dev/null || echo "0")
MAJ=${OSV%%.*}
if [ "${MAJ:-0}" -ge 13 ] 2>/dev/null; then
  add "macOS 版本" "通过" "$OSV（≥13 Ventura 可运行 Cage 的虚拟机组件）"
else
  add "macOS 版本" "不合格" "$OSV（低于 13，Cage 依赖的虚拟化接口不完整）"
fi

# ---------- 2. CPU 架构 ----------
ARCH=$(uname -m)
case "$ARCH" in
  arm64) add "CPU 架构" "通过" "Apple Silicon（arm64）" ;;
  x86_64) add "CPU 架构" "注意" "Intel（x86_64），速度明显慢于 Apple Silicon" ;;
  *) add "CPU 架构" "不合格" "$ARCH" ;;
esac

# ---------- 3. 硬件虚拟化 ----------
HV=$(sysctl -n kern.hv_support 2>/dev/null || echo "0")
if [ "$HV" = "1" ]; then
  add "硬件虚拟化" "通过" "kern.hv_support = 1"
else
  add "硬件虚拟化" "不合格" "kern.hv_support = $HV（虚拟机起不来）"
fi

# ---------- 4. 内存 ----------
MEMB=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
MEMG=$(( MEMB / 1073741824 ))
if [ "$MEMG" -ge 16 ]; then
  add "内存" "通过" "${MEMG}GB（客机固定约 7GB，余量充足）"
elif [ "$MEMG" -ge 8 ]; then
  add "内存" "注意" "${MEMG}GB，勉强够用，建议关闭浏览器等大户"
else
  add "内存" "不合格" "${MEMG}GB，低于 8GB 起不来"
fi

# ---------- 5. 磁盘空间 ----------
FREEK=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')
FREEG=$(( ${FREEK:-0} / 1048576 ))
if [ "$FREEG" -ge 60 ]; then
  add "磁盘可用空间" "通过" "${FREEG}GB"
elif [ "$FREEG" -ge 30 ]; then
  add "磁盘可用空间" "注意" "${FREEG}GB，客机镜像约 13GB，装完还需余量"
else
  add "磁盘可用空间" "不合格" "${FREEG}GB，不足 30GB"
fi

# ---------- 6. Cage 应用 ----------
if [ -d "$CAGE_APP" ]; then
  add "Cage 应用" "通过" "$CAGE_APP"
else
  add "Cage 应用" "不合格" "未找到 $CAGE_APP（先装 Cage）"
fi

# ---------- 7. cage 命令行 ----------
for c in "$CAGE_APP/Contents/MacOS/cage" "$CAGE_APP/Contents/Resources/cage" "$CAGE_APP/Contents/Resources/bin/cage"; do
  if [ -x "$c" ]; then CAGE_BIN="$c"; break; fi
done
[ -z "$CAGE_BIN" ] && has cage && CAGE_BIN=$(command -v cage)
if [ -n "$CAGE_BIN" ]; then
  add "cage 命令行" "通过" "$CAGE_BIN"
else
  add "cage 命令行" "不合格" "应用内与 PATH 都没找到 cage"
fi

# ---------- 8. 配置目录 ----------
if [ -d "$CAGE_HOME" ]; then
  add "配置目录" "通过" "$CAGE_HOME"
else
  add "配置目录" "不合格" "$CAGE_HOME 不存在，Cage 尚未初始化"
fi

# ---------- 9. 客机镜像体积 ----------
LIMADIR="$CAGE_HOME/state/lima"
if [ -d "$LIMADIR" ]; then
  SZ=$(du -sh "$LIMADIR" 2>/dev/null | awk '{print $1}')
  add "客机镜像" "通过" "$LIMADIR（$SZ）"
else
  add "客机镜像" "不合格" "缺少 $LIMADIR，需 cage init / cage up 初始化"
fi

# ---------- 10. 控制器端口 ----------
for spec in "17777:workbench" "17778:control"; do
  port=${spec%%:*}; name=${spec##*:}
  if [ -n "$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null)" ]; then
    add "端口 $port（$name）" "通过" "正在监听"
  else
    add "端口 $port（$name）" "不合格" "未监听，Cage 桌面程序未运行"
  fi
done

# ---------- 11. 代理端口 ----------
if [ -n "$(lsof -nP -iTCP:17896 -sTCP:LISTEN 2>/dev/null)" ]; then
  add "代理端口 17896" "通过" "socks5 代理在监听"
else
  add "代理端口 17896" "注意" "未监听：先开 Cage 窗口批准网络，或执行 proxy.restart"
fi

# ---------- 12. 出口 IP ----------
IPJSON=$(curl -s --max-time 10 https://ipinfo.io/json 2>/dev/null)
IPC=$(printf '%s' "$IPJSON" | tr -d '\n' | sed -n 's/.*"ip": *"\([^"]*\)".*/\1/p')
CTRY=$(printf '%s' "$IPJSON" | tr -d '\n' | sed -n 's/.*"country": *"\([^"]*\)".*/\1/p')
if [ -n "$IPC" ]; then
  add "宿主机出口 IP" "通过" "$IPC ${CTRY:-?}（这里是本机出口，客机出口另算）"
else
  add "宿主机出口 IP" "注意" "取不到 ipinfo，可能本机没网或被拦"
fi

# ---------- 13. CheckCC 站点可达 ----------
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 https://checkcc.org/ 2>/dev/null || echo 000)
case "$CODE" in
  2*|3*) add "CheckCC 站点可达" "通过" "HTTP $CODE" ;;
  *) add "CheckCC 站点可达" "注意" "HTTP $CODE（需在 Cage 内置浏览器里手动跑一次检测）" ;;
esac

# ---------- 14. 分享目录 ----------
if [ -d "$HOME/.claude-cage-downloads" ]; then
  add "共享目录" "通过" "$HOME/.claude-cage-downloads（客机可读）"
else
  add "共享目录" "注意" "缺少 ~/.claude-cage-downloads，客机拿不到本机文件"
fi

# ---------- 15. 配置备份 ----------
if [ -d "$CAGE_HOME/backup" ] && [ -n "$(ls -A "$CAGE_HOME/backup" 2>/dev/null)" ]; then
  add "配置备份" "通过" "$CAGE_HOME/backup 已有备份"
else
  add "配置备份" "待办" "建议把 config.json / workbench.json / environment-storage.json 复制一份留底"
fi

# ---------- 16. 时区语言锁定 ----------
WB="$CAGE_HOME/workbench.json"
if [ -f "$WB" ]; then
  if grep -q '"auto_timezone": *false' "$WB" && grep -q '"auto_language": *false' "$WB"; then
    add "时区/语言锁定" "通过" "auto_timezone 与 auto_language 均为 false"
  else
    add "时区/语言锁定" "注意" "自动同步没关，客机时区会跟着宿主机变，容易暴露地区特征"
  fi
else
  add "时区/语言锁定" "待办" "没有 workbench.json，先启动一次 Cage 生成配置"
fi

# ---------- 17. 安全自检报告 ----------
SR="$CAGE_HOME/last-safety-report.json"
if [ -f "$SR" ]; then
  add "最近安全自检" "通过" "$SR 存在（详情看文件内容）"
else
  add "最近安全自检" "待办" "没有报告文件，Cage 首次启动后才生成"
fi

# ---------- 客机侧检查（走 lima 的 ssh.config） ----------
SSHCFG=""
if [ -d "$LIMADIR" ]; then
  SSHCFG=$(find "$LIMADIR" -name ssh.config -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
fi

if [ -n "$SSHCFG" ]; then
  HOSTA=$(awk '/^Host /{h=$2} END{print h}' "$SSHCFG")
  PORT=$(awk '/^ *Port /{p=$2} END{print p}' "$SSHCFG")
  add "SSH 配置" "通过" "$(basename "$(dirname "$SSHCFG")") 端口 ${PORT:-?}"

  SSHOPTS="-F $SSHCFG -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o LogLevel=ERROR"
  # shellcheck disable=SC2086
  if ssh $SSHOPTS "$HOSTA" true >/dev/null 2>&1; then
    add "客机 SSH 连通" "通过" "ssh -F ssh.config $HOSTA 可登录"

    # shellcheck disable=SC2086
    CV=$(ssh $SSHOPTS "$HOSTA" 'claude --version 2>/dev/null' 2>/dev/null | tail -1)
    if [ -n "$CV" ]; then
      add "客机 Claude Code" "通过" "$CV"
    else
      add "客机 Claude Code" "不合格" "客机内 claude 命令不可用"
    fi

    # shellcheck disable=SC2086
    if ssh $SSHOPTS "$HOSTA" 'test -f "$HOME/.claude/.credentials.json"' >/dev/null 2>&1; then
      add "Claude 登录凭据" "通过" "客机内已有 .credentials.json"
    else
      add "Claude 登录凭据" "不合格" "还没登录，这个必须在 Cage 窗口里的浏览器完成"
    fi

    # shellcheck disable=SC2086
    GC=$(ssh $SSHOPTS "$HOSTA" 'curl -s -o /dev/null -w %{http_code} --max-time 8 https://claude.ai' 2>/dev/null | tail -1)
    case "$GC" in
      2*|3*) add "客机访问 claude.ai" "通过" "HTTP $GC" ;;
      *) add "客机访问 claude.ai" "不合格" "HTTP ${GC:-000}，登录与请求都会失败" ;;
    esac

    # shellcheck disable=SC2086
    TZ=$(ssh $SSHOPTS "$HOSTA" 'date +"%Z %z"' 2>/dev/null | tail -1)
    if [ -n "$TZ" ]; then
      add "客机时区" "通过" "$TZ"
    else
      add "客机时区" "注意" "读不到"
    fi
  else
    add "客机 SSH 连通" "不合格" "连不上，可能 Cage 没 up 或端口变了"
  fi
else
  add "SSH 配置" "待办" "没找到 ssh.config，Cage 还没初始化过环境"
fi

# ---------- 汇总 ----------
if [ "$JSON" = "1" ]; then
  printf '{\n  "summary": {"pass": %d, "warn": %d, "fail": %d, "todo": %d},\n  "items": [\n' "$PASS" "$WARN" "$FAIL" "$TODO"
  n=${#NAMES[@]}
  for ((i=0;i<n;i++)); do
    sep=","; [ "$i" -eq $((n-1)) ] && sep=""
    printf '    {"name": "%s", "status": "%s", "detail": "%s"}%s\n' "${NAMES[$i]}" "${STATS[$i]}" "${DETAILS[$i]}" "$sep"
  done
  printf '  ]\n}\n'
  [ "$FAIL" -gt 0 ] && exit 1
  exit 0
fi

printf '\n%s Claude-Cage 体检 · macOS %s\n' "$BLD" "$(sw_vers -productVersion 2>/dev/null)"
printf '%s\n' "------------------------------------------------------------"
for ((i=0;i<${#NAMES[@]};i++)); do
  s=${STATS[$i]}
  case "$s" in
    通过) col=$GRN ;;
    注意) col=$YEL ;;
    不合格) col=$RED ;;
    *) col=$DIM ;;
  esac
  printf '%s%-6s%s %-24s %s\n' "$col" "$s" "$RST" "${NAMES[$i]}" "${DETAILS[$i]}"
done
printf '%s\n' "------------------------------------------------------------"
printf '通过 %s%d%s  注意 %s%d%s  不合格 %s%d%s  待办 %s%d%s\n' \
  "$GRN" "$PASS" "$RST" "$YEL" "$WARN" "$RST" "$RED" "$FAIL" "$RST" "$DIM" "$TODO" "$RST"

if [ "$FAIL" -gt 0 ]; then
  printf '\n%s有 %d 项不合格，先修这些再谈账号安全。%s\n' "$RED" "$FAIL" "$RST"
else
  printf '\n%s主机侧没有硬性不合格项。封号风险主要看出口 IP 与浏览器指纹，去 Cage 里开 checkcc.org 跑一次。%s\n' "$GRN" "$RST"
fi
printf '%s本脚本只读，不改配置、不上传数据。%s\n\n' "$DIM" "$RST"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
