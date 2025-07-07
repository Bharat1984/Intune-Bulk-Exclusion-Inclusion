try {
    Connect-MgGraph -Scopes "DeviceManagementApps.ReadWrite.All", "Group.Read.All"
} catch {
    [System.Windows.Forms.MessageBox]::Show("Graph connection failed: $_")
    return
}

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

$global:StopAudit = $false

function Resolve-AADGroup {
    param([string]$GroupName)
    $filter = "displayName eq '$GroupName'"
    $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$filter"
    return $resp.value | Select-Object -First 1
}

function Get-AppAssignments {
    param([string]$AppId)
    $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/assignments"
    return $resp.value
}

function Add-GroupAsInclusionToApps {
    param ([string]$GroupName, [string[]]$AppNameFilters, [System.Windows.Forms.TextBox]$LogViewer)
    $summary = "Results:`n"
    $groupObj = Resolve-AADGroup -GroupName $GroupName
    if (-not $groupObj) { $LogViewer.AppendText("❌ Group '$GroupName' not found.`r`n"); return }
    $apps = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=999").value
    foreach ($app in $apps) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($global:StopAudit) { $LogViewer.AppendText("⛔ Stop requested.`r`n"); break }
        $appName = $app.displayName
        $appType = $app.'@odata.type'
        if (($AppNameFilters.Count -ne 0) -and (-not ($AppNameFilters | Where-Object { $appName -like "*$_*" }))) { continue }
        $assignments = Get-AppAssignments -AppId $app.id
        $exists = $assignments | Where-Object { $_.target.groupId -eq $groupObj.id -and $_.intent -eq "required" }
        if ($exists) {
            $LogViewer.AppendText("✅ Already included: '$appName' [$appType].`r`n"); $summary += "✅ Already included: $appName [$appType]`n"
        } else {
            try {
                Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)/assignments" -Body @{ target = @{"@odata.type"="#microsoft.graph.groupAssignmentTarget"; groupId=$groupObj.id}; intent="required" } | Out-Null
                $LogViewer.AppendText("➕ Added inclusion on '$appName' [$appType].`r`n"); $summary += "➕ Added: $appName [$appType]`n"
            } catch {
                $LogViewer.AppendText("❌ Failed on '$appName': $_.`r`n"); $summary += "❌ Failed: $appName [$appType]`n"
            }
        }
    }
    $LogViewer.AppendText("📊 Summary:`r`n$summary`r`n")
    [System.Windows.Forms.MessageBox]::Show($Form, $summary, "Summary", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}

function Add-GroupAsExclusionToApps {
    param ([string]$GroupName, [string[]]$AppNameFilters, [System.Windows.Forms.TextBox]$LogViewer)
    $summary = "Results:`n"
    $groupObj = Resolve-AADGroup -GroupName $GroupName
    if (-not $groupObj) { $LogViewer.AppendText("❌ Group '$GroupName' not found.`r`n"); return }
    $apps = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=999").value
    foreach ($app in $apps) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($global:StopAudit) { $LogViewer.AppendText("⛔ Stop requested.`r`n"); break }
        $appName = $app.displayName
        $appType = $app.'@odata.type'
        if (($AppNameFilters.Count -ne 0) -and (-not ($AppNameFilters | Where-Object { $appName -like "*$_*" }))) { continue }
        $assignments = Get-AppAssignments -AppId $app.id
        $exists = $assignments | Where-Object { $_.target.groupId -eq $groupObj.id -and $_.target.'@odata.type' -eq "#microsoft.graph.exclusionGroupAssignmentTarget" }
        if ($exists) {
            $LogViewer.AppendText("✅ Already excluded: '$appName' [$appType].`r`n"); $summary += "✅ Already excluded: $appName [$appType]`n"
        } else {
            try {
                Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)/assignments" -Body @{ target = @{"@odata.type"="#microsoft.graph.exclusionGroupAssignmentTarget"; groupId=$groupObj.id}; intent="required" } | Out-Null
                $LogViewer.AppendText("🚫 Added exclusion on '$appName' [$appType].`r`n"); $summary += "🚫 Added: $appName [$appType]`n"
            } catch {
                $LogViewer.AppendText("❌ Failed on '$appName': $_.`r`n"); $summary += "❌ Failed: $appName [$appType]`n"
            }
        }
    }
    $LogViewer.AppendText("📊 Summary:`r`n$summary`r`n")
    [System.Windows.Forms.MessageBox]::Show($Form, $summary, "Summary", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}
function Remove-GroupExclusionFromApps {
    param ([string]$GroupName, [string[]]$AppNameFilters, [System.Windows.Forms.TextBox]$LogViewer)
    $summary = "Results:`n"
    $groupObj = Resolve-AADGroup -GroupName $GroupName
    if (-not $groupObj) { $LogViewer.AppendText("❌ Group '$GroupName' not found.`r`n"); return }
    $apps = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=999").value
    foreach ($app in $apps) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($global:StopAudit) {$LogViewer.AppendText("⛔ Stop requested.`r`n"); break}
        $appName = $app.displayName
        if (($AppNameFilters.Count -ne 0) -and (-not ($AppNameFilters | Where-Object { $appName -like "*$_*" }))) { continue }

        $assignments = Get-AppAssignments -AppId $app.id
        $groupAssignments = $assignments | Where-Object { $_.target.groupId -eq $groupObj.id }
        if (-not $groupAssignments) {
            $LogViewer.AppendText("ℹ️ No assignment found for '$appName'.`r`n"); $summary += "ℹ️ No assignment: $appName`n"
            continue
        }
        foreach ($assignment in $groupAssignments) {
            try {
                Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)/assignments/$($assignment.id)" | Out-Null
                $LogViewer.AppendText("🧹 Removed assignment (any type) on '$appName'.`r`n"); $summary += "🧹 Removed: $appName`n"
            } catch {
                $LogViewer.AppendText("❌ Failed to remove on '$appName': $_.`r`n"); $summary += "❌ Failed: $appName`n"
            }
        }
    }
    
    [System.Windows.Forms.MessageBox]::Show($Form, $summary, "Summary", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}

function Export-AllAppAssignments {
    param([System.Windows.Forms.TextBox]$LogViewer)
    $LogViewer.AppendText("🚀 Extracting all assignments across all apps including explicit operations like exclusions/inclusions...`r`n")
    $results = @()
    $apps = @()
    $skip = 0
    $totalAssignments = 0
    do {
        $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=999&`$skip=$skip"
        $apps += $resp.value
        $skip += 999
        $LogViewer.AppendText("📦 Retrieved $($apps.Count) apps so far...`r`n")
    } while ($resp.'@odata.nextLink')

    foreach ($app in $apps) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($global:StopAudit) { $LogViewer.AppendText("⛔ Stop requested.`r`n"); break }
        $assignments = Get-AppAssignments -AppId $app.id
        $totalAssignments += $assignments.Count
        $LogViewer.AppendText("🔍 App: $($app.displayName) [$($app.'@odata.type')] → Found $($assignments.Count) assignments.`r`n")

        if ($assignments.Count -eq 0) {
            $results += [PSCustomObject]@{
                AppName = $app.displayName
                AppId = $app.id
                AppType = $app.'@odata.type'
                Intent = "(none)"
                Type = "(none)"
                GroupId = "(none)"
                GroupName = "(none)"
            }
            $LogViewer.AppendText("    → No assignments recorded, app still listed: '$($app.displayName)' [$($app.'@odata.type')]`r`n")
        }

        foreach ($a in $assignments) {
            $groupName = ""
            if ($a.target.groupId) {
                try {
                    $groupObj = Get-MgGroup -GroupId $a.target.groupId -ErrorAction SilentlyContinue
                    if ($groupObj) { $groupName = $groupObj.DisplayName } else { $groupName = "Unknown Group" }
                } catch { $groupName = "Unknown Group" }
            } elseif ($a.target.'@odata.type' -eq "#microsoft.graph.allLicensedUsersAssignmentTarget") {
                $groupName = "All Users"
            } else {
                $groupName = "(unresolved)"
            }

            $results += [PSCustomObject]@{
                AppName = $app.displayName
                AppId = $app.id
                AppType = $app.'@odata.type'
                Intent = $a.intent
                Type = $a.target.'@odata.type'
                GroupId = $a.target.groupId
                GroupName = $groupName
            }
            $LogViewer.AppendText("    → Recorded assignment: '$($app.displayName)' [$($a.intent)] $($a.target.'@odata.type') GroupId=$($a.target.groupId) GroupName=$groupName`r`n")
        }
    }
    $results | Export-Csv -Path "$env:USERPROFILE\Desktop\Intune-All-App-Assignments.csv" -NoTypeInformation
    $LogViewer.AppendText("✅ CSV saved to Desktop: Intune-All-App-Assignments.csv`r`n")
    $LogViewer.AppendText("📊 Summary: Processed $($apps.Count) apps with $totalAssignments total assignments including explicit adds/removes.`r`n")
    [System.Windows.Forms.MessageBox]::Show("Export complete. Processed $($apps.Count) apps with $totalAssignments assignments. CSV saved to Desktop.", "Export Done")
}

function Add-GroupAsBulkExclusionToAllApps {
    param ([string]$GroupName, [System.Windows.Forms.TextBox]$LogViewer)
    $summary = "Results:`n"
    $groupObj = Resolve-AADGroup -GroupName $GroupName
    if (-not $groupObj) { $LogViewer.AppendText("❌ Group '$GroupName' not found.`r`n"); return }
    $apps = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=999").value
    foreach ($app in $apps) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($global:StopAudit) { $LogViewer.AppendText("⛔ Stop requested.`r`n"); break }
        $appName = $app.displayName
        $appType = $app.'@odata.type'
        $assignments = Get-AppAssignments -AppId $app.id
        $exists = $assignments | Where-Object { $_.target.groupId -eq $groupObj.id -and $_.target.'@odata.type' -eq "#microsoft.graph.exclusionGroupAssignmentTarget" }
        if ($exists) {
            $LogViewer.AppendText("✅ Already excluded: '$appName' [$appType].`r`n"); $summary += "✅ Already excluded: $appName [$appType]`n"
        } else {
            try {
                Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)/assignments" -Body @{ target = @{"@odata.type"="#microsoft.graph.exclusionGroupAssignmentTarget"; groupId=$groupObj.id}; intent="required" } | Out-Null
                $LogViewer.AppendText("🚫 Added bulk exclusion on '$appName' [$appType].`r`n"); $summary += "🚫 Added: $appName [$appType]`n"
            } catch {
                $LogViewer.AppendText("❌ Failed on '$appName': $_.`r`n"); $summary += "❌ Failed: $appName [$appType]`n"
            }
        }
    }
    $LogViewer.AppendText("📊 Summary:`r`n$summary`r`n")
    
    [System.Windows.Forms.MessageBox]::Show($Form, $summary, "Summary", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}

function Export-SelectedAppDetails {
    param([string[]]$SelectedApps, [System.Windows.Forms.TextBox]$LogViewer)
    $LogViewer.AppendText("🚀 Extracting assignments for selected apps: $($SelectedApps -join ', ')...`r`n")
    $results = @()
    $apps = @()
    $skip = 0
    do {
        $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=999&`$skip=$skip"
        $apps += $resp.value
        $skip += 999
    } while ($resp.'@odata.nextLink')

    foreach ($app in $apps) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($global:StopAudit) { $LogViewer.AppendText("⛔ Stop requested.`r`n"); break }
        if (-not ($SelectedApps | Where-Object { $app.displayName -like "*$_*" })) { continue }

        $assignments = Get-AppAssignments -AppId $app.id
        $LogViewer.AppendText("🔍 App: $($app.displayName) [$($app.'@odata.type')] → Found $($assignments.Count) assignments.`r`n")

        if ($assignments.Count -eq 0) {
            $results += [PSCustomObject]@{
                AppName = $app.displayName
                AppId = $app.id
                AppType = $app.'@odata.type'
                Intent = "(none)"
                Type = "(none)"
                GroupId = "(none)"
                GroupName = "(none)"
            }
            $LogViewer.AppendText("    → No assignments recorded for '$($app.displayName)' [$($app.'@odata.type')]`r`n")
        }

        foreach ($a in $assignments) {
            $groupName = ""
            if ($a.target.groupId) {
                try {
                    $groupObj = Get-MgGroup -GroupId $a.target.groupId -ErrorAction SilentlyContinue
                    if ($groupObj) { $groupName = $groupObj.DisplayName } else { $groupName = "Unknown Group" }
                } catch { $groupName = "Unknown Group" }
            } elseif ($a.target.'@odata.type' -eq "#microsoft.graph.allLicensedUsersAssignmentTarget") {
                $groupName = "All Users"
            } else {
                $groupName = "(unresolved)"
            }

            $results += [PSCustomObject]@{
                AppName = $app.displayName
                AppId = $app.id
                AppType = $app.'@odata.type'
                Intent = $a.intent
                Type = $a.target.'@odata.type'
                GroupId = $a.target.groupId
                GroupName = $groupName
            }
            $LogViewer.AppendText("    → Recorded: '$($app.displayName)' [$($a.intent)] $($a.target.'@odata.type') GroupId=$($a.target.groupId) GroupName=$groupName`r`n")
        }
    }
    $results | Export-Csv -Path "$env:USERPROFILE\Desktop\Intune-Selected-App-Details.csv" -NoTypeInformation
    $LogViewer.AppendText("✅ CSV saved to Desktop: Intune-Selected-App-Details.csv`r`n")
    [System.Windows.Forms.MessageBox]::Show("Export complete. Details for selected apps saved to CSV.", "Export Done")
}


$Form = New-Object system.Windows.Forms.Form
$Form.ClientSize = New-Object System.Drawing.Point(950, 900)
$Form.Text = "Intune App Inclusion & Exclusion Tool - Full Features"

$LabelGroupExc = New-Object System.Windows.Forms.Label
$LabelGroupExc.Text = "AAD Group Name (for operations):"
$LabelGroupExc.AutoSize = $true
$LabelGroupExc.Font = 'Microsoft Sans Serif,10'
$LabelGroupExc.Location = New-Object System.Drawing.Point(20, 15)
$Form.Controls.Add($LabelGroupExc)

$GroupInputExc = New-Object System.Windows.Forms.TextBox
$GroupInputExc.Width = 600
$GroupInputExc.Font = 'Microsoft Sans Serif,10'
$GroupInputExc.Location = New-Object System.Drawing.Point(20, 40)
$Form.Controls.Add($GroupInputExc)

$LabelAppInput = New-Object System.Windows.Forms.Label
$LabelAppInput.Text = "App Names (comma-separated):"
$LabelAppInput.AutoSize = $true
$LabelAppInput.Font = 'Microsoft Sans Serif,10'
$LabelAppInput.Location = New-Object System.Drawing.Point(20, 75)
$Form.Controls.Add($LabelAppInput)

$AppInput = New-Object System.Windows.Forms.TextBox
$AppInput.Width = 800
$AppInput.Font = 'Microsoft Sans Serif,10'
$AppInput.Location = New-Object System.Drawing.Point(20, 100)
$Form.Controls.Add($AppInput)

$LogViewer = New-Object System.Windows.Forms.TextBox
$LogViewer.Multiline = $true
$LogViewer.ScrollBars = 'Vertical'
$LogViewer.ReadOnly = $true
$LogViewer.Font = 'Consolas,9'
$LogViewer.Size = New-Object System.Drawing.Size(880, 520)
$LogViewer.Location = New-Object System.Drawing.Point(20, 140)
$Form.Controls.Add($LogViewer)

$Stop = New-Object System.Windows.Forms.Button
$Stop.Text = "Stop"
$Stop.Width = 120
$Stop.Location = New-Object System.Drawing.Point(20, 680)
$Stop.Add_Click({ $global:StopAudit = $true; $LogViewer.AppendText("⛔ Stop requested.`r`n") })
$Form.Controls.Add($Stop)

$IncludeBtn = New-Object System.Windows.Forms.Button
$IncludeBtn.Text = "Add Inclusion To Selected Apps"
$IncludeBtn.Width = 280
$IncludeBtn.Location = New-Object System.Drawing.Point(160, 680)
$IncludeBtn.Add_Click({
    $global:StopAudit = $false
    $groupName = $GroupInputExc.Text.Trim()
    $appNames = $AppInput.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    if (-not $groupName) { [System.Windows.Forms.MessageBox]::Show("Please enter a group name."); return }
    Add-GroupAsInclusionToApps -GroupName $groupName -AppNameFilters $appNames -LogViewer $LogViewer
})
$Form.Controls.Add($IncludeBtn)

$ExcludeBtn = New-Object System.Windows.Forms.Button
$ExcludeBtn.Text = "Add Exclusion To Selected Apps"
$ExcludeBtn.Width = 280
$ExcludeBtn.Location = New-Object System.Drawing.Point(460, 680)
$ExcludeBtn.Add_Click({
    $global:StopAudit = $false
    $groupName = $GroupInputExc.Text.Trim()
    $appNames = $AppInput.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    if (-not $groupName) { [System.Windows.Forms.MessageBox]::Show("Please enter a group name."); return }
    Add-GroupAsExclusionToApps -GroupName $groupName -AppNameFilters $appNames -LogViewer $LogViewer
})
$Form.Controls.Add($ExcludeBtn)

$BulkExcludeBtn = New-Object System.Windows.Forms.Button
$BulkExcludeBtn.Text = "Bulk Exclude Group From All Apps"
$BulkExcludeBtn.Width = 300
$BulkExcludeBtn.Location = New-Object System.Drawing.Point(20, 730)
$BulkExcludeBtn.Add_Click({
    $global:StopAudit = $false
    $groupName = $GroupInputExc.Text.Trim()
    if (-not $groupName) { [System.Windows.Forms.MessageBox]::Show("Please enter a group name."); return }
    Add-GroupAsBulkExclusionToAllApps -GroupName $groupName -LogViewer $LogViewer
})
$Form.Controls.Add($BulkExcludeBtn)

$RemoveBtn = New-Object System.Windows.Forms.Button
$RemoveBtn.Text = "Remove Assignment From Selected Apps"
$RemoveBtn.Width = 300
$RemoveBtn.Location = New-Object System.Drawing.Point(340, 730)
$RemoveBtn.Add_Click({
    $global:StopAudit = $false
    $groupName = $GroupInputExc.Text.Trim()
    $appNames = $AppInput.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    if (-not $groupName) { [System.Windows.Forms.MessageBox]::Show("Please enter a group name."); return }
    Remove-GroupExclusionFromApps -GroupName $groupName -AppNameFilters $appNames -LogViewer $LogViewer
})
$Form.Controls.Add($RemoveBtn)

$ExportBtn = New-Object System.Windows.Forms.Button
$ExportBtn.Text = "Extract All App Assignments"
$ExportBtn.Width = 260
$ExportBtn.Location = New-Object System.Drawing.Point(660, 730)
$ExportBtn.Add_Click({ Export-AllAppAssignments -LogViewer $LogViewer })
$Form.Controls.Add($ExportBtn)

$ExportSelectedBtn = New-Object System.Windows.Forms.Button
$ExportSelectedBtn.Text = "Export Selected App Details"
$ExportSelectedBtn.Width = 300
$ExportSelectedBtn.Location = New-Object System.Drawing.Point(20, 780)
$ExportSelectedBtn.Add_Click({
    $global:StopAudit = $false
    $selectedApps = $AppInput.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    if ($selectedApps.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Please enter at least one app name."); return
    }
    Export-SelectedAppDetails -SelectedApps $selectedApps -LogViewer $LogViewer
})
$Form.Controls.Add($ExportSelectedBtn)

[void]$Form.ShowDialog()



