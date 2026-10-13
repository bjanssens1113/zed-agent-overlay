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
    $forms = @($form, $rings)
    Set-Field $hostApp 'form' $form
    Set-Field $hostApp 'rings' $rings
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
    $hostApp.OnIndex()
    Assert ((Get-Field $hostApp 'active').Session -eq $session) 'A late database snapshot must re-match the selected new thread without needing another OCR change.'
    $null = Invoke-Private $hostApp 'SetActive' (, $info)
    Assert ($hostApp.ActiveSession -eq $session) 'Refreshing the selected thread must preserve its active session.'
    $otherInfo = New-Object ZedColors.ThreadInfo
    $otherInfo.Session = [Guid]::NewGuid().ToString(); $otherInfo.Agent = $info.Agent
    $null = Invoke-Private $hostApp 'SetActive' (, $otherInfo)
    Assert ($hostApp.ActiveSession -eq $otherInfo.Session) 'Switching threads must still update the active session without floating panels.'
    $null = Invoke-Private $hostApp 'SetActive' (, $info)
    $null = Invoke-Private $hostApp 'LoadThreads'
    $null = Invoke-Private $hostApp 'UpdateDots'
    Assert ($rings.Dots[$row.Key] -eq 1) 'The newly discovered session must receive a blue working ring.'
    $form.Host = $hostApp
    Set-Field $hostApp 'colors' (New-Object 'System.Collections.Generic.Dictionary[string,int]')
    Set-Field $hostApp 'dataPath' (Join-Path $temp 'colors.tsv')
    $hostApp.SetColor($row.Key, 4)
    Assert ($hostApp.ColorIndex($row.Key) -eq 4 -and $rings.Dots[$row.Key] -eq 1) 'Changing a saved thread color must not change its working status.'
    $hostApp.SetColor('differentworkspace|examplethread', 7)
    $hostApp.SetColor($row.Key, 2)
    Assert ($hostApp.ColorIndex($row.Key) -eq 2 -and $hostApp.ColorIndex('differentworkspace|examplethread') -eq 7) 'Changing one thread color must leave the same title in another workspace unchanged.'
    Set-Field $hostApp 'colors' (New-Object 'System.Collections.Generic.Dictionary[string,int]')
    $null = Invoke-Private $hostApp 'Load'
    Assert ($hostApp.ColorIndex($row.Key) -eq 2 -and $hostApp.ColorIndex('differentworkspace|examplethread') -eq 7) 'Saved color changes must survive reloading.'
    $hostApp.SetColor($row.Key, 0)
    Assert ($hostApp.ColorIndex($row.Key) -eq 0 -and $hostApp.ColorIndex('differentworkspace|examplethread') -eq 7) 'Clearing one color must not clear another workspace.'
    $hostApp.SetColor('sample|buildapi1', 4)
    $hostApp.SetColor('sample|buildapi2', 7)
    Assert ($hostApp.ColorIndex('sample|buildapi1') -eq 4 -and $hostApp.ColorIndex('sample|buildapi2') -eq 7) 'Similar session titles in the same project must have independent editable colors.'
    $hostApp.SetColor('sample|buildapi2', 0)
    Assert ($hostApp.ColorIndex('sample|buildapi1') -eq 4 -and $hostApp.ColorIndex('sample|buildapi2') -eq 0) 'Clearing a neighboring session color must not clear or inherit another session color.'
    $hostApp.SetColor('samples|buildapi1', 7)
    Assert ($hostApp.ColorIndex('sample|buildapi1') -eq 4 -and $hostApp.ColorIndex('samples|buildapi1') -eq 7) 'Nearly identical project names must not share color assignments.'
    Set-Field $hostApp 'colors' (New-Object 'System.Collections.Generic.Dictionary[string,int]')
    $null = Invoke-Private $hostApp 'Load'
    Assert ($hostApp.ColorIndex('sample|buildapi1') -eq 4 -and $hostApp.ColorIndex('samples|buildapi1') -eq 7) 'Independent colors must remain independent after a restart.'

    $parserApp = [Runtime.Serialization.FormatterServices]::GetUninitializedObject([ZedColors.App])
    Set-Field $parserApp 'words' (New-Object 'System.Collections.Generic.List[ZedColors.Word]')
    Set-Field $parserApp 'scale' ([single]1)
    Set-Field $parserApp 'sidebar' (New-Object Drawing.Rectangle(0, 0, 280, 360))
    $parserThreads = New-Object 'System.Collections.Generic.List[ZedColors.ThreadInfo]'
    foreach ($name in @('Build API 1', 'Build API 2', 'GitHub Help')) {
        $t = New-Object ZedColors.ThreadInfo
        $t.Session = [Guid]::NewGuid().ToString(); $t.Display = $name
        $t.Folders = Join-Path $temp 'same-project'; $t.Agent = 'github-copilot-cli'
        $parserThreads.Add($t)
    }
    Set-Field $parserApp 'threads' $parserThreads
    function Add-SidebarLine([int]$line, [string]$value, [double]$x, [double]$y) {
        $parserApp.AddWord($line, $value, $x * 2, $y * 2, 150 * 2, 14 * 2)
    }
    function Sample-Sidebar([bool]$middleTimestamp) {
        $parserApp.BeginOcr()
        Add-SidebarLine 0 'same-project' 16 70
        Add-SidebarLine 1 'Build API 1' 40 100
        Add-SidebarLine 2 '1m' 40 124
        Add-SidebarLine 3 'Build API 2' 40 160
        if ($middleTimestamp) { Add-SidebarLine 4 '2m' 40 184 }
        Add-SidebarLine 5 'GitHub Help' 40 220
        Add-SidebarLine 6 '3m' 40 244
        return @(Invoke-Private $parserApp 'ReadRows')
    }
    $completeRows = Sample-Sidebar $true
    $missingRows = Sample-Sidebar $false
    Assert ($completeRows.Count -eq 3 -and $missingRows.Count -eq 3) 'Multiple agents in one project must each retain one sidebar row.'
    Assert ($missingRows[1].RowTop -eq $completeRows[1].RowTop -and $missingRows[1].RowBottom -eq $completeRows[1].RowBottom) 'Missing timestamp OCR must not shrink the session ring or its clickable color bar.'
    Assert ($missingRows[1].RowBottom -lt $missingRows[2].RowTop) 'Recovered full-height session boxes must not overlap their neighboring agent.'
    $parserApp.BeginOcr()
    Add-SidebarLine 0 'same-project' 16 70
    Add-SidebarLine 1 'Build API 1' 40 100
    Add-SidebarLine 3 'Build API 2' 40 160
    Add-SidebarLine 5 'GitHub Help' 40 220
    $allMissingRows = @(Invoke-Private $parserApp 'ReadRows')
    Assert ($allMissingRows[1].RowBottom -eq $completeRows[1].RowBottom) 'Previously measured timestamp spacing must survive a capture where every timestamp is missed.'
    $parserApp.BeginOcr()
    Add-SidebarLine 0 'same-project' 16 70
    $parserApp.AddWord(1, 'Build', 80, 200, 60, 28)
    $parserApp.AddWord(2, 'API', 150, 202, 40, 26)
    $parserApp.AddWord(3, '1', 200, 200, 14, 28)
    Add-SidebarLine 4 '1m' 40 124
    Add-SidebarLine 5 'Build API 2' 40 160
    Add-SidebarLine 6 '2m' 40 184
    $splitRows = @(Invoke-Private $parserApp 'ReadRows')
    Assert ($splitRows.Count -eq 2 -and $splitRows[0].Title -eq 'Build API 1') 'OCR fragments on the same visual title line must form one session rather than multiple boxes.'
    Assert ($splitRows[0].RowTop -eq $completeRows[0].RowTop -and $splitRows[0].RowBottom -eq $completeRows[0].RowBottom) 'Splitting a title across OCR line IDs must not collapse the ring through the text.'
    $parserApp.BeginOcr()
    Add-SidebarLine 0 'same-project' 16 70
    Add-SidebarLine 1 'Build API 1' 40 100
    Add-SidebarLine 1 '1m' 40 124
    Add-SidebarLine 2 'Build API 2' 40 160
    Add-SidebarLine 2 '2m' 40 184
    $mergedRows = @(Invoke-Private $parserApp 'ReadRows')
    Assert ($mergedRows.Count -eq 2 -and $mergedRows[0].Key -eq $completeRows[0].Key) 'Title and timestamp sharing an OCR line ID must remain distinct visual lines and preserve the color key.'
    Assert ($mergedRows[0].RowBottom -eq $completeRows[0].RowBottom) 'Merged OCR line IDs must not distort session height.'
    $parserApp.BeginOcr()
    Add-SidebarLine 0 'same-project' 16 70
    Add-SidebarLine 1 'Build API 1' 40 100
    $parserApp.AddWord(2, 'O', 32, 224, 12, 12)
    Add-SidebarLine 3 '1m' 40 124
    Add-SidebarLine 4 'Build API 2' 40 160
    Add-SidebarLine 5 '2m' 40 184
    $iconRows = @(Invoke-Private $parserApp 'ReadRows')
    Assert ($iconRows.Count -eq 2 -and $iconRows[0].RowBottom -eq $completeRows[0].RowBottom) 'An isolated animated icon between title and timestamp must not become a row boundary or shrink the ring.'
    $geometryRings = New-Object ZedColors.RingForm
    $geometryBars = New-Object ZedColors.BoxForm
    $forms += $geometryRings; $forms += $geometryBars
    foreach ($dpi in @([single]1, [single]1.5, [single]2)) {
        Set-Field $parserApp 'scale' $dpi
        Set-Field $parserApp 'sidebar' (New-Object Drawing.Rectangle(0, 0, ([int](280 * $dpi)), ([int](360 * $dpi))))
        $parserApp.BeginOcr()
        $parserApp.AddWord(0, 'same-project', 32 * $dpi, 140 * $dpi, 220 * $dpi, 28 * $dpi)
        $parserApp.AddWord(1, 'Build', 80 * $dpi, 200 * $dpi, 60 * $dpi, 28 * $dpi)
        $parserApp.AddWord(2, 'API', 150 * $dpi, 200 * $dpi, 40 * $dpi, 28 * $dpi)
        $parserApp.AddWord(3, '1', 200 * $dpi, 200 * $dpi, 14 * $dpi, 28 * $dpi)
        $parserApp.AddWord(1, '1m', 80 * $dpi, 248 * $dpi, 30 * $dpi, 28 * $dpi)
        $spatialRows = @(Invoke-Private $parserApp 'ReadRows')
        Assert ($spatialRows.Count -eq 1) 'Visual line grouping must handle simultaneous split titles and merged timestamps at each DPI.'
        $geometryRings.UiScale = $dpi; $geometryRings.Size = New-Object Drawing.Size(([int](280 * $dpi)), ([int](360 * $dpi)))
        $geometryBars.UiScale = $dpi; $geometryBars.Size = New-Object Drawing.Size(([int](22 * $dpi)), ([int](360 * $dpi)))
        $geometryRings.Rows.Clear(); $geometryRings.Rows.Add($spatialRows[0])
        $ringBounds = $geometryRings.RingRect($spatialRows[0])
        $barBounds = $geometryBars.BarRect($spatialRows[0])
        Assert ($ringBounds.Top -lt 100 * $dpi -and $ringBounds.Bottom -gt 138 * $dpi) 'The ring must enclose both title and timestamp instead of crossing the title.'
        Assert ($barBounds.Height -gt 35 * $dpi) 'The clickable color bar must retain its full height alongside a fragmented session.'
        $bitmap = New-Object Drawing.Bitmap($geometryRings.Width, $geometryRings.Height)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            foreach ($status in @(1, 3, 1, 3)) {
                $geometryRings.Dots[$spatialRows[0].Key] = $status
                $graphics.Clear([Drawing.Color]::Transparent)
                $null = Invoke-Private $geometryRings 'Draw' (, $graphics)
                Assert ($geometryRings.RingRect($spatialRows[0]) -eq $ringBounds) 'Switching between working and waiting-for-input must never alter ring geometry.'
            }
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
    }
    Set-Field $parserApp 'scale' ([single]1)
    Set-Field $parserApp 'sidebar' (New-Object Drawing.Rectangle(0, 0, 280, 360))
    $parserApp.BeginOcr()
    Add-SidebarLine 0 'same-projectv' 16 70
    Add-SidebarLine 1 'BuiId API 1' 40 100
    Add-SidebarLine 2 '1m' 40 124
    $correctedRows = @(Invoke-Private $parserApp 'ReadRows')
    Assert ($correctedRows[0].Key -eq 'sameproject|buildapi1') 'Unique database matches must canonicalize project and title OCR errors before color lookup.'
    $parserColors = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    $parserColors.Add('sameprojectv|buildapi1', 4)
    Set-Field $parserApp 'colors' $parserColors
    $correctedRows = @(Invoke-Private $parserApp 'ReadRows')
    Assert ($correctedRows[0].Key -eq 'sameprojectv|buildapi1' -and $parserApp.ColorIndex($correctedRows[0].Key) -eq 4) 'An existing project OCR spelling must retain its saved color when it uniquely identifies the same session.'
    $parserColors.Add('sameproject|buildapi1', 7)
    $correctedRows = @(Invoke-Private $parserApp 'ReadRows')
    Assert ($correctedRows[0].Key -eq 'sameproject|buildapi1' -and $parserApp.ColorIndex($correctedRows[0].Key) -eq 7) 'An explicit canonical color must take precedence over an older project-spelling key.'
    Assert ($null -eq (Invoke-Private $parserApp 'MatchThread' @('other-project', 'Build API 1'))) 'A title in another project must not borrow an agent status from this project.'
    $duplicate = New-Object ZedColors.ThreadInfo
    $duplicate.Session = [Guid]::NewGuid().ToString()
    $duplicate.Display = $parserThreads[0].Display; $duplicate.Folders = $parserThreads[0].Folders
    $parserThreads.Add($duplicate)
    Assert ($null -eq (Invoke-Private $parserApp 'MatchThread' @('same-project', 'Build API 1'))) 'Ambiguous same-title sessions must not all inherit the newest agent status.'
    Set-Field $hostApp 'active' $info
    [IO.File]::Delete($file)
    $hoverLines = Invoke-Private $hostApp 'CardLines' (, $row)
    Assert (@($hoverLines | Where-Object {$_.Text -eq 'Make the sample clearer'}).Count -eq 1) 'The hover card must use the cached last prompt, not read the file.'

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
        $rings.ActiveHelpers[$row.Key] = 1
        $rings.Show()
        $helper = $rings.HelperRects($row)[0]
        $clearPoint = New-Object Drawing.Point([int]($rings.RingRect($row).Right - 10 + $rings.Left), [int][Math]::Ceiling($helper.Bottom + $rings.Top))
        Assert (@($rings.Bands() | Where-Object {$_[0].Contains($clearPoint)}).Count -eq 0) 'Masking a helper dash must not erase an entire horizontal strip beneath the session tag.'
    } finally { $rings.Hide(); $graphics.Dispose(); $drawing.Dispose() }

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
    Copilot-Event @{ type = 'user.message'; timestamp = $now; data = @{ content = 'Complete this task' } }
    Copilot-Event @{ type = 'assistant.message'; timestamp = $now; data = @{
        toolRequests = @(@{ toolCallId = 'finish-task'; name = 'task_complete'; arguments = @{ summary = 'Finished' } })
    } }
    Copilot-Event @{ type = 'tool.execution_start'; timestamp = $now; data = @{ toolName = 'task_complete'; toolCallId = 'finish-task' } }
    Copilot-Event @{ type = 'tool.execution_complete'; timestamp = $now; data = @{ toolCallId = 'finish-task'; success = $true } }
    Assert $copilot.Working 'A completed tool alone must not prematurely finish the agent turn.'
    Copilot-Event @{ type = 'session.task_complete'; timestamp = $now; data = @{ success = $true; parentToolCallId = 'nested-helper' } }
    Assert $copilot.Working 'A helper session completion must not finish the parent agent.'
    Copilot-Event @{ type = 'session.task_complete'; timestamp = $now; data = @{ success = $false } }
    Assert $copilot.Working 'A rejected task-completion event must not finish the agent.'
    Copilot-Event @{ type = 'session.task_complete'; timestamp = $now; data = @{ success = $true } }
    Assert (-not $copilot.Working -and $copilot.TurnEnd -ne [DateTime]::MinValue) 'Successful Copilot session.task_complete must finish even when its final assistant message requested the completion tool.'
    $end = $copilot.TurnEnd
    Copilot-Event @{ type = 'assistant.turn_end'; timestamp = [DateTime]::UtcNow.AddSeconds(1).ToString('o'); data = @{} }
    Assert (-not $copilot.Working -and $copilot.TurnEnd -eq $end) 'The following turn-end event must not restart or re-date a completed task.'
    Copilot-Event @{ type = 'assistant.turn_start'; timestamp = $now; data = @{ parentToolCallId = 'finished-helper' } }
    Copilot-Event @{ type = 'tool.execution_start'; timestamp = $now; data = @{
        toolName = 'powershell'; toolCallId = 'late-helper-tool'; parentToolCallId = 'finished-helper'
    } }
    Assert (-not $copilot.Working) 'Late nested helper events must not turn a completed parent blue again.'
    $completionDoc = New-Object ZedColors.ThreadDoc
    $completionDoc.Info = $info; $completionDoc.File = $copilot.Path
    (Get-Field $indexer 'scans')[$copilot.Path] = $copilot
    $completionDocs = New-Object 'System.Collections.Generic.List[ZedColors.ThreadDoc]'
    $completionDocs.Add($completionDoc)
    $null = Invoke-Private $indexer 'PublishUsage' (, $completionDocs)
    $indexer.Usage.BySession[$info.Session].TurnEnd = [DateTime]::Now
    $null = Invoke-Private $hostApp 'UpdateDots'
    Assert ($rings.Dots[$row.Key] -eq 2) 'The successful completion event must propagate through the published snapshot to a green sidebar ring.'
    Copilot-Event @{ type = 'user.message'; timestamp = $now; data = @{ content = 'Finish after the helper' } }
    Copilot-Event @{ type = 'tool.execution_start'; timestamp = $now; data = @{
        toolName = 'task'; toolCallId = 'pending-finish'; arguments = @{ mode = 'background' }
    } }
    Copilot-Event @{ type = 'session.task_complete'; timestamp = $now; data = @{ success = $true } }
    Assert ($copilot.Working -and $copilot.WaitingForBackground) 'Task completion must retain blue while a real background helper is still running.'
    Copilot-Event @{ type = 'subagent.completed'; timestamp = $now; data = @{ toolCallId = 'pending-finish' } }
    Assert (-not $copilot.Working -and $copilot.Background -eq 0) 'Finishing the last background helper after main-task completion must clear working without requiring another assistant message.'
    Copilot-Event @{ type = 'user.message'; timestamp = $now; data = @{ content = 'A new task' } }
    Assert ($copilot.Working -and -not $copilot.WaitingForBackground) 'A new human prompt must restore normal blue working state.'

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
    $null = Invoke-Private $hostApp 'LoadThreads'
    $hoverLines = Invoke-Private $hostApp 'CardLines' (, $row)
    Assert (@($hoverLines | Where-Object {$_.Text -eq $missingDoc.Problem}).Count -eq 1) 'The hover card must explain why history is unavailable.'

    foreach ($type in @('QuestionLedger', 'PromptBar', 'CiCard', 'AdjustableOverlay', 'OverlayLayout')) {
        Assert ($null -eq [ZedColors.App].Assembly.GetType("ZedColors.$type")) "The removed panel/tracking type $type must not remain in the overlay."
    }
    Assert (-not $source.Contains('Show last-prompt bar') -and -not $source.Contains('Lock overlay layout')) 'The tray must not retain controls for removed floating panels.'
    $ciWatcher = New-Object ZedColors.CiWatcher($hostApp)
    Set-Field $hostApp 'ci' $ciWatcher
    try {
        $hoverLines = Invoke-Private $hostApp 'CardLines' (, $row)
        Assert (@($hoverLines | Where-Object {$_.Text -eq 'Checking GitHub Actions...'}).Count -eq 1) 'GitHub status must explicitly show when it has not been checked yet.'
        $ciInfo = New-Object ZedColors.CiInfo
        $ciInfo.Repo = 'example/sample'; $ciInfo.Workflow = 'Build'; $ciInfo.Status = 'in_progress'
        $ciInfo.Title = 'Verify the sample'; $ciInfo.Branch = 'main'
        $ciInfo.Url = 'https://github.com/example/sample/actions/runs/123'
        $ciInfo.StepsDone = 2; $ciInfo.StepsTotal = 4
        $snapshot = New-Object ZedColors.CiSnapshot
        $snapshot.Run = $ciInfo
        $null = Invoke-Private $ciWatcher 'Publish' @($info.Folders, $snapshot)
        $hostApp.OnCi()
        Assert ($rings.GitHubProgress[$row.Key] -eq 50) 'Running GitHub steps must reach the top-of-session progress bar.'
        $originalDots = $rings.Dots[$row.Key]
        $ciInfo.StepsDone = 3
        $hostApp.OnCi()
        Assert ($rings.GitHubProgress[$row.Key] -eq 75 -and $rings.Dots[$row.Key] -eq $originalDots) 'GitHub progress must update independently of the agent activity ring.'
        $ciInfo.StepsDone = 2
        $hostApp.OnCi()
        foreach ($dpi in @([single]1, [single]1.5, [single]2)) {
            $rings.UiScale = $dpi
            $rings.Width = [int](230 * $dpi); $rings.Height = [int](140 * $dpi)
            $track = $rings.GitHubTrack($row)
            Assert ($track.Top -ge $rings.RingRect($row).Top -and $track.Bottom -le $rings.RingRect($row).Top + 6 * $dpi) 'The GitHub bar must remain at the top of the session tag, clear of its title.'
            foreach ($percent in @(0, 25, 50, 100)) {
                $rings.GitHubProgress[$row.Key] = $percent
                $fill = $rings.GitHubFill($row, 0)
                Assert ([Math]::Abs($fill.Width - $track.Width * $percent / 100) -lt 0.01) 'The rendered progress width must match the actual percentage at every DPI.'
                Assert ($fill.Left -eq $track.Left -and $fill.Right -le $track.Right + 0.01) 'Measured progress must fill left-to-right without overflowing the tag.'
            }
            $rings.GitHubProgress[$row.Key] = -1
            $first = $rings.GitHubFill($row, 0)
            $next = $rings.GitHubFill($row, 0.5)
            Assert ($first.X -ne $next.X -and $next.Right -le $track.Right + 0.01) 'Unmeasured progress must animate within the tag rather than invent a percentage.'
        }
        $rings.UiScale = 1; $rings.Width = 230; $rings.Height = 140
        $rings.Dots.Clear(); $rings.ActiveHelpers.Clear(); $rings.GitHubProgress[$row.Key] = 50
        Assert $rings.AnyRings() 'A GitHub progress bar must remain drawable even when the agent is idle.'
        $ringParams = $rings.GetType().GetProperty('CreateParams', [Reflection.BindingFlags]'Instance, NonPublic').GetValue($rings)
        Assert (($ringParams.ExStyle -band 0x20) -ne 0) 'GitHub progress must not intercept clicks on Zed session tags.'
        $drawing = New-Object Drawing.Bitmap(230, 140)
        $graphics = [Drawing.Graphics]::FromImage($drawing)
        try {
            $graphics.Clear([Drawing.Color]::Transparent)
            $null = Invoke-Private $rings 'Draw' (, $graphics)
            $track = $rings.GitHubTrack($row)
            $filled = $drawing.GetPixel([int]($track.Left + $track.Width / 4), [int]($track.Top + 1))
            $remaining = $drawing.GetPixel([int]($track.Left + $track.Width * 3 / 4), [int]($track.Top + 1))
            Assert ($filled.A -gt 200 -and $filled.B -gt 150 -and $remaining.A -lt 100) 'The actual drawing must show a blue 50% fill and a subdued remainder without an agent ring.'
            $rings.Show()
            $screenTrack = [Drawing.Rectangle]::Ceiling($track)
            $screenTrack.Offset($rings.Left, $rings.Top)
            $bands = $rings.Bands()
            Assert (@($bands | Where-Object {$_[0].Contains($screenTrack)}).Count -gt 0) 'The OCR mask must cover GitHub progress independently of agent rings.'
            $pixels = New-Object 'int[]' (230 * 140)
            for ($i = 0; $i -lt $pixels.Length; $i++) { $pixels[$i] = 0x111111 }
            for ($y = $screenTrack.Top; $y -lt $screenTrack.Bottom; $y++) {
                for ($x = $screenTrack.Left; $x -lt $screenTrack.Right; $x++) { $pixels[($y - $rings.Top) * 230 + $x - $rings.Left] = 0x72cffe }
            }
            $null = Invoke-Private $hostApp 'ScrubRings' @($pixels, 230, 140, $rings.Left, $rings.Top)
            Assert (@($pixels | Where-Object {$_ -ne 0x111111}).Count -eq 0) 'Progress animation must be fully removed from OCR captures so it cannot destabilize colors or session matching.'
        } finally {
            $rings.Hide(); $graphics.Dispose(); $drawing.Dispose()
        }
        $hostApp.OnCi()
        $hoverLines = Invoke-Private $hostApp 'CardLines' (, $row)
        Assert (@($hoverLines | Where-Object {$_.Text -like '*example/sample*Build*'}).Count -eq 1) 'Hover GitHub status must identify the repository and workflow.'
        Assert (@($hoverLines | Where-Object {$_.Text -like '*50% (2 of 4 steps)*main*'}).Count -eq 1) 'Hover GitHub status must show actual progress, step counts, and branch.'
        Assert (@($hoverLines | Where-Object {$_.Text -eq 'Verify the sample' -and $_.Url -eq $ciInfo.Url}).Count -eq 1) 'The run title must link to the originating GitHub run.'
        foreach ($status in @('queued', 'pending', 'waiting')) {
            $ciInfo.Status = $status
            $hostApp.OnCi()
            Assert ($rings.GitHubProgress[$row.Key] -eq -1) 'Queued GitHub runs must use unmeasured animation.'
            Assert ($ciInfo.StatusText -eq 'Queued') 'Queued runs must not look like completed runs or measured progress.'
        }
        $ciInfo.Status = 'in_progress'; $ciInfo.StepsTotal = 0
        $hostApp.OnCi()
        Assert ($rings.GitHubProgress[$row.Key] -eq -1) 'GitHub runs without measured steps must not show a fabricated percentage.'
        Assert ($ciInfo.StatusText -eq 'Running') 'Unmeasured progress must not be presented as a fabricated percentage.'
        $ciInfo.Status = 'completed'
        foreach ($state in @(
            @('success', 'Passed'), @('failure', 'Failed'), @('cancelled', 'Cancelled'),
            @('skipped', 'Skipped'), @('timed_out', 'Timed out'), @('startup_failure', 'Startup failure')
        )) {
            $ciInfo.Conclusion = $state[0]
            $hostApp.OnCi()
            Assert (-not $rings.GitHubProgress.ContainsKey($row.Key)) 'The top progress bar must clear after every completed GitHub outcome.'
            $hoverLines = Invoke-Private $hostApp 'CardLines' (, $row)
            Assert (@($hoverLines | Where-Object {$_.Text -like ($state[1] + '*main*')}).Count -eq 1) "GitHub conclusion $($state[0]) must be visible in the hover card."
            if ($state[0] -eq 'success') {
                Assert ($ciInfo.StatusColor.G -gt $ciInfo.StatusColor.R) 'Passed runs must be green.'
            } elseif ($state[0] -in @('failure', 'timed_out', 'startup_failure')) {
                Assert ($ciInfo.StatusColor.R -gt $ciInfo.StatusColor.G) 'Failed runs must be red.'
            }
        }
        $otherFolder = Join-Path $temp 'other-workspace'
        $null = [IO.Directory]::CreateDirectory($otherFolder)
        $otherInfo.Display = 'Other thread'; $otherInfo.Folders = $otherFolder
        $otherDoc = New-Object ZedColors.ThreadDoc
        $otherDoc.Info = $otherInfo; $otherDoc.Prompt = 'A different project request'
        $indexer.Index.Docs.Add($otherDoc)
        $null = Invoke-Private $hostApp 'LoadThreads'
        $otherRow = New-Object ZedColors.Row
        $otherRow.Key = 'other-workspace|otherthread'
        $otherRow.Title = $otherInfo.Display; $otherRow.Project = 'other-workspace'
        $hoverLines = Invoke-Private $hostApp 'CardLines' (, $otherRow)
        Assert (@($hoverLines | Where-Object {$_.Text -eq 'Checking GitHub Actions...'}).Count -eq 1) 'An unqueried hovered project must not inherit the open thread GitHub result.'
        Assert (@($hoverLines | Where-Object {$_.Text -like '*example/sample*'}).Count -eq 0) 'GitHub status must never leak from another project.'
        $ciWatcher.SetFolders($otherFolder)
        $null = Invoke-Private $ciWatcher 'Poll' (, $otherFolder)
        $hoverLines = Invoke-Private $hostApp 'CardLines' (, $otherRow)
        Assert (@($hoverLines | Where-Object {$_.Text -eq 'No GitHub repository found for this thread.'}).Count -eq 1) 'A thread without a GitHub repo must be distinguished from loading or a failed check.'
        Assert ($ciWatcher.SnapshotFor($info.Folders).Run -eq $ciInfo) 'Switching projects must retain independently scoped cached results.'
        $errorSnapshot = New-Object ZedColors.CiSnapshot
        $errorSnapshot.Message = 'GitHub status unavailable. Open log for details.'
        $null = Invoke-Private $ciWatcher 'Publish' @($otherFolder, $errorSnapshot)
        $hoverLines = Invoke-Private $hostApp 'CardLines' (, $otherRow)
        Assert (@($hoverLines | Where-Object {$_.Text -eq $errorSnapshot.Message}).Count -eq 1) 'Failed GitHub checks must be visible rather than look like no runs.'
        $null = Invoke-Private $ciWatcher 'Publish' @($info.Folders, $snapshot)
        Assert ($ciWatcher.SnapshotFor($otherFolder).Message -eq $errorSnapshot.Message) 'A late result from another project must not overwrite the currently hovered project.'
        $emptySnapshot = New-Object ZedColors.CiSnapshot
        $emptySnapshot.Message = 'No GitHub Actions runs found.'
        $null = Invoke-Private $ciWatcher 'Publish' @($otherFolder, $emptySnapshot)
        $hoverLines = Invoke-Private $hostApp 'CardLines' (, $otherRow)
        Assert (@($hoverLines | Where-Object {$_.Text -eq $emptySnapshot.Message}).Count -eq 1) 'A repository without Actions runs must be distinct from a failed check.'
        $form.Rows.Add($otherRow)
        $ciInfo.Status = 'in_progress'; $ciInfo.StepsTotal = 4
        $hostApp.OnCi()
        Assert ($rings.GitHubProgress[$row.Key] -eq 50 -and -not $rings.GitHubProgress.ContainsKey($otherRow.Key)) 'A running project must not add a progress bar to another project.'
        $otherRun = New-Object ZedColors.CiInfo
        $otherRun.Status = 'in_progress'; $otherRun.StepsDone = 1; $otherRun.StepsTotal = 4
        $otherSnapshot = New-Object ZedColors.CiSnapshot
        $otherSnapshot.Run = $otherRun
        $null = Invoke-Private $ciWatcher 'Publish' @($otherFolder, $otherSnapshot)
        $hostApp.OnCi()
        Assert ($rings.GitHubProgress[$row.Key] -eq 50 -and $rings.GitHubProgress[$otherRow.Key] -eq 25) 'Simultaneous GitHub runs must display their own project progress, even without an agent turn.'
        $nowUtc = [DateTime]::UtcNow
        $snapshot.CheckedUtc = $nowUtc.AddSeconds(-7)
        $otherSnapshot.CheckedUtc = $nowUtc.AddSeconds(-8)
        $due = @(Invoke-Private $ciWatcher 'DueFolders' (, $nowUtc))
        Assert ($due.Count -eq 1 -and $due[0] -eq $otherFolder) 'Each running visible project must be polled independently at the eight-second threshold.'
        $ciInfo.Status = 'completed'; $snapshot.CheckedUtc = $nowUtc.AddSeconds(-44)
        $otherRun.Status = 'completed'; $otherSnapshot.CheckedUtc = $nowUtc
        Assert ((Invoke-Private $ciWatcher 'DueFolders' (, $nowUtc)).Count -eq 0) 'Idle projects must not be polled on every UI refresh.'
        $snapshot.CheckedUtc = $nowUtc.AddSeconds(-45)
        $due = @(Invoke-Private $ciWatcher 'DueFolders' (, $nowUtc))
        Assert ($due.Count -eq 1 -and $due[0] -eq $info.Folders) 'Idle visible projects must still be checked at the 45-second threshold for new runs.'
        $ciWatcher.SetVisibleFolders((New-Object 'System.Collections.Generic.List[string]'))
        Assert ((Invoke-Private $ciWatcher 'DueFolders' (, $nowUtc)).Count -eq 0) 'Projects that leave the sidebar must stop polling unless open or hovered.'
        $hostApp.OnCi()
        Assert ($rings.GitHubProgress.Count -eq 0) 'Completing simultaneous GitHub runs must clear every progress bar.'
        $null = Invoke-Private $ciWatcher 'Publish' @($info.Folders, $errorSnapshot)
        $hostApp.OnCi()
        Assert (-not $rings.GitHubProgress.ContainsKey($row.Key)) 'Unavailable GitHub status must never leave a stale working bar behind.'
        $null = Invoke-Private $ciWatcher 'Publish' @($info.Folders, $snapshot)
        $fakeGh = Join-Path $temp 'fake-gh'
        $fakeRepo = Join-Path $fakeGh 'repository'
        $null = [IO.Directory]::CreateDirectory((Join-Path $fakeRepo '.git'))
        [IO.File]::WriteAllText((Join-Path $fakeRepo '.git\config'), "[remote `"origin`"]`nurl = https://github.com/example/sample.git`n")
        $fakeSource = @'
using System;
using System.IO;
public class FakeGitHub {
    public static int Main(string[] args) {
        string dir = Environment.GetEnvironmentVariable("ZED_TEST_GITHUB");
        File.AppendAllText(Path.Combine(dir, "calls.txt"), string.Join(" ", args) + "\n");
        if (File.Exists(Path.Combine(dir, "fail"))) {
            Console.Error.WriteLine("Synthetic GitHub failure");
            return 1;
        }
        string file = args[1] == "view" ? "jobs.json"
            : Array.IndexOf(args, "--status") >= 0 ? "active.json" : "latest.json";
        Console.Write(File.ReadAllText(Path.Combine(dir, file)));
        return 0;
    }
}
'@
        Add-Type -TypeDefinition $fakeSource -OutputAssembly (Join-Path $fakeGh 'gh.exe') -OutputType ConsoleApplication
        $oldPath = $env:PATH; $oldFakeGitHub = $env:ZED_TEST_GITHUB
        try {
            $env:PATH = $fakeGh + ';' + $oldPath
            $env:ZED_TEST_GITHUB = $fakeGh
            $activeRun = @{
                databaseId = 100; status = 'in_progress'; workflowName = 'Build'; displayTitle = 'An older running build'
                createdAt = [DateTime]::UtcNow.AddMinutes(-2).ToString('o')
                updatedAt = [DateTime]::UtcNow.ToString('o'); headBranch = 'main'
                url = 'https://github.com/example/sample/actions/runs/100'
            }
            $latestRun = @{
                databaseId = 200; status = 'completed'; conclusion = 'success'; workflowName = 'Lint'
                displayTitle = 'A newer completed lint run'; createdAt = [DateTime]::UtcNow.ToString('o')
                url = 'https://github.com/example/sample/actions/runs/200'
            }
            [IO.File]::WriteAllText((Join-Path $fakeGh 'active.json'), (ConvertTo-Json -InputObject @($activeRun) -Compress))
            [IO.File]::WriteAllText((Join-Path $fakeGh 'latest.json'), (ConvertTo-Json -InputObject @($latestRun) -Compress))
            $jobs = @{ jobs = @(@{ steps = @(
                @{ status = 'completed' }, @{ status = 'completed' }, @{ status = 'in_progress' }, @{ status = 'pending' }
            ) }) }
            [IO.File]::WriteAllText((Join-Path $fakeGh 'jobs.json'), ($jobs | ConvertTo-Json -Depth 10 -Compress))
            $null = Invoke-Private $ciWatcher 'Poll' (, $fakeRepo)
            $polled = $ciWatcher.SnapshotFor($fakeRepo)
            Assert ($polled.Run.Url -like '*/100' -and $polled.Run.Percent -eq 50) 'Actual CLI polling must prefer a running workflow and calculate progress from completed GitHub steps.'
            Assert ([IO.File]::ReadAllText((Join-Path $fakeGh 'calls.txt')).Contains('run view 100')) 'Measured progress must come from the selected running workflow jobs.'
            [IO.File]::WriteAllText((Join-Path $fakeGh 'active.json'), '[]')
            $null = Invoke-Private $ciWatcher 'Poll' (, $fakeRepo)
            Assert ($ciWatcher.SnapshotFor($fakeRepo).Run.Conclusion -eq 'success') 'When no workflow is running, polling must retain the newest completed run for hover details.'
            [IO.File]::WriteAllText((Join-Path $fakeGh 'fail'), '')
            $null = Invoke-Private $ciWatcher 'Poll' (, $fakeRepo)
            Assert ($null -eq $ciWatcher.SnapshotFor($fakeRepo).Run -and $null -ne $ciWatcher.SnapshotFor($fakeRepo).Message) 'A CLI failure must replace stale running data with an explicit unavailable state.'
        } finally {
            $env:PATH = $oldPath; $env:ZED_TEST_GITHUB = $oldFakeGitHub
        }
        $oldAgent = $info.Agent
        $oldLimit = $indexer.Usage.CodexPrimary
        try {
            $info.Agent = 'codex-acp'
            $limit = New-Object ZedColors.RateWin
            $limit.Pct = 42; $limit.Minutes = 10080; $limit.Resets = [DateTime]::Now.AddDays(1)
            $indexer.Usage.CodexPrimary = $limit
            $hoverLines = Invoke-Private $hostApp 'CardLines' (, $row)
            Assert (@($hoverLines | Where-Object {$_.Text -like '*limit: 42% used*resets*'}).Count -eq 1) 'Codex limit percentages and reset times must remain accessible on hover after removing the usage chip.'
        } finally {
            $info.Agent = $oldAgent
            $indexer.Usage.CodexPrimary = $oldLimit
        }
        $hover = New-Object ZedColors.HoverCard
        $forms += $hover
        $hoverLines = Invoke-Private $hostApp 'CardLines' (, $row)
        foreach ($dpi in @([single]1, [single]1.5)) {
            $hover.SetContent($hoverLines, $dpi)
            $heights = Get-Field $hover 'heights'
            $y = [int][Math]::Round(10 * $dpi)
            for ($i = 0; $i -lt $hoverLines.Count; $i++) {
                $point = New-Object Drawing.Point([int][Math]::Round(16 * $dpi), ($y + 1))
                $link = Invoke-Private $hover 'LinkAt' (, $point)
                Assert ($link -eq $hoverLines[$i].Url) 'Only linked GitHub lines must be clickable, at each display scale.'
                $y += $heights[$i] + [int][Math]::Round(3 * $dpi)
            }
            $image = New-Object Drawing.Bitmap($hover.Width, $hover.Height)
            try { $hover.DrawToBitmap($image, (New-Object Drawing.Rectangle(0, 0, $image.Width, $image.Height))) }
            finally { $image.Dispose() }
        }
        $cp = $hover.GetType().GetProperty('CreateParams', [Reflection.BindingFlags]'Instance, NonPublic').GetValue($hover)
        Assert (($cp.ExStyle -band 0x08000000) -ne 0) 'The hover card must not take focus from Zed.'
        $oldSidebar = Get-Field $hostApp 'sidebar'
        $oldBounds = $form.Bounds
        $oldTop = $row.RowTop; $oldBottom = $row.RowBottom
        Set-Field $hostApp 'card' $hover
        Set-Field $hostApp 'hoverKey' $row.Key
        Set-Field $hostApp 'sidebar' (New-Object Drawing.Rectangle(80, 80, 180, 600))
        $row.RowTop = 120; $row.RowBottom = 160
        $hover.Location = New-Object Drawing.Point(288, 126)
        try {
            $form.Show(); $hover.Show()
            Assert ((Invoke-Private $hostApp 'RowForHover' (, (New-Object Drawing.Point(100, 140)))) -eq $row) 'Hovering the sidebar must retain the originating thread.'
            Assert ((Invoke-Private $hostApp 'RowForHover' (, (New-Object Drawing.Point(264, 140)))) -eq $row) 'Crossing the gap into the hover card must not dismiss its GitHub link.'
            Assert ((Invoke-Private $hostApp 'RowForHover' (, (New-Object Drawing.Point(310, 140)))) -eq $row) 'Moving onto the hover card must keep it available for clicking.'
            Assert ($null -eq (Invoke-Private $hostApp 'RowForHover' (, (New-Object Drawing.Point(($hover.Right + 20), 140))))) 'Leaving the hover card must release its originating row.'
            $form.Hide()
            Assert ($null -eq (Invoke-Private $hostApp 'RowForHover' (, (New-Object Drawing.Point(310, 140))))) 'A hidden overlay must not leave an interactive hover card active.'
        } finally {
            $form.Hide(); $hover.Hide()
            $form.Bounds = $oldBounds
            Set-Field $hostApp 'sidebar' $oldSidebar
            Set-Field $hostApp 'card' $null
            $row.RowTop = $oldTop; $row.RowBottom = $oldBottom
        }
        $rowPixels = New-Object 'int[]' 600
        for ($x = 0; $x -lt 600; $x++) { $rowPixels[$x] = if ($x -lt 300) { 0x111111 } else { 0x555555 } }
        $cleanPixels = New-Object 'int[]' 360000
        for ($y = 0; $y -lt 600; $y++) { [Array]::Copy($rowPixels, 0, $cleanPixels, ($y * 600), 600) }
        $edge = Invoke-Private $hostApp 'FindEdge' @($cleanPixels, 600, 600)
        Assert ($edge -eq 300) 'Sidebar recognition must work without floating panels.'
    } finally {
        (Get-Field $ciWatcher 'wake').Dispose()
        Set-Field $hostApp 'ci' $null
    }

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
    'Passed: compilation, fragmented/merged OCR line sizing and input-state geometry at multiple DPIs, explicit Copilot task completion and green-ring propagation, pending-helper completion and nested-event guards, independent similar-title/project colors, missing-timestamp row sizing, canonical OCR color keys, ambiguous-session matching, floating-panel/inbox removal, GitHub tag progress rendering and OCR masking, per-project polling thresholds, running-workflow CLI selection and step progress, hover GitHub status and links, hover rendering and DPI, real-prompt filtering, helper counts and rendering, working/waiting status, new-session ring, saved colors, completion colors, Claude background lifecycles, cached hover prompts, history errors, JSON fallback, startup opt-in, responsive OCR, and preview SVG.'
} finally {
    if ($null -ne $timer) { $timer.Stop(); $timer.Dispose() }
    if ($null -ne $worker) { $worker.Stop(); $worker.Dispose() }
    if ($null -ne $runspace) { $runspace.Dispose() }
    foreach ($f in $forms) { $f.Dispose() }
    $env:COPILOT_HOME = $oldHome
    [IO.Directory]::Delete($temp, $true)
}
