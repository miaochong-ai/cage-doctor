# cage-fix.ps1 — Claude-Cage 一键修复（Windows）
# 针对 checkcc 那 48 个检测点里"本地能改"的部分做自动修复，改完自动复测给分。
# 只读诊断 + 可回滚的改动，不改节点、不伪造指纹。

param(
    [switch]$Json,
    [switch]$DryRun,
    [switch]$SkipWeb,
    [string]$Timezone = 'America/Los_Angeles',
    [string]$Locale = 'en_US.UTF-8'
)

$ErrorActionPreference = 'Continue'
$script:log = @()
$script:changes = @()

function Log($msg) { $script:log += $msg; if (-not $Json) { Write-Host $msg } }
function Step($msg) { if (-not $Json) { Write-Host ("== " + $msg) -ForegroundColor Cyan } }

# ---------------- 定位 ----------------
$cageHome = Join-Path $env:USERPROFILE '.claude-cage'
if (-not (Test-Path -LiteralPath $cageHome)) {
    Write-Host "没有找到 $cageHome，Cage 可能没装或没初始化。" -ForegroundColor Red
    exit 2
}
$wbPath = Join-Path $cageHome 'workbench.json'
$stagePath = Join-Path $cageHome 'environment-storage.json'
$limaRoot = Join-Path $cageHome 'state\lima'

$sshExeCandidates = @(
    'D:\Cage\app\resources\runtime\openssh\ssh.exe',
    'C:\Program Files\Cage\resources\runtime\openssh\ssh.exe',
    (Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe')
)
$sshExe = $sshExeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$sshCfg = $null
if (Test-Path -LiteralPath $limaRoot) {
    $sshCfg = Get-ChildItem -LiteralPath $limaRoot -Recurse -Filter 'ssh.config' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
$sshHost = $null
$sshReady = $false
if ($sshExe -and $sshCfg) {
    $sshHost = (Select-String -LiteralPath $sshCfg.FullName -Pattern '^Host\s+(\S+)' -Encoding UTF8 |
        Select-Object -First 1)
    if ($sshHost) { $sshHost = $sshHost.Matches[0].Groups[1].Value }
}

function Guest($cmd, [int]$timeout = 60) {
    if (-not $sshCfg -or -not $sshExe) { return @{ ok = $false; out = 'no ssh' } }
    try {
        $o = & $sshExe -F $sshCfg.FullName -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=no `
            -o LogLevel=ERROR $sshHost $cmd 2>$null
        return @{ ok = $true; out = (($o | Out-String).Trim()) }
    } catch { return @{ ok = $false; out = $_.Exception.Message } }
}

if ($sshHost) {
    $p = Guest 'echo SSH_OK'
    $sshReady = ($p.out -ne $null) -and ($p.out -match 'SSH_OK')
}

# ---------------- 备份 ----------------
function Backup-Configs {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $cageHome ("backup\" + $stamp)
    if ($DryRun) { Log "（预演）会备份配置到 $dir"; return }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($f in @('config.json', 'workbench.json', 'guest-profile.json', 'environment-storage.json')) {
        $p = Join-Path $cageHome $f
        if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $dir -Force }
    }
    Log "已备份配置到 $dir"
}

# ---------------- 修复 1：工作台自动同步 ------------
function Fix-Workbench {
    Step '1/6 工作台：关闭时区/语言自动同步'
    if (-not (Test-Path -LiteralPath $wbPath)) { Log '  跳过：没有 workbench.json'; return }
    $raw = [System.IO.File]::ReadAllText($wbPath, [Text.Encoding]::UTF8)
    try { $obj = $raw | ConvertFrom-Json } catch { Log '  跳过：workbench.json 解析失败'; return }
    $need = @()
    if ($obj.auto_timezone -ne $false) { $need += 'auto_timezone' }
    if ($obj.auto_language -ne $false) { $need += 'auto_language' }
    if ($need.Count -eq 0) { Log '  已是 false，无需改动'; return }
    if ($DryRun) { Log ("  （预演）会把 " + ($need -join '、') + " 改成 false"); return }
    $obj.auto_timezone = $false
    $obj.auto_language = $false
    $json = $obj | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($wbPath, $json, (New-Object Text.UTF8Encoding($false)))
    $script:changes += ('workbench.json: ' + ($need -join '、') + ' -> false')
    Log ('  已改：' + ($need -join '、') + ' = false（重启 Cage 生效）')
}

# ---------------- 修复 2：客机时区 ------------
function Fix-GuestTimezone {
    Step '2/6 客机时区'
    if (-not $sshReady) { Log '  跳过：连不上客机（先启动 Cage 并 cage up）'; return }
    $now = Guest 'date +"%Z %z"'
    Log ("  当前：" + $now.out)
    $utc = Guest 'date -u +%H'
    $off = Guest 'date +%z'
    $wantOff = '-0800'
    if ($off.out -eq $wantOff -or $off.out -eq '-0700') { Log '  已是美西时区，无需改动'; return }
    if ($DryRun) { Log "  （预演）会设置时区为 $Timezone"; return }
    $r = Guest ("sudo -n timedatectl set-timezone " + $Timezone + " 2>&1; date +'%Z %z'")
    $script:changes += ('guest tz -> ' + $Timezone)
    Log ('  已设置：' + $r.out)
}

# ---------------- 修复 3：客机语言 ------------
function Fix-GuestLocale {
    Step '3/6 客机语言环境'
    if (-not $sshReady) { Log '  跳过：连不上客机'; return }
    $l = Guest 'locale 2>/dev/null | grep -m1 "^LANG=" | cut -d= -f2'
    Log ('  当前 LANG=' + $l.out)
    if ($l.out -like ($Locale + '*')) { Log '  已是 en_US.UTF-8，无需改动'; return }
    if ($DryRun) { Log "  （预演）会设置 LANG=$Locale"; return }
    $r = Guest ("sudo -n update-locale LANG=" + $Locale + " 2>&1; . /etc/default/locale 2>/dev/null; echo LANG=`$LANG")
    $script:changes += ('guest locale -> ' + $Locale)
    Log ('  已设置：' + $r.out + '（重新登录后生效）')
}

# ---------------- 修复 4：客机中文字体 ------------
function Fix-GuestFonts {
    Step '4/6 客机字体（checkcc 字体地区特征的主要来源）'
    if (-not $sshReady) { Log '  跳过：连不上客机'; return }
    $c = Guest 'fc-list 2>/dev/null | grep -ci "CJK SC"'
    $n = 0
    [void][int]::TryParse(($c.out -replace '\D', ''), [ref]$n)
    Log ("  当前 Noto CJK SC 字体数：" + $n)
    if ($n -eq 0) { Log '  已经干净，无需改动'; return }
    if ($DryRun) { Log '  （预演）会卸载 fonts-noto-cjk 并刷新字体缓存'; return }
    $r = Guest ("sudo -n DEBIAN_FRONTEND=noninteractive apt-get purge -y fonts-noto-cjk fonts-noto-cjk-extra >/tmp/cagefix-apt.log 2>&1; sudo -n fc-cache -f >/dev/null 2>&1; echo REMAIN=`$(fc-list 2>/dev/null | grep -ci 'CJK SC')", 180)
    $script:changes += 'guest fonts: 已卸载 Noto CJK'
    Log ('  已卸载，剩余 CJK SC 字体：' + $r.out)
    Log '  还原办法：sudo apt install fonts-noto-cjk'
}

# ---------------- 修复 5：共享挂载 ------------
function Check-Mounts {
    Step '5/6 共享挂载（只检查，不自动删）'
    if (-not $sshReady) { Log '  跳过：连不上客机'; return }
    $m = Guest 'mount 2>/dev/null | grep -c "fuse.sshfs"'
    $k = 0
    [void][int]::TryParse(($m.out -replace '\D', ''), [ref]$k)
    if ($k -le 1) { Log ("  sshfs 挂载数：" + $k + "，正常") }
    else { Log ("  sshfs 挂载数：" + $k + "，多于 1 条，可能挂进了宿主目录，建议手动清理") }
}

# ---------------- 修复 6：Cage 控制面 ------------
function Check-Controller {
    Step '6/6 Cage 控制面与代理状态'
    $cageExe = @('D:\Cage\app\resources\cage.exe', 'C:\Program Files\Cage\resources\cage.exe') |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $cageExe) { Log '  没有找到 cage.exe'; return }
    $out = '{}' | & $cageExe agent call proxy.status --input - 2>$null | Out-String
    $st = $null
    try { $st = $out | ConvertFrom-Json } catch { }
    if (-not $st) { Log '  proxy.status 无返回'; return }
    if ($st.status -eq 'error') {
        Log '  控制器不可用：先打开 Cage 窗口，等它显示已联网，再重跑本脚本'
        return
    }
    $d = $st.data
    if (-not $d) { Log '  proxy.status 没有 data 字段'; return }
    Log ('  state=' + $d.state + ' / ' + $d.state_label + '  active=' + $d.active + '  udp_blocked=' + $d.udp_blocked + '  ipv6_blocked=' + $d.ipv6_blocked)
    if (-not $d.active) {
        if ($DryRun) { Log '  （预演）会执行 proxy.restart' }
        else {
            '{}' | & $cageExe agent call proxy.restart --input - > $null 2>$null
            $script:changes += 'proxy: 已尝试 restart'
            Start-Sleep -Seconds 3
            $again = '{}' | & $cageExe agent call proxy.status --input - 2>$null | Out-String
            try { $st2 = $again | ConvertFrom-Json } catch { $st2 = $null }
            if ($st2 -and $st2.data) { Log ('  restart 后 active=' + $st2.data.active + ' state=' + $st2.data.state) }
        }
    }
}

# ---------------- 复测：跑 checkcc ----------------
$ccPy = @'
import json,re,sys,time,urllib.request
sys.path.insert(0,'/tmp')
import cdp
def page_ws():
    d=json.load(urllib.request.urlopen('http://127.0.0.1:9333/json',timeout=6))
    ps=[t for t in d if t.get('type')=='page' and 'checkcc' in t.get('url','')]
    return ps[0]['webSocketDebuggerUrl'] if ps else None
ws=None
for i in range(30):
    try: ws=page_ws()
    except Exception: ws=None
    if ws: break
    time.sleep(0.5)
if not ws:
    print('CC_RESULT='+json.dumps({"ok":False,"err":"no page"})); sys.exit()
def S():
    s=cdp.ws_open(ws); cdp.evaluate(s,"1"); return s
def ev(js):
    try: return cdp.evaluate(S(),js)
    except Exception: return None
def txt():
    r=ev("document.body.innerText")
    return r if isinstance(r,str) else ''
def click(x,y):
    s=S()
    for m,bt in (("mouseMoved",0),("mousePressed",1),("mouseReleased",0)):
        cdp.call(s,"Input.dispatchMouseEvent",{"type":m,"x":x,"y":y,"button":"left","clickCount":0 if m=="mouseMoved" else 1,"buttons":bt})
    time.sleep(1)
def rect(t):
    js="(()=>{const b=[...document.querySelectorAll('button')].filter(x=>x.textContent.includes('%s')).pop();if(!b)return null;const q=b.getBoundingClientRect();if(q.width<4)return null;return [Math.round(q.x+q.width/2),Math.round(q.y+q.height/2)]})()" % t
    try: return ev(js)
    except Exception: return None
for k in range(6):
    if len(txt())>200: break
    ev("location.href='https://checkcc.org/'")
    time.sleep(4)
for i in range(40):
    if ev("document.readyState")=='complete' and len(txt())>200: break
    time.sleep(0.5)
for i in range(20):
    if '立即检测' in txt(): break
    time.sleep(0.5)
time.sleep(1)
r2=None
for k in range(6):
    r2=rect('开始检测')
    if r2: break
    if k%2==0:
        ev("(()=>{const b=[...document.querySelectorAll('button')].filter(x=>x.textContent.includes('立即检测')).pop();if(b)b.click();return 1})()")
    else:
        r=rect('立即检测')
        if r: click(r[0],r[1])
    time.sleep(1.5)
if not r2:
    print('CC_RESULT='+json.dumps({"ok":False,"err":"no modal"})); sys.exit()
def started():
    x=txt()
    return ('等待检测' in x) or ('检测中' in x) or bool(re.search(r'\d+%\s*\n\s*封号风险',x))
ev("(()=>{const b=[...document.querySelectorAll('button')].filter(x=>x.textContent.trim()==='开始检测').pop()||[...document.querySelectorAll('button')].filter(x=>x.textContent.includes('开始检测')).pop();if(!b)return 'no';b.click();return 'ok'})()")
time.sleep(1.5)
if not started():
    click(r2[0],r2[1]); time.sleep(1.5)
if not started():
    r3=rect('开始检测')
    if r3: click(r3[0],r3[1])
t=''
for i in range(60):
    time.sleep(0.5); x=txt()
    if len(x)>len(t): t=x
    if re.search(r'\d+%\s*\n\s*封号风险',x) and x.count('等待检测')<=5: t=x; break
time.sleep(2); t2=txt()
if len(t2)>len(t): t=t2
try: open('/tmp/cc_text.txt','w').write(t)
except Exception: pass
if not re.search(r'(\d+)%\s*\n\s*封号风险',t):
    print('CC_RESULT='+json.dumps({"ok":False,"err":"no score","t":t[-60:]},ensure_ascii=False)); sys.exit()
d={"ok":True}
m=re.search(r'(\d+)%\s*\n\s*封号风险',t); d["score"]=int(m.group(1)) if m else None
m=re.search(r'命中高危风险\s*(\d+)\s*个',t); d["high"]=int(m.group(1)) if m else None
m=re.search(r'命中\s*(\d+)\s*个检测信号',t); d["signals"]=int(m.group(1)) if m else None
L=[x.strip() for x in t.split('\n')]
items=[]
for i in range(len(L)-2):
    a,b,c=L[i],L[i+1],L[i+2]
    if re.match(r'^[+-]\d+$',c) and 2<=len(a)<=24 and 1<=len(b)<=48 and a not in ('高危风险','封号风险'):
        items.append([a,b,c])
d["ded"]=[]
for a,b,c in items:
    if c.startswith('+') and int(c[1:])>0: d["ded"].append(a+" "+b+" "+c)
print('CC_RESULT='+json.dumps(d,ensure_ascii=False))
'@

$cdpPy = @'
import socket, base64, json, os, struct, time
def ws_open(url):
    host_port, path = url[5:].split('/', 1)
    host, port = host_port.split(':')
    s = socket.create_connection((host, int(port)), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    req = ("GET /%s HTTP/1.1\r\nHost: %s:%s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (path, host, port, key))
    s.sendall(req.encode())
    resp = b''
    while b'\r\n\r\n' not in resp:
        d = s.recv(4096)
        if not d: break
        resp += d
    return s
def _send(s, payload):
    b = payload.encode(); n = len(b)
    if n < 126: hdr = bytes([0x81, 0x80 | n])
    elif n < 65536: hdr = bytes([0x81, 0x80 | 126]) + struct.pack('>H', n)
    else: hdr = bytes([0x81, 0x80 | 127]) + struct.pack('>Q', n)
    mk = os.urandom(4)
    s.sendall(hdr + mk + bytes(b[i] ^ mk[i % 4] for i in range(n)))
def _recv(s):
    h = b''
    while len(h) < 2:
        c = s.recv(2 - len(h))
        if not c: return b''
        h += c
    ln = h[1] & 0x7f
    if ln == 126: ln = struct.unpack('>H', s.recv(2))[0]
    elif ln == 127: ln = struct.unpack('>Q', s.recv(8))[0]
    data = b''
    while len(data) < ln:
        c = s.recv(ln - len(data))
        if not c: break
        data += c
    return data
_id = [0]
def call(s, method, params=None):
    _id[0] += 1; mid = _id[0]
    _send(s, json.dumps({"id": mid, "method": method, "params": params or {}}))
    deadline = time.time() + 15
    while time.time() < deadline:
        m = _recv(s)
        if not m: return None
        try: o = json.loads(m)
        except Exception: continue
        if o.get('id') == mid:
            if 'error' in o: return None
            return o.get('result')
    return None
def evaluate(s, expr):
    r = call(s, "Runtime.evaluate", {"expression": expr, "returnByValue": True, "awaitPromise": True})
    if not r: return None
    return (r.get('result') or {}).get('value')
'@

$ccSh = @'
#!/bin/bash
export DISPLAY=:99
pgrep -x Xvfb >/dev/null || (Xvfb :99 -screen 0 1440x960x24 >/tmp/xvfb.log 2>&1 &)
sleep 1
pkill -f 'user-data-dir=/tmp/cchp' 2>/dev/null
sleep 1
rm -rf /tmp/cchp
google-chrome --no-sandbox --disable-dev-shm-usage --use-gl=swiftshader --user-data-dir=/tmp/cchp --remote-debugging-port=9333 --window-size=1440,900 --window-position=0,0 about:blank >/tmp/chrome.log 2>&1 &
for i in $(seq 1 40); do sleep 0.3; curl -s -m 2 http://127.0.0.1:9333/json/version >/dev/null && break; done
for i in $(seq 1 3); do curl -s -X PUT 'http://127.0.0.1:9333/json/new?https://checkcc.org/' | grep -q webSocketDebuggerUrl && break; sleep 1; done
timeout 110 python3 /tmp/cc_run.py
echo CC_END
pkill -f 'user-data-dir=/tmp/cchp' 2>/dev/null
'@

function Push-File($content, $remote) {
    $tmp = Join-Path $env:TEMP ([IO.Path]::GetFileName($remote))
    [System.IO.File]::WriteAllText($tmp, $content, (New-Object Text.UTF8Encoding($false)))
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($tmp))
    $r = Guest ("echo " + $b64 + " | base64 -d > " + $remote + " && echo PUSHED", 60)
    return ($r.out -match 'PUSHED')
}

function Run-CheckCC {
    Step '复测：在客机里跑一次 checkcc'
    if (-not $sshReady) { Log '  跳过：连不上客机'; return $null }
    if (-not (Push-File $cdpPy '/tmp/cdp.py')) { Log '  推送 cdp.py 失败'; return $null }
    if (-not (Push-File $ccPy '/tmp/cc_run.py')) { Log '  推送 cc_run.py 失败'; return $null }
    if (-not (Push-File $ccSh '/tmp/cc.sh')) { Log '  推送 cc.sh 失败'; return $null }
    Log '  正在跑（约 40-70 秒）…'
    $r = Guest 'bash /tmp/cc.sh' 180
    $m = [regex]::Match([string]$r.out, 'CC_RESULT=(\{.*\})')
    if (-not $m.Success) { Log '  没抓到结果'; return $null }
    try { return ($m.Groups[1].Value | ConvertFrom-Json) } catch { return $null }
}

# ---------------- 主流程 ----------------
if (-not $Json) {
    Write-Host ''
    Write-Host 'Claude-Cage 一键修复' -ForegroundColor White
    Write-Host ('会话：' + (Get-Date -Format 'yyyy-MM-dd HH:mm')) -ForegroundColor DarkGray
    if ($DryRun) { Write-Host '预演模式：只说不做' -ForegroundColor Yellow }
    Write-Host ''
}

Backup-Configs
Fix-Workbench
Fix-GuestTimezone
Fix-GuestLocale
Fix-GuestFonts
Check-Mounts
Check-Controller

$cc = $null
if (-not $SkipWeb -and -not $DryRun) { $cc = Run-CheckCC }

# 不可自动修的部分，如实列出
$unfixable = @(
    '网络出口类型（数据中心/云厂商）：由出口 IP 的 ASN 决定，只能换真正的住宅 IP 节点',
    '多源 IP 情报一致性：三方库对同一 IP 的判断冲突，本地改不了',
    'claude.ai 浏览器侧可达性：Cloudflare 人机验证（cf-mitigated: challenge），浏览器能过、脚本过不了',
    'DNS/代理一致性：边缘机房与 IP 归属城市不一致（anycast 就近），换节点才会变'
)

if ($Json) {
    $obj = [ordered]@{
        ok          = $true
        dry_run     = [bool]$DryRun
        ssh         = $sshReady
        changes     = $script:changes
        checkcc     = $cc
        unfixable   = $unfixable
    }
    $obj | ConvertTo-Json -Depth 6
    exit 0
}

Write-Host ''
Write-Host '本次改动：' -ForegroundColor Cyan
if ($script:changes.Count -eq 0) { Write-Host '  无（要么本来就没问题，要么是预演）' }
else { foreach ($c in $script:changes) { Write-Host ('  · ' + $c) -ForegroundColor Green } }

if ($cc) {
    Write-Host ''
    Write-Host ('复测结果：' + $cc.score + '% 风险 · 高危 ' + $cc.high + ' 个 · ' + $cc.signals + ' 项信号') -ForegroundColor Yellow
    if ($cc.ded -and $cc.ded.Count -gt 0) {
        Write-Host '仍然扣分的项：' -ForegroundColor Cyan
        foreach ($d in $cc.ded) { Write-Host ('  - ' + $d) }
    }
}

Write-Host ''
Write-Host '改不了的部分（需要换出口或接受现状）：' -ForegroundColor Cyan
foreach ($u in $unfixable) { Write-Host ('  · ' + $u) -ForegroundColor DarkGray }

Write-Host ''
Write-Host '完成后建议重启一次 Cage 让工作台配置生效。' -ForegroundColor DarkGray
Write-Host ''
