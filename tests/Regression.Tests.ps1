$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Web.Extensions
$root = Split-Path $PSScriptRoot -Parent
$path = Join-Path $root 'ZedThreadColors.ps1'
$text = [IO.File]::ReadAllText($path)
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }

function Get-Literal([string]$name) {
    $node = $ast.Find({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $name
    }.GetNewClosure(), $true)
    return $node.Right.Expression.Value
}

$source = Get-Literal '$source'
Add-Type -TypeDefinition $source -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Web.Extensions
$ocrSource = Get-Literal '$ocrSource'

function Assert([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}
function Get-Field($target, [string]$name) {
    return $target.GetType().GetField($name, [Reflection.BindingFlags]'Instance, NonPublic, Public').GetValue($target)
}
function Set-Field($target, [string]$name, $value) {
    $target.GetType().GetField($name, [Reflection.BindingFlags]'Instance, NonPublic, Public').SetValue($target, $value)
}
function Invoke-Private($target, [string]$name, [object[]]$arguments = @()) {
    for ($i = 0; $i -lt $arguments.Length; $i++) {
        if ($null -ne $arguments[$i]) { $arguments[$i] = $arguments[$i].PSObject.BaseObject }
    }
    return $target.GetType().GetMethod($name, [Reflection.BindingFlags]'Instance, NonPublic').Invoke($target, $arguments)
}
function Write-Events([string]$file, [object[]]$events) {
    $lines = @($events | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress })
    [IO.File]::WriteAllLines($file, $lines)
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('ZedOverlayTests-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($temp)
$oldHome = $env:COPILOT_HOME
$worker = $null; $runspace = $null; $timer = $null
$forms = @()
try {
    $env:COPILOT_HOME = Join-Path $temp 'copilot'
    $hostApp = [Runtime.Serialization.FormatterServices]::GetUninitializedObject([ZedColors.App])
    Set-Field $hostApp 'logPath' (Join-Path $temp 'log.txt')
    Set-Field $hostApp 'logWarnings' (New-Object 'System.Collections.Generic.Dictionary[string,string]')
    Set-Field $hostApp 'threads' (New-Object 'System.Collections.Generic.List[ZedColors.ThreadInfo]')
    $indexer = New-Object ZedColors.Indexer($hostApp)
    Set-Field $hostApp 'indexer' $indexer
    Set-Field $indexer 'js' (New-Object System.Web.Script.Serialization.JavaScriptSerializer)

    $session = [Guid]::NewGuid().ToString()
    $dir = Join-Path $env:COPILOT_HOME ('session-state\' + $session)
    $null = [IO.Directory]::CreateDirectory($dir)
    $file = Join-Path $dir 'events.jsonl'
    $info = New-Object ZedColors.ThreadInfo
    $info.Session = $session; $info.Agent = 'github-copilot-cli'; $info.Display = 'Example thread'
    $info.Folders = $temp
    $found = Invoke-Private $indexer 'Resolve' (, $info)
    Assert ($null -eq $found) 'A history that does not exist should be unavailable.'
    $until = (Get-Field $indexer 'missing')[$session]
    Assert ($until -gt [DateTime]::Now) 'The first missing-history lookup must be cached.'

    $now = [DateTime]::UtcNow.ToString('o')
    Write-Events $file @(
        @{ type = 'user.message'; timestamp = $now; data = @{ content = 'Make the sample clearer' } },
        @{ type = 'assistant.turn_start'; timestamp = $now; data = @{} }
    )
    $hostApp.ActiveSession = $session
    $found = Invoke-Private $indexer 'Resolve' (, $info)
    Assert ($found -eq $file) 'New active histories must bypass a previous missing-file cache immediately.'
    $doc = New-Object ZedColors.ThreadDoc
    $doc.Info = $info
    $null = Invoke-Private $indexer 'IndexDoc' (, $doc)
    Assert ($doc.Prompt -eq 'Make the sample clearer') 'The background indexer must publish the last prompt.'
    Assert ($null -eq $doc.Problem) 'A readable history should not show an error.'
    $docs = New-Object 'System.Collections.Generic.List[ZedColors.ThreadDoc]'
    $docs.Add($doc)
    $null = Invoke-Private $indexer 'PublishUsage' (, $docs)
    $usage = $indexer.Usage.BySession[$session]
    Assert ($usage.HasTurn -and $usage.Working) 'A newly created Copilot session must be working.'

    $form = New-Object ZedColors.BoxForm
    $rings = New-Object ZedColors.RingForm
    $bar = New-Object ZedColors.PromptBar
    $forms = @($form, $rings, $bar)
    Set-Field $hostApp 'form' $form
    Set-Field $hostApp 'rings' $rings
    Set-Field $hostApp 'bar' $bar
    Set-Field $hostApp 'seen' (New-Object 'System.Collections.Generic.Dictionary[string,datetime]')
    $row = New-Object ZedColors.Row
    $row.Key = 'sample|examplethread'; $row.Project = [IO.Path]::GetFileName($temp); $row.Title = $info.Display
    $row.CenterY = 50
    $form.Rows.Add($row)
    $indexer.Index = New-Object ZedColors.IndexSnapshot
    $indexer.Index.Docs = $docs
    Set-Field $hostApp 'sidebar' (New-Object Drawing.Rectangle(0, 0, 200, 100))
    Set-Field $hostApp 'lastCapW' 200
    Set-Field $hostApp 'lastCh' 100
    $pixels = New-Object 'int[]' 20000
    $pixels[50 * 200 + 188] = 0xffffff
    Set-Field $hostApp 'lastPx' $pixels
    Set-Field $hostApp 'scale' ([single]1)
    Set-Field $hostApp 'barEnabled' $true
    $hostApp.OnIndex()
    Assert ((Get-Field $hostApp 'active').Session -eq $session) 'A late database snapshot must re-match the selected new thread without needing another OCR change.'
    $null = Invoke-Private $hostApp 'LoadThreads'
    $null = Invoke-Private $hostApp 'UpdateDots'
    Assert ($rings.Dots[$row.Key] -eq 1) 'The newly discovered session must receive a blue working ring.'
    Set-Field $hostApp 'active' $info
    Set-Field $hostApp 'barEnabled' $true
    [IO.File]::Delete($file)
    $null = Invoke-Private $hostApp 'RefreshPrompt'
    Assert ($bar.Prompt -eq 'Make the sample clearer') 'The UI prompt reader must use the snapshot, not read the file.'

    Write-Events $file @(
        @{ type = 'user.message'; timestamp = $now; data = @{ content = 'A new prompt' } },
        @{ type = 'assistant.message'; timestamp = $now; data = @{ content = 'Finished'; toolRequests = @() } },
        @{ type = 'assistant.turn_end'; timestamp = $now; data = @{} }
    )
    $next = New-Object ZedColors.ThreadDoc
    $next.Info = $info
    $null = Invoke-Private $indexer 'IndexDoc' (, $next)
    Assert ($next.Prompt -eq 'A new prompt') 'Rewritten histories must replace the cached prompt.'
    $docs.Clear(); $docs.Add($next)
    $null = Invoke-Private $indexer 'PublishUsage' (, $docs)
    Assert (-not $indexer.Usage.BySession[$session].Working) 'A completed Copilot turn must not keep a working ring.'

    [IO.File]::AppendAllText($file, '{"type":"user.message","data":' + "`n")
    $broken = New-Object ZedColors.ThreadDoc
    $broken.Info = $info
    $null = Invoke-Private $indexer 'IndexDoc' (, $broken)
    Assert ($null -ne $broken.Problem) 'Malformed history must be marked incomplete rather than silently ignored.'
    $null = Invoke-Private $indexer 'IndexDoc' (, $broken)
    $warnings = @([IO.File]::ReadAllLines((Join-Path $temp 'log.txt')) | Where-Object { $_ -like '*could not be parsed*' })
    Assert ($warnings.Count -eq 1) 'An unchanged history error should not flood the log.'
    $docs.Clear(); $docs.Add($broken)
    $null = Invoke-Private $indexer 'Publish' @($docs, 1, $false)
    Assert ($indexer.Index.Unavailable -eq 1) 'Search must count incomplete histories.'
    $search = New-Object ZedColors.SearchForm($hostApp, 1)
    $forms += $search
    Assert ((Get-Field $search 'status').Text -like '*incomplete*') 'The search window must make incomplete history visible.'
    Set-Field $search 'resultStatus' 'No matches'
    $indexer.Index.Problem = 'Thread list unavailable'
    $search.Show()
    $search.OnIndexUpdated()
    Assert ((Get-Field $search 'status').Text -eq 'Thread list unavailable') 'A database failure must not look like an empty search.'
    $indexer.Index.Problem = $null
    $search.OnIndexUpdated()
    Assert ((Get-Field $search 'status').Text -notlike '*Thread list unavailable*') 'The visible search status must recover after database access recovers.'
    $search.Hide()
    $missingDoc = New-Object ZedColors.ThreadDoc
    $missingDoc.Info = $info; $missingDoc.Problem = 'Saved history unavailable. Open log for details.'
    $indexer.Index.Docs = New-Object 'System.Collections.Generic.List[ZedColors.ThreadDoc]'
    $indexer.Index.Docs.Add($missingDoc)
    $null = Invoke-Private $hostApp 'RefreshPrompt'
    Assert ($bar.Prompt -eq $missingDoc.Problem) 'The prompt bar must explain why history is unavailable.'

    $legacy = Join-Path $temp 'legacy.json'
    [IO.File]::WriteAllText($legacy, '[{"role":"user","content":"Legacy prompt"}]')
    $legacyInfo = New-Object ZedColors.ThreadInfo
    $legacyInfo.Agent = 'github-copilot-cli'; $legacyInfo.Session = 'legacy'
    (Get-Field $indexer 'files')['legacy'] = $legacy
    $legacyDoc = New-Object ZedColors.ThreadDoc
    $legacyDoc.Info = $legacyInfo
    $null = Invoke-Private $indexer 'IndexDoc' (, $legacyDoc)
    Assert ($legacyDoc.Prompt -eq 'Legacy prompt') 'Moving prompt reads must preserve single-file JSON history support.'

    $constructor = $source.Substring($source.IndexOf('public App(string script)'))
    $constructor = $constructor.Substring(0, $constructor.IndexOf('form = new BoxForm()'))
    Assert (-not $constructor.Contains('ToggleStartup()' + ';')) 'The constructor must not enable Windows startup.'
    Assert (-not $constructor.Contains('installed.txt')) 'First-run startup must not be changed by an installation marker.'
    Set-Field $hostApp 'paused' $true
    Assert (-not $hostApp.CanApplyOcr($hostApp.OcrRevision)) 'Paused overlays must reject in-flight OCR results.'
    Assert (-not $hostApp.CanApplyOcr($hostApp.OcrRevision + 1)) 'Superseded OCR results must be rejected.'

    $bmp = New-Object Drawing.Bitmap(800, 200)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $font = New-Object Drawing.Font('Segoe UI', 36)
    $ms = New-Object IO.MemoryStream
    try {
        $g.Clear([Drawing.Color]::White)
        $g.DrawString('Example thread', $font, [Drawing.Brushes]::Black, 20, 40)
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        $bytes = $ms.ToArray()
    } finally { $font.Dispose(); $g.Dispose(); $bmp.Dispose(); $ms.Dispose() }

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = [Threading.ApartmentState]::MTA
    $runspace.ThreadOptions = [Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()
    $worker = [Management.Automation.PowerShell]::Create()
    $worker.Runspace = $runspace
    $script:ticks = 0
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 10
    $timer.Add_Tick({ $script:ticks++ })
    $timer.Start()
    for ($pass = 0; $pass -lt 2; $pass++) {
        $worker.Commands.Clear(); $worker.Streams.Error.Clear()
        $null = $worker.AddScript($ocrSource).AddArgument($bytes)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $job = $worker.BeginInvoke()
        $watch.Stop()
        Assert ($watch.ElapsedMilliseconds -lt 100) 'Starting background OCR must not block the UI for 100 ms.'
        $deadline = [DateTime]::Now.AddSeconds(30)
        while (-not $job.IsCompleted) {
            Assert ([DateTime]::Now -lt $deadline) 'Background OCR did not complete within 30 seconds.'
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 5
        }
        $result = $worker.EndInvoke($job)
        Assert ($worker.Streams.Error.Count -eq 0) ('Background OCR failed: ' + ($worker.Streams.Error | Out-String))
        Assert ($result.Count -eq 1) 'Background OCR must return exactly one result.'
        $recognized = ($result[0].Words | ForEach-Object { $_.Text }) -join ' '
        Assert ($recognized -like '*Example thread*') ('OCR did not recognize the fixture: ' + $recognized)
    }
    Assert ($script:ticks -gt 0) 'The interface timer must keep running while background OCR executes.'

    $tickNode = $ast.Find({
        param($n)
        $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'Add_Tick'
    }, $true)
    $tick = $tickNode.Arguments[0].ScriptBlock.GetScriptBlock()
    $script:app = [pscustomobject]@{ PngBytes = $bytes; OcrRevision = 0; Captures = 0; Applied = 0; Words = 0; Warnings = 0; Retries = 0; TargetCurrent = $true }
    $script:app | Add-Member ScriptMethod Prepare {
        $this.Captures++; $this.OcrRevision++
        return $true
    }
    $script:app | Add-Member ScriptMethod CanApplyOcr { param($revision) return $this.TargetCurrent -and $revision -eq $this.OcrRevision }
    $script:app | Add-Member ScriptMethod BeginOcr { $this.Words = 0 }
    $script:app | Add-Member ScriptMethod AddWord { $this.Words++ }
    $script:app | Add-Member ScriptMethod EndOcr { $this.Applied++ }
    $script:app | Add-Member ScriptMethod RetryOcr { $this.Retries++ }
    $script:app | Add-Member ScriptMethod LogOnce { param($key) if ($key -eq 'ocr-worker' -or $key -eq 'ocr-input') { $this.Warnings++ } }
    $script:app | Add-Member ScriptMethod Log { $this.Warnings++ }
    $script:ocrWorker = $worker
    $script:ocrJob = $null; $script:ocrPending = $false; $script:busy = $false; $script:errors = 0
    $null = & $tick
    $script:app.TargetCurrent = $false
    if (-not $script:ocrJob.IsCompleted) {
        $null = & $tick
        Assert ($script:app.Captures -eq 1) 'Animated sidebar captures must not supersede an in-flight OCR request.'
    }
    $deadline = [DateTime]::Now.AddSeconds(30)
    while (-not $script:ocrJob.IsCompleted) {
        Assert ([DateTime]::Now -lt $deadline) 'The timer integration OCR request did not complete.'
        Start-Sleep -Milliseconds 5
    }
    $null = & $tick
    Assert ($script:app.Applied -eq 0) 'The actual interface callback must discard OCR when its target window changed.'
    $script:app.TargetCurrent = $true
    while ($script:app.Applied -eq 0) {
        Assert ([DateTime]::Now -lt $deadline) 'Animated sidebar captures caused an endless retry loop.'
        $null = & $tick
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 5
    }
    Assert ($script:app.Words -ge 2) 'The actual interface callback must apply recognized words.'
    Assert ($script:app.Warnings -eq 0) 'The actual interface callback must not report errors for valid OCR.'
    Assert ($script:app.Retries -eq 1) 'Only the invalid window target should require an OCR retry.'
    Assert ($script:app.Captures -eq 3) 'A continuously changing sidebar must apply OCR before taking its next capture.'
    $null = [xml]([IO.File]::ReadAllText((Join-Path $root 'docs\overlay-preview.svg')))
    'Passed: compilation, new-session discovery and working ring, cached prompts, completion, history errors, JSON fallback, startup opt-in, stale OCR, responsive OCR worker, and preview SVG.'
} finally {
    if ($null -ne $timer) { $timer.Stop(); $timer.Dispose() }
    if ($null -ne $worker) { $worker.Stop(); $worker.Dispose() }
    if ($null -ne $runspace) { $runspace.Dispose() }
    foreach ($f in $forms) { $f.Dispose() }
    $env:COPILOT_HOME = $oldHome
    [IO.Directory]::Delete($temp, $true)
}
