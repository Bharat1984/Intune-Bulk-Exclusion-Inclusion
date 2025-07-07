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

function Add-GroupAsExclusionToAllApps {
    param (
        [string]$GroupName,
        [string[]]$AppNameFilters,
        [System.Windows.Forms.TextBox]$LogViewer
    )

    $groupObj = Resolve-AADGroup -GroupName $GroupName
    if (-not $groupObj) {
        $LogViewer.AppendText("❌ Group '$GroupName' not found in AAD.`r`n")
        return
    }

    $LogViewer.AppendText("🚀 Adding '$($groupObj.displayName)' as exclusion to matching apps...`r`n")
    $appsResponse = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=999"
    $apps = $appsResponse.value

    foreach ($app in $apps) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($global:StopAudit) {
            $LogViewer.AppendText("⛔ Stop requested by user. Exiting global exclusion.`r`n")
            return
        }

        $appName = $app.displayName
        $match = ($AppNameFilters.Count -eq 0) -or ($AppNameFilters | Where-Object { $appName -like "*$_*" })

        if (-not $match) { continue }

        $assignments = Get-AppAssignments -AppId $app.id
        $alreadyExcluded = $assignments | Where-Object {
            $_.target.groupId -eq $groupObj.id -and $_.target.'@odata.type' -eq "#microsoft.graph.exclusionGroupAssignmentTarget"
        }

        if ($alreadyExcluded) {
            $LogViewer.AppendText("✅ '$($groupObj.displayName)' already excluded on '$appName'.`r`n")
        } else {
            try {
                Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)/assignments" -Body @{
                    target = @{ "@odata.type" = "#microsoft.graph.exclusionGroupAssignmentTarget"; groupId = $groupObj.id }
                    intent = "required"
                } | Out-Null
                $LogViewer.AppendText("🚫 Added exclusion for '$($groupObj.displayName)' on '$appName'.`r`n")
            } catch {
                $LogViewer.AppendText("❌ Failed to add exclusion for '$($groupObj.displayName)' on '$appName'.`r`n")
            }
        }
    }
    $LogViewer.AppendText("✅ Done adding exclusions across selected apps.`r`n")
}

$Form = New-Object system.Windows.Forms.Form
$Form.ClientSize = New-Object System.Drawing.Point(950, 750)
$Form.Text = "Intune App Exclusion Tool - Filtered by App Names"

$LabelGroupExc = New-Object System.Windows.Forms.Label
$LabelGroupExc.Text = "Excluded AAD Group Names (comma-separated):"
$LabelGroupExc.AutoSize = $true
$LabelGroupExc.Location = New-Object System.Drawing.Point(20, 20)
$Form.Controls.Add($LabelGroupExc)

$GroupInputExc = New-Object System.Windows.Forms.TextBox
$GroupInputExc.Width = 400
$GroupInputExc.Location = New-Object System.Drawing.Point(20, 45)
$Form.Controls.Add($GroupInputExc)

$LabelAppInput = New-Object System.Windows.Forms.Label
$LabelAppInput.Text = "App Names (comma-separated):"
$LabelAppInput.AutoSize = $true
$LabelAppInput.Location = New-Object System.Drawing.Point(20, 80)
$Form.Controls.Add($LabelAppInput)

$AppInput = New-Object System.Windows.Forms.TextBox
$AppInput.Width = 800
$AppInput.Location = New-Object System.Drawing.Point(20, 105)
$Form.Controls.Add($AppInput)

$LogViewer = New-Object System.Windows.Forms.TextBox
$LogViewer.Multiline = $true
$LogViewer.ScrollBars = 'Vertical'
$LogViewer.ReadOnly = $true
$LogViewer.Size = New-Object System.Drawing.Size(880, 500)
$LogViewer.Location = New-Object System.Drawing.Point(20, 140)
$Form.Controls.Add($LogViewer)

$Stop = New-Object System.Windows.Forms.Button
$Stop.Text = "Stop Audit"
$Stop.Width = 120
$Stop.Height = 40
$Stop.Location = New-Object System.Drawing.Point(20, 660)
$Stop.Add_Click({
    $global:StopAudit = $true
    $LogViewer.AppendText("⛔ Stop requested by user.`r`n")
})
$Form.Controls.Add($Stop)

$GlobalExclusion = New-Object System.Windows.Forms.Button
$GlobalExclusion.Text = "Add Exclusion To Selected Apps"
$GlobalExclusion.Width = 280
$GlobalExclusion.Height = 40
$GlobalExclusion.Location = New-Object System.Drawing.Point(160, 660)
$GlobalExclusion.Add_Click({
    $global:StopAudit = $false
    $groupName = $GroupInputExc.Text.Split(",")[0].Trim()
    $appNames = $AppInput.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    if (-not $groupName) {
        [System.Windows.Forms.MessageBox]::Show("Please enter at least one group name.")
        return
    }
    Add-GroupAsExclusionToAllApps -GroupName $groupName -AppNameFilters $appNames -LogViewer $LogViewer
})
$Form.Controls.Add($GlobalExclusion)

[void]$Form.ShowDialog()
