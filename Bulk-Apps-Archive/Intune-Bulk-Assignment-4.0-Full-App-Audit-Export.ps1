try {
    Connect-MgGraph -Scopes "DeviceManagementApps.ReadWrite.All", "Group.Read.All"
} catch {
    [System.Windows.Forms.MessageBox]::Show("Graph connection failed: $_")
    return
}

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

$global:StopAudit = $false

# ================================================================
# Function: Set-IntuneAppExclusion (bulletproof with Intent)
# ================================================================
function Set-IntuneAppExclusion {
    param (
        [string]$AppId,
        [string]$AppName,
        [object[]]$CurrentAssignments,
        [string]$GroupName,
        [System.Windows.Forms.TextBox]$LogViewer,
        [ref]$Summary
    )

    $groupObj = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction SilentlyContinue
    if (-not $groupObj) {
        $LogViewer.AppendText("❌ Excluded group '$GroupName' not found.`r`n")
        return
    }

    $existingExclusions = $CurrentAssignments | Where-Object {
        $_.Target.AdditionalProperties['groupId'] -eq $groupObj.Id -and
        $_.Target.AdditionalProperties['@odata.type'] -eq "#microsoft.graph.exclusionGroupAssignmentTarget"
    }

    foreach ($exclusion in $existingExclusions) {
        Remove-MgDeviceAppManagementMobileAppAssignment -MobileAppId $AppId -MobileAppAssignmentId $exclusion.Id
        $LogViewer.AppendText("🧹 Removed old exclusion for '$($groupObj.DisplayName)' (was intent: $($exclusion.Intent)).`r`n")
        $Summary.Value += "🧹 Removed old exclusion for $($groupObj.DisplayName) (was $($exclusion.Intent))`n"
    }

    try {
        New-MgDeviceAppManagementMobileAppAssignment -MobileAppId $AppId -BodyParameter @{
            target = @{
                "@odata.type" = "#microsoft.graph.exclusionGroupAssignmentTarget"
                groupId = $groupObj.Id
            }
            Intent = "required"
        }
        $LogViewer.AppendText("🚫 Assigned exclusion for '$($groupObj.DisplayName)' with Intent 'required'.`r`n")
        $Summary.Value += "🚫 $AppName → $($groupObj.DisplayName) [Excluded] (required)`n"
    } catch {
        $LogViewer.AppendText("❌ Failed to assign exclusion to '$($groupObj.DisplayName)' with Intent 'required'.`r`n")
        $Summary.Value += "❌ $AppName → $($groupObj.DisplayName) [Excluded] FAILED (required)`n"
    }
}

# ================================================================
# GUI Form
# ================================================================
$Form = New-Object system.Windows.Forms.Form
$Form.ClientSize = New-Object System.Drawing.Point(950, 700)
$Form.Text = "Intune App Assignment Tool with Audit & Stop"
$Form.TopMost = $false

$LabelGroupInc = New-Object System.Windows.Forms.Label
$LabelGroupInc.Text = "Included AAD Group Names (comma-separated):"
$LabelGroupInc.AutoSize = $true
$LabelGroupInc.Location = New-Object System.Drawing.Point(20, 20)
$Form.Controls.Add($LabelGroupInc)

$GroupInputInc = New-Object System.Windows.Forms.TextBox
$GroupInputInc.Width = 400
$GroupInputInc.Location = New-Object System.Drawing.Point(20, 45)
$Form.Controls.Add($GroupInputInc)

$LabelGroupExc = New-Object System.Windows.Forms.Label
$LabelGroupExc.Text = "Excluded AAD Group Names (comma-separated):"
$LabelGroupExc.AutoSize = $true
$LabelGroupExc.Location = New-Object System.Drawing.Point(20, 90)
$Form.Controls.Add($LabelGroupExc)

$GroupInputExc = New-Object System.Windows.Forms.TextBox
$GroupInputExc.Width = 400
$GroupInputExc.Location = New-Object System.Drawing.Point(20, 115)
$Form.Controls.Add($GroupInputExc)

$LabelAppInput = New-Object System.Windows.Forms.Label
$LabelAppInput.Text = "App Names (comma-separated):"
$LabelAppInput.AutoSize = $true
$LabelAppInput.Location = New-Object System.Drawing.Point(20, 160)
$Form.Controls.Add($LabelAppInput)

$AppInput = New-Object System.Windows.Forms.TextBox
$AppInput.Width = 800
$AppInput.Location = New-Object System.Drawing.Point(20, 185)
$Form.Controls.Add($AppInput)

$LogViewer = New-Object System.Windows.Forms.TextBox
$LogViewer.Multiline = $true
$LogViewer.ScrollBars = 'Vertical'
$LogViewer.ReadOnly = $true
$LogViewer.Size = New-Object System.Drawing.Size(880, 300)
$LogViewer.Location = New-Object System.Drawing.Point(20, 230)
$Form.Controls.Add($LogViewer)

$ShowSummaryCheckbox = New-Object System.Windows.Forms.CheckBox
$ShowSummaryCheckbox.Text = "Show summary popup after assignment"
$ShowSummaryCheckbox.Checked = $true
$ShowSummaryCheckbox.AutoSize = $true
$ShowSummaryCheckbox.Location = New-Object System.Drawing.Point(20, 550)
$Form.Controls.Add($ShowSummaryCheckbox)

# ================================================================
# Buttons
# ================================================================
$Submit = New-Object System.Windows.Forms.Button
$Submit.Text = "Assign"
$Submit.Width = 120
$Submit.Height = 40
$Submit.Location = New-Object System.Drawing.Point(780, 550)
$Form.Controls.Add($Submit)

$Export = New-Object System.Windows.Forms.Button
$Export.Text = "Export CSV Audit"
$Export.Width = 160
$Export.Height = 40
$Export.Location = New-Object System.Drawing.Point(600, 550)
$Form.Controls.Add($Export)

$Stop = New-Object System.Windows.Forms.Button
$Stop.Text = "Stop Audit"
$Stop.Width = 120
$Stop.Height = 40
$Stop.Location = New-Object System.Drawing.Point(420, 550)
$Form.Controls.Add($Stop)

$Stop.Add_Click({
    $global:StopAudit = $true
    $LogViewer.AppendText("⛔ Stop requested by user.`r`n")
})

# ================================================================
# Submit Click Logic
# ================================================================
$Submit.Add_Click({
    $includedGroups = $GroupInputInc.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $excludedGroups = $GroupInputExc.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $appNames       = $AppInput.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

    if (($includedGroups.Count -eq 0) -and ($excludedGroups.Count -eq 0)) {
        [System.Windows.Forms.MessageBox]::Show("Please enter at least one included or excluded group.")
        return
    }
    if ($appNames.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Please enter at least one app name.")
        return
    }

    $summary = "Assignment Results:`n"

    foreach ($appName in $appNames) {
        $appObj = Get-MgDeviceAppManagementMobileApp -All -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName.ToLower().Contains($appName.ToLower()) } | Select-Object -First 1

        if (-not $appObj) {
            $LogViewer.AppendText("❌ App '$appName' not found.`r`n")
            $summary += "❌ $appName → Not Found`n"
            continue
        }

        $currentAssignments = Get-MgDeviceAppManagementMobileAppAssignment -MobileAppId $appObj.Id

        # INCLUDED groups
        foreach ($groupName in $includedGroups) {
            $groupObj = Get-MgGroup -Filter "displayName eq '$groupName'" -ErrorAction SilentlyContinue
            if (-not $groupObj) {
                $LogViewer.AppendText("❌ Included group '$groupName' not found.`r`n")
                continue
            }

            $existing = $currentAssignments | Where-Object {
                $_.Target.AdditionalProperties['groupId'] -eq $groupObj.Id -and
                $_.Target.AdditionalProperties['@odata.type'] -eq "#microsoft.graph.groupAssignmentTarget"
            }

            if ($existing) {
                Remove-MgDeviceAppManagementMobileAppAssignment -MobileAppId $appObj.Id -MobileAppAssignmentId $existing.Id
                $LogViewer.AppendText("🧹 Removed existing included assignment for '$($groupObj.DisplayName)'`r`n")
            }

            try {
                New-MgDeviceAppManagementMobileAppAssignment -MobileAppId $appObj.Id -BodyParameter @{
                    target = @{ "@odata.type" = "#microsoft.graph.groupAssignmentTarget"; groupId = $groupObj.Id }
                    Intent = "required"
                }
                $LogViewer.AppendText("✅ Assigned '$($appObj.DisplayName)' to '$($groupObj.DisplayName)' (Included)`r`n")
                $summary += "✅ $($appObj.DisplayName) → $($groupObj.DisplayName) [Included]`n"
            } catch {
                $LogViewer.AppendText("❌ Failed to assign '$($appObj.DisplayName)' to '$groupName' (Included)`r`n")
                $summary += "❌ $($appObj.DisplayName) → $groupName [Included] FAILED`n"
            }
        }

        # EXCLUDED groups
        foreach ($groupName in $excludedGroups) {
            Set-IntuneAppExclusion -AppId $appObj.Id -AppName $appObj.DisplayName `
                -CurrentAssignments $currentAssignments -GroupName $groupName `
                -LogViewer $LogViewer -Summary ([ref]$summary)
        }
    }

    if ($ShowSummaryCheckbox.Checked) {
        [System.Windows.Forms.MessageBox]::Show($summary, "Assignment Summary", 'OK', 'Information')
    }
})

# ================================================================
# Export Audit Click Logic
# ================================================================
$Export.Add_Click({
    $global:StopAudit = $false
    $LogViewer.AppendText("🚀 Starting audit export...`r`n")
    $results = @()
    $totalApps = 0
    $totalAssignments = 0

    $apps = Get-MgDeviceAppManagementMobileApp -All

    foreach ($app in $apps) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($global:StopAudit) {
            $LogViewer.AppendText("⛔ Audit stopped by user.`r`n")
            break
        }

        $totalApps++
        $appName = $app.DisplayName
        $appId   = $app.Id
        $LogViewer.AppendText("📦 Checking app: $appName ($appId)`r`n")

        $assignments = Get-MgDeviceAppManagementMobileAppAssignment -MobileAppId $appId
        $totalAssignments += $assignments.Count
        $LogViewer.AppendText("✅ Found $($assignments.Count) assignments.`r`n")

        foreach ($assignment in $assignments) {
            [System.Windows.Forms.Application]::DoEvents()
            if ($global:StopAudit) {
                $LogViewer.AppendText("⛔ Audit stopped by user.`r`n")
                break
            }

            $targetType = $assignment.Target.AdditionalProperties['@odata.type']
            $groupId    = $assignment.Target.AdditionalProperties['groupId']
            $intent     = $assignment.Intent
            $groupName  = ""

            if ($groupId) {
                $groupObj = Get-MgGroup -GroupId $groupId -ErrorAction SilentlyContinue
                if ($groupObj) {
                    $groupName = $groupObj.DisplayName
                    $LogViewer.AppendText("🔎 Group: $groupName`r`n")
                } else {
                    $LogViewer.AppendText("⚠️ Could not resolve groupId: $groupId`r`n")
                }
            }

            $results += [PSCustomObject]@{
                AppName   = $appName
                AppId     = $appId
                Intent    = $intent
                Type      = $targetType
                GroupId   = $groupId
                GroupName = $groupName
            }
        }
    }

    # Always write partial or full results
    $csvPath = "$env:USERPROFILE\Desktop\Intune-App-Assignments-Audit.csv"
    $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    $LogViewer.AppendText("✅ Audit CSV saved to Desktop: Intune-App-Assignments-Audit.csv`r`n")
    $LogViewer.AppendText("📊 Summary: Processed $totalApps apps, found $totalAssignments assignments.`r`n")
    Start-Process "explorer.exe" -ArgumentList "/select,`"$csvPath`""
})


[void]$Form.ShowDialog()
