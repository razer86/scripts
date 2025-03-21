#Config Variables
$SiteURL = "https://mipecmcscomau.sharepoint.com"
$FileRelativeURL ="/Shared Documents/Working/Coal/2020/June 2020/..exe"
 
#Get Credentials to connect
$Cred = Get-Credential
 
Try {
    #Connect to PnP Online
    Connect-PnPOnline -Url $SiteURL -Credentials $Cred -Verbose
     
    #Try to Get File
    $File = Get-PnPFile -Url $FileRelativeURL -ErrorAction SilentlyContinue
    If($File)
    {
        #Delete the File
        Remove-PnPFile -ServerRelativeUrl $FileRelativeURL -Force -whatif
        Write-Host -f Green "File $FileRelativeURL deleted successfully!"
    }
    Else
    {
        Write-Host -f Yellow "Could not Find File at $FileRelativeURL"
    }
}
catch {
    write-host "Error: $($_.Exception.Message)" -foregroundcolor Red
}