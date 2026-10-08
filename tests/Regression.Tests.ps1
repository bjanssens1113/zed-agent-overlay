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
    Set-Field $hostApp 'overlayLayout' (New-Object ZedColors.OverlayLayout)
    Set-Field $hostApp 'layoutPath' (Join-Path $temp 'layout.json')
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
    Assert $bar.Expanded 'Last Prompt must start expanded by default.'
    $bar.Host = $hostApp
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
    $bar.Expanded = $false
    $hostApp.OnIndex()
    Assert ((Get-Field $hostApp 'active').Session -eq $session) 'A late database snapshot must re-match the selected new thread without needing another OCR change.'
    Assert $bar.Expanded 'Opening a thread must expand Last Prompt by default.'
    $bar.Expanded = $false
    $null = Invoke-Private $hostApp 'SetActive' (, $info)
    Assert (-not $bar.Expanded) 'Refreshing the same thread must respect a manual collapse.'
    $otherInfo = New-Object ZedColors.ThreadInfo
    $otherInfo.Session = [Guid]::NewGuid().ToString(); $otherInfo.Agent = $info.Agent
    $null = Invoke-Private $hostApp 'SetActive' (, $otherInfo)
    Assert $bar.Expanded 'Switching threads must reopen Last Prompt.'
    $null = Invoke-Private $hostApp 'SetActive' (, $info)
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
    $completed = $indexer.Usage.BySession[$session]
    $completed.TurnEnd = [DateTime]::Now
    (Get-Field $hostApp 'seen')[$session] = [DateTime]::Now
    $null = Invoke-Private $hostApp 'UpdateDots'
    Assert ($rings.Dots[$row.Key] -eq 2) 'A just-finished turn must briefly turn green even when already seen.'
    $completed.TurnEnd = [DateTime]::Now.AddSeconds(-6)
    $null = Invoke-Private $hostApp 'UpdateDots'
    Assert (-not $rings.Dots.ContainsKey($row.Key)) 'A viewed completion must clear after the five-second green flash.'
    (Get-Field $hostApp 'seen')[$session] = [DateTime]::Now.AddMinutes(-1)
    $null = Invoke-Private $hostApp 'UpdateDots'
    Assert ($rings.Dots[$row.Key] -eq 2) 'An unseen completion must stay green beyond the brief flash.'
    $completed.Working = $true; $completed.ActiveHelpers = 3; $completed.LastWrite = [DateTime]::Now
    $null = Invoke-Private $hostApp 'UpdateDots'
    Assert ($rings.ActiveHelpers[$row.Key] -eq 3) 'Active helper counts must reach the sidebar ring.'
    $completed.ActiveHelpers = 1
    $null = Invoke-Private $hostApp 'UpdateDots'
    Assert ($rings.ActiveHelpers[$row.Key] -eq 1) 'Helper dashes must update even when the ring stays blue.'
    $completed.Working = $false
    $null = Invoke-Private $hostApp 'UpdateDots'
    Assert (-not $rings.ActiveHelpers.ContainsKey($row.Key)) 'Finished threads must not retain helper dashes.'

    $statusUsage = New-Object ZedColors.ThreadUsage
    $statusUsage.HasTurn = $true; $statusUsage.Working = $true
    $statusUsage.ActiveHelpers = 8; $statusUsage.LastWrite = [DateTime]::Now
    $color = [Drawing.Color]::Empty
    $statusText = [ZedColors.App]::StatusTextPublic($statusUsage, [ref]$color)
    Assert ($statusText -eq 'Working with 8 helper agents') 'The shared status must report the exact helper count beyond the visual cap.'
    $statusUsage.WaitingForHelpers = $true
    $statusText = [ZedColors.App]::StatusTextPublic($statusUsage, [ref]$color)
    Assert ($statusText -eq 'Waiting for 8 helper agents') 'The shared status must distinguish working from waiting on helpers.'
    $statusUsage.AskText = 'Choose an option'
    $statusText = [ZedColors.App]::StatusTextPublic($statusUsage, [ref]$color)
    Assert ($statusText -like '*8 helper agents working*') 'The exact helper count must remain visible while the main agent asks the user a question.'

    $row.RowTop = 40; $row.RowBottom = 85
    $rings.Rows.Clear(); $rings.Rows.Add($row)
    foreach ($scale in @([single]1, [single]1.5, [single]2)) {
        $rings.UiScale = $scale
        $rings.Width = [int](230 * $scale); $rings.Height = [int](140 * $scale)
        foreach ($count in @(0, 1, 3, 6, 7, 50)) {
            $rings.ActiveHelpers[$row.Key] = $count
            $bars = $rings.HelperRects($row)
            Assert ($bars.Count -eq [Math]::Min(6, $count)) 'Helper dashes must match the live count, capped at exactly six.'
            foreach ($rect in $bars) {
                Assert ($rect.Top -gt $rings.RingRect($row).Bottom) 'Helper dashes must be beneath the ring, not over thread text.'
                Assert ($rings.HelperBand($row).Contains([Drawing.Rectangle]::Ceiling($rect))) 'The OCR masking band must cover every helper dash.'
                Assert ($rect.Right -le $rings.Width) 'Scaled helper dashes must fit within the sidebar.'
            }
        }
    }
    $rings.UiScale = 1; $rings.Width = 230; $rings.Height = 140
    $rings.Dots[$row.Key] = 1; $rings.ActiveHelpers[$row.Key] = 7
    $drawing = New-Object Drawing.Bitmap(230, 140)
    $graphics = [Drawing.Graphics]::FromImage($drawing)
    try {
        $graphics.Clear([Drawing.Color]::Transparent)
        $null = Invoke-Private $rings 'Draw' (, $graphics)
        $bars = $rings.HelperRects($row)
        foreach ($rect in $bars) {
            $pixel = $drawing.GetPixel([int]($rect.Left + $rect.Width / 2), [int]($rect.Top + $rect.Height / 2))
            Assert ($pixel.A -gt 150 -and $pixel.B -gt 150) 'The rendered helper dashes must be visible on the alpha overlay.'
        }
        $plusPixels = 0
        for ($x = [int]($bars[-1].Right + 3); $x -lt $rings.Width - 3; $x++) {
            for ($y = [int]$bars[0].Top; $y -lt $rings.HelperBand($row).Bottom; $y++) {
                if ($drawing.GetPixel($x, $y).A -gt 150) { $plusPixels++ }
            }
        }
        Assert ($plusPixels -gt 0) 'Counts over six must render a visible plus sign after the six dashes.'
    } finally { $graphics.Dispose(); $drawing.Dispose() }

    $claude = New-Object ZedColors.FileScan
    $claude.Kind = 'claude'; $claude.WantText = $true; $claude.Path = Join-Path $temp 'claude.jsonl'
    function Claude-Event($event) {
        $line = $event | ConvertTo-Json -Depth 20 -Compress
        $null = Invoke-Private $indexer 'Line' @($claude, $line)
    }
    Claude-Event @{ type = 'assistant'; timestamp = $now; message = @{
        stop_reason = 'tool_use'; content = @(@{ type = 'tool_use'; id = 'foreground'; name = 'Agent'; input = @{} })
    } }
    Assert ($claude.ActiveHelpers -eq 1 -and $claude.Background -eq 0) 'Foreground helper calls must count without pretending to be background work.'
    Claude-Event @{ type = 'user'; timestamp = $now; toolUseResult = @{ isAsync = $false };
        message = @{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = 'foreground'; content = 'Finished' }) } }
    Assert ($claude.ActiveHelpers -eq 0) 'Foreground helper results must clear their dash.'
    Claude-Event @{ type = 'user'; timestamp = $now; message = @{ role = 'user'; content = 'Run two sample checks' } }
    foreach ($id in @('tool-one', 'tool-two')) {
        Claude-Event @{ type = 'assistant'; timestamp = $now; message = @{
            stop_reason = 'tool_use'; content = @(@{ type = 'tool_use'; id = $id; name = 'Agent'; input = @{ run_in_background = $true } })
        } }
        Claude-Event @{ type = 'user'; timestamp = $now; toolUseResult = @{ isAsync = $true; status = 'async_launched'; agentId = ('task-' + $id) };
            message = @{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = $id; content = 'Started' }) } }
    }
    Claude-Event @{ type = 'assistant'; timestamp = $now; message = @{ stop_reason = 'end_turn'; content = @(@{ type = 'text'; text = 'Waiting for checks' }) } }
    Assert ($claude.Background -eq 2 -and $claude.Working) 'Claude must remain working while two real background tasks are pending.'
    Assert ($claude.ActiveHelpers -eq 2 -and $claude.WaitingForBackground) 'Pending background helpers must be counted as helpers the main agent is waiting for.'
    $noteOne = '<task-notification><task-id>task-tool-one</task-id><status>completed</status></task-notification>'
    Claude-Event @{ type = 'queue-operation'; operation = 'enqueue'; timestamp = $now; content = $noteOne }
    Assert ($claude.Background -eq 2) 'Enqueued but not delivered notifications must not change the active task state.'
    Claude-Event @{ type = 'attachment'; timestamp = $now; attachment = @{ type = 'queued_command'; prompt = $noteOne } }
    Assert ($claude.Background -eq 1) 'Claude queued-command attachments must retire their matching background task.'
    Assert ($claude.ActiveHelpers -eq 1) 'A background helper completion must remove its corresponding dash.'
    Claude-Event @{ type = 'user'; timestamp = $now; message = @{ role = 'user'; content = $noteOne } }
    Assert ($claude.Background -eq 1) 'The same completion delivered twice must not retire another task.'
    $noteTwo = '<task-notification><task-id>task-tool-two</task-id><status>completed</status></task-notification>'
    Claude-Event @{ type = 'attachment'; timestamp = $now; attachment = @{ type = 'queued_command'; prompt = $noteTwo } }
    Claude-Event @{ type = 'assistant'; timestamp = $now; message = @{ stop_reason = 'end_turn'; content = @(@{ type = 'text'; text = 'Checks complete' }) } }
    Assert ($claude.Background -eq 0 -and -not $claude.Working) 'Claude must finish after queued background completions and its final reply.'
    Assert ($claude.ActiveHelpers -eq 0) 'Completed background helpers must not accumulate as live dashes.'
    Claude-Event @{ type = 'user'; timestamp = $now; message = @{ role = 'user'; content = $noteTwo } }
    Assert (-not $claude.Working) 'A duplicate completion must not turn a finished Claude thread blue again.'
    Claude-Event @{ type = 'user'; timestamp = $now; toolUseResult = @{ agentId = 'task-tool-two'; isAsync = $true };
        message = @{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = 'tool-two'; content = 'Started' }) } }
    Assert ($claude.Background -eq 0) 'A duplicated launch result must not resurrect a completed background job.'
    $claude.BackgroundStarted('tool-three'); $claude.BackgroundLaunched('tool-three', 'task-three')
    $claude.BackgroundStarted('tool-four'); $claude.BackgroundLaunched('tool-four', 'task-four')
    Assert ($claude.ActiveHelpers -eq 0) 'Background commands must not be counted as helper agents.'
    Claude-Event @{ type = 'assistant'; timestamp = $now; message = @{ stop_reason = 'tool_use';
        content = @(@{ type = 'tool_use'; id = 'stop-tool'; name = 'TaskStop'; input = @{ task_id = 'task-three' } }) } }
    Assert ($claude.Background -eq 2) 'Requesting TaskStop must not count as a successful stop.'
    Claude-Event @{ type = 'user'; timestamp = $now; message = @{ role = 'user';
        content = @(@{ type = 'tool_result'; tool_use_id = 'stop-tool'; is_error = $true; content = 'Stop failed' }) } }
    Assert ($claude.Background -eq 2) 'A failed TaskStop must leave its background task active.'
    Claude-Event @{ type = 'assistant'; timestamp = $now; message = @{ stop_reason = 'tool_use';
        content = @(@{ type = 'tool_use'; id = 'stop-again'; name = 'TaskStop'; input = @{ task_id = 'task-three' } }) } }
    Claude-Event @{ type = 'user'; timestamp = $now; message = @{ role = 'user';
        content = @(@{ type = 'tool_result'; tool_use_id = 'stop-again'; content = 'Stopped' }) } }
    Assert ($claude.Background -eq 1 -and $claude.BackgroundTasks.Contains('task-four')) 'A successful TaskStop must retire the named task, not an arbitrary counter.'
    $null = $claude.BackgroundFinished('task-four')
    Claude-Event @{ type = 'assistant'; timestamp = $now; message = @{ stop_reason = 'end_turn'; content = @(@{ type = 'text'; text = 'Finished' }) } }
    foreach ($id in @('one', 'two')) {
        Claude-Event @{ type = 'assistant'; timestamp = $now; message = @{ stop_reason = 'tool_use';
            content = @(@{ type = 'tool_use'; id = ('send-' + $id); name = 'SendMessage'; input = @{ to = ('task-tool-' + $id); message = 'Continue checking' } }) } }
        Claude-Event @{ type = 'user'; timestamp = $now; toolUseResult = @{ success = $true; resumedAgentId = ('task-tool-' + $id) };
            message = @{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = ('send-' + $id); content = 'Resumed' }) } }
    }
    Assert ($claude.Background -eq 2 -and $claude.Working) 'SendMessage must reactivate finished background helpers.'
    Assert ($claude.ActiveHelpers -eq 2) 'Resumed helpers must restore their live dashes.'
    Claude-Event @{ type = 'user'; timestamp = $now; toolUseResult = @{ success = $true; resumedAgentId = 'task-tool-two' };
        message = @{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = 'send-two'; content = 'Resumed' }) } }
    Assert ($claude.Background -eq 2) 'Duplicate SendMessage results must not double-count resumed helpers.'
    Claude-Event @{ type = 'user'; timestamp = $now; toolUseResult = @{ success = $false; resumedAgentId = 'not-started' };
        message = @{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = 'send-failed'; content = 'Not resumed' }) } }
    Assert ($claude.Background -eq 2) 'A failed SendMessage must not create a running helper.'
    Claude-Event @{ type = 'assistant'; timestamp = $now; message = @{ stop_reason = 'end_turn'; content = @(@{ type = 'text'; text = 'Waiting for resumed checks' }) } }
    Assert ($claude.Working) 'A main-agent end_turn must not finish the thread while resumed helpers still work.'
    Claude-Event @{ type = 'attachment'; timestamp = $now; attachment = @{ type = 'queued_command'; prompt = $noteOne } }
    Claude-Event @{ type = 'assistant'; timestamp = $now; message = @{ stop_reason = 'end_turn'; content = @(@{ type = 'text'; text = 'One check returned' }) } }
    Assert ($claude.Working -and $claude.Background -eq 1) 'One resumed completion must not finish another helper.'
    $claude.Write = [DateTime]::UtcNow.AddMinutes(-11)
    (Get-Field $indexer 'scans')[$claude.Path] = $claude
    $claudeDoc = New-Object ZedColors.ThreadDoc
    $claudeDoc.File = $claude.Path; $claudeDoc.Info = New-Object ZedColors.ThreadInfo
    $claudeDoc.Info.Session = 'claude-test'; $claudeDoc.Info.Agent = 'claude-acp'
    $claudeDocs = New-Object 'System.Collections.Generic.List[ZedColors.ThreadDoc]'
    $claudeDocs.Add($claudeDoc)
    $null = Invoke-Private $indexer 'PublishUsage' (, $claudeDocs)
    Assert ($indexer.Usage.BySession['claude-test'].Working) 'A quiet pending background helper must not be guessed finished after ten minutes.'
    Assert ($indexer.Usage.BySession['claude-test'].ActiveHelpers -eq 1 -and $indexer.Usage.BySession['claude-test'].WaitingForHelpers) 'The published snapshot must carry helper count and waiting state.'
    Claude-Event @{ type = 'attachment'; timestamp = $now; attachment = @{ type = 'queued_command'; prompt = $noteTwo } }
    Claude-Event @{ type = 'assistant'; timestamp = $now; message = @{ stop_reason = 'end_turn'; content = @(@{ type = 'text'; text = 'All resumed checks returned' }) } }
    Assert (-not $claude.Working -and $claude.Background -eq 0) 'The thread must finish after all resumed helpers complete and the main agent ends its turn.'
    $copilot = New-Object ZedColors.FileScan
    $copilot.Kind = 'copilot'; $copilot.WantText = $true; $copilot.Path = Join-Path $temp 'copilot.jsonl'
    foreach ($event in @(
        @{ type = 'tool.execution_start'; timestamp = $now; data = @{ toolName = 'task'; toolCallId = 'helper-call'; arguments = @{ mode = 'sync' } } },
        @{ type = 'tool.execution_start'; timestamp = $now; data = @{ toolName = 'task'; toolCallId = 'nested-call'; parentToolCallId = 'helper-call'; arguments = @{ mode = 'sync' } } }
    )) { $null = Invoke-Private $indexer 'Line' @($copilot, ($event | ConvertTo-Json -Depth 20 -Compress)) }
    Assert ($copilot.ActiveHelpers -eq 1) 'Copilot must count directly called helpers, not a helper nested inside another helper.'
    $event = @{ type = 'tool.execution_complete'; timestamp = $now; data = @{ toolCallId = 'helper-call'; success = $true } }
    $null = Invoke-Private $indexer 'Line' @($copilot, ($event | ConvertTo-Json -Depth 20 -Compress))
    Assert ($copilot.ActiveHelpers -eq 0) 'Copilot helper call completion must clear its dash.'
    $promptFile = Join-Path $temp 'prompt-provenance.jsonl'
    $promptEvents = @(
        @{ type = 'user.message'; timestamp = $now; data = @{ content = 'My actual request' } },
        @{ type = 'assistant.message'; timestamp = $now; data = @{ content = 'Done'; toolRequests = @() } },
        @{ type = 'assistant.turn_end'; timestamp = $now; data = @{} },
        @{ type = 'user.message'; timestamp = $now; data = @{ content = 'Internal helper results'; source = 'agent-example-session' } },
        @{ type = 'user.message'; timestamp = $now; data = @{ content = 'A nested helper prompt'; parentToolCallId = 'parent-helper' } },
        @{ type = 'user.message'; timestamp = $now; data = @{ content = '<system_notification>Agent finished</system_notification>' } }
    )
    Write-Events $promptFile $promptEvents
    Assert ([ZedColors.Transcripts]::LastPrompt($promptFile) -eq 'My actual request') 'Agent-injected results, nested messages, and runtime notices must not replace the real last prompt.'
    $provenance = New-Object ZedColors.FileScan
    $provenance.Kind = 'copilot'; $provenance.WantText = $true; $provenance.Path = $promptFile
    foreach ($event in $promptEvents) { $null = Invoke-Private $indexer 'Line' @($provenance, ($event | ConvertTo-Json -Depth 20 -Compress)) }
    Assert ($provenance.Prompts -eq 1 -and -not $provenance.Working) 'Injected messages must not count as prompts or restart a completed turn.'
    Assert (@($provenance.Msgs | Where-Object {$_.You}).Count -eq 1) 'Search and prompt navigation must exclude injected messages too.'
    $named = New-Object ZedColors.FileScan
    $named.HelperStarted('named-call', 'Review the changes')
    $named.BackgroundStarted('named-call'); $named.BackgroundLaunched('named-call', 'named-agent')
    $named.HelperStarted('unknown-call')
    Assert ($named.ActiveHelpers -eq 2 -and $named.ActiveHelperDescriptions().Length -eq 1) 'Unknown helper descriptions must not be invented.'
    $named.BackgroundFinished('named-agent') | Out-Null
    Assert ($named.ActiveHelperDescriptions().Length -eq 0) 'Completed helper descriptions must disappear from the active list.'
    $named.BackgroundResumed('resume-call', 'named-agent') | Out-Null
    Assert ($named.ActiveHelperDescriptions()[0] -eq 'Review the changes') 'Resumed Claude helpers must retain their recorded description.'
    $named.Reset()
    Assert ($named.HelperDescriptions.Count -eq 0) 'History reset must discard helper descriptions.'
    function Copilot-Event($event) {
        $null = Invoke-Private $indexer 'Line' @($copilot, ($event | ConvertTo-Json -Depth 20 -Compress))
    }
    $agent = '11111111-2222-3333-4444-555555555555'
    Copilot-Event @{ type = 'tool.execution_start'; timestamp = $now; data = @{ toolName = 'task'; toolCallId = 'long-call'; arguments = @{ mode = 'background' } } }
    $launch = @{ type = 'tool.execution_complete'; timestamp = $now; data = @{ toolCallId = 'long-call'; success = $true; result = @{ content = "Agent started in background with agent_id: $agent." } } }
    Copilot-Event $launch
    Copilot-Event $launch
    Assert ($copilot.ActiveHelpers -eq 1 -and $copilot.Background -eq 1 -and $copilot.HelperTasks.Contains('long-call')) 'Background launch must preserve one helper by its lifecycle tool-call ID, without double-counting.'
    Copilot-Event @{ type = 'assistant.message'; timestamp = $now; data = @{ content = 'Waiting'; toolRequests = @() } }
    Copilot-Event @{ type = 'assistant.turn_end'; timestamp = $now; data = @{} }
    Assert ($copilot.Working -and $copilot.WaitingForBackground -and $copilot.ActiveHelpers -eq 1) 'A parent turn ending must not clear a still-running background helper.'
    Copilot-Event @{ type = 'tool.execution_start'; timestamp = $now; data = @{ toolName = 'task'; toolCallId = 'short-call'; arguments = @{ mode = 'sync' } } }
    Assert ($copilot.ActiveHelpers -eq 2) 'A short helper must appear alongside the long helper.'
    Copilot-Event @{ type = 'tool.execution_complete'; timestamp = $now; data = @{ toolCallId = 'short-call'; success = $true } }
    Assert ($copilot.ActiveHelpers -eq 1) 'Completing a short helper must leave the long helper counted.'
    Copilot-Event @{ type = 'subagent.completed'; timestamp = $now; data = @{ toolCallId = 'nested-call' } }
    Assert ($copilot.ActiveHelpers -eq 1) 'A nested helper completion must not retire a direct helper.'
    $finished = @{ type = 'subagent.completed'; timestamp = $now; data = @{ toolCallId = 'long-call' } }
    Copilot-Event $finished
    Copilot-Event $finished
    Assert ($copilot.ActiveHelpers -eq 0 -and $copilot.Background -eq 0) 'Confirmed completion must retire the long helper exactly once.'
    Copilot-Event @{ type = 'assistant.turn_end'; timestamp = $now; data = @{} }
    Assert (-not $copilot.Working) 'The parent can finish once its background helper is finished.'
    Copilot-Event @{ type = 'tool.execution_start'; timestamp = $now; data = @{ toolName = 'task'; toolCallId = 'launch-failed'; arguments = @{ mode = 'background' } } }
    Copilot-Event @{ type = 'tool.execution_complete'; timestamp = $now; data = @{ toolCallId = 'launch-failed'; success = $false } }
    Assert ($copilot.ActiveHelpers -eq 0 -and $copilot.Background -eq 0) 'A failed background launch must not leave a stuck dash.'
    Copilot-Event @{ type = 'subagent.completed'; timestamp = $now; data = @{ toolCallId = 'launch-failed' } }
    Assert ($copilot.ActiveHelpers -eq 0) 'A completion after launch failure must remain harmless.'

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

    $area = New-Object Drawing.Rectangle(100, 80, 900, 600)
    $minimum = New-Object Drawing.Size(220, 68)
    $fit = [ZedColors.AdjustableOverlay]::ClampBounds((New-Object Drawing.Rectangle(-200, 900, 1200, 20)), $area, $minimum)
    Assert ($fit -eq (New-Object Drawing.Rectangle(100, 612, 900, 68))) 'Panel bounds must remain reachable and respect minimum sizes within a smaller window.'
    $start = New-Object Drawing.Rectangle(300, 200, 400, 120)
    $resized = [ZedColors.AdjustableOverlay]::GestureBounds($start, (New-Object Drawing.Point(350, 200)), 5, $area, $minimum)
    Assert ($resized.Right -eq $start.Right -and $resized.Bottom -eq $start.Bottom -and $resized.Size -eq $minimum) 'Top-left resizing must preserve the opposite corner at the minimum size.'
    $moved = [ZedColors.AdjustableOverlay]::GestureBounds($start, (New-Object Drawing.Point(1000, -1000)), 16, $area, $minimum)
    Assert ($moved -eq (New-Object Drawing.Rectangle(600, 80, 400, 120))) 'Dragging must clamp the entire panel, including its handle, inside the window.'
    $ciCard = New-Object ZedColors.CiCard
    $ciCard.Host = $hostApp; $forms += $ciCard
    Set-Field $hostApp 'ciCard' $ciCard
    $ciInfo = New-Object ZedColors.CiInfo
    $ciInfo.Repo = 'example/sample'; $ciInfo.Workflow = 'Build'; $ciInfo.Status = 'in_progress'
    $ciInfo.Title = 'A sample workflow title that wraps when the card is enlarged'
    $ciInfo.StepsDone = 2; $ciInfo.StepsTotal = 4
    $ciWatcher = New-Object ZedColors.CiWatcher($hostApp)
    $ciWatcher.Latest = $ciInfo
    Set-Field $hostApp 'ci' $ciWatcher
    $oldClient = Get-Field $hostApp 'lastClient'
    $oldBounds = $form.Bounds
    $oldPrompt = Get-Field $hostApp 'promptText'
    $client = New-Object Drawing.Rectangle(80, 80, 1000, 600)
    Set-Field $hostApp 'lastClient' $client
    Set-Field $hostApp 'promptText' 'A synthetic prompt for panel layout tests'
    $bar.Expanded = $false
    $form.Bounds = New-Object Drawing.Rectangle(80, 80, 180, 600)
    $form.Show()
    $hostApp.LayoutBar()
    Assert ($bar.Visible -and $ciCard.Visible) 'Default panel layouts must retain their existing visibility conditions.'
    Assert ($ciCard.Right -eq $bar.Right -and $ciCard.Top -eq $bar.Bottom + 6) 'The unadjusted GitHub card must still follow the prompt bar.'
    function Panel-Gesture($panel, [Drawing.Point]$point, [Drawing.Point]$delta) {
        $screen = $panel.PointToScreen($point)
        $null = Invoke-Private $panel 'OnMouseDown' (, (New-Object Windows.Forms.MouseEventArgs([Windows.Forms.MouseButtons]::Left, 1, $point.X, $point.Y, 0)))
        Assert $panel.Adjusting 'A handle or resize edge must begin a real mouse gesture.'
        $screen.Offset($delta)
        $local = $panel.PointToClient($screen)
        $null = Invoke-Private $panel 'OnMouseMove' (, (New-Object Windows.Forms.MouseEventArgs([Windows.Forms.MouseButtons]::Left, 0, $local.X, $local.Y, 0)))
        $during = $panel.Bounds
        $hostApp.LayoutBar()
        Assert ($panel.Bounds -eq $during) 'An asynchronous refresh must not overwrite a panel during a gesture.'
        $local = $panel.PointToClient($screen)
        $null = Invoke-Private $panel 'OnMouseUp' (, (New-Object Windows.Forms.MouseEventArgs([Windows.Forms.MouseButtons]::Left, 1, $local.X, $local.Y, 0)))
        Assert (-not $panel.Adjusting) 'Mouse release must finish the adjustment.'
    }
    $dashboard = New-Object ZedColors.DashboardPanel
    $dashboard.Host = $hostApp; $forms += $dashboard
    Set-Field $hostApp 'dashboard' $dashboard
    $currentUsage = New-Object ZedColors.ThreadUsage
    $currentUsage.HasTurn = $true; $currentUsage.TurnStart = [DateTime]::Now.AddMinutes(-1)
    $indexer.Usage.BySession[$session] = $currentUsage
    $currentUsage.Working = $true; $currentUsage.LastWrite = [DateTime]::Now
    $currentUsage.Step = 'Editing the sample'; $currentUsage.ActiveHelpers = 2
    $currentUsage.HelperDescriptions = @('review-demo: Review changes')
    $otherDoc = New-Object ZedColors.ThreadDoc
    $otherDoc.Info = New-Object ZedColors.ThreadInfo
    $otherDoc.Info.Session = 'other-dashboard'; $otherDoc.Info.Display = 'Another thread'; $otherDoc.Project = 'Another project'
    $otherUsage = New-Object ZedColors.ThreadUsage
    $otherUsage.AskText = 'Can you approve this change?'; $otherUsage.AskTime = [DateTime]::Now
    $indexer.Index.Docs.Add($otherDoc); $indexer.Usage.BySession[$otherDoc.Info.Session] = $otherUsage
    $null = Invoke-Private $hostApp 'UpdateDashboard'
    Assert ($dashboard.Visible -and $dashboard.Data.Step -eq 'Editing the sample') 'The dashboard must show snapshot-based current activity.'
    Assert ($dashboard.Data.ActiveHelpers -eq 2 -and $dashboard.Data.HelperDescriptions.Length -eq 1) 'The dashboard must preserve exact counts with only recorded helper descriptions.'
    Assert ($dashboard.Data.Attention.Length -eq 1 -and $dashboard.Data.Attention[0].Session -eq 'other-dashboard') 'Other threads with recorded open questions must appear in the dashboard.'
    $otherDoc.Archived = $true
    $null = Invoke-Private $hostApp 'UpdateDashboard'
    Assert ($dashboard.Data.Attention.Length -eq 0) 'Archived threads must not appear as needing attention.'
    $otherDoc.Archived = $false; $otherUsage.AskText = $null
    $currentUsage.LastWrite = [DateTime]::Now.AddMinutes(-31)
    $null = Invoke-Private $hostApp 'UpdateDashboard'
    Assert ($dashboard.Data.ActiveHelpers -eq 0 -and $dashboard.Data.Step.Length -eq 0) 'Stale activity must not claim live helpers or current work.'
    $currentUsage.LastWrite = [DateTime]::Now
    $null = Invoke-Private $hostApp 'UpdateDashboard'
    $dashboard.Bounds = New-Object Drawing.Rectangle(300, 250, 330, 200)
    $hostApp.RememberOverlayBounds($dashboard, $false)
    Panel-Gesture $dashboard (New-Object Drawing.Point(14, 16)) (New-Object Drawing.Point(30, 10))
    Panel-Gesture $dashboard (New-Object Drawing.Point(($dashboard.Width - 2), ($dashboard.Height - 2))) (New-Object Drawing.Point(40, 50))
    $dashboardBounds = $dashboard.Bounds
    $image = New-Object Drawing.Bitmap($dashboard.Width, $dashboard.Height)
    try { $dashboard.DrawToBitmap($image, (New-Object Drawing.Rectangle(0, 0, $image.Width, $image.Height))) }
    finally { $image.Dispose() }
    Assert ((Get-Field $dashboard 'contentHeight') -gt 0) 'Dashboard sections must render actual content.'
    $scrollData = New-Object ZedColors.DashboardData
    $scrollData.Session = $session; $scrollData.Status = 'Working'; $scrollData.ActiveHelpers = 12
    $scrollData.HelperDescriptions = @(1..12 | ForEach-Object { "Recorded helper $_ reviewing a separate task" })
    $dashboard.SetData($scrollData, 1)
    $image = New-Object Drawing.Bitmap($dashboard.Width, $dashboard.Height)
    try { $dashboard.DrawToBitmap($image, (New-Object Drawing.Rectangle(0, 0, $image.Width, $image.Height))) }
    finally { $image.Dispose() }
    Assert ((Get-Field $dashboard 'contentHeight') -gt $dashboard.Height) 'Long helper lists must remain accessible rather than disappearing below the panel.'
    $mouse = New-Object Windows.Forms.MouseEventArgs([Windows.Forms.MouseButtons]::None, 0, 100, 100, -120)
    $null = Invoke-Private $dashboard 'OnMouseWheel' (, $mouse)
    Assert ((Get-Field $dashboard 'scroll') -gt 0) 'The dashboard must scroll when content exceeds the chosen height.'
    $null = Invoke-Private $hostApp 'UpdateDashboard'
    $hostApp.LayoutBar()
    Assert ($dashboard.Bounds -eq $dashboardBounds) 'Refreshes must preserve independent dashboard placement and size.'
    $null = Invoke-Private $hostApp 'ToggleDashboard'
    Assert (-not $dashboard.Visible) 'The dashboard must have an independent hide control.'
    $null = Invoke-Private $hostApp 'ToggleDashboard'
    Assert $dashboard.Visible 'The dashboard must be restorable without changing other panels.'
    $before = $bar.Bounds
    Panel-Gesture $bar (New-Object Drawing.Point(14, 16)) (New-Object Drawing.Point(0, 90))
    Assert ($bar.Top -eq $before.Top + 90 -and -not $bar.Expanded) 'Dragging the prompt handle must move without expanding or activating its click action.'
    Panel-Gesture $bar (New-Object Drawing.Point(($bar.Width - 2), ($bar.Height - 2))) (New-Object Drawing.Point(-200, 90))
    Assert ($bar.Width -eq $before.Width - 200 -and $bar.Height -eq 128 -and $bar.Expanded) 'Prompt resizing must change width and height and expose wrapped text.'
    Panel-Gesture $ciCard (New-Object Drawing.Point(14, 16)) (New-Object Drawing.Point(-100, 60))
    Panel-Gesture $ciCard (New-Object Drawing.Point(($ciCard.Width - 2), ($ciCard.Height - 2))) (New-Object Drawing.Point(70, 80))
    $ciBounds = $ciCard.Bounds
    $ciCard.SetInfo($ciInfo, 1)
    Assert ($ciCard.Bounds -eq $ciBounds) 'GitHub polling must not reset the user-selected card size.'
    $bar.Top += 20
    $hostApp.RememberOverlayBounds($bar, $false)
    Assert ($ciCard.Bounds -eq $ciBounds) 'An adjusted GitHub card must be independent of subsequent prompt-bar movement.'
    $savedPrompt = (Get-Field $hostApp 'overlayLayout').Prompt
    $savedHeight = $savedPrompt.Height
    $hostApp.TogglePromptExpansion()
    Assert ($bar.Height -eq $bar.CollapsedHeight -and $savedPrompt.Height -eq $savedHeight) 'Collapsing must preserve the chosen expanded height.'
    $hostApp.TogglePromptExpansion()
    Assert ($bar.Height -eq $savedHeight) 'Expanding must restore the chosen height.'
    $mouse = New-Object Windows.Forms.MouseEventArgs([Windows.Forms.MouseButtons]::Left, 1, 14, 16, 0)
    $null = Invoke-Private $bar 'OnMouseDown' (, $mouse)
    $mouse = New-Object Windows.Forms.MouseEventArgs([Windows.Forms.MouseButtons]::Left, 0, 14, 26, 0)
    $null = Invoke-Private $bar 'OnMouseMove' (, $mouse)
    $bar.Capture = $false
    Assert (-not $bar.Adjusting) 'Losing mouse capture must finish and save an adjustment.'
    $mouse = New-Object Windows.Forms.MouseEventArgs([Windows.Forms.MouseButtons]::Left, 1, 14, 16, 0)
    $null = Invoke-Private $bar 'OnMouseUp' (, $mouse)
    Assert $bar.Expanded 'A release after capture loss must not activate the prompt body click.'
    $promptBounds = $bar.Bounds
    $ciBounds = $ciCard.Bounds
    Set-Field $hostApp 'lastClient' (New-Object Drawing.Rectangle(80, 80, 600, 300))
    $hostApp.LayoutBar()
    Assert ($hostApp.OverlayArea.Contains($bar.Bounds) -and $hostApp.OverlayArea.Contains($ciCard.Bounds)) 'Both panels must remain reachable when Zed becomes smaller.'
    Assert ($savedPrompt.Width -eq $promptBounds.Width -and $savedPrompt.Height -eq $promptBounds.Height) 'Temporary clamping must not overwrite remembered sizes.'
    Set-Field $hostApp 'lastClient' $client
    $hostApp.LayoutBar()
    Assert ($bar.Bounds -eq $promptBounds -and $ciCard.Bounds -eq $ciBounds) 'The chosen layouts must return when Zed becomes larger again.'
    $shiftedClient = New-Object Drawing.Rectangle(($client.X + 20), ($client.Y + 10), $client.Width, $client.Height)
    $shiftedSidebar = $form.Bounds; $shiftedSidebar.Offset(20, 10)
    Set-Field $hostApp 'lastClient' $shiftedClient
    $form.Bounds = $shiftedSidebar
    $hostApp.LayoutBar()
    $expectedPrompt = New-Object Drawing.Rectangle(($promptBounds.X + 20), ($promptBounds.Y + 10), $promptBounds.Width, $promptBounds.Height)
    $expectedCi = New-Object Drawing.Rectangle(($ciBounds.X + 20), ($ciBounds.Y + 10), $ciBounds.Width, $ciBounds.Height)
    Assert ($bar.Bounds -eq $expectedPrompt -and $ciCard.Bounds -eq $expectedCi) 'Both independent panels must follow Zed window movement.'
    Set-Field $hostApp 'lastClient' $client
    $form.Bounds = New-Object Drawing.Rectangle(80, 80, 180, 600)
    $hostApp.LayoutBar()
    $null = Invoke-Private $hostApp 'ToggleOverlayLock'
    $lockedBounds = $bar.Bounds
    $null = Invoke-Private $bar 'OnMouseDown' (, (New-Object Windows.Forms.MouseEventArgs([Windows.Forms.MouseButtons]::Left, 1, 14, 16, 0)))
    Assert (-not $bar.Adjusting) 'Locked handles must not start moving.'
    $null = Invoke-Private $bar 'OnMouseUp' (, (New-Object Windows.Forms.MouseEventArgs([Windows.Forms.MouseButtons]::Left, 1, 14, 16, 0)))
    Assert ($bar.Bounds -eq $lockedBounds -and $bar.Expanded) 'A locked handle must not trigger expansion.'
    foreach ($expectedExpanded in @($false, $true)) {
        $mouse = New-Object Windows.Forms.MouseEventArgs([Windows.Forms.MouseButtons]::Left, 1, 30, 16, 0)
        $null = Invoke-Private $bar 'OnMouseDown' (, $mouse)
        $null = Invoke-Private $bar 'OnMouseUp' (, $mouse)
        Assert ($bar.Expanded -eq $expectedExpanded -and $hostApp.OverlayLocked) 'Locking the layout must preserve ordinary prompt expand/collapse clicks.'
    }
    Set-Field $hostApp 'overlayLayout' (New-Object ZedColors.OverlayLayout)
    $layoutFile = Join-Path $temp 'layout.json'
    $legacyLayout = [IO.File]::ReadAllText($layoutFile) -replace '^\{', '{"PromptExpanded":false,'
    [IO.File]::WriteAllText($layoutFile, $legacyLayout)
    $null = Invoke-Private $hostApp 'LoadOverlayLayout'
    $saved = Get-Field $hostApp 'overlayLayout'
    Assert ($saved.Locked -and $saved.Prompt.Width -eq $bar.Width -and $saved.GitHub.Height -eq $ciCard.Height) 'Positions, sizes, and locking must survive loading, including older layouts with a collapsed-state preference.'
    Assert ($saved.DashboardEnabled -and $saved.Dashboard.Width -eq $dashboardBounds.Width -and $saved.Dashboard.Height -eq $dashboardBounds.Height) 'Dashboard placement, size, and visibility must survive layout reload.'
    Assert (-not [IO.File]::Exists((Join-Path $temp 'layout.json.tmp'))) 'Atomic layout saving must leave no temporary file.'
    Set-Field $hostApp 'scale' ([single]1.5)
    $scaled = Invoke-Private $hostApp 'PlacementBounds' (, $saved.Prompt)
    Assert ($scaled.X -eq $client.X + [Math]::Round($saved.Prompt.X * 1.5) -and $scaled.Width -eq [Math]::Round($saved.Prompt.Width * 1.5)) 'Remembered layouts must scale their Zed-relative position and size with DPI.'
    Set-Field $hostApp 'scale' ([single]1)
    foreach ($panel in @($bar, $ciCard, $dashboard)) {
        $cp = $panel.GetType().GetProperty('CreateParams', [Reflection.BindingFlags]'Instance, NonPublic').GetValue($panel)
        Assert (($cp.ExStyle -band 0x08000000) -ne 0) 'Adjustable panels must not activate over Zed while interacting.'
        $image = New-Object Drawing.Bitmap($panel.Width, $panel.Height)
        try { $panel.DrawToBitmap($image, (New-Object Drawing.Rectangle(0, 0, $image.Width, $image.Height))) }
        finally { $image.Dispose() }
        $null = Invoke-Private $panel 'OnMouseDown' (, (New-Object Windows.Forms.MouseEventArgs([Windows.Forms.MouseButtons]::Left, 1, ($panel.Width - 2), ($panel.Height - 2), 0)))
        Assert (-not $panel.Adjusting) 'Locked resize corners must remain inactive.'
        $null = Invoke-Private $panel 'OnMouseUp' (, (New-Object Windows.Forms.MouseEventArgs([Windows.Forms.MouseButtons]::Left, 1, ($panel.Width - 2), ($panel.Height - 2), 0)))
    }
    $bar.Size = New-Object Drawing.Size(360, 38)
    $bar.Expanded = $false; $bar.Chip = 'Premium: 100 | Today: 10000 prompts'
    $bar.Status = 'Waiting for 6 helper agents'; $bar.NavLabel = '10000 of 10001'
    $image = New-Object Drawing.Bitmap(360, 38)
    try { $bar.DrawToBitmap($image, (New-Object Drawing.Rectangle(0, 0, 360, 38))) }
    finally { $image.Dispose() }
    $buttons = Get-Field $bar 'btnRects'
    for ($i = 0; $i -lt 3; $i++) {
        Assert ($bar.ClientRectangle.Contains($buttons[$i]) -and $buttons[$i].Left -ge 28) 'Narrow prompt layouts must keep navigation controls clear of the drag handle.'
        $center = New-Object Drawing.Point(($buttons[$i].Left + 10), ($buttons[$i].Top + 10))
        Assert ((Invoke-Private $bar 'ButtonAt' (, $center)) -eq $i) 'Resizing must preserve navigation button hit targets.'
    }
    $rowPixels = New-Object 'int[]' 600
    for ($x = 0; $x -lt 600; $x++) { $rowPixels[$x] = if ($x -lt 300) { 0x111111 } else { 0x555555 } }
    $cleanPixels = New-Object 'int[]' 360000
    for ($y = 0; $y -lt 600; $y++) { [Array]::Copy($rowPixels, 0, $cleanPixels, ($y * 600), 600) }
    $coveredPixels = $cleanPixels.Clone()
    for ($x = 180; $x -lt 500; $x++) { $rowPixels[$x] = 0xaaaaaa }
    for ($y = 0; $y -lt 550; $y++) { [Array]::Copy($rowPixels, 0, $coveredPixels, ($y * 600), 600) }
    $bar.Bounds = New-Object Drawing.Rectangle(260, 80, 320, 550)
    $edge = Invoke-Private $hostApp 'FindEdge' @($coveredPixels, 600, 600)
    Assert ($edge -eq -1) 'A tall moved panel covering a resized sidebar must not become a false sidebar edge.'
    $bar.Hide(); $ciCard.Hide(); $dashboard.Hide()
    $edge = Invoke-Private $hostApp 'FindEdge' @($cleanPixels, 600, 600)
    Assert ($edge -eq 300) 'Sidebar detection must recover on an unobstructed capture.'
    $hostApp.ResetOverlayLayout()
    Assert ($null -eq $saved.Prompt -and $null -eq $saved.GitHub -and $null -eq $saved.Dashboard -and $bar.Expanded -and $saved.Locked) 'Reset must restore all default placements with Last Prompt expanded, while preserving the lock preference.'
    Assert ([IO.File]::ReadAllText($layoutFile) -notmatch 'PromptExpanded') 'A temporary collapse must not be persisted as the startup default.'
    [IO.File]::WriteAllText((Join-Path $temp 'layout.json'), '{"Prompt":{"X":0,"Y":0,"Width":-10,"Height":20}}')
    $null = Invoke-Private $hostApp 'LoadOverlayLayout'
    Assert ($null -ne (Get-Field $hostApp 'layoutProblem')) 'Invalid saved geometry must be reported explicitly.'
    Assert ($null -eq (Get-Field $hostApp 'overlayLayout').Prompt) 'Invalid geometry must not replace the default layout.'
    $form.Hide(); $bar.Hide(); $ciCard.Hide(); $dashboard.Hide()
    Set-Field $hostApp 'dashboard' $null
    (Get-Field $ciWatcher 'wake').Dispose()
    Set-Field $hostApp 'ci' $null
    Set-Field $hostApp 'lastClient' $oldClient
    Set-Field $hostApp 'promptText' $oldPrompt
    $form.Bounds = $oldBounds

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
    'Passed: compilation, dashboard activity/helpers/attention and scrolling, real-prompt filtering, panel drag/resize, independent placement, saved layouts, DPI, locking/reset, helper counts and rendering, working/waiting status, new-session ring, completion colors, Claude background lifecycles, cached prompts, history errors, JSON fallback, startup opt-in, responsive OCR, and preview SVG.'
} finally {
    if ($null -ne $timer) { $timer.Stop(); $timer.Dispose() }
    if ($null -ne $worker) { $worker.Stop(); $worker.Dispose() }
    if ($null -ne $runspace) { $runspace.Dispose() }
    foreach ($f in $forms) { $f.Dispose() }
    $env:COPILOT_HOME = $oldHome
    [IO.Directory]::Delete($temp, $true)
}
