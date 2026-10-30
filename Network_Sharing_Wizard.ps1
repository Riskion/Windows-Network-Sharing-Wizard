# Windows 11 Network Sharing Wizard - Version 2.0.3
# Run as administrator. Uses authenticated SMB sharing; does not enable guest access.
$ErrorActionPreference = 'Stop'

function Pause-Menu { Write-Host ''; Read-Host 'Press Enter to continue' | Out-Null }
function Show-Title([string]$Text) {
    Clear-Host
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ''
}
function Test-IPv4([string]$Address) {
    $parsed = $null
    return [System.Net.IPAddress]::TryParse($Address, [ref]$parsed) -and $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}
function Test-SecureStringEqual([System.Security.SecureString]$First, [System.Security.SecureString]$Second) {
    $ptr1 = [IntPtr]::Zero
    $ptr2 = [IntPtr]::Zero
    try {
        $ptr1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($First)
        $ptr2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Second)
        $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr1)
        $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr2)
        return [string]::Equals($plain1, $plain2, [StringComparison]::Ordinal)
    } finally {
        if ($ptr1 -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr1) }
        if ($ptr2 -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr2) }
    }
}
function Get-SecureStringLength([System.Security.SecureString]$Value) {
    $ptr = [IntPtr]::Zero
    try {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        return $plain.Length
    } finally {
        if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }
}
function Read-ConfirmedNetworkPassword {
    Write-Host ''
    Write-Host 'CREATE YOUR NETWORK-SHARING PASSWORD' -ForegroundColor Cyan
    Write-Host 'Choose a strong password for access to the shared files.'
    Write-Host 'IMPORTANT: Write this password down in Notepad or somewhere safe before continuing. You will need it when connecting from your other PC.' -ForegroundColor Yellow
    Write-Host 'IMPORTANT: Copying and pasting does not work in this hidden password field. You must type the password manually.' -ForegroundColor Yellow
    Write-Host 'As you type, Windows will show NO letters, dots, or asterisks. This is normal; the keyboard is working.'
    Write-Host 'Type the password and press Enter, then type it again to confirm.'
    while ($true) {
        $first = Read-Host 'New network-sharing password (input is hidden)' -AsSecureString
        $length = Get-SecureStringLength $first
        if ($length -lt 8) {
            Write-Host "Your password has $length characters. Please use at least 8 characters. A longer, unique password is safer." -ForegroundColor Yellow
            $first.Dispose()
            continue
        }
        $second = Read-Host 'Type the same password again (input is hidden)' -AsSecureString
        $matches = Test-SecureStringEqual $first $second
        $second.Dispose()
        if ($matches) { return $first }
        Write-Host 'The passwords did not match. Please try again.' -ForegroundColor Yellow
        $first.Dispose()
    }
}
function Get-ComputerIPv4 {
    Get-NetIPConfiguration | Where-Object {
        $_.IPv4Address -and $_.NetAdapter.Status -eq 'Up' -and $_.IPv4DefaultGateway
    } | ForEach-Object {
        [pscustomobject]@{ Adapter=$_.InterfaceAlias; IPv4=$_.IPv4Address.IPAddress; Gateway=($_.IPv4DefaultGateway.NextHop -join ', ') }
    }
}
function Configure-Discovery {
    Write-Host 'Preparing this computer for network discovery and file sharing...'
    Write-Host 'IMPORTANT: Use this sharing wizard only on a trusted home or work network.' -ForegroundColor Yellow
    Write-Host 'Active Public network profiles will automatically be changed to Private.'
    $profiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue
    $public = @($profiles | Where-Object NetworkCategory -eq 'Public')
    foreach ($p in $public) {
        try {
            Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
            Write-Host "Network '$($p.Name)' changed to Private." -ForegroundColor Green
        } catch {
            Write-Host "Could not change network '$($p.Name)' to Private: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    foreach ($serviceName in @('FDResPub','fdPHost')) {
        try {
            Set-Service -Name $serviceName -StartupType Automatic
            Start-Service -Name $serviceName -ErrorAction SilentlyContinue
        } catch { Write-Host "Could not configure discovery service $serviceName." -ForegroundColor Yellow }
    }
    try {
        Enable-NetFirewallRule -DisplayGroup 'Network Discovery' -Profile Private -ErrorAction SilentlyContinue | Out-Null
        Enable-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -Profile Private -ErrorAction SilentlyContinue | Out-Null
    } catch { }
}

function Read-SharePath {
    while ($true) {
        Write-Host 'What would you like to share?'
        Write-Host '  1. An entire drive'
        Write-Host '  2. A specific folder'
        $choice = Read-Host 'Choose 1 or 2'
        if ($choice -eq '1') {
            Write-Host 'Available drives:' -ForegroundColor Cyan
            $volumes = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveType -in @('Fixed','Removable') })
            foreach ($volume in $volumes) {
                $label = if ([string]::IsNullOrWhiteSpace($volume.FileSystemLabel)) { 'Local drive' } else { $volume.FileSystemLabel }
                Write-Host ("  {0} ({1}:)" -f $label, $volume.DriveLetter)
            }
            Write-Host 'You can also check the drive names and letters under This PC.'
            $letter = (Read-Host 'Enter the drive letter only, for example E').Trim().TrimEnd(':')
            if ($letter -match '^[A-Za-z]$') {
                $path = "$($letter.ToUpper()):\"
                if (Test-Path -LiteralPath $path) { return $path }
            }
            Write-Host 'That drive could not be found. Enter one drive letter, such as E.' -ForegroundColor Yellow
        } elseif ($choice -eq '2') {
            Write-Host ''
            Write-Host 'WANT TO SHARE JUST ONE FOLDER?' -ForegroundColor Cyan
            Write-Host 'You can create a folder inside This PC and share only that folder:'
            Write-Host '  Open This PC.'
            Write-Host '  Open the drive where you want the folder.'
            Write-Host '  Right-click an empty space and choose New > Folder.'
            Write-Host '  Give the folder a name, for example SharedFiles.'
            Write-Host '  Choose that folder when this wizard asks what you want to share.'
            Write-Host ''
            Write-Host 'HOW TO FIND THE FOLDER PATH' -ForegroundColor Cyan
            Write-Host '  Open the folder you want to share.'
            Write-Host '  At the top, click the bar where the folder name is displayed.'
            Write-Host '  Right-click the path and select Copy (or press Ctrl + C).'
            Write-Host '  Return to this setup and paste the path using Ctrl + V.'
            $path = Read-Host 'Paste the full folder path here'
            if (Test-Path -LiteralPath $path -PathType Container) { return (Resolve-Path -LiteralPath $path).Path }
            Write-Host 'That folder could not be found. Try again.' -ForegroundColor Yellow
        } else { Write-Host 'Please enter 1 or 2.' -ForegroundColor Yellow }
    }
}

function Show-NetworkPrerequisite {
    Show-Title 'BEFORE YOU START - CHECK BOTH PCs'
    Write-Host 'IMPORTANT: Both PCs must be connected to the same local network.' -ForegroundColor Yellow
    Write-Host 'For example, both must use the same home router, by Wi-Fi or network cable.'
    Write-Host ''
    Write-Host 'CHECK THIS ON BOTH PCs:' -ForegroundColor Cyan
    Write-Host '  1. Press Windows + R, type cmd, and press Enter.'
    Write-Host '  2. Type ipconfig and press Enter.'
    Write-Host '  3. Find IPv4 Address and Default Gateway under the active Wi-Fi or Ethernet adapter.'
    Write-Host '  4. Repeat these steps on the other PC, then compare the results.'
    Write-Host ''
    Write-Host 'In a typical home network, the first three groups of the IPv4 addresses should match.'
    Write-Host 'For example: 192.168.178.20 and 192.168.178.35.'
    Write-Host 'The Default Gateway should also be the same on both PCs, for example 192.168.178.1.'
    Write-Host 'If they differ, check that both PCs are connected to the same router/network.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Do not compare VPN or virtual adapters. Use the active Wi-Fi or Ethernet connection.'
    Pause-Menu
}

function Show-AccountFirstStep {
    Show-Title 'CHECK YOUR WINDOWS ACCOUNT TYPE'
    Write-Host 'You do not need to change your Windows account. This is just information.' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'To check which type of account you use:'
    Write-Host '  1. Right-click the Start button.'
    Write-Host '  2. Select Settings.'
    Write-Host '  3. Select Accounts.'
    Write-Host '  4. Select Your info.'
    Write-Host ''
    Write-Host 'There you can see whether you use a Microsoft account or a local account.'
    Write-Host 'The wizard creates a separate local account named NetworkShare for file sharing.' -ForegroundColor Green
    Write-Host 'This network-sharing account is separate from your normal Windows sign-in.'
    Write-Host 'When connecting to another PC, the username is NetworkShare and the password is the one created on the PC hosting the files.'
    Pause-Menu
}


# Save credentials through the Windows Credential Manager API instead of putting the password
# on a cmdkey command line. Credentials are saved for both the host name and IPv4 address.
if (-not ('NetworkWizardCredentialApi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NetworkWizardCredentialApi {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public UInt32 Flags;
        public UInt32 Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public UInt32 CredentialBlobSize;
        public IntPtr CredentialBlob;
        public UInt32 Persist;
        public UInt32 AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }
    [DllImport("Advapi32.dll", EntryPoint="CredWriteW", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool CredWrite(ref CREDENTIAL userCredential, UInt32 flags);
    [DllImport("Advapi32.dll", EntryPoint="CredReadW", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool CredRead(string target, UInt32 type, UInt32 flags, out IntPtr credential);
    [DllImport("Advapi32.dll", EntryPoint="CredFree", SetLastError=false)]
    public static extern void CredFree(IntPtr buffer);
}
'@
}
function Save-NetworkCredential([string]$Target,[string]$UserName,[System.Security.SecureString]$Password) {
    $ptr = [IntPtr]::Zero
    $blobPtr = [IntPtr]::Zero
    try {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        $blob = [Text.Encoding]::Unicode.GetBytes($plain + [char]0)
        $blobPtr = [Runtime.InteropServices.Marshal]::AllocHGlobal($blob.Length)
        [Runtime.InteropServices.Marshal]::Copy($blob, 0, $blobPtr, $blob.Length)
        $cred = New-Object NetworkWizardCredentialApi+CREDENTIAL
        $cred.Flags = 0
        $cred.Type = 2 # CRED_TYPE_DOMAIN_PASSWORD, used by Windows for network logons
        $cred.TargetName = $Target
        $cred.CredentialBlobSize = [uint32]$blob.Length
        $cred.CredentialBlob = $blobPtr
        $cred.Persist = 2 # CRED_PERSIST_LOCAL_MACHINE
        $cred.AttributeCount = 0
        $cred.Attributes = [IntPtr]::Zero
        $cred.TargetAlias = $null
        $cred.UserName = $UserName
        if (-not [NetworkWizardCredentialApi]::CredWrite([ref]$cred, 0)) {
            $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "Windows Credential Manager could not save '$Target' (error $err)."
        }
        $readPtr = [IntPtr]::Zero
        if (-not [NetworkWizardCredentialApi]::CredRead($Target, 2, 0, [ref]$readPtr)) {
            $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "Credential '$Target' was written but could not be verified (error $err)."
        }
        try {
            $verified = [Runtime.InteropServices.Marshal]::PtrToStructure($readPtr, [type][NetworkWizardCredentialApi+CREDENTIAL])
            if ($verified.TargetName -ine $Target -or $verified.UserName -ine $UserName) {
                throw "Credential Manager verification failed for '$Target'."
            }
        } finally { [NetworkWizardCredentialApi]::CredFree($readPtr) }
    } finally {
        if ($blobPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeHGlobal($blobPtr) }
        if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        if ($plain) { $plain = $null }
    }
}
function Save-BothNetworkCredentials([string]$HostName,[string]$Address,[string]$UserName,[System.Security.SecureString]$Password) {
    Write-Host ''
    Write-Host 'Saving and verifying network credentials in Windows Credential Manager...' -ForegroundColor Cyan
    Save-NetworkCredential -Target $HostName -UserName $UserName -Password $Password
    Save-NetworkCredential -Target $Address -UserName $UserName -Password $Password
    Write-Host "Verified computer-name credential: $HostName" -ForegroundColor Green
    Write-Host "Verified IPv4-address credential: $Address" -ForegroundColor Green
    Write-Host 'Unrelated saved credentials are not removed.'
}

function Setup-Share {
    Show-Title 'SET UP SHARING ON THIS COMPUTER'
    Write-Host 'This option creates a share on THIS computer so your other computer can access it.'
    Write-Host 'You can share an entire drive or one specific folder.'
    Write-Host ''
    Configure-Discovery
    $path = Read-SharePath
    Write-Host "`nSelected path: $path" -ForegroundColor Cyan
    if ($path -match '^([A-Za-z]):\\$') {
        $driveLetter = $Matches[1].ToUpper()
        $driveInfo = Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue | Select-Object -First 1
        $driveLabel = if ($driveInfo -and -not [string]::IsNullOrWhiteSpace($driveInfo.FileSystemLabel)) { $driveInfo.FileSystemLabel } else { 'Local drive' }
        $confirm = Read-Host "Are you sure you want to share this entire drive $driveLabel ($driveLetter`:)? Type YES to continue, or anything else to cancel"
        if ($confirm -cne 'YES') { Write-Host 'Cancelled.'; return }
        $shareName = $driveLetter
        Write-Host "Network share name: $shareName (the drive is $driveLetter`:)." -ForegroundColor Cyan
    } else {
        Write-Host ''
        $folderName = Split-Path -Path $path -Leaf
        if ([string]::IsNullOrWhiteSpace($folderName)) { $folderName = (Get-Item -LiteralPath $path).Name }
        Write-Host 'CHOOSE A NETWORK SHARE NAME' -ForegroundColor Cyan
        Write-Host "The folder name is '$folderName'. This will be the default network share name."
        Write-Host "  1. Use $folderName (recommended)"
        Write-Host '  2. Choose your own network name'
        $nameChoice = Read-Host 'Enter 1 or 2'
        if ($nameChoice -eq '2') {
            do { $shareName = (Read-Host 'Enter your own short network share name (no slashes or colons)').Trim() }
            while ([string]::IsNullOrWhiteSpace($shareName) -or $shareName -match '[\\/:*?"<>|]')
        } else { $shareName = $folderName }
    }
    $existing = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "A share named '$shareName' already exists at '$($existing.Path)'." -ForegroundColor Yellow
        $replace = Read-Host 'Keep the existing share and return? Type YES to keep it'
        if ($replace -ceq 'YES') { return }
        Write-Host 'No changes made to the existing share.'
        return
    }

    Write-Host ''
    # Use a predictable dedicated account so the connecting wizard can explain it simply.
    $account = 'NetworkShare'
    $computer = $env:COMPUTERNAME
    $fullAccount = "$computer\$account"
    $user = Get-LocalUser -Name $account -ErrorAction SilentlyContinue
    $changeExistingPassword = $false
    if ($user) {
        Write-Host "A local network-sharing account named '$account' already exists on this computer." -ForegroundColor Yellow
        if (-not $user.PasswordRequired) {
            Write-Host 'WARNING: Windows reports that this account does not require a password.' -ForegroundColor Red
            Write-Host 'This can cause network connections to be treated as guest/unauthenticated.' -ForegroundColor Yellow
            Write-Host 'To continue safely, you must explicitly set a password for this account, or cancel.' -ForegroundColor Yellow
            $accountChoice = Read-Host 'Type SETPASSWORD to set a new network-sharing password, or anything else to cancel'
            if ($accountChoice -cne 'SETPASSWORD') {
                Write-Host 'Cancelled. The existing account and password were left unchanged.' -ForegroundColor Yellow
                return
            }
            $changeExistingPassword = $true
        } else {
            Write-Host 'By default, the wizard will KEEP its existing password and continue without changing it.' -ForegroundColor Green
            Write-Host 'Only choose a new password if you know this will not disrupt another use of the account.' -ForegroundColor Yellow
            Write-Host '  1. Keep the existing password (recommended default)'
            Write-Host '  2. Set a new password (requires explicit choice)'
            Write-Host '  3. Cancel setup'
            $accountChoice = Read-Host 'Choose 1, 2, or 3'
            if ($accountChoice -eq '3' -or $accountChoice -notin @('1','2')) {
                Write-Host 'Cancelled. No share was created and the account password was not changed.' -ForegroundColor Yellow
                return
            }
            $changeExistingPassword = ($accountChoice -eq '2')
        }
    }
    $password = $null
    if (-not $user -or $changeExistingPassword) {
        $password = Read-ConfirmedNetworkPassword
    }
    try {
        if (-not $user) {
            New-LocalUser -Name $account -Password $password -Description 'Account for authenticated network file sharing' -PasswordNeverExpires:$false | Out-Null
            $user = Get-LocalUser -Name $account
        } elseif ($changeExistingPassword) {
            Set-LocalUser -Name $account -Password $password
            $user = Get-LocalUser -Name $account
        }
        if (-not $user.Enabled) { Enable-LocalUser -Name $account }

        # Explicitly require a password and verify the resulting account state.
        & net.exe user $account /passwordreq:yes | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Windows could not set the password-required flag for '$account'."
        }
        $user = Get-LocalUser -Name $account
        if (-not $user.Enabled -or -not $user.PasswordRequired) {
            throw "The '$account' account is not enabled with password-required set to True. Sharing setup stopped."
        }
    } finally {
        if ($password) { $password.Dispose() }
    }

    Write-Host ''
    Write-Host 'NETWORK LOGIN DETAILS' -ForegroundColor Cyan
    Write-Host 'The network share name (drive letter or folder name) is NOT the login name.'
    Write-Host 'Network name for sign-in: NetworkShare'
    Write-Host 'Password: The network-sharing password you created on THIS PC.'

    Write-Host ''
    Write-Host 'The wizard needs permission to let this account access the selected files.'
    Write-Host 'It will grant Modify access to this folder and its contents. For a whole drive, this applies across that drive.' -ForegroundColor Yellow
    $perm = Read-Host 'Apply these file permissions and create the share? Type YES to continue'
    if ($perm -cne 'YES') { Write-Host 'Cancelled. No share was created.'; return }

    # Apply inherited Modify rights at the selected folder/drive root. Avoid /T here:
    # recursive ACL changes can fail on protected system folders and prevent share creation.
    $aclGrant = "${computer}\${account}:(OI)(CI)M"
    $icaclsOutput = & icacls.exe $path /grant $aclGrant /C 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Windows reported a problem setting folder permissions. The share has NOT been created.' -ForegroundColor Red
        $icaclsOutput | Select-Object -Last 8 | ForEach-Object { Write-Host $_ }
        Write-Host 'Try a folder inside your user Documents folder, rather than a protected Windows/system folder or the root of a drive.' -ForegroundColor Yellow
        return
    }

    try {
        New-SmbShare -Name $shareName -Path $path -ChangeAccess $fullAccount -FolderEnumerationMode AccessBased -CachingMode None -ErrorAction Stop | Out-Null
        $createdShare = Get-SmbShare -Name $shareName -ErrorAction Stop
        if (-not $createdShare -or $createdShare.Path -ne $path) {
            throw 'Windows did not confirm that the share points to the selected folder.'
        }
    } catch {
        Write-Host "Windows could not create or verify the share: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'No successful share creation is being reported. Check that the share name is not already used and that the selected path is accessible.' -ForegroundColor Yellow
        return
    }

    $ipv4s = @(Get-ComputerIPv4)
    Write-Host ''
    Write-Host 'SHARE CREATED AND VERIFIED' -ForegroundColor Green
    Write-Host "Share name: $shareName"
    Write-Host "Shared path: $path"
    Write-Host "Network address: \\$computer\$shareName"
    Write-Host "Network account: $fullAccount"
    Write-Host 'Keep the password safe. Do not share it with people who should not access these files.'
    Write-Host ''
    Write-Host 'Hiding the NetworkShare account from the Windows sign-in screen...' -ForegroundColor Cyan
    Write-Host 'The account remains enabled for network authentication.'
    try {
        $userListPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
        New-Item -Path $userListPath -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $userListPath -Name $account -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
        Write-Host 'NetworkShare is hidden from the sign-in screen.' -ForegroundColor Green
    } catch {
        Write-Host "Could not hide the account from the sign-in screen: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host 'The account remains enabled; network sharing can still work.' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host 'SETUP COMPLETE!' -ForegroundColor Green
    Write-Host 'Your folder has been successfully shared.'
    Write-Host 'The Network Sharing Wizard has finished.'
    Write-Host ''
    Write-Host 'You can now close this wizard.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'NEXT STEP: GO TO YOUR OTHER PC' -ForegroundColor Cyan
    Write-Host '  1. On your other PC, open Network from the desktop.'
    Write-Host "  2. Find the name of the PC where you just created the shared folder: $computer"
    Write-Host '  3. Double-click that PC.'
    Write-Host "  4. You should see your shared folder, named: $shareName"
    Write-Host '  5. Double-click the folder to open it.'
    Write-Host ''
    Write-Host 'IF WINDOWS ASKS FOR NETWORK CREDENTIALS' -ForegroundColor Cyan
    Write-Host '  Network name: NetworkShare'
    Write-Host '  Password: Enter the password you created during setup.'
    Write-Host '  Tick Remember my credentials, then click OK.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "CAN'T SEE THE NETWORK ICON ON YOUR DESKTOP?" -ForegroundColor Cyan
    Write-Host '  1. Right-click an empty area of the desktop and select Personalize.'
    Write-Host '  2. Open Themes, then Desktop icon settings.'
    Write-Host '  3. Tick Network, then select Apply and OK.'
    Write-Host ''
    Write-Host 'If the PC or folder does not appear immediately, wait a little and press F5 to refresh.'
    Write-Host 'Remember: the shared folder name is not the network sign-in name.'
    if ($ipv4s.Count) {
        Write-Host "`nPossible IPv4 addresses for this computer:"
        $ipv4s | ForEach-Object { Write-Host "  Adapter: $($_.Adapter) | IPv4: $($_.IPv4) | Gateway: $($_.Gateway)" }
        Write-Host 'Give the other person the IPv4 address on the adapter connected to the same router/network.'
    }
    Write-Host "`nShare network address: \\$computer\$shareName"
}
function Show-IpHelp {
    Write-Host 'HOW TO FIND THE OTHER COMPUTER NAME AND IP ADDRESS' -ForegroundColor Cyan
    Write-Host 'On the computer that already has the shared folder:'
    Write-Host '  1. Press Windows + R, type cmd, and press Enter.'
    Write-Host '  2. Type hostname and press Enter. Write down the result.'
    Write-Host '  3. Type ipconfig and press Enter.'
    Write-Host '  4. Find IPv4 Address under the active Ethernet or Wi-Fi adapter.'
    Write-Host '     If several adapters appear, use the one connected to the same router as this PC.'
    Write-Host '     Normally ignore Media disconnected, VPN, and virtual adapters.'
    Write-Host ''
    Write-Host 'Example only: PC-1 = 192.168.0.15 and PC-2 = 192.168.0.25.'
    Write-Host 'The first three number groups (192.168.0) match in this common home-network example.'
    Write-Host 'If the groups differ, check both connections and the router; this comparison is only a quick check.'
    Write-Host ''
    Write-Host 'To return to the wizard, leave this window open and use Alt+Tab.'
    $open = Read-Host 'Open Command Prompt now? Type YES (the wizard will wait while you check details)'
    if ($open -ceq 'YES') { Start-Process cmd.exe -Wait }
}
function Add-HostsMapping([string]$HostName,[string]$Address) {
    $answer = Read-Host "Help Windows find $HostName by linking its name to $Address on this PC? This does not rename the computer. Type YES to continue"
    if ($answer -cne 'YES') { return }
    $hostsPath = Join-Path $env:windir 'System32\drivers\etc\hosts'
    if (-not (Test-Path -LiteralPath $hostsPath -PathType Leaf)) {
        Write-Host "The Windows hosts file was not found at $hostsPath. No file was created." -ForegroundColor Red
        return
    }
    $backup = "$hostsPath.backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Copy-Item -LiteralPath $hostsPath -Destination $backup -ErrorAction Stop
    try {
        $lines = @(Get-Content -LiteralPath $hostsPath -ErrorAction Stop)
        # If the file is genuinely empty, seed it with explanatory standard comments before adding the mapping.
        if ($lines.Count -eq 0 -or (@($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -eq 0)) {
            $lines = @(
                '# Copyright (c) Microsoft Corp.',
                '#',
                '# This is a sample HOSTS file used by Microsoft TCP/IP for Windows.',
                '# Each entry should be kept on an individual line.',
                '# The IP address should be placed in the first column followed by the host name.',
                '#',
                '# Example:',
                '#      192.168.0.15    PC-1',
                '#'
            )
        }
        $output = New-Object System.Collections.Generic.List[string]
        foreach ($line in $lines) {
            $trim = $line.Trim()
            if (-not $trim -or $trim.StartsWith('#')) { $output.Add($line); continue }
            $parts = @($trim -split '\s+')
            if ($parts.Count -ge 2) {
                $aliases = @($parts[1..($parts.Count-1)])
                if (@($aliases | Where-Object { $_ -ieq $HostName }).Count -gt 0) {
                    $kept = @($aliases | Where-Object { $_ -ine $HostName })
                    if ($kept.Count -gt 0) { $output.Add("$($parts[0])`t$($kept -join ' ')") }
                    continue
                }
            }
            $output.Add($line)
        }
        $output.Add("$Address`t$HostName")
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($hostsPath, $output.ToArray(), $encoding)
        if ((Get-Content -LiteralPath $hostsPath -ErrorAction Stop | Measure-Object -Line).Lines -lt 1) {
            throw 'The hosts file appears empty after writing the entry.'
        }
        ipconfig /flushdns | Out-Null
        Write-Host "Name entry added/updated. Existing entries were preserved. Backup saved as: $backup" -ForegroundColor Green
        Write-Host "Added: $Address    $HostName"
    } catch {
        Copy-Item -LiteralPath $backup -Destination $hostsPath -Force -ErrorAction SilentlyContinue
        Write-Host "Could not update the hosts file. The backup was restored where possible. Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}
function Connect-Share {
    Show-Title 'CONNECT TO ANOTHER COMPUTER'
    Write-Host 'This option connects to a share that has ALREADY been created on the other computer.'
    Write-Host 'If no share exists yet, run this wizard on that computer and choose Set up sharing first.'
    Write-Host ''
    Show-IpHelp
    Write-Host ''
    $hostName = (Read-Host 'Enter the other computer name (example PC-1)').Trim()
    if ($hostName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,61}[A-Za-z0-9]$|^[A-Za-z0-9]$') { throw 'That computer name does not look valid. Use the name returned by hostname.' }
    $ip = (Read-Host 'Enter that computer IPv4 address (example 192.168.0.15)').Trim()
    if (-not (Test-IPv4 $ip)) { throw 'That is not a valid IPv4 address.' }
    $local = @(Get-ComputerIPv4)
    if ($local.Count) {
        $local | ForEach-Object { Write-Host "This PC: $($_.Adapter) = $($_.IPv4) (gateway $($_.Gateway))" }
        $localOctets = $local | ForEach-Object { ($_.IPv4 -split '\.')[0..2] -join '.' } | Select-Object -Unique
        $remotePrefix = ($ip -split '\.')[0..2] -join '.'
        if ($remotePrefix -notin $localOctets) {
            Write-Host 'Warning: the first three number groups do not match a local adapter shown above.' -ForegroundColor Yellow
            Write-Host 'This can be normal on some networks, but check both PCs are connected to the same router.'
            $continue = Read-Host 'Continue anyway? Type YES'
            if ($continue -cne 'YES') { return }
        }
    }
    Add-HostsMapping -HostName $hostName -Address $ip
    $shareName = (Read-Host 'Enter the share name created on the other computer (for example ShareFiles or E)').Trim()
    if ([string]::IsNullOrWhiteSpace($shareName) -or $shareName -match '[\\/:*?"<>|]') { throw 'That share name is invalid.' }
    $unc = "\\$hostName\$shareName"
    Write-Host ''
    Write-Host 'NETWORK-SHARING LOGIN' -ForegroundColor Cyan
    Write-Host 'Use the account configured for file sharing on the host computer, not your Windows PIN.'
    Write-Host 'Username: NetworkShare'
    Write-Host 'If Windows displays a Network Credentials box, tick Remember my credentials before clicking OK.' -ForegroundColor Yellow
    $networkUser = 'NetworkShare'
    Write-Host 'Enter the network-sharing account password. Input is hidden; no characters will appear while typing.' -ForegroundColor Yellow
    $networkPassword = Read-Host 'Network-sharing password (hidden)' -AsSecureString
    try {
        Save-BothNetworkCredentials -HostName $hostName -Address $ip -UserName $networkUser -Password $networkPassword
    } catch {
        Write-Host "Could not save and verify both credentials: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'The connection has been stopped so the wizard does not claim that both credentials were saved.' -ForegroundColor Yellow
        return
    } finally {
        if ($networkPassword) { $networkPassword.Dispose() }
    }
    Write-Host "`nTesting access to $unc ..."
    $shareAccessible = $false
    try {
        $shareAccessible = Test-Path -LiteralPath $unc -ErrorAction Stop
    } catch {
        $shareAccessible = $false
    }
    if (-not $shareAccessible) {
        Write-Host "Windows could not verify access to $unc using the saved credentials." -ForegroundColor Red
        Write-Host 'The credentials were saved, but no drive mapping will be reported as successful.' -ForegroundColor Yellow
        Write-Host 'Check that the share name exists on the host and that the network-sharing username/password are correct.' -ForegroundColor Yellow
        return
    }
    Write-Host 'Connection test succeeded.' -ForegroundColor Green
    $letter = (Read-Host 'Map it into This PC as a drive? Type YES for automatic drive-letter selection').Trim()
    if ($letter -ceq 'YES') {
        $used = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object Name)
        $available = @('Z','Y','X','W','V','U','T','S','R','Q','P','O','N','M','L','K','J','I','H','G','F','E','D') | Where-Object { $_ -notin $used } | Select-Object -First 1
        if (-not $available) { throw 'No available drive letter was found.' }
        $drive = "$available`:"
        Write-Host "The share will appear in This PC as drive $drive. Windows will ask for the network password if needed."
        Write-Host "The saved network-sharing username is: $networkUser"
        Write-Host 'The credentials have been saved for both the computer name and IPv4 address.'
        & net.exe use $drive $unc "/user:$networkUser" '/persistent:yes'
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Mapped successfully as $drive" -ForegroundColor Green
            $shortcutAnswer = Read-Host 'Also create a desktop shortcut to this share? Type YES'
            if ($shortcutAnswer -ceq 'YES') {
                $desktop = [Environment]::GetFolderPath('Desktop')
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $shell.CreateShortcut((Join-Path $desktop "$hostName - $shareName.lnk"))
                $shortcut.TargetPath = $unc
                $shortcut.Save()
                Write-Host 'Desktop shortcut created.' -ForegroundColor Green
            }
        }
    } else {
        Write-Host "To open it, press Windows + R and enter: $unc"
    }
    Write-Host ''
    Write-Host 'If the PC does not appear under Network straight away, wait a little or open the share using its network address.'
}

Show-NetworkPrerequisite
Show-AccountFirstStep
while ($true) {
    Show-Title 'WINDOWS 11 NETWORK SHARING WIZARD'
    Write-Host 'Choose what you want to do:'
    Write-Host '  1. Set up sharing on THIS computer (create a shared folder/drive)'
    Write-Host '  2. Connect to another computer (open an existing share and add it to This PC)'
    Write-Host '  3. Exit'
    $choice = Read-Host 'Enter 1, 2, or 3'
    try {
        switch ($choice) {
            '1' { Setup-Share; Pause-Menu }
            '2' { Connect-Share; Pause-Menu }
            '3' { break }
            default { Write-Host 'Please enter 1, 2, or 3.'; Pause-Menu }
        }
    } catch {
        Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'No success is claimed if the setup step failed.' -ForegroundColor Yellow
        Pause-Menu
    }
    if ($choice -eq '3') { break }
}