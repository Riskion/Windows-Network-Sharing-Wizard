# Windows 11 Network Sharing Wizard

A PowerShell wizard for setting up authenticated Windows 11 network sharing between PCs.

## Version

**2.0.3**

## Features

- Set up authenticated SMB sharing on a Windows PC.
- Share a specific folder or an entire drive.
- Create/use the dedicated local network-sharing account `NetworkShare`.
- Connect to shares from another PC and optionally map them as network drives.
- Store credentials through Windows Credential Manager.
- Supports share access without enabling guest access.

## Requirements

- Windows 11 on both PCs.
- Administrator privileges on the PC where sharing is configured.
- Both PCs connected to the same local network and able to communicate.
- A trusted home or work network. The wizard configures an active Public network profile as Private.

## Getting started

1. Download `Network_Sharing_Wizard.ps1` from this repository.
2. On the PC that will host the shared folder or drive, open **Windows PowerShell as Administrator**.
3. Run the script:
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\Network_Sharing_Wizard.ps1
   ```
4. Choose **Set up sharing** and follow the prompts.
5. On the other PC, run the wizard and choose **Connect** to connect to the share or map it as a network drive.

Before starting, check `ipconfig` on both PCs and make sure they are on the same local network. Ignore VPN and virtual-network adapters when comparing addresses.

## Security notes

- Use this wizard only on a network you trust.
- It uses authenticated SMB access and does not enable guest access.
- Keep the `NetworkShare` account password private and enter it only on PCs you control.
- Sharing an entire drive gives network access to a much larger set of files than sharing one folder. Choose the scope carefully.

## Version 2.0.3

Includes a correction to drive-root path handling for whole-drive shares. The removable-drive scenario should be tested on the target PC before relying on it.

## Testing status

Folder sharing has been tested successfully on a home network with an earlier 2.0.x version. The 2.0.3 whole-drive/removable-drive correction has not yet been confirmed by a user retest. Windows PowerShell execution validation has not been performed in this publishing environment.

## License

No license has been specified yet. Unless a license is added, normal copyright applies and reuse/redistribution permissions are not granted by default.
