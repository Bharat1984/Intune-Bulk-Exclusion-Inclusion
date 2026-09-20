# Intune Bulk Assignment Manager

Windows Forms tool for safely managing Microsoft Intune mobile-app group assignments through Microsoft Graph.

## Requirements

- Windows PowerShell 5.1 or later
- Microsoft Graph PowerShell SDK (`Install-Module Microsoft.Graph -Scope CurrentUser`)
- Delegated permissions: `DeviceManagementApps.ReadWrite.All` and `Group.Read.All`
- An active Intune licence in the tenant

## Using the tool

1. Click **Login** and complete the Microsoft Graph sign-in prompt. Assignment and export controls remain unavailable until the session is connected.
2. Enter a Group ID where possible. A unique display name is also accepted; duplicate display names are rejected rather than choosing an arbitrary group.
3. Enter comma-separated partial app names for selected-app actions.
4. Choose an **OS / platform filter**. It defaults to **All platforms**; Windows, macOS, iOS/iPadOS, Android, and Other are available.
5. Leave **Dry run** selected to review the intended changes in the log.
6. Clear **Dry run** only after review. The tool asks for confirmation before every write.

Click **Logout** when finished to clear the Microsoft Graph session and disable the operational controls.

Use **How it works** in the header for an in-app description of every operation.

## Operations

| Action | Effect |
|---|---|
| Add inclusion (selected apps) | Adds the group as a required inclusion target for matching apps. |
| Add exclusion (selected apps) | Adds the group as an exclusion target for matching apps. |
| Remove exclusions (selected apps) | Removes only exclusion assignments for the group; required inclusions are preserved. |
| Add exclusion to all apps | Adds the exclusion group to every Intune app. This operation is confirmed before it runs. |
| Export all assignments | Writes `Intune-All-App-Assignments.csv` to the current user's Desktop. |
| Export selected app details | Writes matching-app assignments to `Intune-Selected-App-Details.csv` on the Desktop. |

## Safety and reliability

- Uses Microsoft Graph `v1.0` endpoints.
- Follows Graph `@odata.nextLink` values for apps and assignments, so large tenants are fully processed.
- Retries throttling and server errors up to three times.
- Caches group display-name lookups during exports.
- Stop requests take effect between app operations; an in-flight Graph request completes first.

## Notes

The tool uses partial, case-insensitive app-name matching. Review dry-run output carefully, especially before the all-app exclusion operation. The user needs sufficient Intune administrator permissions in addition to granting the Graph scopes.

Built by [https://techtrendinsights.co.in/](https://techtrendinsights.co.in/) | Owner: Bharat Arora
