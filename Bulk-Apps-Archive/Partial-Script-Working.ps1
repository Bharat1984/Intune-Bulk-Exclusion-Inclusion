$appId = "d7a89ff6-d45e-4224-a713-41d443dbec41"
$groupId = "63f113c3-e05d-41b4-8af8-f30a5131ec95"
$assignments = Get-MgDeviceAppManagementMobileAppAssignment -MobileAppId $appId
$assignments | ForEach-Object {
    $_.Target | Format-List *
}


Get-MgDeviceAppManagementMobileAppAssignment -MobileAppId $appId |
Select-Object Id, Intent, @{n='GroupId';e={$_.Target.AdditionalProperties['groupId']}}, @{n='Type';e={$_.Target.AdditionalProperties['@odata.type']}}

Get-MgDeviceAppManagementMobileAppAssignment -MobileAppId $appId |
Select-Object Id, Intent, @{n='GroupId';e={$_.Target.AdditionalProperties['groupId']}}, @{n='Type';e={$_.Target.AdditionalProperties['@odata.type']}}



# Get the current assignment for this group
$assignment = Get-MgDeviceAppManagementMobileAppAssignment -MobileAppId $appId | Where-Object {
    $_.Target.AdditionalProperties['groupId'] -eq $groupId -and
    $_.Target.AdditionalProperties['@odata.type'] -eq "#microsoft.graph.exclusionGroupAssignmentTarget"
}

# Remove it if found
if ($assignment) {
    Write-Host "🧹 Removing existing exclusion assignment for $groupId (intent: $($assignment.Intent))"
    Remove-MgDeviceAppManagementMobileAppAssignment -MobileAppId $appId -MobileAppAssignmentId $assignment.Id
}

# Now add as a required exclusion
Write-Host "🚀 Adding new exclusion for required intent..."
New-MgDeviceAppManagementMobileAppAssignment -MobileAppId $appId -BodyParameter @{
    target = @{
        "@odata.type" = "#microsoft.graph.exclusionGroupAssignmentTarget"
        groupId = $groupId
    }
    Intent = "required"
}
Write-Host "✅ Done: group $groupId is now excluded from required installs."
