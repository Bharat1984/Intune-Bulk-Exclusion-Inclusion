# Intune Win32 App Assignment Tool – Manual Mode (No Preloading for Speed)

try {
    Connect-MgGraph -Scopes "DeviceManagementApps.ReadWrite.All", "Group.Read.All"
} catch {
    [System.Windows.Forms.MessageBox]::Show("Graph connection failed: $_")
    return
}

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

# Form Setup
$Form = New-Object system.Windows.Forms.Form
$Form.ClientSize = New-Object System.Drawing.Point(950, 600)
$Form.Text = "Intune Win32 App Manual Assignment"
$Form.TopMost = $false

$logPath = "$env:TEMP\IntuneAssignmentLog.log"

# Included Group Input
$LabelGroupInc = New-Object System.Windows.Forms.Label
$LabelGroupInc.Text = "Included AAD Group Names (comma-separated):"
$LabelGroupInc.AutoSize = $true
$LabelGroupInc.Location = New-Object System.Drawing.Point(20, 20)
$Form.Controls.Add($LabelGroupInc)

$GroupInputInc = New-Object System.Windows.Forms.TextBox
$GroupInputInc.Width = 400
$GroupInputInc.Location = New-Object System.Drawing.Point(20, 45)
$Form.Controls.Add($GroupInputInc)

# Excluded Group Input
$LabelGroupExc = New-Object System.Windows.Forms.Label
$LabelGroupExc.Text = "Excluded AAD Group Names (comma-separated):"
$LabelGroupExc.AutoSize = $true
$LabelGroupExc.Location = New-Object System.Drawing.Point(20, 90)
$Form.Controls.Add($LabelGroupExc)

$GroupInputExc = New-Object System.Windows.Forms.TextBox
$GroupInputExc.Width = 400
$GroupInputExc.Location = New-Object System.Drawing.Point(20, 115)
$Form.Controls.Add($GroupInputExc)

# Manual Win32 App Name Input
$LabelAppInput = New-Object System.Windows.Forms.Label
$LabelAppInput.Text = "Win32 App Names (comma-separated):"
$LabelAppInput.AutoSize = $true
$LabelAppInput.Location = New-Object System.Drawing.Point(20, 160)
$Form.Controls.Add($LabelAppInput)

$AppInput = New-Object System.Windows.Forms.TextBox
$AppInput.Width = 800
$AppInput.Location = New-Object System.Drawing.Point(20, 185)
$Form.Controls.Add($AppInput)

# Log Viewer
$LogViewer = New-Object System.Windows.Forms.TextBox
$LogViewer.Multiline = $true
$LogViewer.ScrollBars = 'Vertical'
$LogViewer.ReadOnly = $true
$LogViewer.Size = New-Object System.Drawing.Size(880, 200)
$LogViewer.Location = New-Object System.Drawing.Point(20, 230)
$Form.Controls.Add($LogViewer)

# Summary Popup Checkbox
$ShowSummaryCheckbox = New-Object System.Windows.Forms.CheckBox
$ShowSummaryCheckbox.Text = "Show summary popup after assignment"
$ShowSummaryCheckbox.Checked = $true
$ShowSummaryCheckbox.AutoSize = $true
$ShowSummaryCheckbox.Location = New-Object System.Drawing.Point(20, 450)
$Form.Controls.Add($ShowSummaryCheckbox)

# Submit Button
$Submit = New-Object System.Windows.Forms.Button
$Submit.Text = "Assign"
$Submit.Width = 120
$Submit.Height = 40
$Submit.Location = New-Object System.Drawing.Point(780, 450)
$Form.Controls.Add($Submit)

# Submit Click Logic
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
        # Lookup App from Name
        #$appObj = Get-MgDeviceAppManagementMobileApp -Filter "displayName eq '$appName'" -ErrorAction SilentlyContinue |
                  #Where-Object { $_.'@odata.type' -eq '#microsoft.graph.win32LobApp' }

      $appObj = Get-MgDeviceAppManagementMobileApp -All |
                Where-Object {
                    $_.DisplayName.ToLower().Contains($appName.Trim().ToLower())
                } | Select-Object -First 1




        if (-not $appObj) {
            $LogViewer.AppendText("❌ App '$appName' not found.`r`n")
            $summary += "❌ $appName → Not Found`n"
            continue
        }

        # Included Assignments
        foreach ($groupName in $includedGroups) {
            $groupObj = Get-MgGroup -Filter "displayName eq '$groupName'" -ErrorAction SilentlyContinue
            if (-not $groupObj) {
                $LogViewer.AppendText("❌ Included group '$groupName' not found.`r`n")
                continue
            }

            try {
                New-MgDeviceAppManagementMobileAppAssignment -MobileAppId $appObj.Id -BodyParameter @{
                    target = @{ "@odata.type" = "#microsoft.graph.groupAssignmentTarget"; groupId = $groupObj.Id }
                    installIntent = "required"
                }
                $LogViewer.AppendText("✅ Assigned '$($appObj.DisplayName)' to '$($groupObj.DisplayName)' (Included)`r`n")
                $summary += "✅ $($appObj.DisplayName) → $($groupObj.DisplayName) [Included]`n"
            } catch {
                $LogViewer.AppendText("❌ Failed to assign '$($appObj.DisplayName)' to '$groupName' (Included)`r`n")
                $summary += "❌ $($appObj.DisplayName) → $groupName [Included] FAILED`n"
            }
        }

        # Excluded Assignments
        foreach ($groupName in $excludedGroups) {
            $groupObj = Get-MgGroup -Filter "displayName eq '$groupName'" -ErrorAction SilentlyContinue
            if (-not $groupObj) {
                $LogViewer.AppendText("❌ Excluded group '$groupName' not found.`r`n")
                continue
            }

            try {
                New-MgDeviceAppManagementMobileAppAssignment -MobileAppId $appObj.Id -BodyParameter @{
                    target = @{ "@odata.type" = "#microsoft.graph.groupAssignmentTarget"; groupId = $groupObj.Id }
                    installIntent = "uninstall"
                }
                $LogViewer.AppendText("✅ Assigned '$($appObj.DisplayName)' to '$($groupObj.DisplayName)' (Excluded)`r`n")
                $summary += "✅ $($appObj.DisplayName) → $($groupObj.DisplayName) [Excluded]`n"
            } catch {
                $LogViewer.AppendText("❌ Failed to assign '$($appObj.DisplayName)' to '$groupName' (Excluded)`r`n")
                $summary += "❌ $($appObj.DisplayName) → $groupName [Excluded] FAILED`n"
            }
        }
    }

    if ($ShowSummaryCheckbox.Checked) {
        [System.Windows.Forms.MessageBox]::Show($summary, "Assignment Summary", 'OK', 'Information')
    }
})

# Run Form
[void]$Form.ShowDialog()
