@{
    # PSScriptAnalyzer configuration for Stagearr.
    #
    # We run Error + Warning severities. A few default rules are excluded because
    # they conflict with deliberate, project-wide design choices (not bugs):
    #
    #   PSAvoidUsingWriteHost
    #     Stagearr has its own event-based output system (Write-SAOutcome etc.) for
    #     business logic, but the CLI entry point and the interactive setup wizard
    #     legitimately use Write-Host for direct user interaction.
    #
    #   PSUseShouldProcessForStateChangingFunctions
    #     Fires on pure builder/factory functions (New-SA*, etc.) that create and
    #     return an object without changing system state, so ShouldProcess is noise.
    #
    #   PSUseSingularNouns
    #     Several commands are intentionally plural because they act on collections
    #     (Get-SAJobs, Restore-SAOrphanedJobs).
    #
    # Genuine findings (e.g. ConvertTo-SecureString with plaintext) are kept active
    # and suppressed precisely at the call site with a justification, not excluded
    # globally.

    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSingularNouns'
    )
}
