# Requires Microsoft.Graph.Authentication & DeviceManagement modules
Import-Module Microsoft.Graph.Authentication

# Connect to Graph with appropriate scopes
if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes "DeviceManagementConfiguration.ReadWrite.All", "Group.Read.All"
}

# Add GUI assemblies
Add-Type -AssemblyName PresentationFramework

# Build minimal XAML
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Intune Policy Exclusion Tool" Height="260" Width="600">
    <Grid Margin="10">
        <StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                <Label Content="AAD Group Name:" Width="120"/>
                <TextBox Name="GroupBox" Width="300"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                <Label Content="Policy Name Filter:" Width="120"/>
                <TextBox Name="PolicyBox" Width="300"/>
            </StackPanel>
            <CheckBox Name="DoInclude" Content="Also Include group (along with Exclude)?" Margin="0,0,0,8"/>
            <TextBox Name="LogBox" Height="100" IsReadOnly="True" VerticalScrollBarVisibility="Auto"/>
            <Button Name="RunBtn" Content="Run Exclusion" Width="150" HorizontalAlignment="Center"/>
        </StackPanel>
    </Grid>
</Window>
"@

# Load XAML
$reader = (New-Object System.Xml.XmlNodeReader $xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

# Map controls
$GroupBox = $window.FindName("GroupBox")
$PolicyBox = $window.FindName("PolicyBox")
$LogBox = $window.FindName("LogBox")
$DoInclude = $window.FindName("DoInclude")
$RunBtn = $window.FindName("RunBtn")

# Helper to log to GUI
function Log($msg) {
    $LogBox.AppendText("$msg`r`n")
    $LogBox.ScrollToEnd()
}

# Main run
$RunBtn.Add_Click({
    $LogBox.Clear()
    $GroupName = $GroupBox.Text
    $Filter = $PolicyBox.Text

    if ([string]::IsNullOrWhiteSpace($GroupName)) {
        Log "🚨 Enter a group name."
        return
    }

    # Lookup AAD group
    $group = Get-MgGroup -Filter "displayName eq '$GroupName'"
    if (-not $group) {
        Log "❌ Group '$GroupName' not found."
        return
    }
    $groupId = $group.Id
    Log "✅ Found group: $($group.DisplayName) [$groupId]"

    # Process device configuration (OG) policies
    $policies = (Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations" -Method GET).value
    if ($Filter) { $policies = $policies | Where-Object { $_.displayName -match $Filter } }
    foreach ($policy in $policies) {
        $assignUri = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$($policy.id)/groupAssignments"
        $assigns = (Invoke-MgGraphRequest -Method GET -Uri $assignUri).value
        $keep = @()
        $hasInclude = $false
        foreach ($a in $assigns) {
            if ($a.targetGroupId -eq $groupId) {
                if ($a.excludeGroup -eq $true) {
                    Log "➡️ Already excluded in '$($policy.displayName)'"
                } else {
                    Log "🚫 Removing include from '$($policy.displayName)'"
                }
            } else {
                $keep += $a
            }
        }
        if ($DoInclude.IsChecked) {
            $keep += @{
                "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                groupId = $groupId
            }
            Log "✅ Adding include on '$($policy.displayName)'"
        }
        $keep += @{
            "@odata.type" = "#microsoft.graph.exclusionGroupAssignmentTarget"
            groupId = $groupId
        }
        $json = @{ assignments = @(@($keep | ForEach-Object { @{ target = $_ } })) } | ConvertTo-Json -Depth 5
        Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$($policy.id)/assign" -Method POST -Body $json -ContentType "application/json"
        Log "✏️ Patched '$($policy.displayName)'"
    }

    # Process settings catalog policies
    $scpolicies = (Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies" -Method GET).value
    if ($Filter) { $scpolicies = $scpolicies | Where-Object { $_.name -match $Filter } }
    foreach ($policy in $scpolicies) {
        $assignUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($policy.id)/assignments"
        $assigns = (Invoke-MgGraphRequest -Method GET -Uri $assignUri).value
        $keep = @()
        foreach ($a in $assigns) {
            if ($a.target.groupId -eq $groupId) {
                if ($a.target.'@odata.type' -eq "#microsoft.graph.exclusionGroupAssignmentTarget") {
                    Log "➡️ Already excluded in '$($policy.name)'"
                } else {
                    Log "🚫 Removing include from '$($policy.name)'"
                }
            } else {
                $keep += $a
            }
        }
        if ($DoInclude.IsChecked) {
            $keep += @{
                target = @{
                    "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                    groupId = $groupId
                }
            }
            Log "✅ Adding include on '$($policy.name)'"
        }
        $keep += @{
            target = @{
                "@odata.type" = "#microsoft.graph.exclusionGroupAssignmentTarget"
                groupId = $groupId
            }
        }
        $json = @{ assignments = $keep } | ConvertTo-Json -Depth 5
        Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($policy.id)/assign" -Method POST -Body $json -ContentType "application/json"
        Log "✏️ Patched '$($policy.name)'"
    }

    Log "`n🎉 Done."
})

# Show the window
$window.ShowDialog() | Out-Null
