#Requires -Version 5.1
<#
.SYNOPSIS
    HTTP client helpers for Stagearr
.DESCRIPTION
    Provides HTTP request functionality with retry logic and rate-limit handling (429).
    Compatible with both PowerShell 5.1 and 7.x.
    
    SOLID Refactor (Phase 6): Extracted pure helper functions for testability.
#>

#region Pure Helper Functions (SOLID Refactor - Phase 6)

function New-SAHttpResult {
    <#
    .SYNOPSIS
        Creates a standardized HTTP result object.
    .DESCRIPTION
        Pure function - no I/O. Creates the standard result object returned
        by all HTTP operations for consistent handling.
    .PARAMETER Success
        Whether the request succeeded.
    .PARAMETER StatusCode
        HTTP status code (or $null if unknown).
    .PARAMETER Data
        Parsed response data.
    .PARAMETER Headers
        Response headers.
    .PARAMETER ErrorMessage
        Error message if failed.
    .PARAMETER RawContent
        Raw response content.
    .OUTPUTS
        PSCustomObject with standardized structure.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Success,
        
        [Parameter()]
        [Nullable[int]]$StatusCode,
        
        [Parameter()]
        [object]$Data,
        
        [Parameter()]
        [object]$Headers,
        
        [Parameter()]
        [string]$ErrorMessage,
        
        [Parameter()]
        [string]$RawContent
    )
    
    return [PSCustomObject]@{
        Success      = $Success
        StatusCode   = $StatusCode
        Data         = $Data
        Headers      = if ($Headers) { $Headers } else { @{} }
        ErrorMessage = $ErrorMessage
        RawContent   = $RawContent
    }
}

function Get-SAHttpRetryDelay {
    <#
    .SYNOPSIS
        Calculates retry delay with exponential backoff.
    .DESCRIPTION
        Pure function - no I/O. Returns the delay in seconds for a given
        retry attempt, supporting Retry-After header values.
    .PARAMETER Attempt
        Current retry attempt (1-based).
    .PARAMETER BaseDelaySeconds
        Base delay between retries.
    .PARAMETER RetryAfterHeader
        Optional Retry-After header value from response.
    .OUTPUTS
        Integer delay in seconds.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Attempt,
        
        [Parameter()]
        [int]$BaseDelaySeconds = 2,
        
        [Parameter()]
        [string]$RetryAfterHeader
    )
    
    $delay = $BaseDelaySeconds * $Attempt
    
    # Check for Retry-After header
    if (-not [string]::IsNullOrWhiteSpace($RetryAfterHeader)) {
        $retryAfterInt = 0
        if ([int]::TryParse($RetryAfterHeader, [ref]$retryAfterInt)) {
            if ($retryAfterInt -gt 0) {
                $delay = $retryAfterInt
            }
        }
    }
    
    return $delay
}

function Test-SAHttpStatusRetryable {
    <#
    .SYNOPSIS
        Determines if an HTTP status code should trigger a retry.
    .DESCRIPTION
        Pure function - no I/O. Returns whether a status code indicates
        a transient error that should be retried.
    .PARAMETER StatusCode
        HTTP status code to check.
    .OUTPUTS
        Boolean indicating if retry is appropriate.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$StatusCode
    )
    
    # Retry server errors (5xx) and rate limiting (429)
    # Don't retry auth errors (401, 403) - they won't succeed with same credentials
    if ($StatusCode -eq 429) { return $true }
    if ($StatusCode -ge 500) { return $true }
    
    return $false
}

function Test-SAHttpStatusAuthError {
    <#
    .SYNOPSIS
        Determines if an HTTP status code is an authentication error.
    .DESCRIPTION
        Pure function - no I/O. Returns whether a status code indicates
        an auth error that should NOT be retried (caller should handle).
    .PARAMETER StatusCode
        HTTP status code to check.
    .OUTPUTS
        Boolean indicating if this is an auth error.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$StatusCode
    )
    
    return $StatusCode -in @(401, 403)
}

#endregion

#region Main HTTP Function

function Invoke-SAWebRequest {
    <#
    .SYNOPSIS
        Makes an HTTP request with retry and rate-limit handling.
    .DESCRIPTION
        Uses Invoke-WebRequest with retry logic and JSON parsing.
    .PARAMETER Uri
        The request URI.
    .PARAMETER Method
        HTTP method: GET, POST, PUT, DELETE, PATCH (default: GET).
    .PARAMETER Headers
        Hashtable of request headers.
    .PARAMETER Body
        Request body (will be JSON-encoded if hashtable/object).
    .PARAMETER ContentType
        Content-Type header (default: application/json for POST/PUT/PATCH).
    .PARAMETER MaxRetries
        Maximum retry attempts (default: 3).
    .PARAMETER RetryDelaySeconds
        Base delay between retries (default: 2).
    .PARAMETER TimeoutSeconds
        Request timeout (default: 30).
    .PARAMETER AsJson
        Parse response as JSON (default: true).
    .OUTPUTS
        PSCustomObject with: Success, StatusCode, Data, Headers, ErrorMessage, RawContent
    .EXAMPLE
        $result = Invoke-SAWebRequest -Uri "https://api.example.com/data" -Headers @{ "Api-Key" = "xxx" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        
        [Parameter()]
        [ValidateSet('GET', 'POST', 'PUT', 'DELETE', 'PATCH')]
        [string]$Method = 'GET',
        
        [Parameter()]
        [hashtable]$Headers = @{},
        
        [Parameter()]
        [object]$Body,
        
        [Parameter()]
        [string]$ContentType,
        
        [Parameter()]
        [int]$MaxRetries = 3,
        
        [Parameter()]
        [int]$RetryDelaySeconds = 2,
        
        [Parameter()]
        [int]$TimeoutSeconds = 30,
        
        [Parameter()]
        [bool]$AsJson = $true
    )
    
    # Ensure TLS 1.2 for PowerShell 5.1 (modern APIs reject older TLS versions)
    if ($PSVersionTable.PSEdition -ne 'Core') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    
    # Determine content type
    if ([string]::IsNullOrWhiteSpace($ContentType)) {
        if ($Method -in @('POST', 'PUT', 'PATCH')) {
            $ContentType = 'application/json'
        }
    }
    
    # Prepare body
    $requestBody = $null
    if ($null -ne $Body) {
        if ($Body -is [string]) {
            $requestBody = $Body
        } elseif ($Body -is [hashtable] -or $Body -is [PSCustomObject]) {
            $requestBody = $Body | ConvertTo-Json -Depth 10 -Compress
        } else {
            $requestBody = $Body.ToString()
        }
    }
    
    $attempt = 0
    $lastError = $null
    $lastStatusCode = $null
    
    while ($attempt -lt $MaxRetries) {
        $attempt++
        
        try {
            # Build request parameters - keep it simple for PS 5.1 compatibility
            $requestParams = @{
                Uri             = $Uri
                Method          = $Method
                Headers         = $Headers
                TimeoutSec      = $TimeoutSeconds
                UseBasicParsing = $true
                ErrorAction     = 'Stop'
            }
            
            if (-not [string]::IsNullOrWhiteSpace($ContentType)) {
                $requestParams.ContentType = $ContentType
            }
            
            if ($null -ne $requestBody) {
                $requestParams.Body = $requestBody
            }
            
            # Make request (suppress built-in verbose - we log our own context)
            $response = Invoke-WebRequest @requestParams -Verbose:$false
            $statusCode = $response.StatusCode
            # PS Core can return byte[] for Content on non-text responses (e.g., empty DELETE responses).
            # Coerce to string for consistent downstream handling.
            $responseContent = if ($response.Content -is [byte[]]) {
                if ($response.Content.Length -gt 0) {
                    [System.Text.Encoding]::UTF8.GetString($response.Content)
                } else {
                    ''
                }
            } else {
                $response.Content
            }
            $responseHeaders = $response.Headers
            
            # Parse response as JSON if requested
            $responseData = $null
            if (-not [string]::IsNullOrWhiteSpace($responseContent)) {
                if ($AsJson) {
                    try {
                        $responseData = ConvertFrom-Json -InputObject $responseContent
                    } catch {
                        $responseData = $responseContent
                    }
                } else {
                    $responseData = $responseContent
                }
            }
            
            # Check for success (2xx status codes)
            if ($statusCode -ge 200 -and $statusCode -lt 300) {
                return New-SAHttpResult -Success $true -StatusCode $statusCode -Data $responseData -Headers $responseHeaders -RawContent $responseContent
            }
            
            # Handle rate limiting (429) - use helper functions
            if ($statusCode -eq 429) {
                $retryAfterValue = if ($responseHeaders -and $responseHeaders['Retry-After']) { $responseHeaders['Retry-After'] } else { $null }
                $waitSeconds = Get-SAHttpRetryDelay -Attempt $attempt -BaseDelaySeconds $RetryDelaySeconds -RetryAfterHeader $retryAfterValue
                
                if ($attempt -lt $MaxRetries) {
                    Write-SAProgress -Label "HTTP" -Text "Rate limited (429), waiting $waitSeconds seconds..."
                    Start-Sleep -Seconds $waitSeconds
                    continue
                }
            }
            
            # Handle server errors with retry (5xx) - use helper function
            if ((Test-SAHttpStatusRetryable -StatusCode $statusCode) -and $attempt -lt $MaxRetries) {
                $delay = Get-SAHttpRetryDelay -Attempt $attempt -BaseDelaySeconds $RetryDelaySeconds
                Write-SAProgress -Label "HTTP" -Text "Server error ($statusCode), retrying in $delay seconds..."
                Start-Sleep -Seconds $delay
                continue
            }
            
            # Don't retry client auth errors (401, 403) - they won't succeed with same credentials
            # Return immediately to let caller handle (e.g., token refresh)
            
            # Non-success response
            $lastStatusCode = $statusCode
            $lastError = "HTTP $statusCode"
            
            return New-SAHttpResult -Success $false -StatusCode $statusCode -Data $responseData -Headers $responseHeaders -ErrorMessage "HTTP $statusCode" -RawContent $responseContent
            
        } catch [System.Net.WebException] {
            $lastError = $_.Exception.Message
            $webResponse = $_.Exception.Response
            
            if ($null -ne $webResponse) {
                $lastStatusCode = [int]$webResponse.StatusCode
                
                # Try to read response body
                $responseContent = $null
                try {
                    $stream = $webResponse.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $responseContent = $reader.ReadToEnd()
                    $reader.Close()
                    $stream.Close()
                } catch {
                    $responseContent = $null
                }
                
                # Handle rate limiting (429) with retry - use helper function
                if ($lastStatusCode -eq 429 -and $attempt -lt $MaxRetries) {
                    $waitSeconds = Get-SAHttpRetryDelay -Attempt $attempt -BaseDelaySeconds $RetryDelaySeconds
                    Write-SAProgress -Label "HTTP" -Text "Rate limited (429), waiting $waitSeconds seconds..."
                    Start-Sleep -Seconds $waitSeconds
                    continue
                }
                
                # Don't retry auth errors (401, 403) - use helper function
                if (Test-SAHttpStatusAuthError -StatusCode $lastStatusCode) {
                    return New-SAHttpResult -Success $false -StatusCode $lastStatusCode -ErrorMessage $lastError -RawContent $responseContent
                }
                
                # Handle server errors (5xx) with retry - use helper function
                if ((Test-SAHttpStatusRetryable -StatusCode $lastStatusCode) -and $attempt -lt $MaxRetries) {
                    $delay = Get-SAHttpRetryDelay -Attempt $attempt -BaseDelaySeconds $RetryDelaySeconds
                    Write-SAProgress -Label "HTTP" -Text "Server error ($lastStatusCode), retrying in $delay seconds..."
                    Start-Sleep -Seconds $delay
                    continue
                }
            }
            
            # Retry on transient/network errors
            if ($attempt -lt $MaxRetries) {
                $delay = Get-SAHttpRetryDelay -Attempt $attempt -BaseDelaySeconds $RetryDelaySeconds
                Write-SAProgress -Label "HTTP" -Text "Request failed ($lastError), retrying in $delay seconds..."
                Start-Sleep -Seconds $delay
                continue
            }
            
            return New-SAHttpResult -Success $false -StatusCode $lastStatusCode -ErrorMessage $lastError -RawContent $responseContent
            
        } catch {
            $lastError = $_.Exception.Message
            
            # PowerShell 7 uses HttpRequestException - try to extract status code from message
            # Format: "Response status code does not indicate success: 401 (Unauthorized)."
            if ($lastError -match 'status code[^:]*:\s*(\d{3})') {
                $lastStatusCode = [int]$Matches[1]
            }
            
            # Don't retry auth errors (401, 403) - use helper function
            if ($null -ne $lastStatusCode -and (Test-SAHttpStatusAuthError -StatusCode $lastStatusCode)) {
                return New-SAHttpResult -Success $false -StatusCode $lastStatusCode -ErrorMessage $lastError
            }
            
            # Retry on transient/network errors (but not auth errors)
            if ($attempt -lt $MaxRetries) {
                $delay = Get-SAHttpRetryDelay -Attempt $attempt -BaseDelaySeconds $RetryDelaySeconds
                Write-SAProgress -Label "HTTP" -Text "Request failed ($lastError), retrying in $delay seconds..."
                Start-Sleep -Seconds $delay
                continue
            }
            
            return New-SAHttpResult -Success $false -StatusCode $lastStatusCode -ErrorMessage $lastError
        }
    }
    
    # Max retries exceeded
    return New-SAHttpResult -Success $false -StatusCode $lastStatusCode -ErrorMessage "Max retries exceeded. Last error: $lastError"
}

#endregion

