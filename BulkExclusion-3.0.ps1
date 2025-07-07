try {
    Connect-MgGraph -Scopes "DeviceManagementConfiguration.ReadWrite.All", "Group.Read.All"
} catch {
    [System.Windows.Forms.MessageBox]::Show("Graph connection failed: $_")
    return
}

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

$global:StopProcess = $false

function Resolve-AADGroup {
    param([string]$GroupName)
    $filter = "displayName eq '$GroupName'"
    $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$filter"
    return $resp.value | Select-Object -First 1
}

function Log {
    param([System.Windows.Forms.TextBox]$box, [string]$msg)
    $box.AppendText("$msg`r`n")
    $box.ScrollToCaret()
}

function Process-Policies {
    param($groupId, [System.Windows.Forms.TextBox]$logBox, $filter, $makeInclude)
    $types = @(
        @{ name='Device Config Policy'; uri='deviceManagement/deviceConfigurations'; sc=$false },
        @{ name='Settings Catalog'; uri='deviceManagement/configurationPolicies'; sc=$true }
    )
    foreach ($t in $types) {
        $policies = (Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/$($t.uri)" -Method GET).value
        if ($filter) {
            if ($t.sc) { $policies = $policies | Where-Object { $_.name -match $filter } }
            else { $policies = $policies | Where-Object { $_.displayName -match $filter } }
        }
        foreach ($policy in $policies) {
            [System.Windows.Forms.Application]::DoEvents()
            if ($global:StopProcess) { Log $logBox "⛔ Stop requested."; return }
            $pName = if ($t.sc) { $policy.name } else { $policy.displayName }
            Log $logBox "🔍 Processing $($t.name): $pName"
            $assignUri = if ($t.sc) {
                "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($policy.id)/assignments"
            } else {
                "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$($policy.id)/groupAssignments"
            }
            $assigns = (Invoke-MgGraphRequest -Method GET -Uri $assignUri).value
            $keep = @()
            foreach ($a in $assigns) {
                $assignedGroupId = if ($t.sc) { $a.target.groupId } else { $a.targetGroupId }
                $odataType = if ($t.sc) { $a.target.'@odata.type' } else {
                    if ($a.excludeGroup) { "#microsoft.graph.exclusionGroupAssignmentTarget" }
                    else { "#microsoft.graph.groupAssignmentTarget" }
                }
                if ($assignedGroupId -eq $groupId) {
                    if ($makeInclude -and $odataType -eq "#microsoft.graph.exclusionGroupAssignmentTarget") {
                        Log $logBox "🚫 Removing exclusion to set include."
                    } elseif (-not $makeInclude -and $odataType -eq "#microsoft.graph.groupAssignmentTarget") {
                        Log $logBox "🚫 Removing inclusion to set exclude."
                    } else { continue }
                } else {
                    $keep += $a
                }
            }
            if ($t.sc) {
                if ($makeInclude) {
                    $newAssign = @{ target = @{ "@odata.type"="#microsoft.graph.groupAssignmentTarget"; groupId=$groupId } }
                } else {
                    $newAssign = @{ target = @{ "@odata.type"="#microsoft.graph.exclusionGroupAssignmentTarget"; groupId=$groupId } }
                }
            } else {
                $newAssign = @{ target = @{
                    "@odata.type"= (if ($makeInclude) {"#microsoft.graph.groupAssignmentTarget"} else {"#microsoft.graph.exclusionGroupAssignmentTarget"});
                    groupId=$groupId
                }}
            }
            $keep += $newAssign
            $json = @{ assignments = $keep } | ConvertTo-Json -Depth 5
            Invoke-MgGraphRequest -Uri $assignUri.Replace("/assignments","/assign") -Method POST -Body $json -ContentType "application/json"
            Log $logBox "✏️ Updated $($t.name): $pName"
        }
    }
    Log $logBox "`n🎉 Completed all updates."
}

# Build GUI
$Form = New-Object system.Windows.Forms.Form
$Form.ClientSize = New-Object System.Drawing.Point(950, 600)
$Form.Text = "Intune Policy Inclusion & Exclusion Tool - Separate Controls"

$LabelGroup = New-Object System.Windows.Forms.Label
$LabelGroup.Text = "AAD Group Name:"
$LabelGroup.Location = New-Object System.Drawing.Point(20, 20)
$LabelGroup.AutoSize = $true
$Form.Controls.Add($LabelGroup)

$GroupInput = New-Object System.Windows.Forms.TextBox
$GroupInput.Width = 400
$GroupInput.Location = New-Object System.Drawing.Point(150, 18)
$Form.Controls.Add($GroupInput)

$LabelFilter = New-Object System.Windows.Forms.Label
$LabelFilter.Text = "Policy Name Filter (regex optional):"
$LabelFilter.Location = New-Object System.Drawing.Point(20, 60)
$LabelFilter.AutoSize = $true
$Form.Controls.Add($LabelFilter)

$FilterInput = New-Object System.Windows.Forms.TextBox
$FilterInput.Width = 400
$FilterInput.Location = New-Object System.Drawing.Point(250, 58)
$Form.Controls.Add($FilterInput)

$LogBox = New-Object System.Windows.Forms.TextBox
$LogBox.Multiline = $true
$LogBox.ScrollBars = 'Vertical'
$LogBox.ReadOnly = $true
$LogBox.Size = New-Object System.Drawing.Size(900, 350)
$LogBox.Location = New-Object System.Drawing.Point(20, 100)
$Form.Controls.Add($LogBox)

$StopBtn = New-Object System.Windows.Forms.Button
$StopBtn.Text = "Stop"
$StopBtn.Width = 120
$StopBtn.Location = New-Object System.Drawing.Point(20, 470)
$StopBtn.Add_Click({ $global:StopProcess = $true; Log $LogBox "⛔ Stop requested by user." })
$Form.Controls.Add($StopBtn)

$InclBtn = New-Object System.Windows.Forms.Button
$InclBtn.Text = "Run Inclusion"
$InclBtn.Width = 200
$InclBtn.Location = New-Object System.Drawing.Point(160, 470)
$InclBtn.Add_Click({
    $global:StopProcess = $false
    $LogBox.Clear()
    $groupName = $GroupInput.Text.Trim()
    $filter = $FilterInput.Text.Trim()
    if (-not $groupName) { [System.Windows.Forms.MessageBox]::Show("Please enter a group name."); return }
    $group = Resolve-AADGroup -GroupName $groupName
    if (-not $group) { Log $LogBox "❌ Group '$groupName' not found."; return }
    Log $LogBox "✅ Found group: $($group.displayName) [$($group.id)]"
    Process-Policies -groupId $group.id -logBox $LogBox -filter $filter -makeInclude $true
})
$Form.Controls.Add($InclBtn)

$ExclBtn = New-Object System.Windows.Forms.Button
$ExclBtn.Text = "Run Exclusion"
$ExclBtn.Width = 200
$ExclBtn.Location = New-Object System.Drawing.Point(380, 470)
$ExclBtn.Add_Click({
    $global:StopProcess = $false
    $LogBox.Clear()
    $groupName = $GroupInput.Text.Trim()
    $filter = $FilterInput.Text.Trim()
    if (-not $groupName) { [System.Windows.Forms.MessageBox]::Show("Please enter a group name."); return }
    $group = Resolve-AADGroup -GroupName $groupName
    if (-not $group) { Log $LogBox "❌ Group '$groupName' not found."; return }
    Log $LogBox "✅ Found group: $($group.displayName) [$($group.id)]"
    Process-Policies -groupId $group.id -logBox $LogBox -filter $filter -makeInclude $false
})
$Form.Controls.Add($ExclBtn)

[void]$Form.ShowDialog()
