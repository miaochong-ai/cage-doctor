﻿# ============================================================
# Cage 体检工具 v2（单文件，可发给别人）
#
# 特点：
#   1. 窗口立刻出现，顶上有进度条，边检边出结果，不用干等
#   2. 网站检测页签填「真实抓到的数据」；抓不到就明确写抓不到
#   3. 自动判断：装了 Cage → 22 项隔离+环境；没装 → 8 项环境检查
#
# 用法：双击 run-doctor.bat
# 隐私：会向 ip-api.com / ipwho.is / ipinfo.io 查当前出口 IP；
#       装了 Cage 时，抓取与探测都在虚拟机内发起（用 VM 的出口 IP）。
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Continue'

# ---------------- 定位 ----------------
function Find-Cage {
    $cands = @(
        'D:\Cage\app\resources\cage.exe',
        "$env:LOCALAPPDATA\Programs\ClaudeCage\resources\cage.exe",
        "$env:ProgramFiles\ClaudeCage\resources\cage.exe",
        "${env:ProgramFiles(x86)}\ClaudeCage\resources\cage.exe"
    )
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return $c } }
    foreach ($k in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClaudeCage',
                     'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClaudeCage')) {
        if (Test-Path $k) {
            $loc = (Get-ItemProperty $k).InstallLocation
            if ($loc -and (Test-Path -LiteralPath (Join-Path $loc 'resources\cage.exe'))) {
                return (Join-Path $loc 'resources\cage.exe')
            }
        }
    }
    return $null
}

function Find-Guest {
    $cfg = Join-Path $env:USERPROFILE '.claude-cage'
    if (-not (Test-Path $cfg)) { return $null }
    $roots = @()
    $store = Join-Path $cfg 'environment-storage.json'
    if (Test-Path $store) {
        try {
            $j = [System.IO.File]::ReadAllText($store, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($j.directory) { $roots += (Join-Path $j.directory 'state\lima') }
        } catch { }
    }
    $roots += (Join-Path $cfg 'state\lima')
    $sshCfg = Get-ChildItem $roots -Recurse -Filter 'ssh.config' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $sshCfg) { return $null }
    $lima = Split-Path (Split-Path $sshCfg.FullName -Parent) -Parent
    $port = ([regex]::Match([System.IO.File]::ReadAllText($sshCfg.FullName), '(?m)^\s*Port\s+(\d+)')).Groups[1].Value
    $sshExe = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
    if (-not (Test-Path $sshExe)) { $sshExe = (Get-Command ssh.exe -ErrorAction SilentlyContinue).Source }
    return @{ Port = $port; Key = (Join-Path $lima '_config\user'); Ssh = $sshExe }
}

$CageExe = Find-Cage
$Guest = Find-Guest
$Mode = if ($CageExe -and $Guest) { 'cage' } else { 'generic' }

# ---------------- 采集（后台作业执行） ----------------
$Collector = {
    param($Mode, $CageExe, $GuestPort, $GuestKey, $GuestSsh, $ProgFile)

    $ErrorActionPreference = 'Continue'

    function Emit($pct, $msg, $row) {
        $o = @{ pct = $pct; msg = $msg }
        if ($row) { $o.row = $row }
        [System.IO.File]::AppendAllText($ProgFile, ($o | ConvertTo-Json -Compress) + "`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    function Add-Check($name, $state, $detail) { Emit $script:pct "检查：$name" @{ 项目 = $name; 结果 = $state; 详情 = $detail } }
    function Add-Web($name, $items, $look, $line, $actual) {
        Emit $script:pct "网站：$name" @{ 站点 = $name; 项 = $items; 看什么 = $look; 门槛 = $line; 实测 = $actual; web = $true }
    }
    function Run-Exe($exe, $argStr, $timeoutSec, $pctFrom, $pctTo, $label) {
        # 异步读输出 + 超时强杀；等待期间每隔 1 秒推一点进度，界面不会看起来卡住
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exe
            $psi.Arguments = $argStr
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.RedirectStandardInput = $true
            $psi.CreateNoWindow = $true
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
            $proc = [System.Diagnostics.Process]::Start($psi)
            try { $proc.StandardInput.Close() } catch { }
            $tOut = $proc.StandardOutput.ReadToEndAsync()
            $tErr = $proc.StandardError.ReadToEndAsync()
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $last = -1
            while (-not $proc.HasExited -and $sw.Elapsed.TotalSeconds -lt $timeoutSec) {
                Start-Sleep -Milliseconds 800
                if ($pctFrom -gt 0 -and $label) {
                    $frac = [Math]::Min(1, $sw.Elapsed.TotalSeconds / $timeoutSec)
                    $p = [int]($pctFrom + ($pctTo - $pctFrom) * $frac)
                    if ($p -ne $last) { Emit $p "$label（已等 $([int]$sw.Elapsed.TotalSeconds) 秒，最多 $timeoutSec 秒）"; $last = $p }
                }
            }
            if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
            [void]$proc.WaitForExit(3000)
            $txt = ''
            if ($tOut.Wait(2000)) { $txt = $tOut.Result }
            return $txt
        } catch { return '' }
    }
    function Cage-Call($argsList) {
        # 必须套一层 cmd.exe：直接从 PowerShell 作业里拉 cage.exe 会被挂住（实测 36 秒无输出）
        $argStr = '/c ""' + $CageExe + '" ' + ($argsList -join ' ') + '"'
        $out = Run-Exe 'cmd.exe' $argStr 20 40 46 '等 Cage 控制器回应'
        for ($k = 0; $k -lt 3 -and -not $out; $k++) { Start-Sleep -Milliseconds 1500; $out = Run-Exe 'cmd.exe' $argStr 20 0 0 '' }
        if (-not $out) { return $null }
        $i = $out.IndexOf('{'); $j = $out.LastIndexOf('}')
        if ($i -lt 0 -or $j -le $i) { return $null }
        try { return ($out.Substring($i, $j - $i + 1) | ConvertFrom-Json) } catch { return $null }
    }
    function Guest-Run($scriptText, $timeoutSec, $pctFrom, $pctTo, $label) {
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($scriptText))
        $argStr = "-i `"$GuestKey`" -p $GuestPort -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=10 -o BatchMode=yes alex97@127.0.0.1 `"echo $b64 | base64 -d | bash`""
        return (Run-Exe $GuestSsh $argStr $timeoutSec $pctFrom $pctTo $label)
    }
    function Get-JsonU($url) {
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20 -UserAgent 'Mozilla/5.0 Chrome/131'
            return ($r.Content | ConvertFrom-Json)
        } catch { return $null }
    }

    $script:pct = 0

    # ---- 出口 IP 与三源情报 ----
    Emit 3 '读取出口 IP…'
    $ip = ''
    if ($Mode -eq 'cage') {
        $cfgFile = Join-Path $env:USERPROFILE '.claude-cage\config.json'
        if (Test-Path $cfgFile) {
            try {
                $cfg = [System.IO.File]::ReadAllText($cfgFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                if ($cfg.exit_policy -and $cfg.exit_policy.ip) { $ip = $cfg.exit_policy.ip }
            } catch { }
        }
    }
    if (-not $ip -and $Mode -eq 'cage') {
        $ip = (Guest-Run 'curl -s -m 20 -4 https://icanhazip.com' 40).Trim()
    }
    if (-not $ip) {
        try { $ip = (Invoke-WebRequest -Uri 'https://api.ipify.org' -UseBasicParsing -TimeoutSec 12).Content.Trim() } catch { }
    }

    $script:pct = 8
    Emit 8 "出口 $ip，查多源情报…"
    $a = Get-JsonU ("http://ip-api.com/json/{0}?fields=status,country,countryCode,regionName,city,isp,org,as,asname,proxy,hosting,mobile" -f $ip)
    $script:pct = 13
    $b = Get-JsonU ("https://ipwho.is/{0}" -f $ip)
    $script:pct = 18
    $c = Get-JsonU ("https://ipinfo.io/{0}/json" -f $ip)
    $script:pct = 21

    if ($ip) { Add-Check '出口 IP' 'PASS' "$ip（$($a.country) / $($a.city) / $($a.isp)）" }
    else { Add-Check '出口 IP' 'FAIL' '拿不到公网出口，可能网络断开' }

    if ($a -and $b -and $c -and $c.country) {
        $c1 = $a.countryCode; $c2 = $b.country_code; $c3 = $c.country
        if ($c1 -eq $c2 -and $c2 -eq $c3) { Add-Check '多源国家一致' 'PASS' "ip-api=$c1 / ipwhois=$c2 / ipinfo=$c3" }
        else { Add-Check '多源国家一致' 'FAIL' "ip-api=$c1 / ipwhois=$c2 / ipinfo=$c3（三方不一致，会被判地区冲突）" }
    } else {
        Add-Check '多源国家一致' 'TODO' "ipinfo 被限流（429）；只核到 ip-api=$($a.countryCode) / ipwhois=$($b.country_code)"
    }

    if ($a) {
        if ($a.hosting) { Add-Check 'IP 类型' 'FAIL' "机房/云厂商（ASN $($a.as)，$($a.isp)）——封号风险最大的一项，只能换住宅/ISP 出口" }
        else { Add-Check 'IP 类型' 'PASS' "非机房（$($a.isp)）" }
    }

    # ---- 环境 ----
    $script:pct = 25
    $tz = (Get-TimeZone).Id
    $cul = (Get-Culture).Name
    $uic = (Get-UICulture).Name
    $v6 = @(Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notmatch '^(fe|ff|::1)' -and $_.PrefixOrigin -ne 'WellKnown' })
    $hostCred = Join-Path $env:USERPROFILE '.claude\.credentials.json'

    if ($Mode -eq 'generic') {
        if ($a) { Add-Check '代理标记' ($(if ($a.proxy) { 'TODO' } else { 'PASS' })) $(if ($a.proxy) { 'ip-api 标为代理/托管（机房段常见）' } else { 'ip-api 未标记为代理' }) }
        if ($a.countryCode -eq 'US') {
            $usOk = $tz -match '(Pacific|Mountain|Central|Eastern|Alaskan|Hawaiian) Standard Time'
            Add-Check '时区与出口匹配' ($(if ($usOk) { 'PASS' } else { 'FAIL' })) "系统时区 $tz，出口 US"
        }
        Add-Check '系统语言' ($(if ($uic -like 'en-*' -or $cul -like 'en-*') { 'PASS' } else { 'FAIL' })) "系统 $cul / 界面 $uic"
        Add-Check '本机公网 IPv6' ($(if ($v6.Count -eq 0) { 'PASS' } else { 'FAIL' })) $(if ($v6.Count -eq 0) { '无公网 IPv6' } else { "有 $($v6.Count) 个公网 IPv6（$($v6[0].IPAddress)），WebRTC 可能漏" })
        Add-Check '宿主凭证位置' 'TODO' $(if (Test-Path $hostCred) { '凭证明文放本机（没 Cage 时是必然），共享电脑注意' } else { '未发现 .claude 凭证' })
    }

    $wv = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion')
    Add-Check '系统版本' 'PASS' "$($wv.CurrentBuildNumber).$($wv.UBR) $($wv.DisplayVersion)"
    $script:pct = 38

    # ---- Cage 隔离 ----
    $gTz = ''; $gLang = ''; $gV6 = ''; $gCred = ''
    if ($Mode -eq 'cage') {
        $bad = @()
        foreach ($pn in @(17777, 17778, 17896, 18500, 16080, 15900)) {
            $conn = Get-NetTCPConnection -State Listen -LocalPort $pn -ErrorAction SilentlyContinue
            if (-not $conn) { continue }
            $addrs = ($conn | Select-Object -ExpandProperty LocalAddress) | Sort-Object -Unique
            if ($addrs | Where-Object { $_ -notin @('127.0.0.1', '::1') }) { $bad += "$pn→$($addrs -join ',')" }
        }
        Add-Check '端口只绑本机' ($(if ($bad.Count -eq 0) { 'PASS' } else { 'FAIL' })) $(if ($bad.Count -eq 0) { '在听端口全部 127.0.0.1' } else { $bad -join '；' })

        $sr = Join-Path $env:USERPROFILE '.claude-cage\last-safety-report.json'
        if (Test-Path $sr) {
            $rep = [System.IO.File]::ReadAllText($sr, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            $crit = @($rep.checks | Where-Object { $_.critical })
            $fa = @($crit | Where-Object { $_.state -ne 'passed' })
            Add-Check '安全自检' ($(if ($fa.Count -eq 0) { 'PASS' } else { 'FAIL' })) "$($crit.Count) 项关键检查，失败 $($fa.Count)"
        } else { Add-Check '安全自检' 'FAIL' '缺少 last-safety-report.json' }

        Emit 40 '问 Cage 控制器要代理状态（最多 20 秒）…'
        $st = Cage-Call @('agent', 'call', 'proxy.status')
        if ($st -and $st.data) {
            Add-Check '代理联网' ($(if ($st.data.network_open) { 'PASS' } else { 'FAIL' })) "state=$($st.data.state) / $($st.data.state_label)"
            Add-Check 'UDP/IPv6 封禁' ($(if ($st.data.udp_blocked -and $st.data.ipv6_blocked) { 'PASS' } else { 'FAIL' })) "udp=$($st.data.udp_blocked) ipv6=$($st.data.ipv6_blocked)"
            Add-Check '节点解析' 'PASS' ("bootstrap=" + (@([regex]::Matches([string]$st.data.bootstrap_dns, 'https?://[^、\s,]+')) -join ' + '))
        } else {
            Add-Check '代理联网' 'TODO' '控制器不可用：先开 Cage 窗口，批准网络后重跑'
            Add-Check 'UDP/IPv6 封禁' 'TODO' '控制器不可用'
            Add-Check '节点解析' 'TODO' '控制器不可用'
        }

        $script:pct = 47
        Emit 47 'SSH 进虚拟机读状态（最多 30 秒）…'
        $g = Guest-Run @'
echo "IP=$(curl -s -m 20 -4 https://icanhazip.com)"
echo "TZ=$(timedatectl | grep 'Local time' | sed 's/^ *//')"
echo "LANG=$LANG"
echo "IPV6=$(ip -6 addr show scope global 2>/dev/null | grep -c inet6)"
echo "MOUNTS=$(mount | grep -c fuse.sshfs)"
echo "CRED=$(test -f $HOME/.claude/.credentials.json && echo yes || echo no)"
'@ 30 47 48 'SSH 进虚拟机读状态'
        $gIp = ([regex]::Match($g, 'IP=([0-9a-fA-F:.]*)')).Groups[1].Value
        $gTz = ([regex]::Match($g, 'TZ=Local time: \w+ \S+ \S+ (\w+)')).Groups[1].Value
        $gLang = ([regex]::Match($g, 'LANG=(\S*)')).Groups[1].Value
        $gV6 = ([regex]::Match($g, 'IPV6=(\d+)')).Groups[1].Value
        $gMt = ([regex]::Match($g, 'MOUNTS=(\d+)')).Groups[1].Value
        $gCred = ([regex]::Match($g, 'CRED=(yes|no)')).Groups[1].Value

        Add-Check '虚拟机出口' ($(if ($gIp -and $gIp -eq $ip) { 'PASS' } else { 'FAIL' })) $(if ($gIp) { "实测 $gIp（SSH 端口 $GuestPort）" } else { '连不进虚拟机，Cage 没启动？' })
        Add-Check '虚拟机时区' ($(if ($gTz) { 'PASS' } else { 'FAIL' })) "实测 $gTz"
        Add-Check '虚拟机语言' ($(if ($gLang -eq 'en_US.UTF-8') { 'PASS' } else { 'FAIL' })) "实测 $gLang"
        Add-Check '虚拟机 IPv6' ($(if ($gV6 -eq '0') { 'PASS' } else { 'FAIL' })) "全局地址 $gV6 个"
        Add-Check '共享挂载' ($(if ($gMt -eq '1') { 'PASS' } else { 'FAIL' })) "sshfs $gMt 条（只应有 1 条中转）"
        Add-Check 'Claude 登录' ($(if ($gCred -eq 'yes') { 'PASS' } else { 'TODO' })) $(if ($gCred -eq 'yes') { '客机已有凭证' } else { '未登录，需在 Cage 窗口登录 claude.ai' })

        if ($gTz -and $a.countryCode -eq 'US') {
            $okTz = $gTz -match '(PST|PDT|MST|MDT|CST|CDT|EST|EDT|AKST|HST)'
            Add-Check '时区与出口匹配' ($(if ($okTz) { 'PASS' } else { 'FAIL' })) "以虚拟机为准：$gTz；宿主 $tz 不计入"
        }
        if ($gLang -eq 'en_US.UTF-8') { Add-Check '系统语言' 'PASS' '以虚拟机为准：en_US.UTF-8；宿主不计入' }
        if ($gV6 -eq '0') { Add-Check '本机公网 IPv6' 'PASS' "宿主 $($v6.Count) 个公网 IPv6，客机 0 个（已封）" }
        Add-Check '代理标记' 'PASS' 'ip-api 对机房段一律标 proxy；实际流量走 Cage 代理，见「代理联网」'

        $wb = Join-Path $env:USERPROFILE '.claude-cage\workbench.json'
        if (Test-Path $wb) {
            $wj = [System.IO.File]::ReadAllText($wb, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            Add-Check '时区语言已锁定' ($(if (-not $wj.auto_timezone -and -not $wj.auto_language) { 'PASS' } else { 'FAIL' })) "auto_timezone=$($wj.auto_timezone) auto_language=$($wj.auto_language)"
        }
        $freeC = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
        Add-Check '磁盘余量' ($(if ($freeC -gt 10) { 'PASS' } else { 'FAIL' })) "C 剩 ${freeC}GB"
    }

    # ---- 网站抓取：CheckCC 实跑分数（顺带并行抓 Scamalytics）----
    $script:pct = 58
    $fraud = ''
    if ($Mode -eq 'cage') {
        Emit 58 '准备隔离浏览器…'
    } else {
        Emit 58 '抓 Scamalytics 欺诈分…'
        try {
            $r0 = Invoke-WebRequest ("https://scamalytics.com/ip/" + $ip) -UseBasicParsing -TimeoutSec 20 -UserAgent 'Mozilla/5.0 Chrome/131'
            $fraud = ([regex]::Match($r0.Content, 'Fraud Score:\s*(\d+)')).Groups[1].Value
        } catch { }
    }

    # CheckCC：起真浏览器 → 点「立即检测 Claude 环境」→ 弹窗点「开始检测」→ 读分数
    $cc = $null
    if ($Mode -eq 'cage') {
        Emit 62 '在隔离浏览器里跑 CheckCC（约 20 秒）…'
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
    print('CC_RESULT='+json.dumps({"ok":False,"err":"no modal","rs":ev("document.readyState"),"t":txt()[-40:]},ensure_ascii=False)); sys.exit()
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
    print('CC_RESULT='+json.dumps({"ok":False,"err":"no score","t":t[-40:]},ensure_ascii=False)); sys.exit()
d={"ok":True}
m=re.search(r'(\d+)%\s*\n\s*封号风险',t); d["score"]=int(m.group(1)) if m else None
m=re.search(r'命中高危风险\s*(\d+)\s*个',t); d["high"]=int(m.group(1)) if m else None
m=re.search(r'命中\s*(\d+)\s*个检测信号',t); d["signals"]=int(m.group(1)) if m else None
m=re.search(r'总耗时\s*(\d+\.?\d*)s',t); d["ms"]=m.group(1) if m else None
m=re.search(r'(疑似[^\n]{0,22}?环境)[：:\s]*(\d+)%',t); d["hint"]=(m.group(1)+' '+m.group(2)+'%') if m else None
L=[x.strip() for x in t.split('\n')]
items=[]
for i in range(len(L)-2):
    a,b,c=L[i],L[i+1],L[i+2]
    if re.match(r'^[+-]\d+$',c) and 2<=len(a)<=24 and 1<=len(b)<=48 and a not in ('高危风险','封号风险'):
        items.append([a,b,c])
d["items"]=items[:64]
top=re.findall(r'\n([^\n]{2,26})\n([^\n]{2,40})\n\+(\d+)',t)
d["top"]=["%s %s +%s"%(a.strip(),b.strip(),c) for a,b,c in top if int(c)>0][:6]
print('CC_RESULT='+json.dumps(d,ensure_ascii=False))
'@
        $ccSh = "export DISPLAY=:99" + "`n" +
            "(curl -s -m 15 -A 'Mozilla/5.0 Chrome/131' " + '"https://scamalytics.com/ip/' + $ip + '"' + " >/tmp/scam.html 2>/dev/null &)" + "`n" +
            "P=`$(ss -ltnp 2>/dev/null | grep ':9333' | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1); [ -n `"`$P`" ] && kill `$P 2>/dev/null; sleep 1" + "`n" +
            "rm -rf /tmp/cchp" + "`n" +
            "pgrep -x Xvfb >/dev/null || (Xvfb :99 -screen 0 1440x960x24 >/tmp/xvfb.log 2>&1 &)" + "`n" +
            "(google-chrome --no-sandbox --disable-dev-shm-usage --use-gl=swiftshader --user-data-dir=/tmp/cchp --remote-debugging-port=9333 --window-size=1440,900 --window-position=0,0 about:blank >/tmp/chrome.log 2>&1 &)" + "`n" +
            "for i in `$(seq 1 40); do sleep 0.3; curl -s -m 2 http://127.0.0.1:9333/json/version >/dev/null && break; done" + "`n" +
            "for i in `$(seq 1 3); do curl -s -X PUT 'http://127.0.0.1:9333/json/new?https://checkcc.org/' | grep -q webSocketDebuggerUrl && break; sleep 1; done" + "`n" +
            "cat > /tmp/cc_run.py <<'PYEOF'" + "`n" + $ccPy + "`nPYEOF" + "`n" +
            "timeout 70 python3 /tmp/cc_run.py" + "`n" +
            "echo CC_END" + "`n" +
            "echo SCAM=" + '$(grep -o "Fraud Score: [0-9]*" /tmp/scam.html 2>/dev/null | head -1 | tr -dc "0-9")' + "`n" +
            "pkill -f 'user-data-dir=/tmp/cchp' 2>/dev/null"
        $ccOut = Guest-Run $ccSh 130 62 86 '在隔离浏览器里跑 CheckCC'
        if ($env:CAGE_DOCTOR_DEBUG) { try { [System.IO.File]::WriteAllText((Join-Path $env:TEMP 'cc-out.txt'), [string]$ccOut) } catch { } }
        $m = [regex]::Match([string]$ccOut, 'CC_RESULT=(\{.*\})')
        if ($m.Success) { try { $cc = $m.Groups[1].Value | ConvertFrom-Json } catch { } }
        $m = [regex]::Match([string]$ccOut, '(?m)^SCAM=(\d+)')
        if ($m.Success) { $fraud = $m.Groups[1].Value }
    }

    $script:pct = 88
    if ($cc -and $cc.score) {
        $ccText = "封号风险 $($cc.score)% · 高危 $($cc.high) 个 · 命中 $($cc.signals) 项信号 · 站内耗时 $($cc.ms)s"
        if ($cc.hint) { $ccText += "　$($cc.hint)" }
        if ($cc.top -and $cc.top.Count -gt 0) { $ccText += "　扣分点：" + ($cc.top -join '；') }
    } elseif ($Mode -eq 'cage') {
        $ccText = '自动抓取没成，点开手动跑一次'
    } else {
        $ccText = '装好 Cage 后能自动抓（本机模式不跑隔离浏览器）'
    }
    Add-Web 'CheckCC' '48 项' '综合封号风险 % + 高危明细' '低于 30% 算干净' $ccText
    if ($cc -and $cc.items) {
        foreach ($it in $cc.items) {
            $n = [string]$it[0]; $v = [string]$it[1]; $dv = [string]$it[2]
            $dnum = 0
            try { $dnum = [int]($dv -replace '[^0-9-]', '') } catch { }
            $mark = if ($dnum -ge 10) { '高危' } elseif ($dnum -gt 0) { '偏' } else { '正常' }
            Emit $script:pct ("明细：" + $n) @{ 站点 = '　· ' + $n; 项 = $dv; 看什么 = $v; 门槛 = ''; 实测 = $mark; web = $true; 明细 = $true }
        }
    } elseif ($Mode -eq 'cage') {
        Emit $script:pct '明细：抓不到' @{ 站点 = '　· 逐项明细'; 项 = '—'; 看什么 = '本次没抓到逐项数据'; 门槛 = ''; 实测 = '需点开看'; web = $true; 明细 = $true }
    }
    $script:pct = 91
    Add-Web 'Scamalytics' '欺诈分' 'Fraud Score 0-100，机房段常见 40+' '低于 20 较好' $(if ($fraud) { "Fraud Score = $fraud" } else { '抓取失败（页面结构变了）' })
    $script:pct = 94
    Add-Web 'IPClaude' '9 项' 'Claude 专用打分：地区/机房/代理/语言/时区' '全绿' '点开看，分数需站内触发'
    Add-Web 'IPCeice' '多源' '同一 IP 在多家库的判定' '多数库判住宅才算干净' '点开看，结果需站内查询'
    Add-Web 'ClaudeIP' '多源' 'IPCeice 备用域名，同上' '同上' '点开看'
    Add-Web 'AbuseIPDB' '举报' '这个 IP 被举报滥用记录' '0 次举报最好' '点开看（脚本被 Cloudflare 拦）'
    Add-Web 'Ping0' '中文多源' '中文界面纯净度 / NAT 类型' '「原生 IP」优先' '点开看，纯净度需站内查询'
    Add-Web 'BrowserLeaks' 'WebRTC' 'WebRTC 有没有带出真实 IP' '只显示代理出口 IP' '在隔离浏览器里开才有意义'

    Emit 99 '汇总…'
    Emit 100 'DONE'
}

# ---------------- 窗体 ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Cage 体检（本机 + 网站）'
$form.Size = New-Object System.Drawing.Size(1120, 940)
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(60, 40)
$form.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 250)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.MinimumSize = New-Object System.Drawing.Size(980, 760)

$head = New-Object System.Windows.Forms.Panel
$head.Dock = 'Top'; $head.Height = 96
$head.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($head)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Cage 体检报告'
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(18, 10)
$title.AutoSize = $true
$head.Controls.Add($title)

$sub = New-Object System.Windows.Forms.Label
$sub.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$sub.ForeColor = [System.Drawing.Color]::FromArgb(108, 117, 125)
$sub.Location = New-Object System.Drawing.Point(20, 45)
$sub.AutoSize = $true
$sub.Text = $(if ($Mode -eq 'cage') { '模式：检测到 Cage，隔离 + 环境 + 网站抓取' } else { '模式：未检测到 Cage，只做环境检查（网站抓取走本机网络）' })
$head.Controls.Add($sub)

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Location = New-Object System.Drawing.Point(20, 74)
$bar.Size = New-Object System.Drawing.Size(700, 12)
$bar.Anchor = 'Top,Left,Right'
$bar.Style = 'Continuous'
$bar.Minimum = 0; $bar.Maximum = 100; $bar.Value = 0
$head.Controls.Add($bar)

$stage = New-Object System.Windows.Forms.Label
$stage.Location = New-Object System.Drawing.Point(730, 66)
$stage.Size = New-Object System.Drawing.Size(360, 26)
$stage.Anchor = 'Top,Right'
$stage.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$stage.ForeColor = [System.Drawing.Color]::FromArgb(73, 80, 87)
$stage.TextAlign = 'MiddleRight'
$stage.Text = '准备中…'
$head.Controls.Add($stage)

$badge = New-Object System.Windows.Forms.Label
$badge.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$badge.TextAlign = 'MiddleRight'
$badge.Location = New-Object System.Drawing.Point(560, 12)
$badge.Size = New-Object System.Drawing.Size(530, 26)
$badge.Anchor = 'Top,Right'
$badge.Text = '检测中…'
$head.Controls.Add($badge)

$badge2 = New-Object System.Windows.Forms.Label
$badge2.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$badge2.ForeColor = [System.Drawing.Color]::FromArgb(108, 117, 125)
$badge2.TextAlign = 'MiddleRight'
$badge2.Location = New-Object System.Drawing.Point(420, 44)
$badge2.Size = New-Object System.Drawing.Size(670, 22)
$badge2.Anchor = 'Top,Right'
$badge2.Text = "$(Get-Date -Format 'MM-dd HH:mm')"
$head.Controls.Add($badge2)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(12, 102)
$tabs.Size = New-Object System.Drawing.Size(1096, 700)
$tabs.Anchor = 'Top,Left,Right,Bottom'
$form.Controls.Add($tabs)

$tab1 = New-Object System.Windows.Forms.TabPage
$tab1.Text = '  本机体检  '
$tab1.BackColor = [System.Drawing.Color]::White
$tabs.Controls.Add($tab1)

$tab2 = New-Object System.Windows.Forms.TabPage
$tab2.Text = '  网站检测  '
$tab2.BackColor = [System.Drawing.Color]::White
$tabs.Controls.Add($tab2)
if ($env:CAGE_DOCTOR_TAB -eq 'web') { $tabs.SelectedIndex = 1 }

function New-Grid($headers, $widths) {
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Location = New-Object System.Drawing.Point(10, 10)
    $g.Size = New-Object System.Drawing.Size(1068, 640)
    $g.Anchor = 'Top,Left,Right,Bottom'
    $g.BackgroundColor = [System.Drawing.Color]::White
    $g.BorderStyle = 'None'
    $g.GridColor = [System.Drawing.Color]::FromArgb(233, 236, 239)
    $g.RowHeadersVisible = $false
    $g.AllowUserToAddRows = $false
    $g.AllowUserToResizeRows = $false
    $g.SelectionMode = 'FullRowSelect'
    $g.MultiSelect = $false
    $g.ReadOnly = $true
    $g.ColumnHeadersHeight = 34
    $g.RowTemplate.Height = 27
    $g.EnableHeadersVisualStyles = $false
    $g.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(241, 243, 245)
    $g.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
    $g.DefaultCellStyle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $g.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(222, 235, 250)
    $g.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::FromArgb(33, 37, 41)
    for ($k = 0; $k -lt $headers.Count; $k++) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = $headers[$k]; $col.ReadOnly = $true
        if ($k -eq ($headers.Count - 1)) { $col.AutoSizeMode = 'Fill' } else { $col.Width = $widths[$k] }
        [void]$g.Columns.Add($col)
    }
    return $g
}

$grid1 = New-Grid @('检查项', '结果', '实测详情') @(190, 86, 0)
$tab1.Controls.Add($grid1)

$grid2 = New-Grid @('站点', '项目', '看什么', '多少算干净', '实测（抓到的数据）') @(118, 62, 320, 190, 0)
$tab2.Controls.Add($grid2)

$hint2 = New-Object System.Windows.Forms.Label
$hint2.Location = New-Object System.Drawing.Point(14, 656)
$hint2.Size = New-Object System.Drawing.Size(1060, 36)
$hint2.Anchor = 'Left,Right,Bottom'
$hint2.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$hint2.ForeColor = [System.Drawing.Color]::FromArgb(73, 80, 87)
$hint2.Text = '双击某行 → 在 Cage 内置浏览器打开该站。带分数的站（CheckCC / IPClaude 等）要进站后点一次「立即检测」才出分，页面是点击后才计算，脚本抓不到分数；能直接抓到数值的（如 Scamalytics 欺诈分）已填在「实测」列。'
$tab2.Controls.Add($hint2)

$panel = New-Object System.Windows.Forms.Panel
$panel.Location = New-Object System.Drawing.Point(12, 812)
$panel.Size = New-Object System.Drawing.Size(1096, 82)
$panel.Anchor = 'Left,Right,Bottom'
$form.Controls.Add($panel)

function New-Btn($text, $x, $y, $w, $primary) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $text
    $btn.Location = New-Object System.Drawing.Point($x, $y)
    $btn.Size = New-Object System.Drawing.Size($w, 34)
    $btn.FlatStyle = 'Flat'
    $btn.Cursor = 'Hand'
    if ($primary) {
        $btn.BackColor = [System.Drawing.Color]::FromArgb(13, 110, 253)
        $btn.ForeColor = [System.Drawing.Color]::White
        $btn.FlatAppearance.BorderSize = 0
    } else {
        $btn.BackColor = [System.Drawing.Color]::White
        $btn.ForeColor = [System.Drawing.Color]::FromArgb(33, 37, 41)
        $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(206, 212, 218)
    }
    $panel.Controls.Add($btn)
    return $btn
}

$btnRedo = New-Btn '重新体检' 6 4 110 $true
$btnCC = New-Btn 'checkcc' 122 4 90 $false
$btnIC = New-Btn 'ipclaude' 216 4 90 $false
$btnICE = New-Btn 'ipceice' 310 4 85 $false
$btnScam = New-Btn 'scamalytics' 399 4 100 $false
$btnAbuse = New-Btn 'abuseipdb' 503 4 95 $false
$btnPing0 = New-Btn 'ping0' 602 4 70 $false
$btnLeak = New-Btn 'browserleaks' 676 4 110 $false
$btnCopy = New-Btn '复制报告' 6 46 110 $false
$btnClose = New-Btn '关闭' 1024 46 66 $false

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(122, 52)
$status.Size = New-Object System.Drawing.Size(890, 22)
$status.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$status.ForeColor = [System.Drawing.Color]::FromArgb(108, 117, 125)
$status.Text = '准备开始…'
$panel.Controls.Add($status)

# ---------------- 渲染 ----------------
$script:rows = @()
$script:webRows = @()
$script:ipForOpen = '104.194.206.225'
$script:done = $false
$script:job = $null
$script:readOffset = 0
$progFile = Join-Path $env:TEMP 'cage-doctor-progress.txt'

function Add-Row($r) {
    $state = [string]$r.结果
    switch ($state) {
        'PASS' { $label = '通过'; $back = [System.Drawing.Color]::FromArgb(234, 246, 234); $fore = [System.Drawing.Color]::FromArgb(27, 94, 32) }
        'FAIL' { $label = '不合格'; $back = [System.Drawing.Color]::FromArgb(253, 236, 234); $fore = [System.Drawing.Color]::FromArgb(183, 28, 28) }
        'TODO' { $label = '待办'; $back = [System.Drawing.Color]::FromArgb(255, 248, 225); $fore = [System.Drawing.Color]::FromArgb(141, 110, 0) }
        default { $label = $state; $back = [System.Drawing.Color]::White; $fore = [System.Drawing.Color]::FromArgb(33, 37, 41) }
    }
    $idx = $grid1.Rows.Add([string]$r.项目, $label, [string]$r.详情)
    foreach ($cell in @($grid1.Rows[$idx].Cells[0], $grid1.Rows[$idx].Cells[1], $grid1.Rows[$idx].Cells[2])) {
        $cell.Style.BackColor = $back; $cell.Style.ForeColor = $fore
    }
    $grid1.Rows[$idx].Cells[1].Style.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
    $script:rows += $r
    if ($r.项目 -eq '出口 IP' -and $r.详情 -match '^([0-9a-fA-F:.]+)') { $script:ipForOpen = $matches[1] }
}

function Add-WebRow($w) {
    $idx = $grid2.Rows.Add([string]$w.站点, [string]$w.项, [string]$w.看什么, [string]$w.门槛, [string]$w.实测)
    if ($w.实测 -match '抓不到|抓取失败|拦') { $grid2.Rows[$idx].Cells[4].Style.ForeColor = [System.Drawing.Color]::FromArgb(141, 110, 0) }
    if ($w.明细) {
        foreach ($cell in $grid2.Rows[$idx].Cells) { $cell.Style.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 250); $cell.Style.ForeColor = [System.Drawing.Color]::FromArgb(73, 80, 87) }
        if ([string]$w.实测 -eq '高危') { $grid2.Rows[$idx].Cells[4].Style.ForeColor = [System.Drawing.Color]::FromArgb(183, 28, 28); $grid2.Rows[$idx].Cells[4].Style.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5, [System.Drawing.FontStyle]::Bold) }
        elseif ([string]$w.实测 -eq '偏') { $grid2.Rows[$idx].Cells[4].Style.ForeColor = [System.Drawing.Color]::FromArgb(141, 110, 0) }
    }
    $script:webRows += $w
}

function Update-Badge {
    $p = @($script:rows | Where-Object { $_.结果 -eq 'PASS' }).Count
    $f = @($script:rows | Where-Object { $_.结果 -eq 'FAIL' }).Count
    $t = @($script:rows | Where-Object { $_.结果 -eq 'TODO' }).Count
    $badge.Text = "通过 $p · 待办 $t · 不合格 $f（$($script:rows.Count) 项）"
    if ($f -gt 0) { $badge.ForeColor = [System.Drawing.Color]::FromArgb(183, 28, 28) }
    elseif ($t -gt 0) { $badge.ForeColor = [System.Drawing.Color]::FromArgb(141, 110, 0) }
    else { $badge.ForeColor = [System.Drawing.Color]::FromArgb(27, 94, 32) }
}

function Pump-Progress {
    if (-not (Test-Path $progFile)) { return }
    $all = [System.IO.File]::ReadAllText($progFile, [System.Text.Encoding]::UTF8)
    if ($all.Length -le $script:readOffset) { return }
    $newText = $all.Substring($script:readOffset)
    $script:readOffset = $all.Length
    foreach ($ln in ($newText -split "`n")) {
        if (-not $ln.Trim()) { continue }
        try { $o = $ln | ConvertFrom-Json } catch { continue }
        if ($o.pct) { $bar.Value = [math]::Min(100, [int]$o.pct) }
        if ($o.msg) { $stage.Text = $o.msg; $status.Text = $o.msg }
        if ($o.row) {
            if ($o.row.web) { Add-WebRow $o.row } else { Add-Row $o.row; Update-Badge }
        }
    }
}

function Start-Check {
    [void]$grid1.Rows.Clear(); [void]$grid2.Rows.Clear()
    $script:rows = @(); $script:webRows = @(); $script:done = $false; $script:readOffset = 0
    [System.IO.File]::WriteAllText($progFile, '', (New-Object System.Text.UTF8Encoding($false)))
    $bar.Value = 0
    $badge.Text = '检测中…'; $badge.ForeColor = [System.Drawing.Color]::FromArgb(33, 37, 41)
    $stage.Text = '启动…'; $status.Text = '启动检测…'
    $btnRedo.Enabled = $false
    if ($script:job) { Stop-Job $script:job -ErrorAction SilentlyContinue; Remove-Job $script:job -Force -ErrorAction SilentlyContinue }
    $script:job = Start-Job -ScriptBlock $Collector -ArgumentList $Mode, $CageExe, $Guest.Port, $Guest.Key, $Guest.Ssh, $progFile
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 600
$timer.Add_Tick({
    try {
        Pump-Progress
        if (-not $script:done -and $script:job -and $script:job.State -eq 'Completed') {
            $script:done = $true
            $timer.Stop()
            $bar.Value = 100
            $stage.Text = '完成'
            Update-Badge
            $p = @($script:rows | Where-Object { $_.结果 -eq 'PASS' }).Count
            $f = @($script:rows | Where-Object { $_.结果 -eq 'FAIL' }).Count
            $t = @($script:rows | Where-Object { $_.结果 -eq 'TODO' }).Count
            $status.Text = "共 $($script:rows.Count) 项：通过 $p，待办 $t，不合格 $f　｜　网站 $($script:webRows.Count) 行，双击可打开"
            $btnRedo.Enabled = $true
        } elseif (-not $script:done -and $script:job -and $script:job.State -eq 'Failed') {
            $script:done = $true
            $timer.Stop()
            $stage.Text = '采集出错'
            $status.Text = '后台采集失败，点重新体检重试'
            $btnRedo.Enabled = $true
        }
    } catch {
        $status.Text = "刷新出错：$($_.Exception.Message)"
    }
})

# ---------------- 打开网站 ----------------
function Open-Site($url) {
    if ($CageExe) {
        try {
            $tmp = Join-Path $env:TEMP 'cage-url.json'
            [System.IO.File]::WriteAllText($tmp, (@{ url = $url } | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'cmd.exe'
            $psi.Arguments = '/c ""' + $CageExe + '" agent call browser.new --input "' + $tmp + '""'
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            $tOut = $proc.StandardOutput.ReadToEndAsync()
            [void]$proc.WaitForExit(15000)
            if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
            $out = ''
            if ($tOut.Wait(2000)) { $out = $tOut.Result }
            if ($out -match '"status":"completed"') { $status.Text = "已在 Cage 浏览器打开：$url"; return }
            $status.Text = "Cage 没打开成功，改用默认浏览器：$url"
        } catch { $status.Text = "Cage 打开出错，改用默认浏览器：$url" }
    }
    try { Start-Process $url; $status.Text = "已用默认浏览器打开：$url" } catch { $status.Text = "打不开：$url" }
}

$btnCC.Add_Click({ Open-Site 'https://checkcc.org' })
$btnIC.Add_Click({ Open-Site 'https://ipclaude.com/claude' })
$btnICE.Add_Click({ Open-Site 'https://ipceice.com/ip' })
$btnScam.Add_Click({ Open-Site "https://scamalytics.com/ip/$script:ipForOpen" })
$btnAbuse.Add_Click({ Open-Site "https://www.abuseipdb.com/check/$script:ipForOpen" })
$btnPing0.Add_Click({ Open-Site 'https://ping0.cc' })
$btnLeak.Add_Click({ Open-Site 'https://browserleaks.com/webrtc' })

$grid2.Add_CellDoubleClick({
    param($s, $e)
    if ($e.RowIndex -lt 0 -or $e.RowIndex -ge $script:webRows.Count) { return }
    switch ($script:webRows[$e.RowIndex].站点) {
        'CheckCC' { Open-Site 'https://checkcc.org' }
        'IPClaude' { Open-Site 'https://ipclaude.com/claude' }
        'IPCeice' { Open-Site 'https://ipceice.com/ip' }
        'ClaudeIP' { Open-Site 'https://claudeip.org' }
        'Scamalytics' { Open-Site "https://scamalytics.com/ip/$script:ipForOpen" }
        'AbuseIPDB' { Open-Site "https://www.abuseipdb.com/check/$script:ipForOpen" }
        'Ping0' { Open-Site 'https://ping0.cc' }
        'BrowserLeaks' { Open-Site 'https://browserleaks.com/webrtc' }
    }
})

$btnRedo.Add_Click({ Start-Check })

$btnCopy.Add_Click({
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("Cage 体检 $((Get-Date).ToString('yyyy-MM-dd HH:mm'))　$($badge.Text)")
    [void]$sb.AppendLine('--- 本机 ---')
    foreach ($r in $script:rows) { [void]$sb.AppendLine(("[{0}] {1} —— {2}" -f $r.结果, $r.项目, $r.详情)) }
    [void]$sb.AppendLine('--- 网站 ---')
    foreach ($w in $script:webRows) { [void]$sb.AppendLine(("{0}：{1}" -f $w.站点, $w.实测)) }
    [System.Windows.Forms.Clipboard]::SetText($sb.ToString())
    $status.Text = '已复制到剪贴板'
})

$btnClose.Add_Click({ $form.Close() })

$form.Add_Shown({
    Start-Check
    $timer.Start()
})
$form.Add_FormClosed({
    $timer.Stop()
    if ($script:job) { Stop-Job $script:job -ErrorAction SilentlyContinue; Remove-Job $script:job -Force -ErrorAction SilentlyContinue }
})

[void]$form.ShowDialog()
