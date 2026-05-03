#Requires -Version 5.1
<#
.SYNOPSIS
    Lists folders in a mailbox store, optionally drilling into a named parent folder.

.PARAMETER MailboxMatch
    Partial match against the store name. Defaults to first store if omitted.

.PARAMETER ParentFolder
    If provided, lists subfolders of this folder name instead of the store root.
    Use 'Inbox' to see what's inside Inbox.

.EXAMPLE
    .\Get-OutlookFolders.ps1
    .\Get-OutlookFolders.ps1 -MailboxMatch 'ray.slater'
    .\Get-OutlookFolders.ps1 -MailboxMatch 'ray.slater' -ParentFolder 'Inbox'
    .\Get-OutlookFolders.ps1 -MailboxMatch 'ray.slater' -ParentFolder '_Businesses'
#>

param(
    [string]$MailboxMatch = '',
    [string]$ParentFolder = ''
)

$ol        = New-Object -ComObject Outlook.Application
$namespace = $ol.GetNamespace('MAPI')

if ($MailboxMatch) {
    $store = $namespace.Folders | Where-Object { $_.Name -like "*$MailboxMatch*" } | Select-Object -First 1
} else {
    $store = $namespace.Folders.Item(1)
}

if (-not $store) {
    Write-Warning "No store matching '$MailboxMatch' found."
    $namespace.Folders | Select-Object Name
    exit
}

Write-Host "Store: $($store.Name)`n" -ForegroundColor Cyan

if ($ParentFolder) {
    # Search store root first, then inside Inbox
    $target = $store.Folders | Where-Object { $_.Name -eq $ParentFolder }
    if (-not $target) {
        $inbox  = $store.Folders | Where-Object { $_.Name -eq 'Inbox' }
        $target = $inbox.Folders | Where-Object { $_.Name -eq $ParentFolder }
    }
    if (-not $target) {
        Write-Warning "Folder '$ParentFolder' not found in store '$($store.Name)'."
        exit
    }
    Write-Host "Subfolders of '$ParentFolder':" -ForegroundColor Yellow
    $target.Folders | Select-Object Name, @{ Name = 'ItemCount'; Expression = { $_.Items.Count } } |
        Sort-Object Name | Format-Table -AutoSize
} else {
    Write-Host 'Top-level folders:' -ForegroundColor Yellow
    $store.Folders | Select-Object Name, @{ Name = 'ItemCount'; Expression = { $_.Items.Count } } |
        Sort-Object Name | Format-Table -AutoSize
}
