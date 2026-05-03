#Requires -Version 5.1
<#
.SYNOPSIS
    Lists all accounts/stores currently loaded in Outlook.
    Run this to find the correct $MailboxMatch value for the main script.
#>

$ol = New-Object -ComObject Outlook.Application
$ol.GetNamespace('MAPI').Folders | Select-Object Name, @{
    Name = 'TopLevelFolders'; Expression = { $_.Folders.Count }
} | Format-Table -AutoSize
