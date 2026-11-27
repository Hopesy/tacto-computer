function Get-TextHash([string]$Text) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($script:Utf8.GetBytes($Text)))).Replace('-','').ToLower() }
    finally { $sha.Dispose() }
}
function ConvertTo-CanonicalJson($Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [string] -or $Value -is [ValueType]) { return ($Value | ConvertTo-Json -Compress) }
    if ($Value -is [Collections.IDictionary]) {
        $keys=@($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)
        $parts=@($keys | ForEach-Object { ($_ | ConvertTo-Json -Compress) + ':' + (ConvertTo-CanonicalJson $Value[$_]) })
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items=@()
        foreach ($item in $Value) { $items += (ConvertTo-CanonicalJson $item) }
        return '[' + ($items -join ',') + ']'
    }
    $props=@($Value.PSObject.Properties | Sort-Object Name)
    $parts=@($props | ForEach-Object { ($_.Name | ConvertTo-Json -Compress) + ':' + (ConvertTo-CanonicalJson $_.Value) })
    return '{' + ($parts -join ',') + '}'
}
function Get-TargetProduct($Config) {
    $metadata=Get-Content -LiteralPath (Join-Path $Config.RuntimePath 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (Property $metadata 'tacto') {
        $resolvedMcp=if (Property $Config 'McpName') { [string]$Config.McpName } else { [string]$metadata.tacto.mcpName }
        $resolvedSkill=if (Property $Config 'SkillName') { [string]$Config.SkillName } else { [string]$metadata.tacto.skillName }
        return @{packageName=$metadata.name;cliName=@($metadata.bin.PSObject.Properties.Name)[0];skillName=$resolvedSkill;mcpName=$resolvedMcp}
    }
    return @{packageName='tacto-mcp';cliName='tacto-mcp';skillName=('tacto-' + $Config.DeviceName);mcpName=('computer-' + $Config.DeviceName)}
}
function Get-TargetSkillFiles($Config, [string]$CliPrefix) {
    $product=Get-TargetProduct $Config
    if (-not $CliPrefix) { $CliPrefix="npx.cmd -y --package $($product.packageName)@latest $($product.cliName) driver --install-dir '" + $InstallDirectory.Replace("'","''") + "'" }
    $template=Get-Content -LiteralPath (Join-Path $Config.RuntimePath 'resources\tacto-skill.md') -Raw -Encoding UTF8
    $files=@{'SKILL.md'=$template.Replace('{{SKILL}}',$product.skillName).Replace('{{SERVER}}',$product.mcpName).Replace('{{DEVICE}}',$Config.DeviceName).Replace('{{BROWSER}}',(Property $Config 'BrowserMode' 'isolated')).Replace('{{CLI}}',$CliPrefix)}
    $bundle=Join-Path $Config.RuntimePath 'install\skill-references.json'
    if (Test-Path -LiteralPath $bundle) {
        $references=[IO.File]::ReadAllText($bundle,[Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($entry in $references.PSObject.Properties) { $files[$entry.Name]=[string]$entry.Value }
        return $files
    }
    # Previous runtimes keep their original layout during rollback.
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
        @((Join-Path $profileRoot '.config\opencode'),(Join-Path $profileRoot '.config\opencode\skills'))
    )
    if ($env:APPDATA) { $pairs+=,@(@((Join-Path $env:APPDATA 'opencode'),(Join-Path $env:APPDATA 'opencode\skills'))) }
    return @($pairs | Where-Object { Test-Path -LiteralPath $_[0] -PathType Container } | ForEach-Object { $_[1] } | Sort-Object -Unique)
}
function Get-IntegrationFiles($Record) {
    if (-not $Record) { return @() }
    if ($Record.PSObject.Properties['files']) { $files=@($Record.files) }
    elseif (Property $Record 'skillPath') { $files=@([pscustomobject]@{path=$Record.skillPath;hash=$Record.skillHash;root=(Split-Path $Record.skillPath)}) }
    else { return @() }
    $expectedRoot=if (Property $Record 'skillName') { [string]$Record.skillName } elseif ($Record.name -eq 'tacto-mcp') { 'tacto-computer' } elseif ($Record.name.StartsWith('computer-')) { 'tacto-' + $Record.name.Substring(9) } else { 'tacto-computer' }
    if ($expectedRoot -notmatch '^[a-z][a-z0-9-]{0,63}$') { throw 'Invalid Skill ownership root.' }
    foreach ($file in $files) {
        $prefix=[IO.Path]::GetFullPath($file.root).TrimEnd('\') + '\'
        $path=[IO.Path]::GetFullPath($file.path)
        if ((Split-Path $file.root -Leaf) -ne $expectedRoot -or -not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or $path.Substring($prefix.Length) -notmatch '^(SKILL\.md|(official|references)[\\/][A-Za-z0-9_.-]+)$') { throw 'Invalid Skill ownership path.' }
    }
    return $files
}
function Remove-EmptySkillDirectories($Files) {
    $folders=@($Files | ForEach-Object { (Split-Path $_.path); $_.root } | Sort-Object -Unique | Sort-Object Length -Descending)
    foreach ($folder in $folders) {
        if ((Test-Path -LiteralPath $folder) -and @(Get-ChildItem -LiteralPath $folder -Force).Count -eq 0) { Remove-Item -LiteralPath $folder }
    }
}
function Resolve-IntegrationPlan($Config, $BaselineIntegration = $null) {
    $product=Get-TargetProduct $Config
    $name=$product.mcpName
    $configPath=Property $Config 'McpConfig'
    $previous=if ($null -ne $BaselineIntegration) { $BaselineIntegration } else { Property $Config 'Integration' }
    $oldFiles=@(Get-IntegrationFiles $previous)
    if (Property $Config 'NoSkills' $false) { $directories=@() }
    elseif (Property $Config 'SkillDirectory') { $directories=@($Config.SkillDirectory) }
    elseif ($Config.PSObject.Properties['SkillDirectories']) { $directories=@($Config.SkillDirectories) }
    elseif ($previous) { $directories=@($oldFiles | ForEach-Object { Split-Path $_.root } | Sort-Object -Unique) }
    else { $directories=@(Get-DetectedSkillDirectories) }
    $content=if (@($directories).Count) { Get-TargetSkillFiles $Config } else { @{} }
    $files=@(); $texts=@{}; $oldMap=@{}
    foreach ($file in $oldFiles) { $oldMap[$file.path]=$file.hash }
    foreach ($directory in $directories) {
        $folder=Join-Path $directory $product.skillName
        foreach ($entry in $content.GetEnumerator()) {
            $path=Join-Path $folder $entry.Key
            $files+=[pscustomobject]@{path=$path;hash=(Get-TextHash $entry.Value);root=$folder}
            $texts[$path]=$entry.Value
        }
    }
    return @{product=$product;name=$name;configPath=$configPath;previous=$previous;directories=$directories;oldFiles=$oldFiles;oldMap=$oldMap;files=$files;texts=$texts}
}
function Assert-AgentIntegrationReady($Config, $BaselineIntegration = $null) {
    if (-not (Property $Config 'RuntimePath')) { return }
    $plan=Resolve-IntegrationPlan $Config $BaselineIntegration
    $checked=@{}
    foreach ($file in @($plan.files)+@($plan.oldFiles)) {
        if ($checked.ContainsKey($file.path)) { continue }
        $checked[$file.path]=$true
        $original=if (Test-Path -LiteralPath $file.path) { Get-Content -LiteralPath $file.path -Raw -Encoding UTF8 } else { $null }
        if ($null -ne $original -and (Get-TextHash $original) -ne $plan.oldMap[$file.path]) { throw 'The target Skill was edited. Preserve or relocate it before updating.' }
    }
    if ($plan.configPath -and (Test-Path -LiteralPath $plan.configPath)) {
        $raw=Get-Content -LiteralPath $plan.configPath -Raw -Encoding UTF8
        $trimmed=if ($null -ne $raw) { $raw.Trim() } else { '' }
        $document=if ($trimmed) { $trimmed | ConvertFrom-Json } else { [pscustomobject]@{} }
        $servers=Property $document 'mcpServers'
        if ($servers) {
            $entry=Property $servers $plan.name
            if ($entry -and (-not $plan.previous -or $plan.previous.name -ne $plan.name -or (ConvertTo-CanonicalJson $entry) -ne (ConvertTo-CanonicalJson $plan.previous.server))) {
                throw "MCP entry $($plan.name) already exists or was edited. Preserve it or select another client config."
            }
            if ($plan.previous -and $plan.previous.name -ne $plan.name) {
                $oldEntry=Property $servers $plan.previous.name
                if ($oldEntry -and (ConvertTo-CanonicalJson $oldEntry) -ne (ConvertTo-CanonicalJson $plan.previous.server)) {
                    throw "MCP entry $($plan.previous.name) was edited. Preserve it before updating."
                }
            }
        }
    }
}
function Set-AgentIntegration($Config, $Server) {
    $plan=Resolve-IntegrationPlan $Config
    $product=$plan.product; $name=$plan.name; $configPath=$plan.configPath; $previous=$plan.previous
    $oldFiles=$plan.oldFiles; $oldMap=$plan.oldMap; $files=$plan.files; $texts=$plan.texts
    Set-Property $Config 'SkillDirectories' $plan.directories
    $backups=@{}
    foreach ($file in @($files)+@($oldFiles)) {
        if ($backups.ContainsKey($file.path)) { continue }
        $original=if (Test-Path -LiteralPath $file.path) { Get-Content -LiteralPath $file.path -Raw -Encoding UTF8 } else { $null }
        if ($null -ne $original -and (Get-TextHash $original) -ne $oldMap[$file.path]) { throw 'The target Skill was edited. Preserve or relocate it before updating.' }
        $backups[$file.path]=$original
    }
    $record=[pscustomobject]@{name=$name;skillName=$product.skillName;device=$Config.DeviceName;configPath=$configPath;server=$Server;skillPath=$null;skillHash=$null;files=$files}
    $entryFile=@($files | Where-Object { (Split-Path $_.path -Leaf) -eq 'SKILL.md' -and (Split-Path $_.path) -eq $_.root })
    if ($entryFile.Count) { $record.skillPath=$entryFile[0].path; $record.skillHash=$entryFile[0].hash }
    try {
        if ($configPath) {
            $original=if (Test-Path -LiteralPath $configPath) { Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 } else { $null }
            $trimmed=if ($null -ne $original) { $original.Trim() } else { '' }
            $document=if ($trimmed) { $trimmed | ConvertFrom-Json } else { [pscustomobject]@{} }
            if (-not (Property $document 'mcpServers')) { Set-Property $document 'mcpServers' ([pscustomobject]@{}) }
            $entry=Property $document.mcpServers $name
            if ($entry -and (-not $previous -or $previous.name -ne $name -or (ConvertTo-CanonicalJson $entry) -ne (ConvertTo-CanonicalJson $previous.server))) { throw "MCP entry $name already exists or was edited. Preserve it or select another client config." }
            if ($previous -and $previous.name -ne $name) {
                $oldEntry=Property $document.mcpServers $previous.name
                if ($oldEntry -and (ConvertTo-CanonicalJson $oldEntry) -ne (ConvertTo-CanonicalJson $previous.server)) { throw "MCP entry $($previous.name) was edited. Preserve it before updating." }
                $document.mcpServers.PSObject.Properties.Remove($previous.name)
            }
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
        try {
            $raw=Get-Content -LiteralPath $record.configPath -Raw -Encoding UTF8
            $trimmed=if ($null -ne $raw) { $raw.Trim() } else { '' }
            $document=if ($trimmed) { $trimmed | ConvertFrom-Json } else { [pscustomobject]@{} }
        }
        catch { Write-Warning "Preserved unreadable Agent config: $($record.configPath)"; $document=[pscustomobject]@{} }
        $entry=Property (Property $document 'mcpServers') $record.name
        if ($entry -and (ConvertTo-CanonicalJson $entry) -eq (ConvertTo-CanonicalJson $record.server)) {
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
