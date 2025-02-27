
$ProgressPreference = 'SilentlyContinue'	# hide any progress output
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ([string]::IsNullOrEmpty($Env:ADMIN_USERNAME)) 	{ Throw "Env:ADMIN_USERNAME must be set" }
if ([string]::IsNullOrEmpty($Env:ADMIN_PASSWORD)) 	{ Throw "Env:ADMIN_PASSWORD must be set" }
if ([string]::IsNullOrEmpty($Env:DEVBOX_HOME)) 		{ Throw "Env:DEVBOX_HOME must be set" }

Get-ChildItem -Path (Join-Path $env:DEVBOX_HOME 'Modules') -Directory | Select-Object -ExpandProperty FullName | ForEach-Object {
	Write-Host ">>> Importing PowerShell Module: $_"
	Import-Module -Name $_
} 

function Get-ShortcutTargetPath() {
	param( 
		[Parameter(Mandatory=$true)][string]$Path
	)

	$Shell = New-Object -ComObject ("WScript.Shell")
	$Shortcut = $Shell.CreateShortcut($Path)

	return $Shortcut.TargetPath
}

$downloadKeyVaultArtifact = {
	param([string] $Source, [string] $Destination, [string] $TokenEndpoint)

	Write-Host ">>> Acquire KeyVault Access Token"
	Connect-AzAccount -Identity -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
	$KeyVaultToken = Get-AzAccessToken -ResourceUrl $TokenEndpoint -ErrorAction Stop -WarningAction SilentlyContinue

	Write-Host ">>> Downloading KeyVault Artifact $Source"
	$KeyVaultHeaders = @{"Authorization" = "Bearer $($KeyVaultToken.Token)"}
	$KeyVaultResponse = Invoke-RestMethod -Uri "$($Source)?api-version=7.1" -Headers $KeyVaultHeaders -ErrorAction Stop
		
	Write-Host ">>> Decoding KeyVault Artifact $Source"
	[System.Convert]::FromBase64String($KeyVaultResponse.value) | Set-Content -Path $Destination -Encoding Byte -Force

	if (Test-Path -Path $Destination -PathType Leaf) {  
		Write-Host ">>> Resolved Artifact $Destination" 
	} else {
		Write-Error "!!! Missing Artifact $Destination"
	}
}

$downloadStorageArtifact = {
	param([string] $Source, [string] $Destination)

	Get-ChildItem -Path (Join-Path $env:DEVBOX_HOME 'Modules') -Directory | Select-Object -ExpandProperty FullName | ForEach-Object {
		Import-Module -Name $_
	} 

	$azcopy = Get-ChildItem -Path (Join-Path $env:DEVBOX_HOME 'Tools') -Recurse -Filter 'azcopy.exe' | Select-Object -ExpandProperty FullName -First 1
	if (-not($azcopy)) { 

		Throw "AzCopy not found" 

	} else {

		Write-Host ">>> Downloading Storage Artifact $Source" 
		Invoke-CommandLine -Command $azcopy -Arguments "copy `"$Source`" `"$Destination`" --output-level=quiet" | Select-Object -ExpandProperty Output | Write-Host
	
		if (Test-Path -Path $Destination -PathType Leaf) { 
			Write-Host ">>> Resolved Artifact $Destination" 
		} else {
			Write-Error "!!! Missing Artifact $Destination"
		}	
	}
}

$downloadArtifact = {
	param([string] $Source, [string] $Destination)

	Get-ChildItem -Path (Join-Path $env:DEVBOX_HOME 'Modules') -Directory | Select-Object -ExpandProperty FullName | ForEach-Object {
		Import-Module -Name $_
	} 

	$Temp = Invoke-FileDownload -Url $Source -Name ([System.IO.Path]::GetFileName($Destination))
	Move-Item -Path $Temp -Destination $Destination -Force

	if (Test-Path -Path $Destination -PathType Leaf) { 
		Write-Host ">>> Resolved Artifact $Destination" 
	} else {
		Write-Error "!!! Missing Artifact $Destination"
	}
}

Invoke-ScriptSection -Title "Register Powershell Gallery" -ScriptBlock {

	# CAUTION - Don't move this section down the sequence of config sections in this file !!!

	# We are going to install the NuGet package provider and the PowerShellGet module from the PSGallery.
	# Especially the latter requires to be NOT loaded into the current process when we install an updated version.

	Write-Host ">>> Installing NuGet package provider" 
	Install-PackageProvider -Name NuGet -Force -Scope AllUsers | Out-Null

	try {

		Write-Host ">>> Trust the PSGallery repository temporarily"
		Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted

		Write-Host ">>> Install PowershellGet module"
		Install-Module -Name PowerShellGet -Force -AllowClobber -Scope AllUsers -WarningAction SilentlyContinue

		# Start a new session to install the PowerShellGet module - this will cover the case where the module is already loaded in the current session
		powershell.exe -NoLogo -Mta -ExecutionPolicy $(Get-ExecutionPolicy) -Command '&{ Install-Module -Name PowerShellGet -Force -AllowClobber -Scope AllUsers }'
	}
	finally {
		Write-Host ">>> Rollback the PSGallery repository policy"
		Set-PSRepository -Name "PSGallery" -InstallationPolicy Untrusted
	}
}

Invoke-ScriptSection -Title 'Setting DevBox environment variables' -ScriptBlock {

	[Environment]::SetEnvironmentVariable("DEVBOX_HOME", $devboxHome, [System.EnvironmentVariableTarget]::Machine)
	Get-ChildItem -Path Env:DEVBOX_* | ForEach-Object { [Environment]::SetEnvironmentVariable($_.Name, $_.Value, [System.EnvironmentVariableTarget]::Machine) }
	Get-ChildItem -Path Env:DEVBOX_* | Out-String | Write-Host
}

Invoke-ScriptSection -Title 'Downloading Tools' -ScriptBlock {

	$tools = New-Item -Path (Join-Path $Env:DEVBOX_HOME 'Tools') -ItemType Directory -Force | Select-Object -ExpandProperty FullName

	Write-Host ">>> Download azcopy"
	$azcopyTemp = Invoke-FileDownload -Url "https://aka.ms/downloadazcopy-v10-windows$(&{ if ([Environment]::Is64BitOperatingSystem) { '' } else { '-32bit' } })" -Name "azcopy.zip" -Expand 
	Get-ChildItem -Path $azcopyTemp -Recurse -Filter 'azcopy.exe' `
		| Select-Object -ExpandProperty FullName -First 1 `
		| ForEach-Object { Move-Item -Path $_ -Destination $tools -Force | Out-Null	}

	Write-Host ">>> Downloading PsExec"
	$pstoolsTemp = Invoke-FileDownload -Url 'https://download.sysinternals.com/files/PSTools.zip' -Name "PSTools.zip" -Expand
	Get-ChildItem -Path $pstoolsTemp -Recurse -Filter 'PsExec*.exe' `
		| Select-Object -ExpandProperty FullName `
		| ForEach-Object { Move-Item -Path $_ -Destination $tools -Force | Out-Null	}
}

Invoke-ScriptSection -Title 'Disable Defrag Schedule' -ScriptBlock {

	Get-ScheduledTask ScheduledDefrag | Disable-ScheduledTask | Out-String | Write-Host
}

Invoke-ScriptSection -Title 'Enable AutoLogon' -ScriptBlock {

	Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoAdminLogon -Value 1 -type String
	Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultUsername -Value "$Env:ADMIN_USERNAME" -type String
	Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultPassword -Value "$Env:ADMIN_PASSWORD" -type String
	Write-Host "done"
}

Invoke-ScriptSection -Title 'Disable User Access Control' -ScriptBlock {

	Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -Value 0 -type DWord
	Write-Host "done"
}

Invoke-ScriptSection -Title 'Deleting Sysprep Logs' -ScriptBlock {

	Remove-Item -Path $env:SystemRoot\Panther -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
	Remove-Item -Path $env:SystemRoot\System32\Sysprep\Panther -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
	Remove-Item -Path $Env:SystemRoot\System32\Sysprep\unattend.xml -Force -ErrorAction SilentlyContinue | Out-Null
	Write-Host "done"
}

Invoke-ScriptSection -Title 'Disable OneDrive Folder Backup' -ScriptBlock {
	
	$OneDriveRegKeyPath = "HKLM:\SOFTWARE\Policies\Microsoft\OneDrive"
	if (-not(Test-Path -Path $OneDriveRegKeyPath)) { New-Item -Path $OneDriveRegKeyPath -ItemType Directory -Force | Out-Null }
	New-ItemProperty -Path $OneDriveRegKeyPath -Name KFMBlockOptIn -PropertyType DWORD -Value 1 -Force | Out-Null
	Write-Host "done"
}

Invoke-ScriptSection -Title 'Enable Teredo support' -ScriptBlock {
	
	Set-NetTeredoConfiguration -Type Enterpriseclient -ErrorAction SilentlyContinue
	Write-Host "done"
}

Invoke-ScriptSection -Title 'Enable Windows Developer Mode' -ScriptBlock {

	Invoke-CommandLine -Command 'reg' -Arguments 'add "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v "AllowDevelopmentWithoutDevLicense" /d "1"' | Select-Object -ExpandProperty Output | Write-Host
	Invoke-CommandLine -Command 'reg' -Arguments 'add "HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Appx" /t REG_DWORD /f /v "AllowDevelopmentWithoutDevLicense" /d "1"' | Select-Object -ExpandProperty Output | Write-Host
}

Invoke-ScriptSection -Title 'List existing Appx packages' -ScriptBlock {
	Get-AppxPackage | Format-Table Name, Version, Status, InstallLocation
}

Invoke-ScriptSection -Title 'Prepare Hibernate Support' -ScriptBlock {

	Write-Host ">>> Enable Virtual Machine Platform feature ..." 
	Get-WindowsOptionalFeature -Online `
		| Where-Object { $_.FeatureName -like "*VirtualMachinePlatform*" -and $_.State -ne "Enabled" } `
		| Enable-WindowsOptionalFeature -Online -All -NoRestart `
		| Out-Null
}

Invoke-ScriptSection -Title 'Enable Hibernate Support' -ScriptBlock {

	Invoke-CommandLine -Command 'powercfg' -Arguments '/hibernate on' | Select-Object -ExpandProperty Output | Write-Host   
	Write-Host "done"
}

Invoke-ScriptSection -Title 'Expand System Partition' -ScriptBlock {

	$partition = Get-Partition | Where-Object { -not($_.IsHidden) } | Sort-Object { $_.DriveLetter } | Select-Object -First 1
	$partitionSize = Get-PartitionSupportedSize -DiskNumber ($partition.DiskNumber) -PartitionNumber ($partition.PartitionNumber)
	if ($partition.Size -lt $partitionSize.SizeMax) {
		Write-Host ">>> Resizing System Partition to $([Math]::Round($partitionSize.SizeMax / 1GB,2)) GB" 
		Resize-Partition -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -Size $partitionSize.SizeMax
	} else {
		Write-Host ">>> No need to resize !!!"
	}
}

# Invoke-ScriptSection -Title 'Restore WindowsApp Permissions' -ScriptBlock {

# 	$programFiles = [Environment]::GetFolderPath('ProgramFiles')
# 	$windowsApps = Join-Path $programFiles 'WindowsApps'
# 	$icaclsConfig = Join-Path $env:TEMP 'icacls.config'

# @"
# windowsapps
# D:PAI(A;;FA;;;S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464)(A;OICIIO;GA;;;S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464)(A;;0x1200a9;;;S-1-15-3-1024-3635283841-2530182609-996808640-1887759898-3848208603-3313616867-983405619-2501854204)(A;OICIIO;GXGR;;;S-1-15-3-1024-3635283841-2530182609-996808640-1887759898-3848208603-3313616867-983405619-2501854204)(A;;FA;;;SY)(A;OICIIO;GA;;;SY)(A;CI;0x1200a9;;;BA)(A;OICI;0x1200a9;;;LS)(A;OICI;0x1200a9;;;NS)(A;OICI;0x1200a9;;;RC)(XA;;0x1200a9;;;BU;(Exists WIN://SYSAPPID))
# "@ | Out-File -FilePath $icaclsConfig -Force

# 	# take over temporary ownership of the WindowsApps folder
# 	Invoke-CommandLine -AsSystem -Command 'takeown' -Arguments "/f `"$windowsApps`"" `
# 		| Select-Object -ExpandProperty Output `
# 		| Write-Host

# 	# reset the permissions of the WindowsApps folder
# 	Invoke-CommandLine -AsSystem -Command 'icacls' -Arguments "`"$programFiles`" /restore `"$icaclsConfig`" /c" `
# 		| Select-Object -ExpandProperty Output `
# 		| Write-Host

# 	# set the owner of the WindowsApps folder back to TrustedInstaller
# 	Invoke-CommandLine -AsSystem -Command 'icacls' -Arguments "`"$windowsApps`" /setowner `"nt service\trustedinstaller`" /c" `
# 		| Select-Object -ExpandProperty Output `
# 		| Write-Host

# 	# grant current user full control of the WindowsApps folder
# 	Invoke-CommandLine -AsSystem -Command 'icacls' -Arguments "`"$windowsApps`" /grant `"$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name):F`" /c" `
# 		| Select-Object -ExpandProperty Output `
# 		| Write-Host

# 	# inherit permissions on all files and folders in the WindowsApps folder
# 	Invoke-CommandLine -AsSystem -Command 'icacls' -Arguments "`"$windowsApps\*`" /reset /c /t" `
# 		| Select-Object -ExpandProperty Output `
# 		| Write-Host
# }

$Artifacts = Join-Path -Path $env:DEVBOX_HOME -ChildPath 'Artifacts'
if (Test-Path -Path $Artifacts -PathType Container) {

	$links = Get-ChildItem -Path $Artifacts -Filter '*.*.url' -Recurse | Select-Object -ExpandProperty FullName

	if ($links) { 

		Invoke-ScriptSection -Title "Download artifacts prepare" -ScriptBlock {

			@( 'Az.Accounts' ) `
			| ForEach-Object { 
				if (Get-Module -ListAvailable -Name $_) {
					Write-Host ">>> Upgrading Powershell Module: $_";
					Update-Module -Name $_ -AcceptLicense -Force -WarningAction SilentlyContinue -ErrorAction Stop
				} else {
					Write-Host ">>> Installing Powershell Module: $_";
					Install-Module -Name $_ -AcceptLicense -Repository PSGallery -Force -AllowClobber -WarningAction SilentlyContinue -ErrorAction Stop
				}
			}
		
			Write-Host ">>> Connect Azure"
			$timeout = (Get-Date).AddMinutes(5)
			while ($true) {
				try {
					Connect-AzAccount -Identity -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
					Write-Host "- Azure login succeeded"
					break
				} catch {
                    if ((Get-Date) -gt $timeout) { throw }
                    Write-Host "- Azure login failed - retry in 10 seconds"
                    Start-Sleep -Seconds 10
				}
			}
		}

		Invoke-ScriptSection -Title "Download artifacts" -ScriptBlock {

			$jobs = @()

			$links | ForEach-Object { 
			
				Write-Host ">>> Downloading artifact: $_" 
				$ArtifactUrl = Get-ShortcutTargetPath -Path $_ 
				$ArtifactFile = $_.TrimEnd([System.IO.Path]::GetExtension($_))

				if ($ArtifactUrl) {

					$KeyVaultEndpoint = (Get-AzEnvironment -Name AzureCloud | Select-Object -ExpandProperty AzureKeyVaultServiceEndpointResourceId)
					$KeyVaultPattern = $KeyVaultEndpoint.replace('://','://*.').trim() + '/*'
					
					$StorageEndpoint = (Get-AzEnvironment -Name AzureCloud | Select-Object -ExpandProperty StorageEndpointSuffix)
					$StoragePattern = "https://*.blob.$StorageEndpoint/*"

					if ($ArtifactUrl -like $KeyVaultPattern) {

						$jobs += Start-Job -Scriptblock $downloadKeyVaultArtifact -ArgumentList ("$ArtifactUrl", "$ArtifactFile", "$KeyVaultEndpoint")

					} elseif ($ArtifactUrl -like $StoragePattern) {

						$jobs += Start-Job -Scriptblock $downloadStorageArtifact -ArgumentList ("$ArtifactUrl", "$ArtifactFile")

					} else {
						
						$jobs += Start-Job -Scriptblock $downloadArtifact -ArgumentList ("$ArtifactUrl", "$ArtifactFile")
					}
				}

			} -End {

				if ($jobs) {
					Write-Host ">>> Waiting for downloads ..."
					$jobs | Receive-Job -Wait -AutoRemoveJob
				}
			}
		}
	}
}