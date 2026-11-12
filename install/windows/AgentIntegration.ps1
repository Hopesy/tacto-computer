function Get-TextHash([string]$Text) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($script:Utf8.GetBytes($Text)))).Replace('-','').ToLower() }
    finally { $sha.Dispose() }
}
function Install-TargetSkill($Config) {
    $folder=Join-Path $InstallDirectory 'skill'
    New-Item -ItemType Directory -Force $folder | Out-Null
    $template=Get-Content -LiteralPath (Join-Path $Config.RuntimePath 'resources\tacto-skill.md') -Raw -Encoding UTF8
    $text=$template.Replace('{{SERVER}}',('computer-' + $Config.DeviceName)).Replace('{{DEVICE}}',$Config.DeviceName).Replace('{{BROWSER}}',(Property $Config 'BrowserMode' 'isolated'))
    Write-Utf8 (Join-Path $folder 'SKILL.md') $text
}
function Set-AgentIntegration($Config, $Server) {
    $name='computer-' + $Config.DeviceName
    $configPath=Property $Config 'McpConfig'
    $skillDirectory=Property $Config 'SkillDirectory'
    $previous=Property $Config 'Integration'
    $record=[pscustomobject]@{name=$name;configPath=$configPath;server=$Server;skillPath=$null;skillHash=$null}
    $backups=@()
    try {
        if ($configPath) {
            $existed=Test-Path -LiteralPath $configPath
            $original=if ($existed) { Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 } else { $null }
            $document=if ($existed) { $original | ConvertFrom-Json } else { [pscustomobject]@{} }
            if (-not (Property $document 'mcpServers')) { Set-Property $document 'mcpServers' ([pscustomobject]@{}) }
            $entry=Property $document.mcpServers $name
            if ($entry -and (-not $previous -or ($entry | ConvertTo-Json -Depth 20 -Compress) -ne ($previous.server | ConvertTo-Json -Depth 20 -Compress))) { throw "MCP entry $name already exists or was edited. Choose a different device name or merge it manually." }
            $backups+=@{path=$configPath;text=$original}
            New-Item -ItemType Directory -Force (Split-Path $configPath) | Out-Null
            Set-Property $document.mcpServers $name $Server
            Write-AtomicJson $configPath $document
        }
        if ($skillDirectory) {
            $folder=Join-Path $skillDirectory ('tacto-' + $Config.DeviceName)
            $path=Join-Path $folder 'SKILL.md'
            $text=Get-Content -LiteralPath (Join-Path $InstallDirectory 'skill\SKILL.md') -Raw -Encoding UTF8
            $original=if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw -Encoding UTF8 } else { $null }
            if ($original -and (-not $previous -or (Get-TextHash $original) -ne $previous.skillHash)) { throw 'The target Skill was edited. Preserve or relocate it before updating.' }
            $backups+=@{path=$path;text=$original}
            New-Item -ItemType Directory -Force $folder | Out-Null
            Write-Utf8 $path $text
            $record.skillPath=$path; $record.skillHash=Get-TextHash $text
        }
        Set-Property $Config 'Integration' $record
        $journal=Join-Path $InstallDirectory 'transaction.json'
        if (Test-Path -LiteralPath $journal) {
            $transaction=Get-Content -LiteralPath $journal -Raw -Encoding UTF8 | ConvertFrom-Json
            $transaction.candidate=$Config
            Write-AtomicJson $journal $transaction
        }
    } catch {
        foreach ($backup in $backups) {
            if ($null -ne $backup.text) { Write-Utf8 $backup.path $backup.text }
            elseif (Test-Path -LiteralPath $backup.path) { Remove-Item -LiteralPath $backup.path -Force }
        }
        throw
    }
}
function Remove-AgentIntegration($Config) {
    $record=Property $Config 'Integration'
    if (-not $record) { return }
    if ($record.configPath -and (Test-Path -LiteralPath $record.configPath)) {
        try { $document=Get-Content -LiteralPath $record.configPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { Write-Warning "Preserved unreadable Agent config: $($record.configPath)"; $document=[pscustomobject]@{} }
        $entry=Property (Property $document 'mcpServers') $record.name
        if ($entry -and ($entry | ConvertTo-Json -Depth 20 -Compress) -eq ($record.server | ConvertTo-Json -Depth 20 -Compress)) {
            $document.mcpServers.PSObject.Properties.Remove($record.name)
            Write-AtomicJson $record.configPath $document
        } elseif ($entry) { Write-Warning "Preserved edited MCP entry: $($record.name)" }
    }
    if ($record.skillPath -and (Test-Path -LiteralPath $record.skillPath)) {
        $text=Get-Content -LiteralPath $record.skillPath -Raw -Encoding UTF8
        if ((Get-TextHash $text) -eq $record.skillHash) {
            Remove-Item -LiteralPath $record.skillPath -Force
            $folder=Split-Path $record.skillPath
            if (@(Get-ChildItem -LiteralPath $folder -Force).Count -eq 0) { Remove-Item -LiteralPath $folder }
        } else { Write-Warning "Preserved edited Skill: $($record.skillPath)" }
    }
}
