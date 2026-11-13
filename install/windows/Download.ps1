function Receive-File([string]$Uri, [string]$Path, [switch]$Resume) {
    $curl=Join-Path $env:WINDIR 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        $arguments=@('--fail','--location','--silent','--show-error','--proto','=https','--proto-redir','=https','--connect-timeout','15','--max-time','120','--output',$Path)
        $resumeArguments=if ($Resume -and (Test-Path -LiteralPath $Path)) { @('--continue-at','-') } else { @() }
        $result=Invoke-ProcessResult $curl ($arguments + $resumeArguments + @($Uri))
        if ($result.Code -eq 33 -and $resumeArguments.Count) {
            # The server rejected byte ranges; start clean once with the same limits.
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            $result=Invoke-ProcessResult $curl ($arguments + @($Uri))
        }
        if ($result.Code -ne 0) { throw ('Download failed: ' + $result.Error.Trim()) }
    } else { Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Path -TimeoutSec 120 }
}

function Receive-VerifiedArchive([string]$Uri, [string]$Path, [string]$Sha256) {
    if ((Test-Path -LiteralPath $Path) -and (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Sha256) { return }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $partial=$Path + '.partial'
    for ($attempt=1; $attempt -le 3; $attempt++) {
        try {
            # A previous request may have received all bytes before the connection failed.
            $complete=(Test-Path -LiteralPath $partial) -and (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -eq $Sha256
            if (-not $complete) {
                $offset=if (Test-Path -LiteralPath $partial) { (Get-Item -LiteralPath $partial).Length } else { 0 }
                Write-Host "Downloading verified CUA package (attempt $attempt/3, resume byte $offset)..."
                Receive-File $Uri $partial -Resume
                if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $Sha256) {
                    Remove-Item -LiteralPath $partial -Force
                    throw 'CUA archive checksum mismatch; the invalid download was discarded.'
                }
            }
            Move-Item -LiteralPath $partial -Destination $Path -Force
            return
        } catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds $attempt
        }
    }
}
