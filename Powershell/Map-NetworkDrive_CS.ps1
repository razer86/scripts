# Create user data table
$users = @(
    #[PSCustomObject]@{ UserAccount = 'AzureAD\Username';   NASAccount = 'first.l';   NASPwd = 'P@ssw0rd';   NASGroup = 'Internal/External/Director';}
    [PSCustomObject]@{ UserAccount = 'CIVIL\Mark';      NASAccount = 'mark.p';           NASPwd = 'UPLw9wiZ';            NASGroup = 'Director';}
    [PSCustomObject]@{ UserAccount = 'CIVIL\Lisa';      NASAccount = 'lisa.p';           NASPwd = '8+G9eQ3z';            NASGroup = 'Internal';}
    [PSCustomObject]@{ UserAccount = 'AzureAD\BonnieCoombs';      NASAccount = 'bonnie.c';           NASPwd = 'p9V8[Wm8';            NASGroup = 'Internal';}

)

#Retrieve the name of the logged in user
$LoggedInUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name

#write-host $LoggedInUser

# Retrieve the user data by AzureAccount
$user = $users | Where-Object { $_.UserAccount -eq $LoggedInUser }

#Check if we found the user in the table
if ($user) {
    #Map the drive(s) based on the NAS group
    if ($user.NASGroup -eq 'Director' ) {
        #Create the user credential object
        # Convert the password to a secure string
        $securePassword = ConvertTo-SecureString $user.NASPwd -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($user.NASAccount, $securePassword)
        
        #Set the Director network path to map
        $DirectorPath = '\\192.168.0.2\Data\Director'

        #Set the Data nework path to map
        $DataPath = '\\192.168.0.2\Data\Data'

        #Check if the Drive exists and Map the drive
        If (-Not(Test-Path -Path "X:\")) {
            New-PSDrive -Name X -PSProvider FileSystem -Root $DirectorPath -Persist -Credential $credential
        }
        If (-Not(Test-Path -Path "P:\")) {
            New-PSDrive -Name P -PSProvider FileSystem -Root $DataPath -Persist -Credential $credential
        }

    } elseif ($user.NASGroup -eq 'Internal' ) {
        #Create the user credential object
        # Convert the password to a secure string
        $securePassword = ConvertTo-SecureString $user.NASPwd -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($user.NASAccount, $securePassword)

        #Set the Data nework path to map
        $DataPath = '\\192.168.0.2\Data\Data'
        If (-Not(Test-Path -Path "P:\")) {
            New-PSDrive -Name P -PSProvider FileSystem -Root $DataPath -Persist -Credential $credential
        }
    }
}