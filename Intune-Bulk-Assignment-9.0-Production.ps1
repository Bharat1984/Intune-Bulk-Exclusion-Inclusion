Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:GraphBaseUri = 'https://graph.microsoft.com/v1.0'
$script:StopRequested = $false
$script:GroupNameCache = @{}
$script:IsGraphConnected = $false

function Write-Log {
    param(
        [System.Windows.Forms.RichTextBox]$LogViewer,
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')] [string]$Level = 'Info'
    )

    $colours = @{ Info = '#334155'; Success = '#15803D'; Warning = '#B45309'; Error = '#B91C1C' }
    $LogViewer.SelectionStart = $LogViewer.TextLength
    $LogViewer.SelectionColor = [System.Drawing.ColorTranslator]::FromHtml($colours[$Level])
    $LogViewer.AppendText('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Message + "`r`n")
    $LogViewer.SelectionColor = $LogViewer.ForeColor
    $LogViewer.ScrollToCaret()
}

function Set-ConnectionUi {
    param([bool]$Connected, [string]$AccountName = '')
    $script:IsGraphConnected = $Connected
    foreach ($button in $script:GraphActionButtons) { $button.Enabled = $Connected }
    $LoginBtn.Enabled = -not $Connected
    $LogoutBtn.Enabled = $Connected
    if ($Connected) {
        $ConnectionStatus.Text = "Connected: $AccountName"
        $ConnectionStatus.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#BBF7D0')
    } else {
        $ConnectionStatus.Text = 'Not connected'
        $ConnectionStatus.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#FDE68A')
    }
}

function Connect-GraphInteractive {
    try {
        Connect-MgGraph -Scopes 'DeviceManagementApps.ReadWrite.All', 'Group.Read.All' -ErrorAction Stop | Out-Null
        $context = Get-MgContext
        if (-not $context -or -not $context.Account) { throw 'Microsoft Graph did not return an authenticated account.' }
        Set-ConnectionUi -Connected $true -AccountName $context.Account
        Write-Log $LogViewer "Signed in as $($context.Account)." Success
    } catch {
        Set-ConnectionUi -Connected $false
        Write-Log $LogViewer "Sign-in failed: $($_.Exception.Message)" Error
        [System.Windows.Forms.MessageBox]::Show($Form, "Graph sign-in failed: $($_.Exception.Message)", 'Connection failed', 'OK', 'Error')
    }
}

function Disconnect-GraphSession {
    if (-not $script:IsGraphConnected) { return }
    try {
        Disconnect-MgGraph | Out-Null
        $script:GroupNameCache = @{}
        Set-ConnectionUi -Connected $false
        Write-Log $LogViewer 'Signed out of Microsoft Graph.' Info
    } catch { Write-Log $LogViewer "Sign-out failed: $($_.Exception.Message)" Error }
}

function Show-UsageInfo {
    $message = @"
How this tool works

1. Login connects your Microsoft Graph session.
2. Enter a group name or, preferably, a Group ID.
3. Optionally enter comma-separated app-name filters.
4. Select an OS/platform. "All platforms" is the default.
5. Keep Dry run enabled to preview results. Disable it only when ready to make changes.

Actions
- Inclusion: adds a required group assignment.
- Exclusion: adds an exclusion assignment.
- Remove exclusions: removes exclusions only; inclusions are preserved.
- Exclude all apps: applies the exclusion to every app in the selected platform.
- Exports do not make changes.

Built by https://techtrendinsights.co.in/ | Owner: Bharat Arora
"@
    [System.Windows.Forms.MessageBox]::Show($Form, $message, 'How it works', 'OK', 'Information')
}

function Invoke-GraphRequestWithRetry {
    param(
        [ValidateSet('GET', 'POST', 'DELETE')] [string]$Method,
        [string]$Uri,
        [object]$Body
    )

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            if ($PSBoundParameters.ContainsKey('Body')) {
                return Invoke-MgGraphRequest -Method $Method -Uri $Uri -Body $Body -ContentType 'application/json' -ErrorAction Stop
            }
            return Invoke-MgGraphRequest -Method $Method -Uri $Uri -ErrorAction Stop
        } catch {
            $statusCode = $null
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
            $isTransient = $statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -lt 600)
            if (-not $isTransient -or $attempt -eq 3) { throw }
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

function Get-GraphPagedCollection {
    param([string]$Uri)

    $items = @()
    do {
        $response = Invoke-GraphRequestWithRetry -Method GET -Uri $Uri
        $items += @($response.value)
        $Uri = $response.'@odata.nextLink'
    } while ($Uri)
    return $items
}

function Get-MobileApps {
    Get-GraphPagedCollection -Uri "$script:GraphBaseUri/deviceAppManagement/mobileApps?`$top=999"
}

function Get-AppAssignments {
    param([string]$AppId)
    Get-GraphPagedCollection -Uri "$script:GraphBaseUri/deviceAppManagement/mobileApps/$AppId/assignments?`$top=999"
}

function Resolve-AADGroup {
    param([Parameter(Mandatory)] [string]$GroupInput)

    $id = [guid]::Empty
    if ([guid]::TryParse($GroupInput, [ref]$id)) {
        return Get-MgGroup -GroupId $id.Guid -Property 'id,displayName' -ErrorAction Stop
    }

    # OData string literals escape a single quote by doubling it.
    $escapedName = $GroupInput.Replace("'", "''")
    $filter = "displayName eq '$escapedName'"
    $encodedFilter = [uri]::EscapeDataString($filter)
    $matches = @(Get-GraphPagedCollection -Uri "$script:GraphBaseUri/groups?`$filter=$encodedFilter&`$select=id,displayName")

    if ($matches.Count -eq 0) { throw "No group was found with the display name '$GroupInput'." }
    if ($matches.Count -gt 1) {
        $choices = ($matches | ForEach-Object { "'$($_.displayName)' ($($_.id))" }) -join ', '
        throw "More than one group matched. Enter the Group ID instead: $choices"
    }
    return $matches[0]
}

function Get-AppPlatform {
    param([object]$App)
    $type = [string]$App.'@odata.type'
    if ($type -match 'win32|windows|office') { return 'Windows' }
    if ($type -match 'macOS|mac') { return 'macOS' }
    if ($type -match 'ios|iPad') { return 'iOS/iPadOS' }
    if ($type -match 'android') { return 'Android' }
    return 'Other'
}

function Test-AppFilter {
    param([object]$App, [string[]]$Filters, [string]$PlatformFilter = 'All platforms')
    if ($PlatformFilter -ne 'All platforms' -and (Get-AppPlatform -App $App) -ne $PlatformFilter) { return $false }
    $AppName = [string]$App.displayName
    if (-not $Filters -or $Filters.Count -eq 0) { return $true }
    foreach ($filter in $Filters) {
        if ($AppName.IndexOf($filter, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function New-GroupAssignmentBody {
    param([string]$GroupId, [ValidateSet('Include', 'Exclude')] [string]$Mode)
    $targetType = if ($Mode -eq 'Include') { '#microsoft.graph.groupAssignmentTarget' } else { '#microsoft.graph.exclusionGroupAssignmentTarget' }
    return (@{
        '@odata.type' = '#microsoft.graph.mobileAppAssignment'
        intent = 'required'
        target = @{ '@odata.type' = $targetType; groupId = $GroupId }
    } | ConvertTo-Json -Depth 5 -Compress)
}

function Invoke-GroupAssignmentOperation {
    param(
        [Parameter(Mandatory)] [string]$GroupInput,
        [string[]]$AppNameFilters,
        [ValidateSet('Include', 'Exclude', 'RemoveExclusion')] [string]$Mode,
        [bool]$DryRun,
        [string]$PlatformFilter = 'All platforms',
        [System.Windows.Forms.RichTextBox]$LogViewer
    )

    try { $group = Resolve-AADGroup -GroupInput $GroupInput } catch {
        Write-Log -LogViewer $LogViewer -Message $_.Exception.Message -Level Error
        return
    }

    $counts = @{ Changed = 0; Skipped = 0; Failed = 0 }
    Write-Log -LogViewer $LogViewer -Message "Using group '$($group.DisplayName)' ($($group.Id))." -Level Info
    try { $apps = @(Get-MobileApps) } catch {
        Write-Log -LogViewer $LogViewer -Message "Could not list Intune apps: $($_.Exception.Message)" -Level Error
        return
    }

    foreach ($app in $apps) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:StopRequested) { Write-Log -LogViewer $LogViewer -Message 'Stop requested. The operation was halted.' -Level Warning; break }
        if (-not (Test-AppFilter -App $app -Filters $AppNameFilters -PlatformFilter $PlatformFilter)) { continue }

        try {
            $assignments = @(Get-AppAssignments -AppId $app.id)
            $exclusions = @($assignments | Where-Object { $_.target.groupId -eq $group.id -and $_.target.'@odata.type' -eq '#microsoft.graph.exclusionGroupAssignmentTarget' })
            $inclusions = @($assignments | Where-Object { $_.target.groupId -eq $group.id -and $_.target.'@odata.type' -eq '#microsoft.graph.groupAssignmentTarget' })

            if ($Mode -eq 'RemoveExclusion') {
                if ($exclusions.Count -eq 0) {
                    $counts.Skipped++; Write-Log $LogViewer "No exclusion found: $($app.displayName)." Info; continue
                }
                foreach ($assignment in $exclusions) {
                    if (-not $DryRun) {
                        Invoke-GraphRequestWithRetry -Method DELETE -Uri "$script:GraphBaseUri/deviceAppManagement/mobileApps/$($app.id)/assignments/$($assignment.id)" | Out-Null
                    }
                    $counts.Changed++
                    $prefix = if ($DryRun) { '[Dry run] Would remove exclusion' } else { 'Removed exclusion' }
                    Write-Log $LogViewer "${prefix}: $($app.displayName)." Success
                }
                continue
            }

            $existing = if ($Mode -eq 'Include') { $inclusions } else { $exclusions }
            if ($existing.Count -gt 0) {
                $counts.Skipped++; Write-Log $LogViewer "Already $($Mode.ToLower())d: $($app.displayName)." Info; continue
            }

            if (-not $DryRun) {
                $body = New-GroupAssignmentBody -GroupId $group.id -Mode $Mode
                Invoke-GraphRequestWithRetry -Method POST -Uri "$script:GraphBaseUri/deviceAppManagement/mobileApps/$($app.id)/assignments" -Body $body | Out-Null
            }
            $counts.Changed++
            $prefix = if ($DryRun) { "[Dry run] Would add $($Mode.ToLower())" } else { "Added $($Mode.ToLower())" }
            Write-Log $LogViewer "${prefix}: $($app.displayName)." Success
        } catch {
            $counts.Failed++
            Write-Log $LogViewer "Failed: $($app.displayName) - $($_.Exception.Message)" Error
        }
    }

    $verb = if ($DryRun) { 'Dry-run complete' } else { 'Operation complete' }
    $summary = "$verb. Changed: $($counts.Changed); skipped: $($counts.Skipped); failed: $($counts.Failed)."
    Write-Log -LogViewer $LogViewer -Message $summary -Level Info
    [System.Windows.Forms.MessageBox]::Show($Form, $summary, 'Intune Bulk Assignment', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}

function Get-AssignmentExportRows {
    param([object[]]$Apps, [string[]]$AppNameFilters, [string]$PlatformFilter = 'All platforms', [System.Windows.Forms.RichTextBox]$LogViewer)
    $results = @()
    foreach ($app in $Apps) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:StopRequested) { Write-Log $LogViewer 'Stop requested. Exporting collected results.' Warning; break }
        if (-not (Test-AppFilter -App $app -Filters $AppNameFilters -PlatformFilter $PlatformFilter)) { continue }
        try { $assignments = @(Get-AppAssignments -AppId $app.id) } catch { Write-Log $LogViewer "Failed to read $($app.displayName): $($_.Exception.Message)" Error; continue }

        if ($assignments.Count -eq 0) {
            $results += [PSCustomObject]@{ AppName = $app.displayName; AppId = $app.id; AppType = $app.'@odata.type'; Intent = '(none)'; Type = '(none)'; GroupId = '(none)'; GroupName = '(none)' }
            continue
        }
        foreach ($assignment in $assignments) {
            $groupId = $assignment.target.groupId
            if ($groupId) {
                if (-not $script:GroupNameCache.ContainsKey($groupId)) {
                    try { $script:GroupNameCache[$groupId] = (Get-MgGroup -GroupId $groupId -Property displayName -ErrorAction Stop).DisplayName } catch { $script:GroupNameCache[$groupId] = 'Unknown Group' }
                }
                $groupName = $script:GroupNameCache[$groupId]
            } elseif ($assignment.target.'@odata.type' -eq '#microsoft.graph.allLicensedUsersAssignmentTarget') { $groupName = 'All Users' } else { $groupName = '(unresolved)' }
            $results += [PSCustomObject]@{ AppName = $app.displayName; AppId = $app.id; AppType = $app.'@odata.type'; Intent = $assignment.intent; Type = $assignment.target.'@odata.type'; GroupId = $groupId; GroupName = $groupName }
        }
        Write-Log $LogViewer "Read $($assignments.Count) assignment(s): $($app.displayName)." Info
    }
    return $results
}

function Export-AppAssignments {
    param([string[]]$AppNameFilters, [string]$PlatformFilter = 'All platforms', [string]$FileName, [System.Windows.Forms.RichTextBox]$LogViewer)
    if (-not $script:IsGraphConnected) { [System.Windows.Forms.MessageBox]::Show($Form, 'Sign in to Microsoft Graph first.', 'Login required', 'OK', 'Warning'); return }
    $script:StopRequested = $false
    try { $apps = @(Get-MobileApps) } catch { Write-Log $LogViewer "Could not list Intune apps: $($_.Exception.Message)" Error; return }
    Write-Log $LogViewer "Reading assignments from $($apps.Count) app(s)." Info
    $results = @(Get-AssignmentExportRows -Apps $apps -AppNameFilters $AppNameFilters -PlatformFilter $PlatformFilter -LogViewer $LogViewer)
    $path = Join-Path ([Environment]::GetFolderPath('Desktop')) $FileName
    try {
        $results | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
        Write-Log $LogViewer "Exported $($results.Count) row(s) to $path." Success
        [System.Windows.Forms.MessageBox]::Show($Form, "Exported $($results.Count) row(s) to:`r`n$path", 'Export complete', 'OK', 'Information')
    } catch { Write-Log $LogViewer "Export failed: $($_.Exception.Message)" Error }
}

function Set-ButtonStyle {
    param([System.Windows.Forms.Button]$Button, [string]$BackColor)
    $Button.FlatStyle = 'Flat'; $Button.FlatAppearance.BorderSize = 0
    $Button.BackColor = [System.Drawing.ColorTranslator]::FromHtml($BackColor)
    $Button.ForeColor = [System.Drawing.Color]::White
    $Button.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    $Button.Height = 38
}

function Start-WriteOperation {
    param([ValidateSet('Include', 'Exclude', 'RemoveExclusion')] [string]$Mode, [bool]$AllApps = $false)
    if (-not $script:IsGraphConnected) { [System.Windows.Forms.MessageBox]::Show($Form, 'Sign in to Microsoft Graph first.', 'Login required', 'OK', 'Warning'); return }
    $script:StopRequested = $false
    $groupInput = $GroupInput.Text.Trim()
    $filters = @($AppInput.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $groupInput) { [System.Windows.Forms.MessageBox]::Show($Form, 'Enter a unique group display name or a Group ID.', 'Group required', 'OK', 'Warning'); return }
    if (-not $AllApps -and $filters.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show($Form, 'Enter at least one app name for a selected-app operation.', 'Apps required', 'OK', 'Warning'); return }
    if (-not $DryRunCheck.Checked) {
        $platformScope = $PlatformFilterCombo.SelectedItem
        $scope = if ($AllApps) { "ALL $platformScope Intune apps" } else { "$platformScope apps matching: $($filters -join ', ')" }
        $action = if ($Mode -eq 'RemoveExclusion') { 'remove exclusions from' } else { "$($Mode.ToLower()) the group for" }
        $answer = [System.Windows.Forms.MessageBox]::Show($Form, "This will $action $scope.`r`n`r`nContinue?", 'Confirm change', 'YesNo', 'Warning')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    Invoke-GroupAssignmentOperation -GroupInput $groupInput -AppNameFilters $filters -Mode $Mode -DryRun $DryRunCheck.Checked -PlatformFilter $PlatformFilterCombo.SelectedItem -LogViewer $LogViewer
}

$Form = New-Object System.Windows.Forms.Form
$Form.ClientSize = New-Object System.Drawing.Size(1060, 790)
$Form.MinimumSize = New-Object System.Drawing.Size(900, 700)
$Form.Text = 'Intune Bulk Assignment Manager'
$Form.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F4F7FB')
$Form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$Form.StartPosition = 'CenterScreen'

$header = New-Object System.Windows.Forms.Panel
$header.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#0F2E4D'); $header.Dock = 'Top'; $header.Height = 88
$title = New-Object System.Windows.Forms.Label
$title.Text = 'Intune Bulk Assignment Manager'; $title.ForeColor = 'White'; $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 20)
$title.AutoSize = $true; $title.Location = New-Object System.Drawing.Point(26, 15)
$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Safe group assignment, exclusion, audit, and export operations'; $subtitle.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#BFDBFE'); $subtitle.AutoSize = $true; $subtitle.Location = New-Object System.Drawing.Point(29, 54)
$ConnectionStatus = New-Object System.Windows.Forms.Label
$ConnectionStatus.AutoSize = $true; $ConnectionStatus.Location = New-Object System.Drawing.Point(742, 57); $ConnectionStatus.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$InfoBtn = New-Object System.Windows.Forms.Button
$InfoBtn.Text = 'How it works'; $InfoBtn.Location = New-Object System.Drawing.Point(720, 12); $InfoBtn.Width = 108; Set-ButtonStyle $InfoBtn '#0284C7'; $InfoBtn.Add_Click({ Show-UsageInfo })
$LoginBtn = New-Object System.Windows.Forms.Button
$LoginBtn.Text = 'Login'; $LoginBtn.Location = New-Object System.Drawing.Point(840, 12); $LoginBtn.Width = 85; Set-ButtonStyle $LoginBtn '#16A34A'; $LoginBtn.Add_Click({ Connect-GraphInteractive })
$LogoutBtn = New-Object System.Windows.Forms.Button
$LogoutBtn.Text = 'Logout'; $LogoutBtn.Location = New-Object System.Drawing.Point(936, 12); $LogoutBtn.Width = 85; Set-ButtonStyle $LogoutBtn '#475569'; $LogoutBtn.Add_Click({ Disconnect-GraphSession })
$header.Controls.AddRange(@($title, $subtitle, $ConnectionStatus, $InfoBtn, $LoginBtn, $LogoutBtn)); $Form.Controls.Add($header)

$inputPanel = New-Object System.Windows.Forms.Panel
$inputPanel.Location = New-Object System.Drawing.Point(22, 108); $inputPanel.Size = New-Object System.Drawing.Size(1016, 128); $inputPanel.BackColor = 'White'; $inputPanel.BorderStyle = 'FixedSingle'
$groupLabel = New-Object System.Windows.Forms.Label
$groupLabel.Text = 'Group display name or Group ID'; $groupLabel.AutoSize = $true; $groupLabel.Location = New-Object System.Drawing.Point(18, 15); $groupLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$GroupInput = New-Object System.Windows.Forms.TextBox
$GroupInput.Location = New-Object System.Drawing.Point(18, 38); $GroupInput.Size = New-Object System.Drawing.Size(620, 28); $GroupInput.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$appLabel = New-Object System.Windows.Forms.Label
$appLabel.Text = 'App name filters (comma-separated)'; $appLabel.AutoSize = $true; $appLabel.Location = New-Object System.Drawing.Point(18, 78); $appLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$AppInput = New-Object System.Windows.Forms.TextBox
$AppInput.Location = New-Object System.Drawing.Point(18, 98); $AppInput.Size = New-Object System.Drawing.Size(620, 24)
$platformLabel = New-Object System.Windows.Forms.Label
$platformLabel.Text = 'OS / platform filter'; $platformLabel.AutoSize = $true; $platformLabel.Location = New-Object System.Drawing.Point(666, 15); $platformLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$PlatformFilterCombo = New-Object System.Windows.Forms.ComboBox
$PlatformFilterCombo.Location = New-Object System.Drawing.Point(666, 37); $PlatformFilterCombo.Size = New-Object System.Drawing.Size(310, 28); $PlatformFilterCombo.DropDownStyle = 'DropDownList'
[void]$PlatformFilterCombo.Items.AddRange([string[]]@('All platforms', 'Windows', 'macOS', 'iOS/iPadOS', 'Android', 'Other'))
$PlatformFilterCombo.SelectedIndex = 0
$DryRunCheck = New-Object System.Windows.Forms.CheckBox
$DryRunCheck.Text = 'Dry run (preview only; no changes)'; $DryRunCheck.Checked = $true; $DryRunCheck.AutoSize = $true; $DryRunCheck.Location = New-Object System.Drawing.Point(666, 73); $DryRunCheck.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#0369A1'); $DryRunCheck.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'Use a Group ID whenever names may be duplicated.'; $hint.AutoSize = $true; $hint.ForeColor = [System.Drawing.Color]::DimGray; $hint.Location = New-Object System.Drawing.Point(666, 101)
$inputPanel.Controls.AddRange(@($groupLabel, $GroupInput, $appLabel, $AppInput, $platformLabel, $PlatformFilterCombo, $DryRunCheck, $hint)); $Form.Controls.Add($inputPanel)

$LogViewer = New-Object System.Windows.Forms.RichTextBox
$LogViewer.Location = New-Object System.Drawing.Point(22, 255); $LogViewer.Size = New-Object System.Drawing.Size(1016, 360); $LogViewer.Anchor = 'Top,Bottom,Left,Right'; $LogViewer.ReadOnly = $true; $LogViewer.BackColor = [System.Drawing.Color]::White; $LogViewer.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#334155'); $LogViewer.Font = New-Object System.Drawing.Font('Cascadia Mono', 9); $LogViewer.BorderStyle = 'FixedSingle'
$Form.Controls.Add($LogViewer)

$IncludeBtn = New-Object System.Windows.Forms.Button
$IncludeBtn.Text = 'Add inclusion (selected apps)'; $IncludeBtn.Location = New-Object System.Drawing.Point(22, 642); $IncludeBtn.Width = 240; Set-ButtonStyle $IncludeBtn '#2563EB'; $IncludeBtn.Add_Click({ Start-WriteOperation Include })
$ExcludeBtn = New-Object System.Windows.Forms.Button
$ExcludeBtn.Text = 'Add exclusion (selected apps)'; $ExcludeBtn.Location = New-Object System.Drawing.Point(274, 642); $ExcludeBtn.Width = 240; Set-ButtonStyle $ExcludeBtn '#7C3AED'; $ExcludeBtn.Add_Click({ Start-WriteOperation Exclude })
$RemoveBtn = New-Object System.Windows.Forms.Button
$RemoveBtn.Text = 'Remove exclusions (selected apps)'; $RemoveBtn.Location = New-Object System.Drawing.Point(526, 642); $RemoveBtn.Width = 250; Set-ButtonStyle $RemoveBtn '#B45309'; $RemoveBtn.Add_Click({ Start-WriteOperation RemoveExclusion })
$StopBtn = New-Object System.Windows.Forms.Button
$StopBtn.Text = 'Stop'; $StopBtn.Location = New-Object System.Drawing.Point(788, 642); $StopBtn.Width = 110; Set-ButtonStyle $StopBtn '#DC2626'; $StopBtn.Add_Click({ $script:StopRequested = $true; Write-Log $LogViewer 'Stop requested; the current request will finish before processing stops.' Warning })
$ClearBtn = New-Object System.Windows.Forms.Button
$ClearBtn.Text = 'Clear log'; $ClearBtn.Location = New-Object System.Drawing.Point(910, 642); $ClearBtn.Width = 128; Set-ButtonStyle $ClearBtn '#475569'; $ClearBtn.Add_Click({ $LogViewer.Clear() })

$BulkExcludeBtn = New-Object System.Windows.Forms.Button
$BulkExcludeBtn.Text = 'Add exclusion to all apps'; $BulkExcludeBtn.Location = New-Object System.Drawing.Point(22, 692); $BulkExcludeBtn.Width = 240; Set-ButtonStyle $BulkExcludeBtn '#6D28D9'; $BulkExcludeBtn.Add_Click({ Start-WriteOperation Exclude $true })
$ExportBtn = New-Object System.Windows.Forms.Button
$ExportBtn.Text = 'Export all assignments'; $ExportBtn.Location = New-Object System.Drawing.Point(274, 692); $ExportBtn.Width = 240; Set-ButtonStyle $ExportBtn '#047857'; $ExportBtn.Add_Click({ Export-AppAssignments -PlatformFilter $PlatformFilterCombo.SelectedItem -FileName 'Intune-All-App-Assignments.csv' -LogViewer $LogViewer })
$ExportSelectedBtn = New-Object System.Windows.Forms.Button
$ExportSelectedBtn.Text = 'Export selected app details'; $ExportSelectedBtn.Location = New-Object System.Drawing.Point(526, 692); $ExportSelectedBtn.Width = 250; Set-ButtonStyle $ExportSelectedBtn '#0F766E'; $ExportSelectedBtn.Add_Click({ $filters = @($AppInput.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }); if ($filters.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show($Form, 'Enter at least one app name.', 'Apps required', 'OK', 'Warning'); return }; Export-AppAssignments -AppNameFilters $filters -PlatformFilter $PlatformFilterCombo.SelectedItem -FileName 'Intune-Selected-App-Details.csv' -LogViewer $LogViewer })
$Form.Controls.AddRange(@($IncludeBtn, $ExcludeBtn, $RemoveBtn, $StopBtn, $ClearBtn, $BulkExcludeBtn, $ExportBtn, $ExportSelectedBtn))
$SignatureLabel = New-Object System.Windows.Forms.LinkLabel
$SignatureLabel.Text = 'Built by https://techtrendinsights.co.in/ | Owner: Bharat Arora'; $SignatureLabel.AutoSize = $true; $SignatureLabel.Location = New-Object System.Drawing.Point(22, 750); $SignatureLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9); $SignatureLabel.LinkColor = [System.Drawing.ColorTranslator]::FromHtml('#0369A1')
[void]$SignatureLabel.Links.Add(9, 32, 'https://techtrendinsights.co.in/')
$SignatureLabel.Add_LinkClicked({ param($sender, $eventArgs) Start-Process $eventArgs.Link.LinkData })
$Form.Controls.Add($SignatureLabel)
$script:GraphActionButtons = @($IncludeBtn, $ExcludeBtn, $RemoveBtn, $StopBtn, $BulkExcludeBtn, $ExportBtn, $ExportSelectedBtn)
Set-ConnectionUi -Connected $false
Write-Log $LogViewer 'Sign in to Microsoft Graph to enable assignment and export actions. Dry run is enabled by default.' Info
[void]$Form.ShowDialog()
