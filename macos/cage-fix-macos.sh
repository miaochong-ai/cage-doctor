#!/usr/bin/env bash
# cage-fix-macos.sh — Claude-Cage 一键修复（macOS）
# 只修本地能改的：工作台自动同步、客机时区/语言/中文字体；改完打印复核结果。
# 用法：bash cage-fix-macos.sh [--dry-run] [--skip-web]

set -u
DRY=0
SKIPWEB=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --skip-web) SKIPWEB=1 ;;
    --help|-h) sed -n '2,4p' "$0"; exit 0 ;;
  esac
done

TZ_WANT="America/Los_Angeles"
LOC_WANT="en_US.UTF-8"
CAGE_HOME="$HOME/.claude-cage"
CHANGES=()

hr() { printf '%s\n' "----------------------------------------"; }
step() { printf '\n== %s\n' "$1"; }
say() { printf '  %s\n' "$1"; }

if [ ! -d "$CAGE_HOME" ]; then
  echo "没有找到 $CAGE_HOME，Cage 可能没装或没初始化。"
  exit 2
fi

SSH_CFG=$(ls -t "$CAGE_HOME"/state/lima/*/ssh.config 2>/dev/null | head -1)
SSH_HOST=""
if [ -n "$SSH_CFG" ]; then
  SSH_HOST=$(awk '/^Host /{print $2; exit}' "$SSH_CFG")
fi

guest() {
  [ -z "$SSH_CFG" ] && { echo "no ssh"; return 0; }
  ssh -F "$SSH_CFG" -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=ERROR "$SSH_HOST" "$1" 2>/dev/null
}

echo
echo "Claude-Cage 一键修复（macOS）"
echo "会话：$(date '+%Y-%m-%d %H:%M')"
[ "$DRY" = "1" ] && echo "预演模式：只说不做"

# 备份
STAMP=$(date '+%Y%m%d-%H%M%S')
if [ "$DRY" = "0" ]; then
  mkdir -p "$CAGE_HOME/backup/$STAMP"
  for f in config.json workbench.json guest-profile.json environment-storage.json; do
    [ -f "$CAGE_HOME/$f" ] && cp "$CAGE_HOME/$f" "$CAGE_HOME/backup/$STAMP/"
  done
  say "已备份配置到 $CAGE_HOME/backup/$STAMP"
else
  say "（预演）会备份配置到 $CAGE_HOME/backup/$STAMP"
fi

# 1 工作台
step "1/5 工作台：关闭时区/语言自动同步"
WB="$CAGE_HOME/workbench.json"
if [ -f "$WB" ]; then
  NEED=$(python3 - "$WB" <<'PY'
import json,sys
p=sys.argv[1]
d=json.load(open(p))
n=[]
if d.get("auto_timezone") is not False: n.append("auto_timezone")
if d.get("auto_language") is not False: n.append("auto_language")
print(",".join(n))
PY
)
  if [ -z "$NEED" ]; then
    say "已是 false，无需改动"
  elif [ "$DRY" = "1" ]; then
    say "（预演）会把 $NEED 改成 false"
  else
    python3 - "$WB" <<'PY'
import json,sys
p=sys.argv[1]
d=json.load(open(p))
d["auto_timezone"]=False
d["auto_language"]=False
open(p,"w").write(json.dumps(d,indent=2,ensure_ascii=False))
PY
    CHANGES+=("workbench.json: $NEED -> false")
    say "已改：$NEED = false（重启 Cage 生效）"
  fi
else
  say "跳过：没有 workbench.json"
fi

if [ -z "$SSH_CFG" ]; then
  step "2/5 客机"; say "跳过：没有找到 ssh.config，先启动 Cage"
  step "3/5 客机"; say "跳过"
  step "4/5 客机"; say "跳过"
else
  # 2 时区
  step "2/5 客机时区"
  now=$(guest 'date +"%Z %z"')
  say "当前：$now"
  case "$now" in
    *-0800*|*-0700*) say "已是美西时区，无需改动" ;;
    *)
      if [ "$DRY" = "1" ]; then say "（预演）会设置 $TZ_WANT"
      else
        r=$(guest "sudo -n timedatectl set-timezone $TZ_WANT >/dev/null 2>&1; date +'%Z %z'")
        CHANGES+=("guest tz -> $TZ_WANT"); say "已设置：$r"
      fi ;;
  esac

  # 3 语言
  step "3/5 客机语言环境"
  l=$(guest 'locale 2>/dev/null | grep -m1 "^LANG=" | cut -d= -f2')
  say "当前 LANG=$l"
  case "$l" in
    en_US.UTF-8*) say "已是 en_US.UTF-8，无需改动" ;;
    *)
      if [ "$DRY" = "1" ]; then say "（预演）会设置 LANG=$LOC_WANT"
      else
        r=$(guest "sudo -n update-locale LANG=$LOC_WANT >/dev/null 2>&1; . /etc/default/locale 2>/dev/null; echo LANG=\$LANG")
        CHANGES+=("guest locale -> $LOC_WANT"); say "已设置：$r（重新登录生效）"
      fi ;;
  esac

  # 4 字体
  step "4/5 客机字体（checkcc 字体地区特征主要来源）"
  n=$(guest 'fc-list 2>/dev/null | grep -ci "CJK SC"')
  say "当前 Noto CJK SC 字体数：${n:-0}"
  if [ "${n:-0}" = "0" ]; then
    say "已经干净，无需改动"
  elif [ "$DRY" = "1" ]; then
    say "（预演）会卸载 fonts-noto-cjk 并刷新字体缓存"
  else
    r=$(guest "sudo -n env DEBIAN_FRONTEND=noninteractive apt-get purge -y fonts-noto-cjk fonts-noto-cjk-extra >/tmp/cagefix-apt.log 2>&1; sudo -n fc-cache -f >/dev/null 2>&1; echo REMAIN=\$(fc-list 2>/dev/null | grep -ci 'CJK SC')")
    CHANGES+=("guest fonts: 已卸载 Noto CJK"); say "已卸载，剩余 CJK SC 字体：$r"
    say "还原办法：sudo apt install fonts-noto-cjk"
  fi
fi

# 5 控制面
step "5/5 Cage 控制面"
CAGE_BIN=""
for c in "/Applications/Claude Cage.app/Contents/Resources/cage" "/Applications/Cage.app/Contents/Resources/cage"; do
  [ -x "$c" ] && CAGE_BIN="$c" && break
done
if [ -z "$CAGE_BIN" ]; then
  say "没有找到 cage 可执行文件，跳过"
else
  out=$(echo '{}' | "$CAGE_BIN" agent call proxy.status --input - 2>/dev/null)
  state=$(printf '%s' "$out" | python3 -c 'import sys,json
try:
 d=json.load(sys.stdin).get("data") or {}
 print("%s|%s|%s|%s"%(d.get("state_label") or d.get("state"),d.get("active"),d.get("udp_blocked"),d.get("ipv6_blocked")))
except Exception: print("")' 2>/dev/null)
  if [ -z "$state" ]; then say "控制器不可用：先打开 Cage，等显示已联网再重跑"; else say "state/active/udp/ipv6 = $state"; fi
fi

hr
echo "本次改动："
if [ ${#CHANGES[@]} -eq 0 ]; then echo "  无（本来就没问题，或是预演）"; else
  for c in "${CHANGES[@]}"; do echo "  · $c"; done
fi

echo
echo "改不了的部分（需要换出口或接受现状）："
echo "  · 网络出口类型（数据中心/云厂商）：由出口 IP 的 ASN 决定，只能换真正的住宅 IP"
echo "  · 多源 IP 情报一致性：三方库判断冲突，本地改不了"
echo "  · claude.ai 浏览器侧可达性：Cloudflare 人机验证，脚本过不了"
echo "  · DNS/代理一致性：边缘机房与 IP 归属城市不一致，换节点才会变"
echo
if [ "$SKIPWEB" = "0" ]; then
  echo "复测：改完重启 Cage，再用 cage-doctor-macos.sh 或 checkcc.org 跑一遍拿分。"
fi
echo "完成后建议重启一次 Cage 让工作台配置生效。"
echo
