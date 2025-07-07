try {
    Connect-MgGraph -Scopes "DeviceManagementApps.ReadWrite.All", "Group.Read.All"
} catch {
    [System.Windows.Forms.MessageBox]::Show("Graph connection failed: $_")
    return
}

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

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

    # Delete any existing exclusion for this group
    $existingExclusions = $CurrentAssignments | Where-Object {
        $_.Target.AdditionalProperties['groupId'] -eq $groupObj.Id -and
        $_.Target.AdditionalProperties['@odata.type'] -eq "#microsoft.graph.exclusionGroupAssignmentTarget"
    }

    foreach ($exclusion in $existingExclusions) {
        Remove-MgDeviceAppManagementMobileAppAssignment -MobileAppId $AppId -MobileAppAssignmentId $exclusion.Id
        $LogViewer.AppendText("🧹 Removed old exclusion for '$($groupObj.DisplayName)' (was intent: $($exclusion.Intent)).`r`n")
        $Summary.Value += "🧹 Removed old exclusion for $($groupObj.DisplayName) (was $($exclusion.Intent))`n"
    }

    # Create exclusion for required
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
$Form.ClientSize = New-Object System.Drawing.Point(950, 600)
$Form.Text = "Intune App Assignment Tool"
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
$LogViewer.Size = New-Object System.Drawing.Size(880, 200)
$LogViewer.Location = New-Object System.Drawing.Point(20, 230)
$Form.Controls.Add($LogViewer)

$ShowSummaryCheckbox = New-Object System.Windows.Forms.CheckBox
$ShowSummaryCheckbox.Text = "Show summary popup after assignment"
$ShowSummaryCheckbox.Checked = $true
$ShowSummaryCheckbox.AutoSize = $true
$ShowSummaryCheckbox.Location = New-Object System.Drawing.Point(20, 450)
$Form.Controls.Add($ShowSummaryCheckbox)

$Submit = New-Object System.Windows.Forms.Button
$Submit.Text = "Assign"
$Submit.Width = 120
$Submit.Height = 40
$Submit.Location = New-Object System.Drawing.Point(780, 450)
$Form.Controls.Add($Submit)

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

[void]$Form.ShowDialog()
