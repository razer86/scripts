<#
.SYNOPSIS
    Identifies and optionally updates Outlook folders from IPF.Imap to IPF.Note

.DESCRIPTION
    After importing Outlook folders from an IMAP profile, the folder type will still be IPF.Imap.
    This script lists all such folders and optionally updates them to IPF.Note (standard Outlook folders).
    Requires Outlook to be open and the desired mailbox/folder selected in the explorer.
#>

param (
    [switch]$ListOnly  # Use -ListOnly to prevent making changes
)

Function List-And-UpdateFolders {
    param (
        $Folders,
        $Indent = ""
    )

    ForEach ($Folder in $Folders | Sort-Object Name) {
        try {
            $oPA = $Folder.PropertyAccessor
            $Value = $oPA.GetProperty($PropName)
            $FolderInfo = "$Indent$($Folder.Name) [$Value] ($($Folder.Items.Count) items)"

            if ($Value -eq 'IPF.Imap') {
                Write-Host "[FOUND] $FolderInfo" -ForegroundColor Yellow
                if (-not $ListOnly) {
                    $oPA.SetProperty($PropName, 'IPF.Note')
                    Write-Host " → Updated to IPF.Note" -ForegroundColor Green
                }
            } else {
                Write-Host "$FolderInfo"
            }

            # Recurse into subfolders
            List-And-UpdateFolders -Folders $Folder.Folders -Indent ($Indent + "  ")
        } catch {
            Write-Warning "Error processing folder: $($Folder.Name) - $_"
        }
    }
}

# Initialize
$Outlook = New-Object -ComObject Outlook.Application
$ns = $Outlook.GetNamespace("MAPI")
$PropName = "http://schemas.microsoft.com/mapi/proptag/0x3613001E"

# Start from the current folder or default inbox if none selected
try {
    $oFolder = ($Outlook.ActiveExplorer()).CurrentFolder
} catch {
    Write-Warning "No folder selected. Defaulting to Inbox."
    $oFolder = $ns.GetDefaultFolder(6)  # 6 = olFolderInbox
}

Write-Host "`nStarting scan from folder: $($oFolder.Name)`n" -ForegroundColor Cyan
List-And-UpdateFolders -Folders $oFolder.Folders
