#Requires -Version 5.1
<#
.DESCRIPTION
Credential handling: DPAPI helpers, dialogs, cache/probe, encrypted computer-list config.
#>

function Protect-Credential {
    param([System.Security.SecureString]$SecurePassword)
    
    try {
        # Convert SecureString to encrypted standard string using DPAPI
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
        $PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        
        # Encrypt using DPAPI (user-specific, requires same user context to decrypt)
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainPassword)
        $ProtectedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $Bytes, 
            $null, 
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        
        return [Convert]::ToBase64String($ProtectedBytes)
    } catch {
        Write-DebugLog "Failed to protect credential: $($_.Exception.Message)" -Level 'ERROR'
        return $null
    }
}

function Unprotect-Credential {
    param([string]$ProtectedBase64)
    
    try {
        # Decrypt using DPAPI
        $ProtectedBytes = [Convert]::FromBase64String($ProtectedBase64)
        $PlainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $ProtectedBytes, 
            $null, 
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $PlainPassword = [System.Text.Encoding]::UTF8.GetString($PlainBytes)
        
        # Convert back to SecureString
        $SecurePassword = ConvertTo-SecureString $PlainPassword -AsPlainText -Force
        return $SecurePassword
    } catch {
        Write-DebugLog "Failed to unprotect credential: $($_.Exception.Message)" -Level 'ERROR'
        return $null
    }
}

function Update-WuuCredentialEpoch {
    <#
    .SYNOPSIS Records that the credential configuration changed (Phase 2, R04).
    .DESCRIPTION
    Called whenever custom credentials are enabled, disabled or replaced.

    WHY AN EPOCH IS NEEDED. A per-computer runspace is created ONCE and reused, and its injected
    credential globals are captured at creation. So changing the credentials left every EXISTING row
    resolving its identity from the runspace's stale copies - a newly submitted operation would run
    under the OLD identity, silently, until the row happened to be recreated.

    The epoch is stamped onto a row when its runspace is built (see Start-UpdateCheckJob). A submission
    whose row carries a different epoch rebuilds the runspace, so a submitted operation always runs
    under the identity configured AT SUBMISSION. That is the deterministic behaviour R04 asks for, and
    it costs nothing when credentials have not changed.

    TRANSPLANTED from WUU2-CLI src\Wuu.Credentials.psm1 (donor revision 0566164b...) - the mechanism is
    identical because the defect it fixes is identical; only Write-DebugLog (already a target export)
    is used.
    #>
    [CmdletBinding()]
    param([string]$Reason = '')
    $epoch = 0
    if ($global:CredentialEpoch) { $epoch = [int]$global:CredentialEpoch }
    $global:CredentialEpoch = $epoch + 1
    $suffix = if ($Reason) { " ($Reason)" } else { '' }
    Write-DebugLog "Credential configuration changed - epoch is now $($global:CredentialEpoch)$suffix" -Level 'INFO'
    return $global:CredentialEpoch
}

function Resolve-WuuOperationCredential {
    <#
    .SYNOPSIS Decides, once, which credential identity an operation will use (Phase 2, R04).
    .DESCRIPTION
    THE RULE, stated plainly:

        custom credentials configured  ->  the operation uses that credential.
                                           If it does not work, that is a FAILURE.
                                           It does NOT fall back to the default identity.

    WHY THIS FUNCTION EXISTS. The previous resolver tried custom, and on failure tried the default and
    returned it on success. So an administrator who configured alternate credentials could have an
    operation run as the PROCESS identity instead - silently, with the operation succeeding and no
    indication that the identity differed from the one configured. For a patch-deployment tool that is
    an audit problem as much as a security one: you need to know which account changed a machine, and
    "whichever one happened to work" is not an answer.

    It also returns the MODE, which the old resolver could not: it returned $null for both "use the
    default credential" and "no credential works", so every caller had to re-probe to tell them apart
    and a caller that did not could not distinguish the two.

    Returns:
        Mode        'Custom' when custom credentials are configured and enabled, otherwise 'Default'
        Credential  the [pscredential] to use, or $null meaning "the process identity"
        Username    the identity, for reporting and audit ('' for the process identity)
        Verified    $true/$false when -Verify was asked for; $null when it was not
        Error       why verification failed (only when Verified is $false)
        Reason      one short line explaining the decision, suitable for a log or an audit record

    -Verify runs a bounded reachability+authentication probe. It is OPTIONAL on purpose: identity is
    cheap to establish and can be fixed at submission time, whereas probing is a network round trip and
    must not block a caller that is only queuing work.
    #>
    [CmdletBinding()]
    param(
        [string]$ComputerName = '',
        # Run a probe to confirm this identity can actually authenticate. Off by default.
        [switch]$Verify,
        # Local machines are contacted as the process identity - passing explicit credentials to local
        # DCOM is rejected. Callers that already know the target is local pass -Local.
        [switch]$Local,
        # Bounded probe timeout.
        [int]$TimeoutSeconds = 5
    )

    $customConfigured = [bool]($global:UseCustomCredentials -and $global:CustomCredentials)

    # Decided FIRST, so there is a single branch that can produce a non-custom identity.
    $mode = if ($customConfigured -and -not $Local) { 'Custom' } else { 'Default' }
    $credential = if ($mode -eq 'Custom') { $global:CustomCredentials } else { $null }
    $username = ''
    if ($mode -eq 'Custom' -and $credential) { $username = [string]$credential.UserName }

    $reason = if ($mode -eq 'Custom') {
        "custom credentials configured and enabled - using '$username' (no fallback)"
    } elseif ($customConfigured -and $Local) {
        "custom credentials are configured but '$ComputerName' is the local machine - using the process identity"
    } else {
        'custom credentials are not configured - using the process identity'
    }

    $verified = $null
    $errorText = ''
    if ($Verify -and $ComputerName) {
        try {
            if ($mode -eq 'Custom') {
                $probe = Invoke-CimWithTimeout -ComputerName $ComputerName -ClassName 'Win32_ComputerSystem' `
                    -TimeoutSeconds $TimeoutSeconds -Credential $credential -Operation "credential verification ($username)"
            } else {
                $probe = Invoke-CimWithTimeout -ComputerName $ComputerName -ClassName 'Win32_ComputerSystem' `
                    -TimeoutSeconds $TimeoutSeconds -Operation 'credential verification (process identity)'
            }
            if ($probe -and $probe.Success) {
                $verified = $true
            } else {
                $verified = $false
                $errorText = if ($probe -and $probe.Error) { [string]$probe.Error } else { 'the credential probe did not succeed' }
                # DELIBERATE: no fallback attempt happens here, and none is offered.
                $reason = "the $($mode.ToLower()) credential could not be verified: $errorText (no fallback attempted)"
            }
        } catch {
            $verified = $false
            $errorText = $_.Exception.Message
            $reason = "the $($mode.ToLower()) credential probe failed: $errorText (no fallback attempted)"
        }
    }

    return [pscustomobject]@{
        Mode       = $mode
        Credential = $credential
        Username   = $username
        Verified   = $verified
        Error      = $errorText
        Reason     = $reason
        Computer   = $ComputerName
    }
}

function Get-WuuCredentialStateSignature {
    <#
    .SYNOPSIS A compact, NON-SECRET description of the active credential mode (R04).
    .DESCRIPTION
    Returns the identity part of the credential mode in use, so a saved configuration can record WHAT
    it was saved with and a load can tell whether the running session matches.

    Deliberately identity only: never a password, and never any part of one.

    PSCredential.UserName is the authoritative source. Reading $global:CredentialConfig.Username
    instead would be wrong: that variable is only assigned by the config dialog, so a credential set
    some other way would be recorded as empty.
    #>
    [CmdletBinding()]
    param()
    $enabled = [bool]$global:UseCustomCredentials
    $userName = ''
    if ($enabled -and $global:CustomCredentials) { $userName = [string]$global:CustomCredentials.UserName }
    return @{
        Enabled  = $enabled
        UserName = $userName
        Mode     = if ($enabled) { 'custom' } else { 'current-process' }
    }
}

function Test-WuuCredentialStateMatches {
    <#
    .SYNOPSIS Does the running credential session match what a configuration was saved with? (R04)
    .DESCRIPTION
    Loading a list saved with custom credentials into a session that had none (or the reverse) silently
    changes which account every remote operation will use. Nothing fails - the operations simply run as
    a different principal, which is a security-relevant difference that is invisible until an
    access-denied appears on some host, or does not appear when it should.

    Returns Match plus a human-readable Reason so the caller can warn with the SPECIFIC difference
    rather than a vague "credential mismatch".
    #>
    [CmdletBinding()]
    param([AllowNull()]$Saved)
    $now = Get-WuuCredentialStateSignature
    if (-not $Saved) {
        return [pscustomobject]@{ Match = $true; Reason = 'the configuration records no credential mode (saved by an older build)'; SavedMode = ''; CurrentMode = $now.Mode }
    }
    $savedEnabled = $null
    if ($Saved.PSObject.Properties['Enabled']) { $savedEnabled = [bool]$Saved.Enabled }
    elseif ($Saved -is [hashtable] -and $Saved.ContainsKey('Enabled')) { $savedEnabled = [bool]$Saved['Enabled'] }
    if ($null -eq $savedEnabled) {
        return [pscustomobject]@{ Match = $true; Reason = 'the configuration does not state whether custom credentials were used'; SavedMode = ''; CurrentMode = $now.Mode }
    }
    $savedUser = ''
    if ($Saved.PSObject.Properties['UserName']) { $savedUser = [string]$Saved.UserName }
    elseif ($Saved -is [hashtable] -and $Saved.ContainsKey('UserName')) { $savedUser = [string]$Saved['UserName'] }

    if ($savedEnabled -ne $now.Enabled) {
        $savedMode = if ($savedEnabled) { 'custom' } else { 'current-process' }
        return [pscustomobject]@{
            Match = $false; SavedMode = $savedMode; CurrentMode = $now.Mode
            Reason = "saved with '$savedMode' credentials but this session is using '$($now.Mode)'"
        }
    }
    if ($savedEnabled -and $savedUser -and $now.UserName -and $savedUser -ne $now.UserName) {
        return [pscustomobject]@{
            Match = $false; SavedMode = 'custom'; CurrentMode = $now.Mode
            Reason = "saved with custom credentials for '$savedUser' but this session is using '$($now.UserName)'"
        }
    }
    return [pscustomobject]@{ Match = $true; Reason = ''; SavedMode = $now.Mode; CurrentMode = $now.Mode }
}

function Get-RemoteCredentials {
    <#
    .SYNOPSIS The credential for an operation on $ComputerName (Phase 2, R04).
    .DESCRIPTION
    Kept for its existing callers, and its CONTRACT IS DELIBERATELY UNCHANGED: it still returns a
    [pscredential], or $null meaning "use the process identity". What changed is the part callers could
    not previously rely on - it NO LONGER FALLS BACK to a different identity than the one configured.

    Behaviour now:
      * custom credentials configured and enabled -> that credential, or a FAILURE. The failure THROWS
        (so the operation does not run as an unintended identity) with the reason attached. Callers that
        prefer a reported error over an exception should use Resolve-WuuOperationCredential.
      * custom credentials not configured -> $null (the process identity). The previous version also
        probed the default credential here and returned $null either way, so the probe cost a round trip
        per computer and changed nothing except the log.

    The runtime cache is still honoured, but a cached entry can never contradict the configured mode.

    NOTE ON LOCAL HOSTS: passing explicit credentials to local DCOM is rejected, exactly as the donor
    notes, so a local target resolves to the process identity even when custom credentials are set.
    #>
    param(
        [string]$ComputerName,
        [string]$Operation = 'WMI access',
        # Callers that already know the target is the local machine pass -Local, so the resolver does
        # not offer an identity that local DCOM would reject anyway.
        [switch]$Local
    )

    try {
        # Resolve WITHOUT verification first, purely to learn the mode. Verification is a network round
        # trip, and in the Default case there is nothing to verify that would change the outcome ($null
        # is returned either way). Probing there is the wasted round trip per computer the previous
        # version was criticised for.
      $resolution = Resolve-WuuOperationCredential -ComputerName $ComputerName -Local:$Local

        if ($resolution.Mode -eq 'Default') {
            Write-DebugLog "Using the process identity for $ComputerName ($($resolution.Reason))" -Level 'DEBUG'
            return $null
        }

        # Custom credentials are configured, so the identity MUST be established, not assumed: verify
        # it, and fail if it is not usable. There is no third outcome.
        $resolution = Resolve-WuuOperationCredential -ComputerName $ComputerName -Verify -Local:$Local

        if (-not $resolution.Verified) {
            # THROW rather than return $null. Returning $null here is what made the old silent fallback
            # possible: $null legitimately means "use the process identity", so a failed custom
            # credential became indistinguishable from "no custom credential configured", and the
            # caller proceeded - as the wrong identity.
            $msg = "Configured custom credentials for '$($resolution.Username)' cannot be used on $ComputerName for $Operation. $($resolution.Error)"
            Write-ErrorLog $msg
            throw $msg
        }

        Write-DebugLog "Custom credentials verified for $ComputerName as '$($resolution.Username)'" -Level 'INFO'
        return $resolution.Credential
    } catch {
        # A throw from the verification path above is intentional and must reach the caller.
        if ($_.Exception.Message -match '^Configured custom credentials') { throw }
        Write-DebugLog "Error in Get-RemoteCredentials for $ComputerName : $($_.Exception.Message)" -Level 'ERROR'
        throw
    }
}

function Show-PasswordPrompt {
    param(
        [string]$Title = "Password Required",
        [string]$Message = "Enter password:"
    )
    
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    
    # Create the password prompt dialog
    $xamlPasswordDialog = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Height="200" Width="400"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        ShowInTaskbar="False" Topmost="True">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="20"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="20"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <TextBlock Grid.Row="0" Text="$Message" FontSize="12" TextWrapping="Wrap"/>
        
        <Label Grid.Row="2" Content="Password:" FontSize="11" Padding="0,0,0,5"/>
        <PasswordBox Grid.Row="2" Name="PasswordBox" Height="25" Margin="70,0,0,0" 
                     ToolTip="Enter the password" 
                     MaxLength="256" 
                     Background="White" 
                     BorderBrush="#CCCCCC" 
                     BorderThickness="1"/>
        
        <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
            <Button Name="OKButton" Content="OK" Width="80" Height="30" Margin="0,0,10,0" IsDefault="True"/>
            <Button Name="CancelButton" Content="Cancel" Width="80" Height="30" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
"@
    
    try {
        $reader = [System.Xml.XmlNodeReader]::new([xml]$xamlPasswordDialog)
        $dialog = [Windows.Markup.XamlReader]::Load($reader)
        
        # Get dialog controls
        $passwordBox = $dialog.FindName('PasswordBox')
        $okButton = $dialog.FindName('OKButton')
        $cancelButton = $dialog.FindName('CancelButton')
        
        # Set focus to password box when dialog opens
        $dialog.Add_Loaded({
            $passwordBox.Focus()
        })
        
        # OK button click handler
        $okButton.Add_Click({
            $dialog.Tag = $passwordBox.SecurePassword.Copy()
            $dialog.DialogResult = $true
            $dialog.Close()
        })
        
        # Cancel button click handler
        $cancelButton.Add_Click({
            $dialog.DialogResult = $false
            $dialog.Close()
        })
        
        # Handle Enter key in password box
        $passwordBox.Add_KeyDown({
            if ($_.Key -eq 'Enter') {
                $okButton.RaiseEvent([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
            }
        })
        
        # Set dialog owner to main window if available
        if ($uiHash.Window) {
            $dialog.Owner = $uiHash.Window
        }
        
        # Show dialog
        $result = $dialog.ShowDialog()
        
        if ($result -eq $true) {
            return $dialog.Tag
        } else {
            return $null
        }
        
    } catch {
        Write-Error "Failed to show password dialog: $($_.Exception.Message)"
        return $null
    }
}

function Show-CustomCredentialDialog {
    param(
        [string]$Message = "Enter your credentials",
        [string]$Username = "",
        [string]$Title = "Credentials Required"
    )
    
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    
    # Layout lives in ui/CredentialDialog.xaml; $Title/$Message remain template placeholders
    # interpolated after load. Single source of truth for this dialog and the worker copy.
    $xamlCredentialDialog = Get-Content -Path (Join-Path $PSScriptRoot 'ui\CredentialDialog.xaml') -Raw
    $xamlCredentialDialog = $xamlCredentialDialog -replace '\$Title\b', $Title -replace '\$Message\b', $Message
    
    try {
        $reader = [System.Xml.XmlNodeReader]::new([xml]$xamlCredentialDialog)
        $dialog = [Windows.Markup.XamlReader]::Load($reader)
        
        # Get dialog controls
        $usernameTextBox = $dialog.FindName('UsernameTextBox')
        $passwordBox = $dialog.FindName('PasswordBox')
        $rememberCheckBox = $dialog.FindName('RememberCheckBox')
        $okButton = $dialog.FindName('OKButton')
        $cancelButton = $dialog.FindName('CancelButton')
        
        # Set initial username if provided
        if ($Username) {
            $usernameTextBox.Text = $Username
        }
        
        # Set focus to appropriate control when dialog opens
        $dialog.Add_Loaded({
            # Use dispatcher to ensure proper focus timing
            $dialog.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Input, [System.Action]{
                if ([string]::IsNullOrWhiteSpace($usernameTextBox.Text)) {
                    $usernameTextBox.Focus()
                } else {
                    $passwordBox.Focus()
                }
            })
        })
        
        # OK button click handler with input validation
        $okButton.Add_Click({
            # Validate username - required field
            if ([string]::IsNullOrWhiteSpace($usernameTextBox.Text)) {
                [System.Windows.MessageBox]::Show("Please enter a username.", "Credential Error", 'OK', 'Warning')
                $usernameTextBox.Focus()
                return
            }
            
            # Validate username format (basic sanitization)
            $username = $usernameTextBox.Text.Trim()
            if ($username.Length -lt 3 -or $username.Length -gt 100) {
                [System.Windows.MessageBox]::Show("Username must be between 3 and 100 characters.", "Credential Error", 'OK', 'Warning')
                $usernameTextBox.Focus()
                return
            }
            
            # Check for potentially dangerous characters in username
            if ($username -match '[<>"''\\;/&|]') {
                [System.Windows.MessageBox]::Show("Username contains invalid characters.", "Credential Error", 'OK', 'Warning')
                $usernameTextBox.Focus()
                return
            }
            
            # Validate password - required field
            if ($passwordBox.SecurePassword.Length -eq 0) {
                [System.Windows.MessageBox]::Show("Please enter a password.", "Credential Error", 'OK', 'Warning')
                $passwordBox.Focus()
                return
            }
            
            # Validate password length
            if ($passwordBox.SecurePassword.Length -lt 1 -or $passwordBox.SecurePassword.Length -gt 256) {
                [System.Windows.MessageBox]::Show("Password must be between 1 and 256 characters.", "Credential Error", 'OK', 'Warning')
                $passwordBox.Focus()
                return
            }
            
            # Store results in dialog tag (sanitized username)
            $dialog.Tag = @{
                Username = $username
                Password = $passwordBox.SecurePassword.Copy()
                Remember = $rememberCheckBox.IsChecked
            }
            $dialog.DialogResult = $true
            $dialog.Close()
        })
        
        # Cancel button click handler
        $cancelButton.Add_Click({
            $dialog.DialogResult = $false
            $dialog.Close()
        })
        
        # Handle Enter key in both text boxes
        $usernameTextBox.Add_KeyDown({
            if ($_.Key -eq 'Enter') {
                $passwordBox.Focus()
            }
        })
        
        $passwordBox.Add_KeyDown({
            if ($_.Key -eq 'Enter') {
                $okButton.RaiseEvent([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
            }
        })
        
        # Set dialog owner to main window if available
        if ($uiHash.Window) {
            $dialog.Owner = $uiHash.Window
        }
        
        # Show dialog
        $result = $dialog.ShowDialog()
        
        if ($result -eq $true) {
            $credential = New-Object System.Management.Automation.PSCredential($dialog.Tag.Username, $dialog.Tag.Password)
            return $credential
        } else {
            return $null
        }
        
    } catch {
        Write-Error "Failed to show credential dialog: $($_.Exception.Message)"
        return $null
    }
}

function Show-CredentialConfigDialog {
    param()
    
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    
    # Create the credential configuration dialog
    $xamlDialog = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Configure Remote Credentials" Height="380" Width="500"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="20"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="10"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="10"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="10"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="20"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <TextBlock Grid.Row="0" Text="Configure custom credentials for remote WMI/RPC operations:" 
                   FontWeight="Bold" FontSize="12" TextWrapping="Wrap"/>
        
        <CheckBox Grid.Row="2" Name="UseCredentialsCheckBox" Content="Use custom credentials for remote connections" 
                  FontSize="11" VerticalAlignment="Center"/>
        
        <Label Grid.Row="4" Content="Username:" FontSize="11" Padding="0,0,0,5"/>
        <TextBox Grid.Row="4" Name="UsernameTextBox" Height="25" Margin="80,0,0,0" 
                 ToolTip="Enter username (e.g., administrator or domain\\username)"/>
        
        <Label Grid.Row="6" Content="Domain:" FontSize="11" Padding="0,0,0,5"/>
        <TextBox Grid.Row="6" Name="DomainTextBox" Height="25" Margin="80,0,0,0" 
                 ToolTip="Enter domain name (leave blank for local accounts)"/>
        
        <Label Grid.Row="8" Content="Password:" FontSize="11" Padding="0,0,0,5"/>
        <PasswordBox Grid.Row="8" Name="PasswordBox" Height="25" Margin="80,0,0,0" 
                     ToolTip="Enter password for the specified user"/>
        
        <TextBlock Grid.Row="10" Text="Note: Credentials will be securely stored with saved computer list configurations." 
                   FontStyle="Italic" FontSize="10" Foreground="Gray" TextWrapping="Wrap"/>
        
        <StackPanel Grid.Row="12" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
            <Button Name="TestButton" Content="Test Connection" Width="120" Height="30" Margin="0,0,10,0" 
                    ToolTip="Test the credentials with a sample WMI query"/>
            <Button Name="OKButton" Content="OK" Width="80" Height="30" Margin="0,0,10,0" IsDefault="True"/>
            <Button Name="CancelButton" Content="Cancel" Width="80" Height="30" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
"@
    
    try {
        $reader = [System.Xml.XmlNodeReader]::new([xml]$xamlDialog)
        $dialog = [Windows.Markup.XamlReader]::Load($reader)
        
        # Get dialog controls
        $useCredentialsCheckBox = $dialog.FindName('UseCredentialsCheckBox')
        $usernameTextBox = $dialog.FindName('UsernameTextBox')
        $domainTextBox = $dialog.FindName('DomainTextBox')
        $passwordBox = $dialog.FindName('PasswordBox')
        $testButton = $dialog.FindName('TestButton')
        $okButton = $dialog.FindName('OKButton')
        
        # Load current configuration
        $useCredentialsCheckBox.IsChecked = $global:CredentialConfig.UseCredentials
        $usernameTextBox.Text = $global:CredentialConfig.Username
        $domainTextBox.Text = $global:CredentialConfig.Domain
        
        # Enable/disable controls based on checkbox
        $enableControls = {
            $enabled = $useCredentialsCheckBox.IsChecked
            $usernameTextBox.IsEnabled = $enabled
            $domainTextBox.IsEnabled = $enabled
            $passwordBox.IsEnabled = $enabled
            $testButton.IsEnabled = $enabled
        }
        
        $useCredentialsCheckBox.Add_Click($enableControls)
        & $enableControls
        
        # Test button click handler
        $testButton.Add_Click({
            try {
                if ([string]::IsNullOrWhiteSpace($usernameTextBox.Text)) {
                    [System.Windows.MessageBox]::Show("Please enter a username.", "Test Credentials", 'OK', 'Warning')
                    return
                }
                
                if ($passwordBox.SecurePassword.Length -eq 0) {
                    [System.Windows.MessageBox]::Show("Please enter a password.", "Test Credentials", 'OK', 'Warning')
                    return
                }
                
                # Create test credential
                $username = if ([string]::IsNullOrWhiteSpace($domainTextBox.Text)) { 
                    $usernameTextBox.Text 
                } else { 
                    "$($domainTextBox.Text)\$($usernameTextBox.Text)" 
                }
                
                $testCredential = New-Object System.Management.Automation.PSCredential($username, $passwordBox.SecurePassword.Copy())
                
                # Test with local computer first.
                # NOTE: PS 5.1's Get-CimInstance has NO -Credential parameter; alternate
                # credentials must go through New-CimSession (DCOM) + Get-CimInstance -CimSession.
                $testSession = $null
                try {
                    $testSession = New-CimSession -ComputerName 'localhost' -Credential $testCredential -SessionOption (New-CimSessionOption -Protocol DCOM) -ErrorAction Stop
                    $testResult = Get-CimInstance -CimSession $testSession -ClassName Win32_ComputerSystem -ErrorAction Stop
                } finally {
                    if ($testSession) { Remove-CimSession -CimSession $testSession -ErrorAction SilentlyContinue }
                }
                
                if ($testResult) {
                    [System.Windows.MessageBox]::Show("Credentials test successful!`nComputer: $($testResult.Name)", "Test Credentials", 'OK', 'Information')
                } else {
                    [System.Windows.MessageBox]::Show("Credentials test failed - no result returned.", "Test Credentials", 'OK', 'Error')
                }
            } catch {
                [System.Windows.MessageBox]::Show("Credentials test failed:`n$($_.Exception.Message)", "Test Credentials", 'OK', 'Error')
            }
        })
        
        # OK button click handler
        $okButton.Add_Click({
            try {
                # Update configuration
                $global:CredentialConfig.UseCredentials = $useCredentialsCheckBox.IsChecked
                $global:CredentialConfig.Username = $usernameTextBox.Text
                $global:CredentialConfig.Domain = $domainTextBox.Text
                
                if ($useCredentialsCheckBox.IsChecked) {
                    if ([string]::IsNullOrWhiteSpace($usernameTextBox.Text)) {
                        [System.Windows.MessageBox]::Show("Please enter a username when using custom credentials.", "Configuration Error", 'OK', 'Warning')
                        return
                    }
                    
                    if ($passwordBox.SecurePassword.Length -eq 0) {
                        [System.Windows.MessageBox]::Show("Please enter a password when using custom credentials.", "Configuration Error", 'OK', 'Warning')
                        return
                    }
                    
                    # Create and store the credential
                    $username = if ([string]::IsNullOrWhiteSpace($domainTextBox.Text)) { 
                        $usernameTextBox.Text 
                    } else { 
                        "$($domainTextBox.Text)\$($usernameTextBox.Text)" 
                    }
                    
                    $global:CustomCredentials = New-Object System.Management.Automation.PSCredential($username, $passwordBox.SecurePassword.Copy())
                    $global:UseCustomCredentials = $true
                    
                    # Clear credential cache when credentials change
                    $global:CredentialCache.Clear()
                    # BUMP THE EPOCH. Every existing per-computer runspace captured the OLD credential
                    # globals at creation, so without this a newly submitted operation would resolve its
                    # identity from the stale copies - silently running as the previous account. The
                    # submission point rebuilds a runspace whose stamped epoch differs.
                    Update-WuuCredentialEpoch -Reason 'custom credentials configured' | Out-Null
                    
                    Write-DebugLog "Custom credentials configured for user: $username" -Level 'INFO'
                } else {
                    $global:UseCustomCredentials = $false
                    $global:CustomCredentials = $null
                    $global:CredentialCache.Clear()
                    # Same reason as above: disabling custom credentials changes the identity every
                    # remote operation will use, so stale runspaces must not be reused.
                    Update-WuuCredentialEpoch -Reason 'custom credentials disabled' | Out-Null
                    
                    Write-DebugLog "Custom credentials disabled" -Level 'INFO'
                }
                
                $dialog.DialogResult = $true
                $dialog.Close()
            } catch {
                [System.Windows.MessageBox]::Show("Error saving credentials: $($_.Exception.Message)", "Configuration Error", 'OK', 'Error')
            }
        })
        
        # Set dialog owner to main window if available
        if ($uiHash.Window) {
            $dialog.Owner = $uiHash.Window
        }
        
        # Show dialog
        $result = $dialog.ShowDialog()
        return $result
        
    } catch {
        Write-Error "Failed to show credential configuration dialog: $($_.Exception.Message)"
        return $false
    }
}

function Protect-ComputerListData {
    param(
        [string]$Data,
        [SecureString]$Password
    )
    
    try {
        # Convert SecureString password to byte array for encryption key
        $passwordBSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $passwordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($passwordBSTR)
        
        # Create a 256-bit key from the password
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $key = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($passwordPlain))
        
        # Convert data to SecureString without using -AsPlainText
        $secureData = New-Object System.Security.SecureString
        foreach ($ch in $Data.ToCharArray()) { $secureData.AppendChar($ch) }
        $secureData.MakeReadOnly()
        
        # Encrypt the data using the key
        $encryptedData = $secureData | ConvertFrom-SecureString -Key $key
        
        # Clean up
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordBSTR)
        $sha256.Dispose()
        
        return @{ Success = $true; Data = $encryptedData; Error = $null }
    } catch {
        return @{ Success = $false; Data = $null; Error = $_.Exception.Message }
    }
}

function Unprotect-ComputerListData {
    param(
        [string]$EncryptedData,
        [SecureString]$Password
    )
    
    try {
        # Convert SecureString password to byte array for decryption key
        $passwordBSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $passwordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($passwordBSTR)
        
        # Create a 256-bit key from the password
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $key = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($passwordPlain))
        
        # Decrypt the data
        $secureData = $EncryptedData | ConvertTo-SecureString -Key $key
        
        # Convert back to plain text (free the BSTR holding the decrypted plaintext)
        $dataBSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureData)
        $plainText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($dataBSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($dataBSTR)
        
        # Clean up
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordBSTR)
        $sha256.Dispose()
        
        return @{ Success = $true; Data = $plainText; Error = $null }
    } catch {
        return @{ Success = $false; Data = $null; Error = $_.Exception.Message }
    }
}

function Save-ComputerListConfig {
    param(
        [array]$ComputerList,
        [string]$ConfigPath,
        [SecureString]$Password
    )
    
    try {
        # Create configuration object
        $config = @{
            SavedDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            ComputerCount = $ComputerList.Count
            Computers = $ComputerList | ForEach-Object {
                @{
                    Computer = $_.Computer
                    Phase = if ($_.Phase) { $_.Phase } else { "Phase 1" }
                    # Only save computer name and phase - all other status data is temporary
                }
            }
            # Save credential configuration if custom credentials are used
            CredentialConfig = if ($global:UseCustomCredentials) {
                @{
                    Username = $global:CredentialConfig.Username
                    Domain = $global:CredentialConfig.Domain
                }
            } else {
                $null
            }
        }
        
        # Convert to JSON
        $jsonData = $config | ConvertTo-Json -Depth 4
        
        # Encrypt the data
        $encryptResult = Protect-ComputerListData -Data $jsonData -Password $Password
        
        if (-not $encryptResult.Success) {
            throw "Encryption failed: $($encryptResult.Error)"
        }
        
        # Save to file
        $encryptResult.Data | Out-File -FilePath $ConfigPath -Encoding UTF8 -Force
        
        return @{ Success = $true; Error = $null }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Import-ComputerListConfig {
    param(
        [string]$ConfigPath,
        [SecureString]$Password
    )
    
    try {
        if (-not (Test-Path -Path $ConfigPath)) {
            throw "Configuration file not found: $ConfigPath"
        }
        
        # Read encrypted data
        $encryptedData = Get-Content -Path $ConfigPath -Raw
        
        # Decrypt the data
        $decryptResult = Unprotect-ComputerListData -EncryptedData $encryptedData -Password $Password
        
        if (-not $decryptResult.Success) {
            throw "Decryption failed: $($decryptResult.Error)"
        }
        
        # Parse JSON
        $config = $decryptResult.Data | ConvertFrom-Json
        
        return @{ Success = $true; Config = $config; Error = $null }
    } catch {
        return @{ Success = $false; Config = $null; Error = $_.Exception.Message }
    }
}

Export-ModuleMember -Function @('Protect-Credential', 'Unprotect-Credential', 'Get-RemoteCredentials', 'Resolve-WuuOperationCredential', 'Update-WuuCredentialEpoch', 'Get-WuuCredentialStateSignature', 'Test-WuuCredentialStateMatches', 'Show-PasswordPrompt', 'Show-CustomCredentialDialog', 'Show-CredentialConfigDialog', 'Protect-ComputerListData', 'Unprotect-ComputerListData', 'Save-ComputerListConfig', 'Import-ComputerListConfig')

