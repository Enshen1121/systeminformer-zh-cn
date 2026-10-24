param(
    [ValidateSet('Library','Inventory','Apply')][string]$Mode='Inventory',
    [ValidatePattern('^(report|[0-9]+-[0-9]+)$')][string]$Session='report'
)
$ErrorActionPreference='Stop'
$script:ZhRoot=Split-Path $PSScriptRoot -Parent
$script:DataRoot=Join-Path $script:ZhRoot 'work\third-party'
$script:OutputRoot=Join-Path $script:ZhRoot 'outputs\third-party'
function Normalize-Path([string]$Path) {
    if (-not $Path) { return '' }
    $p=[Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if ($p.StartsWith('\\?\')) { $p=$p.Substring(4) }
    if ($p.StartsWith('\??\')) { $p=$p.Substring(4) }
    if ($p -match '^\\SystemRoot\\') { $p=$env:SystemRoot+$p.Substring(11) }
    try { if ([IO.Path]::IsPathRooted($p)) { return [IO.Path]::GetFullPath($p).TrimEnd('\') } } catch {}
    return $p
}
function Test-Under([string]$Path,[string]$Root) {
    if (-not $Path -or -not $Root) { return $false }
    return $Path.Equals($Root,[StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)
}
function Get-LaunchPath([string]$Command) {
    if (-not $Command) { return '' }
    $c=[Environment]::ExpandEnvironmentVariables($Command.Trim())
    if ($c -match '^"([^"]+)"') { return Normalize-Path $Matches[1] }
    if ($c -match '^(.+?\.(?:exe|com|dll))(?=\s|$)') { return Normalize-Path $Matches[1] }
    if ($c -match '^(\S+)') { return Normalize-Path $Matches[1] }
    return ''
}
function Get-Version([string]$Path) {
    try { $v=[Diagnostics.FileVersionInfo]::GetVersionInfo($Path); return [pscustomobject]@{Description=$v.FileDescription;Company=$v.CompanyName} }
    catch { return [pscustomobject]@{Description='';Company=''} }
}
function Test-SystemPath([string]$Path,[string]$Company) {
    $p=Normalize-Path $Path
    if (Test-Under $p (Normalize-Path $env:windir)) { return -not $Company -or $Company -match '^Microsoft\b' }
    if ($Company -match '^Microsoft\b' -and $p -match '\\(?:Windows Defender|Windows Defender Advanced Threat Protection|Windows Media Player|Common Files\\Microsoft Shared\\ink)\\') { return $true }
    return $p -match '\\WindowsApps\\(?:MicrosoftWindows\.|Microsoft\.(?:WindowsNotepad|WidgetsPlatformRuntime|YourPhone|DesktopAppInstaller|WindowsTerminal|WindowsAppRuntime|SecHealthUI|LockApp|StartExperiences))[^\\]*\\'
}
function Get-Protection([string]$Path,[string]$Company) {
    if (Test-SystemPath $Path $Company) { return 'Windows 组件' }
    if ((Test-Under $Path $script:ZhRoot) -or (Split-Path $Path -Leaf) -match '^(?:SystemInformer|Code|ChatGPT|codex(?:-code-mode-host|-computer-use-swift|-windows-sandbox-service)?|copilot-runtime|node_repl|pwsh|powershell)\.exe$' -or $Path -match '\\(?:OpenAI|\.codex|\.agents|OpenAI\.Codex_[^\\]+)\\') { return '管理/当前工作环境' }
    if ((Test-Under $Path $env:windir) -or $Company -match 'NVIDIA|Advanced Micro Devices|Intel|Realtek|Lenovo|联想|火绒|Synaptics|ELAN|Huorong|Kaspersky|ESET|McAfee|CrowdStrike|Symantec|Trend Micro|Elevoc|Nahimic|A-Volute' -or $Path -match '\\(?:Lenovo|Windows Defender|Windows Defender Advanced Threat Protection)\\') { return '硬件/安全组件，需单独管理' }
    if ($Path -match '\\Microsoft\\EdgeWebView\\') { return '共享运行库，需单独管理' }
    return ''
}
function Get-AppRoot([string]$Path) {
    $directory=Split-Path $Path -Parent
    # Never infer ownership from a shared Windows/user/download directory.
    if (-not $directory -or (Test-Under $directory $env:windir)) { return '' }
    if ($directory -match '^(.+?\\WindowsApps\\[^\\]+)') { return $Matches[1] }
    foreach ($root in @($env:ProgramFiles,${env:ProgramFiles(x86)},($env:LOCALAPPDATA+'\Programs'),($env:LOCALAPPDATA+'\Kingsoft'),($env:APPDATA+'\Tencent'))) {
        if ($root -and (Test-Under $directory $root) -and -not $directory.Equals($root,[StringComparison]::OrdinalIgnoreCase)) {
            # Only trim a version folder at the end or directly before a known binary subfolder.
            return ($directory -replace '\\\d+(?:\.\d+){1,5}(?:\\(?:Application|office6|tray))?$','')
        }
    }
    return ''
}
function Test-AppMatch([string]$Target,[string]$Path,[string]$AppRoot) {
    $t=Normalize-Path $Target
    return $t.Equals((Normalize-Path $Path),[StringComparison]::OrdinalIgnoreCase) -or ($AppRoot -and (Test-Under $t $AppRoot))
}
function Test-TaskOwnership($Task,[string]$Path,[string]$AppRoot) {
    if (-not @($Task.Actions).Count) { return $false }
    foreach ($action in $Task.Actions) {
        $target=Get-LaunchPath $action.Execute
        if (-not $target -or -not (Test-AppMatch $target $Path $AppRoot) -or (Get-Protection $target (Get-Version $target).Company)) { return $false }
    }
    return $true
}
function Get-TaskIdentity([string]$Xml) {
    $document=New-Object xml; $document.LoadXml($Xml)
    $enabled=$document.SelectSingleNode('/*[local-name()="Task"]/*[local-name()="Settings"]/*[local-name()="Enabled"]')
    if ($enabled) { $null=$enabled.ParentNode.RemoveChild($enabled) }
    return $document.OuterXml
}
function Test-FolderIdentity($Entry) {
    try {
        if ((Get-FileHash -LiteralPath $Entry.File -Algorithm SHA256).Hash -ne $Entry.Hash) { return $false }
        $target=if ([IO.Path]::GetExtension($Entry.File) -eq '.lnk') { Normalize-Path (New-Object -ComObject WScript.Shell).CreateShortcut($Entry.File).TargetPath } else { Normalize-Path $Entry.File }
        return $target -eq $Entry.Path
    } catch { return $false }
}
function Get-ServiceIdentity([string]$Name) {
    $svc=Get-CimInstance Win32_Service -Filter ("Name='"+$Name.Replace("'","''")+"'")
    if (-not $svc) { throw '服务已不存在' }
    $path=Get-LaunchPath $svc.PathName
    $key='HKLM:\SYSTEM\CurrentControlSet\Services\'+$Name
    if ($path -and (Split-Path $path -Leaf) -match '^svchost(?:\.exe)?$') { $path=Normalize-Path (Get-ItemProperty -LiteralPath ($key+'\Parameters') -Name ServiceDll).ServiceDll }
    $settings=Get-ItemProperty -LiteralPath $key
    return [pscustomobject]@{Name=$Name;Path=$path;State=$svc.State;StartMode=$svc.StartMode;DelayedAutoStart=$settings.DelayedAutoStart;Command=$svc.PathName}
}
function Test-ServiceOwnership($Current,$Entry) {
    return $Current.Path -and $Current.Path -eq $Entry.Path -and -not (Get-Protection $Current.Path (Get-Version $Current.Path).Company) -and (-not $Entry.Command -or $Entry.Command -eq $Current.Command)
}
function Write-AtomicJson([string]$Path,$Value) {
    $temp=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temp,($Value | ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($true)))
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp,$Path,[NullString]::Value) } else { [IO.File]::Move($temp,$Path) }
}
function New-ChangeRecord($Entry,[string]$BackupDir) {
    return [pscustomobject]@{Entry=$Entry;Changed=$false;Error='Pending';SavedFile=$(if ($Entry.Kind -eq 'Folder') { Join-Path $BackupDir (([Guid]::NewGuid().ToString())+'-'+[IO.Path]::GetFileName($Entry.File)) } else { '' })}
}
function Get-CreationStamp([datetime]$Time) {
    # CIM DATETIME stores microseconds; native FILETIME has 100 ns precision.
    $ticks=$Time.ToUniversalTime().Ticks
    return [string]($ticks-($ticks%10))
}
function Test-ProcessIdentity($Identity) {
    try {
        $p=Get-CimInstance Win32_Process -Filter ('ProcessId='+[uint32]$Identity.ProcessId)
        return $null -ne $p -and (Normalize-Path $p.ExecutablePath) -eq (Normalize-Path $Identity.Path) -and (Get-CreationStamp $p.CreationDate) -eq $Identity.Creation
    } catch { return $false }
}
function Get-StartupEntries {
    $entries=New-Object 'Collections.Generic.List[object]'
    foreach ($hive in @('HKCU','HKLM')) {
        foreach ($branch in @('Software\Microsoft\Windows\CurrentVersion\Run','Software\Microsoft\Windows\CurrentVersion\RunOnce','Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run','Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce')) {
            $key=$hive+':\'+$branch
            if (-not (Test-Path -LiteralPath $key)) { continue }
            $reg=Get-Item -LiteralPath $key
            foreach ($name in $reg.GetValueNames()) {
                $command=[string]$reg.GetValue($name,'',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $path=Get-LaunchPath $command
                if (-not [IO.Path]::IsPathRooted($path)) { continue }
                $approvedKey=$hive+':\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\'+$(if ($branch -match 'WOW6432Node') {'Run32'} else {'Run'})
                $enabled=$true
                try { $approved=(Get-ItemProperty -LiteralPath $approvedKey -Name $name -ErrorAction Stop).$name; if ($approved.Length -ge 4) { $enabled=([BitConverter]::ToUInt32($approved,0) -band 1) -eq 0 } } catch {}
                $entries.Add([pscustomobject]@{Kind='Run';Id=$key+'|'+$name;Name=$name;Key=$key;Value=$command;ValueKind=[string]$reg.GetValueKind($name);Path=$path;Enabled=$enabled;Note='注册表'})
            }
        }
    }
    $shell=New-Object -ComObject WScript.Shell
    foreach ($folder in @([Environment]::GetFolderPath('Startup'),[Environment]::GetFolderPath('CommonStartup'))) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $folder -File) {
            $path=if ($file.Extension -eq '.lnk') { Normalize-Path $shell.CreateShortcut($file.FullName).TargetPath } else { Normalize-Path $file.FullName }
            if (-not $path -or $file.Name -eq 'desktop.ini') { continue }
            $entries.Add([pscustomobject]@{Kind='Folder';Id=$file.FullName;Name=$file.Name;Path=$path;File=$file.FullName;Hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash;Enabled=$true;Note='启动文件夹'})
        }
    }
    try {
        foreach ($task in Get-ScheduledTask -ErrorAction Stop) {
            $automatic=@($task.Triggers | Where-Object { $_.Enabled -ne $false }).Count -gt 0
            if (-not $automatic) { continue }
            foreach ($a in $task.Actions) {
                $path=Get-LaunchPath $a.Execute
                if (-not $path -or -not [IO.Path]::IsPathRooted($path)) { continue }
                $entries.Add([pscustomobject]@{Kind='Task';Id=$task.TaskPath+$task.TaskName;Name=$task.TaskName;TaskPath=$task.TaskPath;Path=$path;Enabled=[bool]$task.Settings.Enabled;Note='计划任务';Fingerprint=(Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath)})
            }
        }
    } catch { $script:Coverage.Add('部分计划任务读取失败：'+$_.Exception.Message) }
    foreach ($svc in Get-CimInstance Win32_Service) {
        $path=Get-LaunchPath $svc.PathName
        if ($path -and (Split-Path $path -Leaf) -match '^svchost(?:\.exe)?$') {
            try { $path=Normalize-Path (Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\'+$svc.Name+'\Parameters') -Name ServiceDll -ErrorAction Stop).ServiceDll } catch { continue }
        }
        if (-not $path -or -not [IO.Path]::IsPathRooted($path)) { continue }
        $delay=(Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\'+$svc.Name)).DelayedAutoStart
        $entries.Add([pscustomobject]@{Kind='Service';Id=$svc.Name;Name=$svc.Name;DisplayName=$svc.DisplayName;Path=$path;Command=$svc.PathName;DelayedAutoStart=$delay;Enabled=$svc.StartMode -eq 'Auto';StartMode=$svc.StartMode;State=$svc.State;Note=('服务/'+$svc.StartMode)})
    }
    return $entries.ToArray()
}
function Clean-Cell($Value) { return ([string]$Value -replace '[\t\r\n]',' ') }
function Write-Inventory([string]$Base) {
    $script:Coverage=New-Object 'Collections.Generic.List[string]'
    $processes=@(Get-CimInstance Win32_Process)
    $unknown=@($processes | Where-Object { -not $_.ExecutablePath -and $_.ProcessId -gt 4 })
    $entries=@(Get-StartupEntries)
    $paths=@{}
    foreach ($p in $processes) { if ($p.ExecutablePath) { $path=Normalize-Path $p.ExecutablePath; $paths[$path]=$true } }
    foreach ($e in $entries) { if ($e.Kind -ne 'Service' -or $e.Enabled -or $e.State -eq 'Running' -or $e.StartMode -eq 'Disabled') { $paths[$e.Path]=$true } }
    $rows=New-Object 'Collections.Generic.List[object]'
    foreach ($path in @($paths.Keys | Sort-Object)) {
        $v=Get-Version $path
        if (Test-SystemPath $path $v.Company) { continue }
        $appRoot=Get-AppRoot $path
        $running=@($processes | Where-Object { $_.ExecutablePath -and (Normalize-Path $_.ExecutablePath) -eq $path })
        $startup=@($entries | Where-Object { Test-AppMatch $_.Path $path $appRoot })
        $identities=@($running | ForEach-Object { [pscustomobject]@{ProcessId=$_.ProcessId;Path=$path;Creation=(Get-CreationStamp $_.CreationDate)} })
        $enabled=@($startup | Where-Object Enabled)
        $summary=if ($startup.Count -eq 0) {'未识别入口'} elseif ($enabled.Count -eq 0) {'已禁用/非自动'} else { ($enabled | ForEach-Object { $_.Note+':'+$_.Name } | Select-Object -Unique) -join '; ' }
        $category=if ($v.Company -match '^Microsoft\b') {'微软可选应用'} elseif (-not $v.Company) {'发布者待核实'} else {'第三方'}
        $rows.Add([pscustomobject]@{Id=$rows.Count;Name=Split-Path $path -Leaf;Description=$v.Description;Company=$v.Company;Count=$running.Count;Pids=($running.ProcessId -join ',');Path=$path;AppRoot=$appRoot;Startup=$startup;StartupSummary=$summary;Protection=(Get-Protection $path $v.Company);Category=$category;Processes=$identities})
    }
    $script:Coverage.Add('覆盖：Run/Run32/RunOnce、启动目录、明确文件动作的计划任务、Win32 服务。')
    $script:Coverage.Add('未覆盖：打包应用 StartupTask、间接脚本/系统宿主启动、应用内部唤醒策略。未识别入口不等于不会自启。')
    $snapshot=[pscustomobject]@{Time=(Get-Date -Format o);UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Administrator=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);UnresolvedProcesses=@($unknown | Select-Object ProcessId,Name);Coverage=$script:Coverage.ToArray();Rows=$rows.ToArray()}
    $snapshot | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath ($Base+'.json') -Encoding UTF8
    $lines=@($rows | ForEach-Object { @($_.Id,$_.Name,$_.Description,$_.Company,$_.Count,$_.Pids,$_.StartupSummary,$_.Category,$_.Protection,$_.Path) | ForEach-Object { Clean-Cell $_ } | Join-StringCompat })
    [IO.File]::WriteAllLines($Base+'.tsv',[string[]]$lines,[Text.Encoding]::Unicode)
    $report=New-Object 'Collections.Generic.List[string]'
    $report.Add('# 第三方程序名单')
    $report.Add('扫描时间：'+$snapshot.Time+'；管理员：'+$snapshot.Administrator+'；未能读取路径的进程：'+$unknown.Count+'。')
    $report.Add('')
    $report.Add('| 程序 | 描述 | 发布者 | 进程数 | 自动启动 | 标注 |')
    $report.Add('|---|---|---|---:|---|---|')
    foreach ($r in $rows) { $report.Add('| '+((@($r.Name,$r.Description,$r.Company,$r.Count,$r.StartupSummary,($r.Protection+' '+$r.Category)) | ForEach-Object { (Clean-Cell $_) -replace '\|','/' }) -join ' | ')+' |') }
    $report.Add(''); foreach ($note in $snapshot.Coverage) { $report.Add($note) }
    $report | Set-Content -LiteralPath (Join-Path $script:OutputRoot '第三方程序名单.md') -Encoding UTF8
    $rows | Select-Object Name,Description,Company,Count,Pids,StartupSummary,Category,Protection,Path | Export-Csv -LiteralPath (Join-Path $script:OutputRoot '第三方程序名单.csv') -NoTypeInformation -Encoding UTF8
    return ('程序 '+$rows.Count+' 项；路径未读取 '+$unknown.Count+' 项；'+$(if ($snapshot.Administrator) {'管理员扫描'} else {'普通权限扫描，可点击管理员扫描补全'}))
}
function Join-StringCompat { begin { $parts=New-Object 'Collections.Generic.List[string]' } process { $parts.Add([string]$_) } end { $parts -join "`t" } }
function Disable-Entry($Entry,[string]$BackupDir,$Pending=$null) {
    $record=if ($null -ne $Pending) {$Pending} else { New-ChangeRecord $Entry $BackupDir }
    $record.Error=''
    try {
        switch ($Entry.Kind) {
            'Run' {
                $key=Get-Item -LiteralPath $Entry.Key
                if ($key.GetValue($Entry.Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -cne $Entry.Value) { throw '入口已变化，请刷新后重试' }
                Remove-ItemProperty -LiteralPath $Entry.Key -Name $Entry.Name
                if ($Entry.Name -in (Get-Item -LiteralPath $Entry.Key).GetValueNames()) { throw '未能移除启动项' }
            }
            'Folder' {
                $resolved=(Resolve-Path -LiteralPath $Entry.File).Path
                if ((Split-Path $resolved -Parent) -notin @([Environment]::GetFolderPath('Startup'),[Environment]::GetFolderPath('CommonStartup'))) { throw '启动文件不在已知启动目录' }
                if (-not (Test-FolderIdentity $Entry)) { throw '启动文件或目标已变化，未移动' }
                Move-Item -LiteralPath $resolved -Destination $record.SavedFile
            }
            'Task' {
                $current=Export-ScheduledTask -TaskName $Entry.Name -TaskPath $Entry.TaskPath
                if ($current -cne $Entry.Fingerprint) { throw '任务已变化，请刷新后重试' }
                if (-not (Test-TaskOwnership (Get-ScheduledTask -TaskName $Entry.Name -TaskPath $Entry.TaskPath) $Entry.OwnerPath $Entry.OwnerRoot)) { throw '任务含其他程序、受保护或未知动作，未禁用整个任务' }
                Disable-ScheduledTask -TaskName $Entry.Name -TaskPath $Entry.TaskPath | Out-Null
                if ((Get-ScheduledTask -TaskName $Entry.Name -TaskPath $Entry.TaskPath).Settings.Enabled) { throw '任务仍然启用' }
            }
            'Service' {
                $current=Get-ServiceIdentity $Entry.Name
                if (-not (Test-ServiceOwnership $current $Entry)) { throw '服务归属或命令已变化，请刷新后重试' }
                Set-Service -Name $Entry.Name -StartupType Disabled
                if ((Get-CimInstance Win32_Service -Filter ("Name='"+$Entry.Name.Replace("'","''")+"'")).StartMode -ne 'Disabled') { throw '服务启动类型未改变' }
            }
            default { throw '不支持的入口类型' }
        }
        $record.Changed=$true
    } catch { $record.Error=$_.Exception.Message }
    return [pscustomobject]$record
}
function Apply-Selection([string]$Base) {
    $request=[IO.File]::ReadAllLines($Base+'.request',[Text.Encoding]::Unicode)
    if ($request.Count -lt 2 -or $request[0] -notin @('close','startup','disable')) { throw '未选择程序或请求无效' }
    $snapshot=Get-Content -LiteralPath ($Base+'.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($snapshot.UserSid -and $snapshot.UserSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw '管理员账户与扫描账户不同，未执行。请使用同一用户提权后重新扫描。' }
    $selected=New-Object 'Collections.Generic.List[object]'
    foreach ($id in @($request | Select-Object -Skip 1 -Unique)) {
        if ($id -notmatch '^\d+$') { throw '无效的程序编号' }
        $r=@($snapshot.Rows | Where-Object { $_.Id -eq [int]$id })
        if ($r.Count -ne 1 -or $r[0].Protection -or (Get-Protection $r[0].Path $r[0].Company)) { throw '受保护或无效的程序，请刷新名单' }
        $selected.Add($r[0])
    }
    if ($selected.Count -eq 0) { throw '未选择程序' }
    $history=Join-Path $script:DataRoot ('history\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $history -Force | Out-Null
    $snapshot | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $history 'snapshot.json') -Encoding UTF8
    $records=New-Object 'Collections.Generic.List[object]'
    $messages=New-Object 'Collections.Generic.List[string]'
    $seen=@{}
    foreach ($r in $selected) {
        if ($request[0] -in @('startup','disable')) {
            $targets=@($r.Startup | Where-Object Enabled)
            if (-not $targets.Count) { $messages.Add($r.Name+'：未识别到已启用入口；不代表全部启动方式已关闭') }
            foreach ($e in $targets) {
                if (-not (Test-AppMatch $e.Path $r.Path $r.AppRoot) -or (Get-Protection $e.Path (Get-Version $e.Path).Company)) { $messages.Add($e.Name+'：入口归属或保护状态不允许批量修改，已跳过'); continue }
                if ($seen.ContainsKey($e.Kind+'|'+$e.Id)) { continue }
                $seen[$e.Kind+'|'+$e.Id]=$true
                # Persist original state before changing it; update with result immediately afterwards.
                $e | Add-Member -NotePropertyName OwnerPath -NotePropertyValue $r.Path -Force
                $e | Add-Member -NotePropertyName OwnerRoot -NotePropertyValue $r.AppRoot -Force
                $pending=New-ChangeRecord $e $history
                $records.Add($pending)
                Write-AtomicJson (Join-Path $history 'changes.json') $records.ToArray()
                $changed=Disable-Entry $e $history $pending
                $records[$records.Count-1]=$changed
                Write-AtomicJson (Join-Path $history 'changes.json') $records.ToArray()
                $messages.Add($r.Name+' / '+$e.Note+' / '+$e.Name+'：'+$(if ($changed.Changed) {'已关闭自启'} else {'失败：'+$changed.Error}))
            }
        }
        if ($request[0] -in @('close','disable')) {
            foreach ($identity in $r.Processes) {
                try {
                    if (-not (Test-ProcessIdentity $identity)) { $messages.Add($r.Name+' PID '+$identity.ProcessId+'：已退出或身份变化，跳过'); continue }
                    # Hold the original process handle while checking start time to prevent PID reuse.
                    $p=[Diagnostics.Process]::GetProcessById([int]$identity.ProcessId)
                    $null=$p.Handle
                    $nativePath=Normalize-Path $p.MainModule.FileName
                    $nativeCreation=Get-CreationStamp $p.StartTime
                    if ($nativePath -ne $identity.Path -or $nativeCreation -ne $identity.Creation) { $p.Dispose(); throw ('进程身份变化，未关闭：'+$nativePath+' / '+$nativeCreation+'；扫描：'+$identity.Path+' / '+$identity.Creation) }
                    $p.Kill(); $exited=$p.WaitForExit(5000); $p.Dispose()
                    if (-not $exited) { throw '进程尚未退出' }
                    $messages.Add($r.Name+' PID '+$identity.ProcessId+'：已关闭')
                } catch { $messages.Add($r.Name+' PID '+$identity.ProcessId+'：失败：'+$_.Exception.Message) }
            }
            foreach ($e in @($r.Startup | Where-Object { $_.Kind -eq 'Service' -and $_.Path -eq $r.Path -and $_.State -eq 'Running' })) {
                try {
                    $current=Get-ServiceIdentity $e.Name
                    if (-not (Test-ServiceOwnership $current $e)) { throw '服务归属或命令已变化，未停止' }
                    Stop-Service -Name $e.Name -ErrorAction Stop
                    if ((Get-Service -Name $e.Name).Status -ne 'Stopped') { throw '服务尚未停止' }
                    $messages.Add($e.Name+'：服务已停止')
                } catch { $messages.Add($e.Name+'：停止失败：'+$_.Exception.Message) }
            }
            if (-not @($r.Processes).Count -and -not @($r.Startup | Where-Object { $_.Kind -eq 'Service' -and $_.Path -eq $r.Path -and $_.State -eq 'Running' }).Count) { $messages.Add($r.Name+'：当前未运行') }
        }
    }
    $messages.Add('恢复资料：'+$history)
    $messages.Add('关闭进程不能恢复未保存内容；取消自启可用同目录 restore.ps1 指定 changes.json 恢复。')
    [IO.File]::WriteAllLines($Base+'.result',[string[]]$messages,[Text.Encoding]::Unicode)
    $messages | Set-Content -LiteralPath (Join-Path $history 'result.txt') -Encoding UTF8
}
if ($Mode -eq 'Library') { return }
New-Item -ItemType Directory -Path $script:DataRoot,$script:OutputRoot -Force | Out-Null
$base=Join-Path $script:DataRoot $Session
try {
    if ($Mode -eq 'Apply') { Apply-Selection $base }
    $summary=Write-Inventory $base
    [IO.File]::WriteAllText($base+'.done',$summary,[Text.Encoding]::Unicode)
} catch {
    [IO.File]::WriteAllText($base+'.error',($_.Exception.ToString()+"`r`n"+$_.ScriptStackTrace),[Text.Encoding]::Unicode)
    exit 1
}
