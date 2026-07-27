# PixAgent —— Windows 侧常驻执行器（文件通道）。
#
# 为什么不用 SSH：这台机器的防火墙会在若干次连接后拦掉 SSH，导致命令随机超时/空输出，
# 排查时根本分不清是"命令失败"还是"连接被拦"。而 C$ 已经 SMB 挂载在 mac 上，
# 读写文件完全不经过 SSH —— 于是改成：mac 丢任务文件，这个 agent 执行并写回结果。
#
# 协议（全部 UTF-8）：
#   in\<id>.job    任务文件，内容就是一行 cmd 命令
#   out\<id>.out   合并后的 stdout+stderr
#   out\<id>.done  写完 .out 之后才创建，作为"结果就绪"的原子信号
#                  （先写 .out 再写 .done，mac 只等 .done，避免读到半截文件）
$root = "C:\_pixagent"
$in   = Join-Path $root "in"
$out  = Join-Path $root "out"
$log  = Join-Path $root "agent.log"
New-Item -ItemType Directory -Force -Path $in, $out | Out-Null

function Log($m) {
    try { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format "s"), $m) -Encoding UTF8 } catch {}
}
Log "PixAgent 启动 pid=$PID"
"ready" | Out-File -FilePath (Join-Path $root "ready.txt") -Encoding UTF8

while ($true) {
    try {
        $jobs = Get-ChildItem -Path $in -Filter *.job -ErrorAction SilentlyContinue | Sort-Object CreationTime
        foreach ($j in $jobs) {
            $id = [IO.Path]::GetFileNameWithoutExtension($j.Name)
            $cmd = ""
            try { $cmd = (Get-Content -Path $j.FullName -Raw -Encoding UTF8).Trim() } catch { }
            Remove-Item $j.FullName -Force -ErrorAction SilentlyContinue
            if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
            Log "run $id : $cmd"

            $body = ""
            try {
                # 用 cmd /c 跑，和用户在命令行里敲的行为一致；stderr 合并进来一起回
                $psi = New-Object Diagnostics.ProcessStartInfo
                $psi.FileName = "$env:ComSpec"
                $psi.Arguments = "/c chcp 65001 >nul & " + $cmd
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
                $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
                $psi.WorkingDirectory = "C:\"
                $p = [Diagnostics.Process]::Start($psi)
                $so = $p.StandardOutput.ReadToEndAsync()
                $se = $p.StandardError.ReadToEndAsync()
                # 单条任务最多 10 分钟，超了就杀掉并说明，别让 agent 卡死在一条命令上
                if (-not $p.WaitForExit(600000)) {
                    try { $p.Kill($true) } catch {}
                    $body = "[PixAgent] 超时 600s，已终止`n"
                }
                $body += $so.Result + $se.Result
                $body += "`n[PixAgent] exit=" + $p.ExitCode
            } catch {
                $body = "[PixAgent] 执行异常: " + $_.Exception.Message
            }

            $outFile = Join-Path $out ($id + ".out")
            [IO.File]::WriteAllText($outFile, $body, (New-Object Text.UTF8Encoding($false)))
            # .done 最后写：mac 只等这个，保证读到的 .out 是完整的
            [IO.File]::WriteAllText((Join-Path $out ($id + ".done")), "1", (New-Object Text.UTF8Encoding($false)))
            Log "done $id exit-written"
        }
    } catch {
        Log ("循环异常: " + $_.Exception.Message)
    }
    Start-Sleep -Milliseconds 300
}
