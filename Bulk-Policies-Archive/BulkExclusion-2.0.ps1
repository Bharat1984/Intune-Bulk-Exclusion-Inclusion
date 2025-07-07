# Updated script with more explicit logs for each step

# Requires Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Authentication

if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes "DeviceManagementConfiguration.ReadWrite.All", "Group.Read.All"
}

Add-Type -AssemblyName PresentationFramework

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Intune Policy Exclusion Tool V2" Height="280" Width="640">
    <Grid Margin="10">
        <StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                <Label Content="AAD Group Name:" Width="140"/>
                <TextBox Name="GroupBox" Width="350"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                <Label Content="Policy Name Filter:" Width="140"/>
                <TextBox Name="PolicyBox" Width="350"/>
            </StackPanel>
            <CheckBox Name="DoInclude" Content="Also Include group?" Margin="0,0,0,8"/>
            <TextBox Name="LogBox" Height="110" IsReadOnly="True" VerticalScrollBarVisibility="Auto"/>
            <Button Name="RunBtn" Content="Run Exclusion" Width="160" HorizontalAlignment="Center"/>
        </StackPanel>
    </Grid>
</Window>
"@

$reader = (New-Object System.Xml.XmlNodeReader $xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$GroupBox = $window.FindName("GroupBox")
$PolicyBox = $window.FindName("PolicyBox")
$LogBox = $window.FindName("LogBox")
$DoInclude = $window.FindName("DoInclude")
$RunBtn = $window.FindName("RunBtn")

function Log($msg) {
    $LogBox.AppendText("$msg`r`n")
    $LogBox.ScrollToEnd()
}

$RunBtn.Add_Click({
    $LogBox.Clear()
    $GroupName = $GroupBox.Text
    $Filter = $PolicyBox.Text

    if ([string]::IsNullOrWhiteSpace($GroupName)) {
        Log "🚨 Please enter a group name."
        return
    }

    $group = Get-MgGroup -Filter "displayName eq '$GroupName'"
    if (-not $group) {
        Log "❌ Group '$GroupName' not found."
        return
    }
    $groupId = $group.Id
    Log "✅ Found group: $($group.DisplayName) [$groupId]"

    $policies = (Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations" -Method GET).value
    if ($Filter) { $policies = $policies | Where-Object { $_.displayName -match $Filter } }
    foreach ($policy in $policies) {
        Log "🔍 Checking Device Config Policy: $($policy.displayName)"
        $assignUri = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$($policy.id)/groupAssignments"
        $assigns = (Invoke-MgGraphRequest -Method GET -Uri $assignUri).value
        $keep = @()
        foreach ($a in $assigns) {
            if ($a.targetGroupId -eq $groupId) {
                if ($a.excludeGroup) {
                    Log "➡️ Already excluded."
                } else {
                    Log "🚫 Removing existing include."
                }
            } else {
                $keep += $a
            }
        }
        if ($DoInclude.IsChecked) {
            $keep += @{ "@odata.type"="#microsoft.graph.groupAssignmentTarget"; groupId=$groupId }
            Log "✅ Adding include."
        }
        $keep += @{ "@odata.type"="#microsoft.graph.exclusionGroupAssignmentTarget"; groupId=$groupId }
        $json = @{ assignments = @(@($keep | ForEach-Object { @{ target = $_ } })) } | ConvertTo-Json -Depth 5
        Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$($policy.id)/assign" -Method POST -Body $json -ContentType "application/json"
        Log "✏️ Updated policy: $($policy.displayName)"
    }

    $scpolicies = (Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies" -Method GET).value
    if ($Filter) { $scpolicies = $scpolicies | Where-Object { $_.name -match $Filter } }
    foreach ($policy in $scpolicies) {
        Log "🔍 Checking Settings Catalog: $($policy.name)"
        $assignUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($policy.id)/assignments"
        $assigns = (Invoke-MgGraphRequest -Method GET -Uri $assignUri).value
        $keep = @()
        foreach ($a in $assigns) {
            if ($a.target.groupId -eq $groupId) {
                if ($a.target.'@odata.type' -eq "#microsoft.graph.exclusionGroupAssignmentTarget") {
                    Log "➡️ Already excluded."
                } else {
                    Log "🚫 Removing existing include."
                }
            } else {
                $keep += $a
            }
        }
        if ($DoInclude.IsChecked) {
            $keep += @{ target=@{"@odata.type"="#microsoft.graph.groupAssignmentTarget"; groupId=$groupId} }
            Log "✅ Adding include."
        }
        $keep += @{ target=@{"@odata.type"="#microsoft.graph.exclusionGroupAssignmentTarget"; groupId=$groupId} }
        $json = @{ assignments = $keep } | ConvertTo-Json -Depth 5
        Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($policy.id)/assign" -Method POST -Body $json -ContentType "application/json"
        Log "✏️ Updated policy: $($policy.name)"
    }

    Log "`n🎉 Completed all updates."
})

$window.ShowDialog() | Out-Null
