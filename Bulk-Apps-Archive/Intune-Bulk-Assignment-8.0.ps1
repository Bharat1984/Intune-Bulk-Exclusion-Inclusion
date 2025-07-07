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

function Add-GroupAsExclusionToApps {
    param ([string]$GroupName, [string[]]$AppNameFilters, [System.Windows.Forms.TextBox]$LogViewer)
    $summary = "Results:`n"
    $groupObj = Resolve-AADGroup -GroupName $GroupName
    if (-not $groupObj) {
        $LogViewer.AppendText("❌ Group '$GroupName' not found.`r`n"); return
    }
    $appsResponse = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=999"
    $apps = $appsResponse.value

    foreach ($app in $apps) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($global:StopAudit) {$LogViewer.AppendText("⛔ Stop requested.`r`n"); break}

        $appName = $app.displayName
        $match = ($AppNameFilters.Count -eq 0) -or ($AppNameFilters | Where-Object { $appName -like "*$_*" })
        if (-not $match) { continue }

        $assignments = Get-AppAssignments -AppId $app.id
        $exists = $assignments | Where-Object { $_.target.groupId -eq $groupObj.id -and $_.target.'@odata.type' -eq "#microsoft.graph.exclusionGroupAssignmentTarget" }
        if ($exists) {
            $LogViewer.AppendText("✅ Already excluded: '$appName'.`r`n")
            $summary += "✅ Already excluded: $appName`n"
        } else {
            try {
                Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)/assignments" -Body @{ target = @{"@odata.type"="#microsoft.graph.exclusionGroupAssignmentTarget"; groupId=$groupObj.id}; intent="required" } | Out-Null
                $LogViewer.AppendText("🚫 Added exclusion on '$appName'.`r`n")
                $summary += "🚫 Added: $appName`n"
            } catch {
                $LogViewer.AppendText("❌ Failed on '$appName': $_.`r`n")
                $summary += "❌ Failed: $appName`n"
            }
        }
    }
    [System.Windows.Forms.MessageBox]::Show($summary, "Summary")
}

function Remove-GroupExclusionFromApps {
    param ([string]$GroupName, [string[]]$AppNameFilters, [System.Windows.Forms.TextBox]$LogViewer)
    $summary = "Results:`n"
    $groupObj = Resolve-AADGroup -GroupName $GroupName
    if (-not $groupObj) {
        $LogViewer.AppendText("❌ Group '$GroupName' not found.`r`n"); return
    }
    $appsResponse = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=999"
    $apps = $appsResponse.value

    foreach ($app in $apps) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($global:StopAudit) {$LogViewer.AppendText("⛔ Stop requested.`r`n"); break}

        $appName = $app.displayName
        $match = ($AppNameFilters.Count -eq 0) -or ($AppNameFilters | Where-Object { $appName -like "*$_*" })
        if (-not $match) { continue }

        $assignments = Get-AppAssignments -AppId $app.id
        $groupAssignments = $assignments | Where-Object { $_.target.groupId -eq $groupObj.id -and $_.target.'@odata.type' -eq "#microsoft.graph.exclusionGroupAssignmentTarget" }
        foreach ($assignment in $groupAssignments) {
            try {
                Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)/assignments/$($assignment.id)" | Out-Null
                $LogViewer.AppendText("🧹 Removed exclusion on '$appName'.`r`n")
                $summary += "🧹 Removed: $appName`n"
            } catch {
                $LogViewer.AppendText("❌ Failed to remove on '$appName': $_.`r`n")
                $summary += "❌ Failed: $appName`n"
            }
        }
    }
    [System.Windows.Forms.MessageBox]::Show($summary, "Summary")
}

function Export-AllAppAssignments {
    param([System.Windows.Forms.TextBox]$LogViewer)
    $LogViewer.AppendText("🚀 Extracting all assignments...`r`n")
    $results = @()
    $appsResponse = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=999"
    $apps = $appsResponse.value

    foreach ($app in $apps) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($global:StopAudit) {$LogViewer.AppendText("⛔ Stop requested.`r`n"); break}
        $assignments = Get-AppAssignments -AppId $app.id
        foreach ($a in $assignments) {
            $results += [PSCustomObject]@{ AppName=$app.displayName; AppId=$app.id; Intent=$a.intent; Type=$a.target.'@odata.type'; GroupId=$a.target.groupId }
        }
    }
    $results | Export-Csv -Path "$env:USERPROFILE\Desktop\Intune-All-App-Assignments.csv" -NoTypeInformation
    $LogViewer.AppendText("✅ CSV saved to Desktop.`r`n")
}

$Form = New-Object system.Windows.Forms.Form
$Form.ClientSize = New-Object System.Drawing.Point(950, 750)
$Form.Text = "Intune App Exclusion Tool - Full"

$LabelGroupExc = New-Object System.Windows.Forms.Label
$LabelGroupExc.Text = "AAD Group Name (for exclusions):"
$LabelGroupExc.AutoSize = $true
$LabelGroupExc.Font = 'Microsoft Sans Serif,10'
$LabelGroupExc.Location = New-Object System.Drawing.Point(20, 15)
$Form.Controls.Add($LabelGroupExc)

$GroupInputExc = New-Object System.Windows.Forms.TextBox
$GroupInputExc.Font = 'Microsoft Sans Serif,10'
$GroupInputExc.Width = 600
$GroupInputExc.Location = New-Object System.Drawing.Point(20, 40)
$Form.Controls.Add($GroupInputExc)

$LabelAppInput = New-Object System.Windows.Forms.Label
$LabelAppInput.Text = "App Names (comma-separated):"
$LabelAppInput.AutoSize = $true
$LabelAppInput.Font = 'Microsoft Sans Serif,10'
$LabelAppInput.Location = New-Object System.Drawing.Point(20, 75)
$Form.Controls.Add($LabelAppInput)

$AppInput = New-Object System.Windows.Forms.TextBox
$AppInput.Font = 'Microsoft Sans Serif,10'
$AppInput.Width = 800
$AppInput.Location = New-Object System.Drawing.Point(20, 100)
$Form.Controls.Add($AppInput)

$LogViewer = New-Object System.Windows.Forms.TextBox
$LogViewer.Multiline = $true
$LogViewer.ScrollBars = 'Vertical'
$LogViewer.ReadOnly = $true
$LogViewer.Font = 'Consolas,9'
$LogViewer.Size = New-Object System.Drawing.Size(880, 500)
$LogViewer.Location = New-Object System.Drawing.Point(20, 140)
$Form.Controls.Add($LogViewer)

$Stop = New-Object System.Windows.Forms.Button
$Stop.Text = "Stop"
$Stop.Width = 120
$Stop.Location = New-Object System.Drawing.Point(20, 660)
$Stop.Add_Click({ $global:StopAudit = $true; $LogViewer.AppendText("⛔ Stop requested.`r`n") })
$Form.Controls.Add($Stop)

$AddBtn = New-Object System.Windows.Forms.Button
$AddBtn.Text = "Add Exclusion To Selected Apps"
$AddBtn.Width = 280
$AddBtn.Location = New-Object System.Drawing.Point(160, 660)
$AddBtn.Add_Click({
    $global:StopAudit = $false
    $groupName = $GroupInputExc.Text.Trim()
    $appNames = $AppInput.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    if (-not $groupName) {
        [System.Windows.Forms.MessageBox]::Show("Please enter a group name."); return
    }
    Add-GroupAsExclusionToApps -GroupName $groupName -AppNameFilters $appNames -LogViewer $LogViewer
})
$Form.Controls.Add($AddBtn)

$RemoveBtn = New-Object System.Windows.Forms.Button
$RemoveBtn.Text = "Remove Exclusion From Selected Apps"
$RemoveBtn.Width = 300
$RemoveBtn.Location = New-Object System.Drawing.Point(460, 660)
$RemoveBtn.Add_Click({
    $global:StopAudit = $false
    $groupName = $GroupInputExc.Text.Trim()
    $appNames = $AppInput.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    if (-not $groupName) {
        [System.Windows.Forms.MessageBox]::Show("Please enter a group name."); return
    }
    Remove-GroupExclusionFromApps -GroupName $groupName -AppNameFilters $appNames -LogViewer $LogViewer
})
$Form.Controls.Add($RemoveBtn)

$ExportBtn = New-Object System.Windows.Forms.Button
$ExportBtn.Text = "Extract All App Assignments"
$ExportBtn.Width = 260
$ExportBtn.Location = New-Object System.Drawing.Point(780, 660)
$ExportBtn.Add_Click({ Export-AllAppAssignments -LogViewer $LogViewer })
$Form.Controls.Add($ExportBtn)

[void]$Form.ShowDialog()