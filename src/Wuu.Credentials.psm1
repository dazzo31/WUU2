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

function Get-RemoteCredentials {
    param(
        [string]$ComputerName,
        [string]$Operation = 'WMI access'
    )
    
    try {
        # Check cache first (runtime only, never persisted)
        if ($global:CredentialCache.ContainsKey($ComputerName)) {
            Write-DebugLog "Using cached credentials for $ComputerName" -Level 'DEBUG'
            return $global:CredentialCache[$ComputerName]
        }
        
        # Try custom configured credentials first if enabled
        if ($global:UseCustomCredentials -and $global:CustomCredentials) {
            try {
                Write-DebugLog "Testing custom credentials for $ComputerName" -Level 'DEBUG'
                # Use helper function for credential test
                $wmiResult = Invoke-CimWithTimeout -ComputerName $ComputerName -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 5 -Credential $global:CustomCredentials -Operation 'Custom credential test'
                
                if ($wmiResult.Success) {
                    # Custom credentials work, cache them (runtime cache only)
                    Write-DebugLog "Custom credentials successful for $ComputerName, caching" -Level 'INFO'
                    $global:CredentialCache[$ComputerName] = $global:CustomCredentials
                    return $global:CustomCredentials
                } else {
                    Write-DebugLog "Custom credentials failed for $ComputerName : $($wmiResult.Error)" -Level 'WARN'
                }
            } catch {
                Write-DebugLog "Custom credentials test failed for $ComputerName : $($_.Exception.Message)" -Level 'WARN'
            }
        }
        
        # Custom credentials failed or not configured, try default credentials
        try {
            Write-DebugLog "Testing default credentials for $ComputerName" -Level 'DEBUG'
            # Use helper function for default credential test
            $wmiResult = Invoke-CimWithTimeout -ComputerName $ComputerName -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 5 -Operation 'Default credential test'
            
            if ($wmiResult.Success) {
                # Default credentials work, cache success (runtime cache only)
                Write-DebugLog "Default credentials successful for $ComputerName, caching" -Level 'INFO'
                $global:CredentialCache[$ComputerName] = $null  # null means use default credentials
                return $null
            } else {
                Write-DebugLog "Default credentials failed for $ComputerName : $($wmiResult.Error)" -Level 'WARN'
            }
        } catch {
            Write-DebugLog "Default credentials test failed for $ComputerName : $($_.Exception.Message)" -Level 'WARN'
        }
        
        # Both failed - return null to indicate auth failure
        # Caller will handle the error appropriately
        Write-DebugLog "All credential tests failed for $ComputerName - returning null" -Level 'WARN'
        return $null
        
    } catch {
        Write-DebugLog "Error in Get-RemoteCredentials for $ComputerName : $($_.Exception.Message)" -Level 'ERROR'
        return $null
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
                    
                    Write-DebugLog "Custom credentials configured for user: $username" -Level 'INFO'
                } else {
                    $global:UseCustomCredentials = $false
                    $global:CustomCredentials = $null
                    $global:CredentialCache.Clear()
                    
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

Export-ModuleMember -Function @('Protect-Credential', 'Unprotect-Credential', 'Get-RemoteCredentials', 'Show-PasswordPrompt', 'Show-CustomCredentialDialog', 'Show-CredentialConfigDialog', 'Protect-ComputerListData', 'Unprotect-ComputerListData', 'Save-ComputerListConfig', 'Import-ComputerListConfig')

