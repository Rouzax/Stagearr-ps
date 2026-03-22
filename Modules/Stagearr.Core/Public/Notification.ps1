#Requires -Version 5.1
<#
.SYNOPSIS
    Email notification functions for Stagearr
.DESCRIPTION
    Sends HTML email notifications using the Mailozaurr module or built-in Send-MailMessage.
    
    SECURITY NOTE: Email passwords are stored in plaintext in the configuration file.
    Consider using application-specific passwords or OAuth where supported.

.NOTES
    DEPRECATION WARNING (Send-MailMessage):
    The built-in Send-MailMessage cmdlet is officially deprecated by Microsoft and has
    known security limitations:
    - No support for modern OAuth2 authentication
    - Limited TLS/SSL options (STARTTLS only, no implicit SSL on port 465)
    - Password stored in plaintext in config file
    
    RECOMMENDED: Install the Mailozaurr module for modern SMTP support:
        Install-Module Mailozaurr -Scope CurrentUser
    
    Mailozaurr provides:
    - Proper SSL/TLS support including implicit SSL (port 465)
    - Better error handling and diagnostics
    - OAuth2 support for services like Microsoft 365
    
    Future versions of Stagearr may remove Send-MailMessage fallback entirely.
#>

function Send-SAEmail {
    <#
    .SYNOPSIS
        Sends an HTML email notification.
    .PARAMETER Config
        Email configuration hashtable (from config.notifications.email).
    .PARAMETER Subject
        Email subject line.
    .PARAMETER Body
        HTML body content.
    .PARAMETER Priority
        Email priority: Low, Normal, High (default: Normal).
    .PARAMETER InlineImages
        Array of inline image attachments for CID references in HTML.
        Each item should be a hashtable with:
        - Bytes: [byte[]] Raw image data
        - MimeType: [string] MIME type (e.g., 'image/jpeg')
        - ContentId: [string] Content-ID for cid: references in HTML
    .EXAMPLE
        Send-SAEmail -Config $config.notifications.email -Subject "Movie - Film.2024" -Body $htmlContent
    .EXAMPLE
        $poster = @{ Bytes = $imageBytes; MimeType = 'image/jpeg'; ContentId = 'poster-abc123' }
        Send-SAEmail -Config $config -Subject "Movie" -Body $html -InlineImages @($poster)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$Subject,
        
        [Parameter(Mandatory = $true)]
        [string]$Body,
        
        [Parameter()]
        [ValidateSet('Low', 'Normal', 'High')]
        [string]$Priority = 'Normal',
        
        [Parameter()]
        [hashtable[]]$InlineImages
    )
    
    # Check if email is enabled
    if (-not $Config.enabled) {
        Write-SAProgress -Label "Email" -Text "Notifications disabled" -Indent 1
        return $false
    }
    
    # Validate required settings
    if ([string]::IsNullOrWhiteSpace($Config.to)) {
        Write-SAOutcome -Level Warning -Label "Email" -Text "No recipient configured" -Indent 1
        return $false
    }
    
    if ([string]::IsNullOrWhiteSpace($Config.smtp.server)) {
        Write-SAOutcome -Level Warning -Label "Email" -Text "No SMTP server configured" -Indent 1
        return $false
    }
    
    # Build from address
    $fromAddress = $Config.from
    if (-not [string]::IsNullOrWhiteSpace($Config.fromName)) {
        $fromAddress = "$($Config.fromName) <$($Config.from)>"
    }
    
    # Show progress (email can take a few seconds)
    Write-SAProgress -Label "Email" -Text "Sending notification..." -Indent 1
    
    # Try Mailozaurr first (supports modern SMTP with proper SSL/TLS and inline images)
    # Suppress verbose from PowerShell module system ("Populating RepositorySourceLocation...")
    $mailozaurrModule = & {
        $VerbosePreference = 'SilentlyContinue'
        Get-Module -ListAvailable -Name Mailozaurr | Select-Object -First 1
    }
    $mailozaurrAvailable = $null -ne $mailozaurrModule

    if ($mailozaurrAvailable) {
        # Inline images require Mailozaurr v2.x (-InlineAttachment parameter)
        $effectiveInlineImages = $InlineImages
        if ($mailozaurrModule.Version.Major -lt 2) {
            if ($InlineImages -and $InlineImages.Count -gt 0) {
                Write-SAVerbose -Label "Email" -Text "Inline images require Mailozaurr v2.x (installed: $($mailozaurrModule.Version))"
            }
            $effectiveInlineImages = @()
        }
        return Send-SAEmailMailozaurr -Config $Config -Subject $Subject -Body $Body -FromAddress $fromAddress -Priority $Priority -InlineImages $effectiveInlineImages
    }
    
    # Fallback to Send-MailMessage (no Mailozaurr installed)
    # Note: Inline images not supported with deprecated Send-MailMessage
    if ($InlineImages -and $InlineImages.Count -gt 0) {
        Write-SAVerbose -Label "Email" -Text "Inline images not supported with Send-MailMessage fallback"
    }
    return Send-SAEmailBuiltin -Config $Config -Subject $Subject -Body $Body -FromAddress $fromAddress -Priority $Priority
}

function Send-SAEmailMailozaurr {
    <#
    .SYNOPSIS
        Sends email using Mailozaurr module.
    .NOTES
        Supports inline images with CID references for displaying posters in email clients.
        Images are serialized as base64 for job boundary crossing, then written to temp
        files for attachment. MailKit (used by Mailozaurr) handles the CID linking.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$Subject,
        
        [Parameter(Mandatory = $true)]
        [string]$Body,
        
        [Parameter(Mandatory = $true)]
        [string]$FromAddress,
        
        [Parameter()]
        [string]$Priority = 'Normal',
        
        [Parameter()]
        [int]$TimeoutSeconds = $script:SAConstants.EmailSendTimeoutSeconds,

        [Parameter()]
        [hashtable[]]$InlineImages
    )
    
    try {
        # Build params as simple types that can serialize across job boundary
        $jobParams = @{
            From         = $FromAddress
            To           = $Config.to
            Subject      = $Subject
            HTML         = $Body
            Server       = $Config.smtp.server
            Port         = $Config.smtp.port
            Priority     = $Priority
            User         = $Config.smtp.user
            Password     = $Config.smtp.password
            InlineImages = @()
        }
        
        # Convert inline images to serializable format (base64)
        if ($InlineImages -and $InlineImages.Count -gt 0) {
            foreach ($img in $InlineImages) {
                if ($null -ne $img.Bytes -and $img.Bytes.Length -gt 0 -and 
                    -not [string]::IsNullOrWhiteSpace($img.ContentId)) {
                    $jobParams.InlineImages += @{
                        ContentId = $img.ContentId
                        Base64    = [Convert]::ToBase64String($img.Bytes)
                        MimeType  = if ($img.MimeType) { $img.MimeType } else { 'image/jpeg' }
                    }
                }
            }
        }
        
        # Use Start-Job for process isolation - can be killed unlike runspace
        $job = Start-Job -ScriptBlock {
            param($p)
            
            # Suppress verbose from module import ("Populating RepositorySourceLocation...")
            $VerbosePreference = 'SilentlyContinue'
            Import-Module Mailozaurr -ErrorAction Stop
            
            $smtpParams = @{
                From     = $p.From
                To       = $p.To
                Subject  = $p.Subject
                HTML     = $p.HTML
                Server   = $p.Server
                Port     = $p.Port
                Priority = $p.Priority
            }
            
            # Build credential inside job
            if ($p.User) {
                $securePassword = ConvertTo-SecureString $p.Password -AsPlainText -Force
                $smtpParams.Credential = New-Object System.Management.Automation.PSCredential ($p.User, $securePassword)
            }
            
            # Set SecureSocketOptions based on port
            switch ($p.Port) {
                465 { $smtpParams.SecureSocketOptions = [MailKit.Security.SecureSocketOptions]::SslOnConnect }
                587 { $smtpParams.SecureSocketOptions = [MailKit.Security.SecureSocketOptions]::StartTls }
                default { $smtpParams.SecureSocketOptions = [MailKit.Security.SecureSocketOptions]::StartTlsWhenAvailable }
            }
            
            # Handle inline images for CID references
            # Note: Data crossing job boundary becomes Deserialized.* PSObjects
            # Must explicitly convert to proper types
            [string[]]$inlineAttachmentPaths = @()
            if ($p.InlineImages -and @($p.InlineImages).Count -gt 0) {
                foreach ($img in @($p.InlineImages)) {
                    # Explicitly extract strings from potentially deserialized PSObject
                    $contentId = [string]$img.ContentId
                    $base64Data = [string]$img.Base64
                    
                    if ([string]::IsNullOrWhiteSpace($contentId) -or [string]::IsNullOrWhiteSpace($base64Data)) {
                        continue
                    }
                    
                    # Decode base64 back to bytes
                    $bytes = [Convert]::FromBase64String($base64Data)
                    
                    # Create temp file using ContentId as filename (includes extension)
                    # Mailozaurr uses filename as Content-ID: Split-Path -Leaf
                    # ContentId format: poster-abc12345.jpg (includes extension for MIME detection)
                    # HTML uses: cid:poster-abc12345.jpg
                    # Mailozaurr CID: poster-abc12345.jpg (from filename)
                    $tempDir = [System.IO.Path]::GetTempPath()
                    $tempPath = [System.IO.Path]::Combine($tempDir, $contentId)
                    [System.IO.File]::WriteAllBytes($tempPath, $bytes)
                    $inlineAttachmentPaths += $tempPath
                }
            }
            
            try {
                if ($inlineAttachmentPaths.Count -gt 0) {
                    # Mailozaurr v2.x -InlineAttachment takes array of file paths (strings)
                    # Content-ID is derived from filename (Split-Path -Leaf)
                    Send-EmailMessage @smtpParams -InlineAttachment $inlineAttachmentPaths -ErrorAction Stop
                } else {
                    Send-EmailMessage @smtpParams -ErrorAction Stop
                }
            } finally {
                # Cleanup temp files
                foreach ($f in $inlineAttachmentPaths) {
                    Remove-Item -Path $f -Force -ErrorAction SilentlyContinue
                }
            }
        } -ArgumentList $jobParams
        
        # Wait with timeout
        $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
        
        if ($null -eq $completed) {
            # Timed out - fire and forget cleanup (don't wait for Stop-Job which blocks on PS5)
            $null = Start-Job -ScriptBlock { 
                param($jobId) 
                Stop-Job -Id $jobId -ErrorAction SilentlyContinue
                Remove-Job -Id $jobId -Force -ErrorAction SilentlyContinue
            } -ArgumentList $job.Id
            throw "Email send timed out after $TimeoutSeconds seconds"
        }
        
        # Check job state and errors
        if ($job.State -eq 'Failed') {
            $errorMsg = $job.ChildJobs[0].JobStateInfo.Reason.Message
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            throw $errorMsg
        }
        
        # Get any error output
        $jobError = $job.ChildJobs[0].Error | Select-Object -First 1
        if ($jobError) {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            throw $jobError.Exception.Message
        }
        
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        
        Write-SAOutcome -Level Success -Label "Email" -Text "Sent to $($Config.to)" -Indent 1
        return $true
        
    } catch {
        Write-SAOutcome -Level Error -Label "Email" -Text "Failed: $($_.Exception.Message)" -Indent 1
        return $false
    }
}

function Send-SAEmailBuiltin {
    <#
    .SYNOPSIS
        Sends email using built-in Send-MailMessage (deprecated but widely available).
    .NOTES
        DEPRECATED: Send-MailMessage is deprecated by Microsoft.
        
        Limitations:
        - Port 465 (implicit SSL) may not work - uses STARTTLS only
        - Password stored in plaintext
        - No OAuth2 support
        
        Recommend using port 587 with STARTTLS, or PowerShell 7+ with Mailozaurr module.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter(Mandatory = $true)]
        [string]$Subject,
        
        [Parameter(Mandatory = $true)]
        [string]$Body,
        
        [Parameter(Mandatory = $true)]
        [string]$FromAddress,
        
        [Parameter()]
        [string]$Priority = 'Normal',
        
        [Parameter()]
        [int]$TimeoutSeconds = $script:SAConstants.EmailSendTimeoutSeconds
    )

    # Log deprecation warning (verbose only - don't spam console/email)
    Write-SAVerbose -Label "Email" -Text "Using deprecated Send-MailMessage. Consider installing Mailozaurr."
    
    # Warn about port 465 compatibility
    if ($Config.smtp.port -eq 465) {
        Write-SAVerbose -Label "Email" -Text "Port 465 (implicit SSL) may not work with built-in cmdlet. Consider port 587."
    }
    
    try {
        # Build params as simple types for job serialization
        $jobParams = @{
            From       = $FromAddress
            To         = $Config.to
            Subject    = $Subject
            Body       = $Body
            SmtpServer = $Config.smtp.server
            Port       = $Config.smtp.port
            Priority   = $Priority
            User       = $Config.smtp.user
            Password   = $Config.smtp.password
            UseSsl     = $Config.smtp.port -in @(465, 587)
        }
        
        # Use Start-Job for process isolation - can be killed unlike runspace
        $job = Start-Job -ScriptBlock {
            param($p)

            # Ensure TLS 1.2 for PowerShell 5.1 (SMTP servers reject older TLS)
            if ($PSVersionTable.PSEdition -ne 'Core') {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            }

            $mailParams = @{
                From       = $p.From
                To         = $p.To
                Subject    = $p.Subject
                Body       = $p.Body
                BodyAsHtml = $true
                SmtpServer = $p.SmtpServer
                Port       = $p.Port
                Priority   = $p.Priority
            }
            
            if ($p.UseSsl) {
                $mailParams.UseSsl = $true
            }
            
            # Build credential inside job
            if ($p.User) {
                $securePassword = ConvertTo-SecureString $p.Password -AsPlainText -Force
                $mailParams.Credential = New-Object System.Management.Automation.PSCredential ($p.User, $securePassword)
            }
            
            $WarningPreference = 'SilentlyContinue'
            Send-MailMessage @mailParams -ErrorAction Stop
        } -ArgumentList $jobParams
        
        # Wait with timeout
        $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
        
        if ($null -eq $completed) {
            # Timed out - fire and forget cleanup (don't wait for Stop-Job which blocks on PS5)
            $null = Start-Job -ScriptBlock { 
                param($jobId) 
                Stop-Job -Id $jobId -ErrorAction SilentlyContinue
                Remove-Job -Id $jobId -Force -ErrorAction SilentlyContinue
            } -ArgumentList $job.Id
            throw "Email send timed out after $TimeoutSeconds seconds. If using port 465, try port 587 or PowerShell 7+."
        }
        
        # Check job state and errors
        if ($job.State -eq 'Failed') {
            $errorMsg = $job.ChildJobs[0].JobStateInfo.Reason.Message
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            throw $errorMsg
        }
        
        # Get any error output
        $jobError = $job.ChildJobs[0].Error | Select-Object -First 1
        if ($jobError) {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            throw $jobError.Exception.Message
        }
        
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        
        Write-SAOutcome -Level Success -Label "Email" -Text "Sent to $($Config.to)" -Indent 1
        return $true
        
    } catch {
        Write-SAOutcome -Level Error -Label "Email" -Text "Failed: $($_.Exception.Message)" -Indent 1
        return $false
    }
}

function Test-SAEmailConfig {
    <#
    .SYNOPSIS
        Tests email configuration by sending a test message.
    .PARAMETER Config
        Email configuration hashtable.
    .EXAMPLE
        Test-SAEmailConfig -Config $config.notifications.email
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    $testBody = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Stagearr Test</title>
</head>
<body style="margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; background-color: #0f172a; color: #f8fafc;">
    <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="background-color: #0f172a;">
        <tr>
            <td align="center" style="padding: 24px 16px;">
                <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="max-width: 480px; background-color: #1e293b; border-radius: 16px; overflow: hidden;">
                    <tr>
                        <td align="center" style="padding: 32px 24px 24px 24px;">
                            <table role="presentation" cellspacing="0" cellpadding="0" border="0">
                                <tr>
                                    <td style="background-color: #22c55e; border-radius: 50px; padding: 12px 32px;">
                                        <span style="color: #ffffff; font-size: 14px; font-weight: 700; letter-spacing: 1px;">&#10003; SUCCESS</span>
                                    </td>
                                </tr>
                            </table>
                        </td>
                    </tr>
                    <tr>
                        <td align="center" style="padding: 0 24px 8px 24px;">
                            <h1 style="margin: 0; font-size: 24px; font-weight: 600; color: #f8fafc; line-height: 1.3;">Email Test</h1>
                        </td>
                    </tr>
                    <tr>
                        <td align="center" style="padding: 0 24px 24px 24px;">
                            <span style="color: #94a3b8; font-size: 14px;">Stagearr</span>
                        </td>
                    </tr>
                    <tr>
                        <td style="padding: 0 16px 16px 16px;">
                            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="background-color: #0f172a; border-radius: 12px; overflow: hidden;">
                                <tr>
                                    <td style="padding: 16px 20px; color: #cbd5e1; font-size: 13px;">
                                        This is a test email from Stagearr. If you received this, your email configuration is working correctly.
                                    </td>
                                </tr>
                                <tr>
                                    <td style="padding: 0 20px 16px 20px; color: #64748b; font-size: 12px;">
                                        Sent at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                                    </td>
                                </tr>
                            </table>
                        </td>
                    </tr>
                    <tr>
                        <td style="padding: 0 24px;">
                            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%">
                                <tr><td style="border-top: 1px solid #334155;"></td></tr>
                            </table>
                        </td>
                    </tr>
                    <tr>
                        <td align="center" style="padding: 16px 24px 24px 24px;">
                            <span style="color: #475569; font-size: 12px;">Stagearr v2.0.0</span>
                        </td>
                    </tr>
                </table>
            </td>
        </tr>
    </table>
</body>
</html>
"@
    
    return Send-SAEmail -Config $Config -Subject "Stagearr - Test Email" -Body $testBody
}
