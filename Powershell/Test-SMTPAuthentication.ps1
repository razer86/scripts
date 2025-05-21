<#
.SYNOPSIS
    Tests SMTP authentication and encryption using provided credentials and settings.

.DESCRIPTION
    Connects to the specified SMTP server with given encryption method and credentials,
    and attempts to send a test email to verify connectivity and authentication.

.PARAMETER SmtpServer
    The SMTP server hostname (e.g., smtp.office365.com, smtp.gmail.com)

.PARAMETER SmtpPort
    The SMTP port number (e.g., 25, 465, 587)

.PARAMETER Encryption
    Encryption type: "None", "SSL", or "STARTTLS"

.PARAMETER Username
    The email address used for SMTP authentication and sending

.PARAMETER Password
    The plain text SMTP password or app password (converted securely)

.EXAMPLE
    .\Test-SMTPAuthentication.ps1 -SmtpServer "smtp.office365.com" -SmtpPort 587 -Encryption STARTTLS -Username "user@domain.com" -Password "MyAppPassword"

.EXAMPLE
    .\Test-SMTPAuthentication.ps1 -SmtpServer "smtp.gmail.com" -SmtpPort 465 -Encryption SSL -Username "you@gmail.com" -Password "YourGmailAppPassword"

.NOTES
    Author: Raymond Slater / ChatGPT
    Requires: Internet access + SMTP credentials
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$SmtpServer,

    [Parameter(Mandatory = $true)]
    [int]$SmtpPort,

    [Parameter(Mandatory = $true)]
    [ValidateSet("None", "SSL", "STARTTLS")]
    [string]$Encryption,

    [Parameter(Mandatory = $true)]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [string]$Password
)

# Convert password to a SecureString
$secpasswd = ConvertTo-SecureString $Password -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($Username, $secpasswd)

# Set up SMTP client
$smtpClient = New-Object System.Net.Mail.SmtpClient($SmtpServer, $SmtpPort)

# Configure encryption
switch ($Encryption.ToUpper()) {
    "SSL" {
        $smtpClient.EnableSsl = $true
        Write-Host "[INFO] Using SSL/TLS encryption on port $SmtpPort" -ForegroundColor Cyan
    }
    "STARTTLS" {
        $smtpClient.EnableSsl = $true
        Write-Host "[INFO] Using STARTTLS encryption on port $SmtpPort" -ForegroundColor Cyan
    }
    "NONE" {
        $smtpClient.EnableSsl = $false
        Write-Host "[INFO] Using unencrypted SMTP on port $SmtpPort" -ForegroundColor Yellow
    }
}

# Apply authentication credentials
$smtpClient.Credentials = $cred.GetNetworkCredential()

# Compose a test message
$mailMessage = New-Object System.Net.Mail.MailMessage
$mailMessage.From = $Username
$mailMessage.To.Add($Username)  # Send to self
$mailMessage.Subject = "SMTP Test Email"
$mailMessage.Body = "This is a test email sent via PowerShell to confirm SMTP authentication."

# Send the test email
try {
    $smtpClient.Send($mailMessage)
    Write-Host "`n[SUCCESS] SMTP authentication successful. Test email sent to $Username." -ForegroundColor Green
} catch {
    Write-Host "`n[ERROR] SMTP Authentication Failed: $($_.Exception.Message)" -ForegroundColor Red
}
