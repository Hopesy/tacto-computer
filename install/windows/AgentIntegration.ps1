function Get-TextHash([string]$Text) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($script:Utf8.GetBytes($Text)))).Replace('-','').ToLower() }
    finally { $sha.Dispose() }
}
function Get-TargetSkillFiles($Config, [string]$CliPrefix) {
    if (-not $CliPrefix) { $CliPrefix="npx.cmd -y tacto-mcp@latest driver --install-dir '" + $InstallDirectory.Replace("'","''") + "'" }
    $template=Get-Content -LiteralPath (Join-Path $Config.RuntimePath 'resources\tacto-skill.md') -Raw -Encoding UTF8
    $files=@{'SKILL.md'=$template.Replace('{{SERVER}}',('computer-' + $Config.DeviceName)).Replace('{{DEVICE}}',$Config.DeviceName).Replace('{{BROWSER}}',(Property $Config 'BrowserMode' 'isolated')).Replace('{{CLI}}',$CliPrefix)}
    $folder=Join-Path $Config.RuntimePath 'resources\cua-skill'
    if (Test-Path -LiteralPath $folder) {
        $manifest=Get-Content -LiteralPath (Join-Path $folder 'source.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in @($manifest.files.PSObject.Properties.Name) + @('source.json','LICENSE')) {
            if ($name -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Invalid official Skill filename.' }
            $text=[IO.File]::ReadAllText((Join-Path $folder $name),[Text.Encoding]::UTF8)
            $expected=Property $manifest.files $name
            if ($expected -and (Get-TextHash $text) -ne $expected) { throw "Official Skill checksum mismatch: $name" }
            $files['official/' + $name]=$text
        }
    }
    return $files
}
function Install-TargetSkill($Config) {
    Remove-OwnedPath 'skill'
    $folder=Join-Path $InstallDirectory 'skill'
    foreach ($entry in (Get-TargetSkillFiles $Config).GetEnumerator()) {
        $path=Join-Path $folder $entry.Key
        New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
        Write-Utf8 $path $entry.Value
    }
}
function Get-DetectedSkillDirectories {
    $profileRoot=$env:USERPROFILE
    $codexMarker=if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $profileRoot '.codex' }
    $codexSkills=if ($env:CODEX_HOME) { Join-Path $env:CODEX_HOME 'skills' } else { Join-Path $profileRoot '.agents\skills' }
    $pairs=@(
        @((Join-Path $profileRoot '.claude'),(Join-Path $profileRoot '.claude\skills')),
        @($codexMarker,$codexSkills),
        @((Join-Path $profileRoot '.cursor'),(Join-Path $profileRoot '.agents\skills')),
        @((Join-Path $profileRoot '.pi\agent'),(Join-Path $profileRoot '.agents\skills')),
        @((Join-Path $profileRoot '.factory'),(Join-Path $profileRoot '.factory\skills')),
        @((Join-Path $profileRoot '.openclaw'),(Join-Path $profileRoot '.openclaw\skills')),
        @((Join-Path $env:APPDATA 'opencode'),(Join-Path $env:APPDATA 'opencode\skills'))
    )
    return @($pairs | Where-Object { Test-Path -LiteralPath $_[0] -PathType Container } | ForEach-Object { $_[1] } | Sort-Object -Unique)
}
function Get-IntegrationFiles($Record) {
    if (-not $Record) { return @() }
    if ($Record.PSObject.Properties['files']) { $files=@($Record.files) }
    elseif (Property $Record 'skillPath') { $files=@([pscustomobject]@{path=$Record.skillPath;hash=$Record.skillHash;root=(Split-Path $Record.skillPath)}) }
    else { return @() }
    foreach ($file in $files) {
        $prefix=[IO.Path]::GetFullPath($file.root).TrimEnd('\') + '\'
        $path=[IO.Path]::GetFullPath($file.path)
        if ((Split-Path $file.root -Leaf) -ne $Record.name.Replace('computer-','tacto-') -or -not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or $path.Substring($prefix.Length) -notmatch '^(SKILL\.md|official[\\/][A-Za-z0-9_.-]+)$') { throw 'Invalid Skill ownership path.' }
    }
    return $files
}
function Remove-EmptySkillDirectories($Files) {
    $folders=@($Files | ForEach-Object { (Split-Path $_.path); $_.root } | Sort-Object -Unique | Sort-Object Length -Descending)
    foreach ($folder in $folders) {
        if ((Test-Path -LiteralPath $folder) -and @(Get-ChildItem -LiteralPath $folder -Force).Count -eq 0) { Remove-Item -LiteralPath $folder }
    }
}
function Set-AgentIntegration($Config, $Server) {
    $name='computer-' + $Config.DeviceName
    $configPath=Property $Config 'McpConfig'
    $previous=Property $Config 'Integration'
    $oldFiles=@(Get-IntegrationFiles $previous)
    if (Property $Config 'NoSkills' $false) { $directories=@() }
    elseif (Property $Config 'SkillDirectory') { $directories=@($Config.SkillDirectory) }
    elseif ($Config.PSObject.Properties['SkillDirectories']) { $directories=@($Config.SkillDirectories) }
    elseif ($previous) { $directories=@($oldFiles | ForEach-Object { Split-Path $_.root } | Sort-Object -Unique) }
    else { $directories=@(Get-DetectedSkillDirectories) }
    Set-Property $Config 'SkillDirectories' $directories
    $content=Get-TargetSkillFiles $Config
    $files=@(); $texts=@{}; $oldMap=@{}; $backups=@{}
    foreach ($file in $oldFiles) { $oldMap[$file.path]=$file.hash }
    foreach ($directory in $directories) {
        $folder=Join-Path $directory ('tacto-' + $Config.DeviceName)
        foreach ($entry in $content.GetEnumerator()) {
            $path=Join-Path $folder $entry.Key
            $files+=[pscustomobject]@{path=$path;hash=(Get-TextHash $entry.Value);root=$folder}
            $texts[$path]=$entry.Value
        }
    }
    foreach ($file in @($files)+@($oldFiles)) {
        if ($backups.ContainsKey($file.path)) { continue }
        $original=if (Test-Path -LiteralPath $file.path) { Get-Content -LiteralPath $file.path -Raw -Encoding UTF8 } else { $null }
        if ($null -ne $original -and (Get-TextHash $original) -ne $oldMap[$file.path]) { throw 'The target Skill was edited. Preserve or relocate it before updating.' }
        $backups[$file.path]=$original
    }
    $record=[pscustomobject]@{name=$name;configPath=$configPath;server=$Server;skillPath=$null;skillHash=$null;files=$files}
    $entryFile=@($files | Where-Object { (Split-Path $_.path -Leaf) -eq 'SKILL.md' -and (Split-Path $_.path) -eq $_.root })
    if ($entryFile.Count) { $record.skillPath=$entryFile[0].path; $record.skillHash=$entryFile[0].hash }
    try {
        if ($configPath) {
            $original=if (Test-Path -LiteralPath $configPath) { Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 } else { $null }
            $document=if ($original) { $original | ConvertFrom-Json } else { [pscustomobject]@{} }
            if (-not (Property $document 'mcpServers')) { Set-Property $document 'mcpServers' ([pscustomobject]@{}) }
            $entry=Property $document.mcpServers $name
            if ($entry -and (-not $previous -or ($entry | ConvertTo-Json -Depth 20 -Compress) -ne ($previous.server | ConvertTo-Json -Depth 20 -Compress))) { throw "MCP entry $name already exists or was edited. Choose a different device name or merge it manually." }
            $backups[$configPath]=$original
            New-Item -ItemType Directory -Force (Split-Path $configPath) | Out-Null
            Set-Property $document.mcpServers $name $Server
            Write-AtomicJson $configPath $document
        }
        foreach ($file in $files) {
            New-Item -ItemType Directory -Force (Split-Path $file.path) | Out-Null
            Write-Utf8 $file.path $texts[$file.path]
        }
        foreach ($file in $oldFiles) { if (-not $texts.ContainsKey($file.path) -and (Test-Path -LiteralPath $file.path)) { Remove-Item -LiteralPath $file.path -Force } }
        Set-Property $Config 'Integration' $record
        $journal=Join-Path $InstallDirectory 'transaction.json'
        if (Test-Path -LiteralPath $journal) {
            $transaction=Get-Content -LiteralPath $journal -Raw -Encoding UTF8 | ConvertFrom-Json
            $transaction.candidate=$Config
            Write-AtomicJson $journal $transaction
        }
    } catch {
        foreach ($backup in $backups.GetEnumerator()) {
            if ($null -ne $backup.Value) { Write-Utf8 $backup.Key $backup.Value }
            elseif (Test-Path -LiteralPath $backup.Key) { Remove-Item -LiteralPath $backup.Key -Force }
        }
        Remove-EmptySkillDirectories $files
        throw
    }
    Remove-EmptySkillDirectories $oldFiles
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
    $files=@(Get-IntegrationFiles $record)
    foreach ($file in $files) {
        if (Test-Path -LiteralPath $file.path) {
            $text=Get-Content -LiteralPath $file.path -Raw -Encoding UTF8
            if ((Get-TextHash $text) -eq $file.hash) { Remove-Item -LiteralPath $file.path -Force }
            else { Write-Warning "Preserved edited Skill: $($file.path)" }
        }
    }
    Remove-EmptySkillDirectories $files
}
