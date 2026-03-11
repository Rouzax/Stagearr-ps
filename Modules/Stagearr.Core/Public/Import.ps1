#Requires -Version 5.1
<#
.SYNOPSIS
    Main import dispatcher for Stagearr
.DESCRIPTION
    Routes import requests to the appropriate media server importer:
    - Radarr (movies) - via ImportArr.ps1
    - Sonarr (TV) - via ImportArr.ps1  
    - Medusa (TV) - via ImportMedusa.ps1
    
    This file contains:
    - Reset-SAImportState: State management for import operations
    - Invoke-SAImport: Main dispatcher routing based on label/config
    
    Importer implementations are in separate files:
    - ImportArr.ps1: Radarr and Sonarr functions
    - ImportMedusa.ps1: Medusa functions
#>

#region Module State

function Reset-SAImportState {
    <#
    .SYNOPSIS
        Resets import module state between jobs.
    .DESCRIPTION
        Clears hostname resolution cache to allow fresh resolution per job.
        Call this at job start or between jobs in worker mode.
    #>
    [CmdletBinding()]
    param()
    
    Reset-SAHostnameCache
    # Note: Intentionally no verbose here - internal state reset is not useful for troubleshooting
}

#endregion

#region Main Import Dispatcher

function Invoke-SAImport {
    <#
    .SYNOPSIS
        Main import dispatcher based on label and config.
    .DESCRIPTION
        Routes import to appropriate application based on download label:
        - 'tv' or tvLabels -> Sonarr or Medusa
        - 'movie' or movieLabels -> Radarr
        
        The dispatcher determines which importer to use and calls the
        appropriate function from ImportArr.ps1 or ImportMedusa.ps1.
    .PARAMETER Context
        Processing context containing Config and State.
    .OUTPUTS
        Import result object with Success, Message, Duration, etc.
    .EXAMPLE
        $result = Invoke-SAImport -Context $ctx
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )
    
    $config = $Context.Config
    $label = $Context.State.ProcessingLabel
    $stagingPath = $Context.State.StagingPath
    
    # Determine import type from label
    $importType = $null
    
    # Check TV labels
    $tvLabels = @($config.labels.tv)
    if ($config.labels.tvLabels) {
        $tvLabels += $config.labels.tvLabels
    }
    if ($label -in $tvLabels -or $label -eq 'tv') {
        $importType = 'tv'
    }
    
    # Check movie labels
    $movieLabels = @($config.labels.movie)
    if ($config.labels.movieLabels) {
        $movieLabels += $config.labels.movieLabels
    }
    if ($label -in $movieLabels -or $label -eq 'movie') {
        $importType = 'movie'
    }
    
    if (-not $importType) {
        Write-SAOutcome -Level Warning -Label "Import" -Text "Unknown label '$label', skipping" -Indent 1
        return [PSCustomObject]@{
            Success = $true
            Skipped = $true
            Message = 'Unknown label'
        }
    }
    
    # Determine which importer will be used for the header
    $importerName = switch ($importType) {
        'tv' {
            $tvImporter = $config.processing.tvImporter
            if ($tvImporter -eq 'Medusa' -and $config.importers.medusa.enabled) { 'Medusa' }
            elseif ($config.importers.sonarr.enabled) { 'Sonarr' }
            else { 'TV' }
        }
        'movie' {
            if ($config.importers.radarr.enabled) { 'Radarr' }
            else { 'Movie' }
        }
    }
    
    Write-SAPhaseHeader -Title "Import ($importerName)"
    
    # Get staging root for remote path mapping
    $stagingRoot = $config.paths.stagingRoot
    
    # Route to appropriate importer
    switch ($importType) {
        'tv' {
            # Use Sonarr or Medusa based on config
            $tvImporter = $config.processing.tvImporter
            
            if ($tvImporter -eq 'Medusa' -and $config.importers.medusa.enabled) {
                return Invoke-SAMedusaImport -Config $config.importers.medusa -StagingPath $stagingPath -StagingRoot $stagingRoot
            }
            elseif ($config.importers.sonarr.enabled) {
                return Invoke-SASonarrImport -Config $config.importers.sonarr -StagingPath $stagingPath `
                    -StagingRoot $stagingRoot -DownloadId $Context.Job.input.torrentHash `
                    -CachedQueueRecords $Context.State.EarlyQueueRecords
            }
            else {
                Write-SAOutcome -Level Warning -Label "Import" -Text "No TV importer configured" -Indent 1
                return [PSCustomObject]@{ Success = $false; Message = 'No TV importer configured' }
            }
        }
        
        'movie' {
            if ($config.importers.radarr.enabled) {
                return Invoke-SARadarrImport -Config $config.importers.radarr -StagingPath $stagingPath `
                    -StagingRoot $stagingRoot -DownloadId $Context.Job.input.torrentHash `
                    -CachedQueueRecords $Context.State.EarlyQueueRecords
            }
            else {
                Write-SAOutcome -Level Warning -Label "Import" -Text "Radarr not configured" -Indent 1
                return [PSCustomObject]@{ Success = $false; Message = 'Radarr not configured' }
            }
        }
    }
}

#endregion
