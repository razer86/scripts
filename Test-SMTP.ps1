param (
    [string]$SmtpServer = "smtp.office365.com",  # SMTP Server
    [int]$SmtpPort = 587,  # SMTP Port (25, 465, or 587)
    [string]$Encryption = "STARTTLS",  # "None", "SSL", or "STARTTLS"
    [string]$Username,  # Email Username
    [string]$Password  # Email Password
)

# Convert password to SecureString
$secpasswd = ConvertTo-SecureString $Password -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($Username, $secpasswd)

# Create SMTP Client
$smtpClient = New-Object System.Net.Mail.SmtpClient($SmtpServer, $SmtpPort)

# Configure security settings
switch ($Encryption.ToUpper()) {
    "SSL" {
        $smtpClient.EnableSsl = $true  # SSL (Implicit TLS)
        Write-Host "[INFO] Using SSL/TLS encryption on port $SmtpPort"
    }
    "STARTTLS" {
        $smtpClient.EnableSsl = $true  # STARTTLS requires SSL enabled
        Write-Host "[INFO] Using STARTTLS encryption on port $SmtpPort"
    }
    "NONE" {
        $smtpClient.EnableSsl = $false  # No encryption for port 25
        Write-Host "[INFO] Using unencrypted SMTP on port $SmtpPort"
    }
    default {
        Write-Host "[ERROR] Invalid encryption method! Use 'None', 'SSL', or 'STARTTLS'."
        exit
    }
}

# Set Authentication
$smtpClient.Credentials = $cred.GetNetworkCredential()

# Create a test email message
$mailMessage = New-Object System.Net.Mail.MailMessage
$mailMessage.From = $Username
$mailMessage.To.Add($Username)  # Send email to self
$mailMessage.Subject = "SMTP Test Email"
$mailMessage.Body = "This is a test email to verify SMTP authentication."

# Try to send the email and capture SMTP response
Try {
    $smtpClient.Send($mailMessage)
    Write-Host "[SUCCESS] SMTP authentication successful. Email sent!"
} Catch {
    Write-Host "[ERROR] SMTP Authentication Failed: $($_.Exception.Message)"
}