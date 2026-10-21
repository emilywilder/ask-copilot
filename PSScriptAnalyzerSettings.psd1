# PSScriptAnalyzer settings used by CI: Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The token read from op or a vault arrives as plain text and is wrapped in a SecureString
        # straight away; there is no encrypted form to start from.
        'PSAvoidUsingConvertToSecureStringWithPlainText'
        # -OpReference, -SecretName and -Vault are read by helper functions through scope.
        'PSReviewUnusedParameter'
        # Internal helpers, not published cmdlets; -WhatIf/-Confirm would mean nothing for them.
        'PSUseShouldProcessForStateChangingFunctions'
        # The one empty catch is deliberate: killing an already-exited Copilot process during cleanup.
        'PSAvoidUsingEmptyCatchBlock'
        # The script requires PowerShell 7.2+, which reads UTF-8 without a BOM; the BOM is for Windows PowerShell 5.1.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
