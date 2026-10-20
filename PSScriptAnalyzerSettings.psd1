@{
    # PSScriptAnalyzer configuration for the installer.
    #
    # These four rules are excluded on purpose:
    #  - PSAvoidUsingWriteHost: the -Console diagnostics write to the terminal.
    #  - PSUseApprovedVerbs / PSUseSingularNouns: the pipeline (Action-*, Ensure-*,
    #    Watch-*, Send-Download, ...) is an internal convention; renaming it would
    #    churn the whole file without changing behaviour.
    #  - PSUseShouldProcessForStateChangingFunctions: the GUI helpers are not
    #    cmdlets exposed to a pipeline.
    #
    # Everything else is enforced, including empty catch blocks, unused
    # parameters and assignments to automatic variables.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSUseApprovedVerbs'
        'PSUseSingularNouns'
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
