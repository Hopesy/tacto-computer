$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$fixture=Join-Path $repo ('.Tacto-temp\download-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $fixture | Out-Null
. (Join-Path $repo 'install\windows\Download.ps1')
function Assert($Condition,$Message) { if (-not $Condition) { throw $Message } }
function Start-Sleep { param($Seconds) }
$payload='verified archive bytes ' * 100
$original=Join-Path $fixture 'expected.zip'
[IO.File]::WriteAllText($original,$payload)
$digest=(Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash
$script:mode='interrupt'; $script:calls=0
function Invoke-ProcessResult($Executable,$Arguments) {
    $script:calls++
    $path=$Arguments[[Array]::IndexOf($Arguments,'--output')+1]
    $resuming=$Arguments -contains '--continue-at'
    if ($script:mode -eq 'interrupt' -and $script:calls -eq 1) {
        [IO.File]::WriteAllText($path,$payload.Substring(0,31))
        return @{Code=28;Error='fixture timeout'}
    }
    if ($script:mode -eq 'offline') {
        if (Test-Path -LiteralPath $path) { Assert $resuming 'Retry lost resume option' }
        [IO.File]::AppendAllText($path,'partial')
        return @{Code=28;Error='fixture offline'}
    }
    if ($script:mode -eq 'bad') { [IO.File]::WriteAllText($path,'corrupted'); return @{Code=0;Error=''} }
    if ($script:mode -eq 'range' -and $resuming) { return @{Code=33;Error='fixture rejects Range'} }
    if ($script:mode -in @('interrupt','complete')) {
        Assert $resuming 'Interrupted download restarted instead of resuming'
        $prefix=[IO.File]::ReadAllText($path)
        if ($script:mode -eq 'interrupt') { Assert ($prefix -eq $payload.Substring(0,31)) 'Partial bytes were lost' }
        [IO.File]::AppendAllText($path,$payload.Substring($prefix.Length))
    } else { Assert (-not (Test-Path -LiteralPath $path)) 'Range fallback did not discard partial'; [IO.File]::WriteAllText($path,$payload) }
    return @{Code=0;Error=''}
}
$archive=Join-Path $fixture 'resumed.zip'
Receive-VerifiedArchive 'https://example.test/cua.zip' $archive $digest
Assert ($script:calls -eq 2 -and (Get-FileHash $archive).Hash -eq $digest) 'Interrupted archive did not verify'
Assert (-not (Test-Path ($archive + '.partial'))) 'Completed partial remains'
$archive=Join-Path $fixture 'retry-next-run.zip'
$script:mode='offline'; $script:calls=0; $failed=$false
try { Receive-VerifiedArchive 'https://example.test/cua.zip' $archive $digest } catch { $failed=$true }
Assert ($failed -and $script:calls -eq 3 -and (Test-Path ($archive + '.partial')) -and -not (Test-Path $archive)) 'Failed attempts lost partial data or promoted incomplete bytes'
# Replace the simulated prefix with valid bytes of the same length, then resume next invocation.
$length=(Get-Item ($archive + '.partial')).Length
[IO.File]::WriteAllText(($archive + '.partial'),$payload.Substring(0,$length))
$script:mode='complete'
Receive-VerifiedArchive 'https://example.test/cua.zip' $archive $digest
Assert ((Get-FileHash $archive).Hash -eq $digest) 'Next invocation failed to resume'
$archive=Join-Path $fixture 'range.zip'
[IO.File]::WriteAllText(($archive + '.partial'),$payload.Substring(0,20))
$script:mode='range'; $script:calls=0
Receive-VerifiedArchive 'https://example.test/cua.zip' $archive $digest
Assert ($script:calls -eq 2 -and (Get-FileHash $archive).Hash -eq $digest) 'Range rejection fallback failed'
$archive=Join-Path $fixture 'bad.zip'
$script:mode='bad'; $failed=$false
try { Receive-VerifiedArchive 'https://example.test/cua.zip' $archive $digest } catch { $failed=$_.Exception.Message -like '*checksum mismatch*' }
Assert ($failed -and -not (Test-Path $archive) -and -not (Test-Path ($archive + '.partial'))) 'Corrupt archive retained or accepted'
Write-Host 'PASS: interrupted transfer resume, next-run resume, rejected Range, and checksum failure'
