@{
    # Module identification
    RootModule        = 'Stagearr.Core.psm1'
    ModuleVersion     = '2.3.0'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'Rouzax'
    Description       = 'Core module for Stagearr - qBittorrent post-processing automation'
    
    # Compatibility
    PowerShellVersion = '5.1'
    
    # Functions to export - explicitly list public functions only
    # Private helpers (Invoke-SAWebRequest, ConvertTo-SAHashtable, etc.) are NOT exported
    FunctionsToExport = @(
        # --- Output System (event-based) ---
        'Initialize-SAOutputSystem'
        'Initialize-SAConsoleRenderer'
        'Write-SABanner'
        'Write-SAKeyValue'
        'Write-SAPhaseHeader'
        'Write-SAOutcome'
        'Write-SAProgress'
        'Write-SAVerbose'
        'Write-SAPollingStatus'
        'Set-SAEmailSummary'
        'Add-SAEmailException'
        'Set-SAEmailLogPath'
        'Save-SAFileLog'
        'Get-SAJobDuration'
        'ConvertTo-SAEmailHtml'
        'Reset-SAOutputState'
        
        # --- Configuration ---
        'Read-SAConfig'
        'Test-SAFeatureEnabled'
        
        # --- Configuration Sync ---
        'Sync-SAConfig'
        'Invoke-SAConfigSync'
        'Test-SAConfigSync'
        'Get-SAConfigSyncReport'
        'Compare-SAConfigSchema'

        # --- Updates ---
        'Invoke-SAUpdateCheck'
        'Invoke-SAInteractiveUpdate'

        # --- Setup ---
        'Invoke-SASetup'
        
        # --- Queue operations ---
        'Add-SAJob'
        'Get-SAJob'
        'Get-SAJobs'
        'Remove-SAJob'
        'Start-SAWorker'
        'Restore-SAOrphanedJobs'
        'Update-SAJobProgress'

        # --- Job processing ---
        'Invoke-SAJobProcessing'
        
        # --- State management ---
        'Reset-SAJobState'
        
        # --- Lock management ---
        'Get-SAGlobalLock'
        'Get-SAGlobalLockInfo'
        'Unlock-SAGlobalLock'
        'Test-SAGlobalLock'
        
        # --- Video processing ---
        'Invoke-SAVideoProcessing'
        'Start-SAUnrar'
        'Start-SAMkvRemux'
        'Start-SARemuxMP4'
        
        # --- Subtitles ---
        'Invoke-SASubtitleProcessing'
        'Get-SAOpenSubtitlesToken'
        'Start-SASubtitleCleanup'
        'Test-SAUploadableSubtitle'
        
        # --- Import (media servers) ---
        'Invoke-SAImport'
        'Invoke-SAArrImport'
        'Test-SAArrConnection'
        'Get-SAArrRecentErrors'
        'Invoke-SAArrManualImportScan'
        'Invoke-SAArrManualImportExecute'
        'Invoke-SARadarrImport'
        'Invoke-SASonarrImport'
        'Invoke-SARadarrManualImportScan'
        'Invoke-SARadarrManualImportExecute'
        'Invoke-SASonarrManualImportScan'
        'Invoke-SASonarrManualImportExecute'
        'Invoke-SAMedusaImport'
        'Test-SARadarrConnection'
        'Test-SASonarrConnection'
        'Test-SAMedusaConnection'
        
        # --- Staging ---
        'Initialize-SAStagingFolder'
        'Remove-SAStagingFolder'
        
        # --- Notifications ---
        'Send-SAEmail'
        'Test-SAEmailConfig'
    )
    
    # Private data
    PrivateData       = @{
        PSData = @{
            Tags       = @('qBittorrent', 'torrent', 'automation', 'post-processing')
            # ProjectUri = '' # TODO: Set once GitHub repository is created
        }
    }
}