<#
.SYNOPSIS
    XM8RIP - Xactimate Cleanup Utility
.DESCRIPTION
    This script removes all remnants of Xactimate/XactimateDesktop applications
    after a failed uninstall to allow for clean reinstallation.
.PARAMETER CompanyName
    Company name for registry paths. Default: "REDACTED"
.PARAMETER BackupRoot
    Root directory for backups. Default: "C:\PKGLOG\xm8rip"
.PARAMETER ProductCodes
    Array of MSI product codes to uninstall. Default includes known Xactimate codes.
.PARAMETER DryRun
    Run in simulation mode without making changes. Default: $false
.PARAMETER CreateZip
    Compress the backup folder when complete. Default: $true
.PARAMETER SendEmail
    Send email with backup. Default: $false
.PARAMETER EmailTo
    Email recipients. Default: ""
.PARAMETER MaxEmailSize
    Maximum email size in MB. Default: 10
.PARAMETER UseFallback
    Use fallback method if zip is too large. Default: $false
.NOTES
    Version: 1.0
    Date: April 29, 2025
#>

param (
    [string]$CompanyName = "REDACTED",
    [string]$BackupRoot = "C:\PKGLOG\xm8rip",
    [array]$ProductCodes = @(
        "{068d963a-4f3f-45b9-8a47-1068250c9ae3}",
        "{5f2642fe-1012-4255-95d8-e42b92866b69}",
        "{987cdd41-7ec8-4884-83c5-171d91abf3c4}",
        "{217CD114-E6F5-4163-B9B7-5D4B73858006}"
    ),
    [switch]$DryRun = $false,
    [switch]$CreateZip = $true,
    [switch]$SendEmail = $false,
    [string]$EmailTo = "",
    [int]$MaxEmailSize = 10,
    [switch]$UseFallback = $false
)

# Create timestamp format for logging and backup folders
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# Create backup root if it doesn't exist
if (-not (Test-Path $BackupRoot)) {
    New-Item -Path $BackupRoot -ItemType Directory -Force | Out-Null
}

# Create backup dir
$backupDir = "$BackupRoot\xm8rip.$timestamp"
if (-not (Test-Path $backupDir)) {
    New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
}

# Set log file path inside the backup directory
$logFile = "$backupDir\xm8rip_$timestamp.log"

# Create backup subdirectories
$backupRegistry = "$backupDir\registry"
$backupProgramData = "$backupDir\programdata"
$backupLogs = "$backupDir\logs"

# Define common registry paths for reuse across functions
$msiRegistryPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products",
    "HKLM:\SOFTWARE\Classes\Installer\Products",
    "HKLM:\SOFTWARE\Classes\Installer\UpgradeCodes",
    "HKLM:\SOFTWARE\Classes\Installer\Features",
    "HKLM:\SOFTWARE\Classes\Installer\Dependencies"
)

#region Helper Functions

function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Output to console with color
    switch ($Level) {
        "INFO" { Write-Host $logEntry -ForegroundColor Gray }
        "WARNING" { Write-Host $logEntry -ForegroundColor Yellow }
        "ERROR" { Write-Host $logEntry -ForegroundColor Red }
        "SUCCESS" { Write-Host $logEntry -ForegroundColor Green }
    }
    
    # Output to log file
    Add-Content -Path $logFile -Value $logEntry
}

function Create-BackupFolders {
    try {
        if ($DryRun) {
            Write-Log "DRY RUN: Would create backup directories at $backupDir" -Level "INFO"
        }
        else {
            if (-not (Test-Path $backupRegistry)) {
                New-Item -Path $backupRegistry -ItemType Directory -Force | Out-Null
                Write-Log "Created registry backup directory: $backupRegistry" -Level "SUCCESS"
            }
            
            if (-not (Test-Path $backupProgramData)) {
                New-Item -Path $backupProgramData -ItemType Directory -Force | Out-Null
                Write-Log "Created ProgramData backup directory: $backupProgramData" -Level "SUCCESS"
            }
            
            if (-not (Test-Path $backupLogs)) {
                New-Item -Path $backupLogs -ItemType Directory -Force | Out-Null
                Write-Log "Created logs backup directory: $backupLogs" -Level "SUCCESS"
            }
        }
    }
    catch {
        Write-Log "Failed to create backup directories: $_" -Level "ERROR"
        throw "Failed to create backup directories"
    }
}

function Test-AdminRights {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        Write-Log "ERROR: This script requires administrator privileges." -Level "ERROR"
        exit 1
    }
    else {
        Write-Log "Running with administrator privileges." -Level "INFO"
    }
}

#endregion

#region Main Removal Functions

function Backup-XactimateLogs {
    Write-Log "Starting Xactimate logs backup..." -Level "INFO"
    
    try {
        # Define base locations
        $baseLocations = @(
            "$env:SystemRoot\Temp",
            "$env:SystemRoot\SystemTemp",
            "$env:SystemDrive\Users\*\AppData\Local\Temp"
        )
        
        # Define specific folders to look for in base locations
        $specificFolders = @(
            "XM8_QA",
            "XactimateDesktop",
            "Xactware"
        )
        
        # Handle wildcard searches in base locations
        foreach ($baseLocation in $baseLocations) {
            Write-Log "Searching for logs in $baseLocation..." -Level "INFO"
            
            # Expand any wildcards in the base path
            $expandedBasePaths = @(Resolve-Path -Path $baseLocation -ErrorAction SilentlyContinue)
            
            foreach ($expandedBasePath in $expandedBasePaths) {
                # Look for files matching *Xactimate*
                $xactimateFiles = Get-ChildItem -Path $expandedBasePath -Filter "*Xactimate*" -File -ErrorAction SilentlyContinue
                
                # Process each file
                foreach ($file in $xactimateFiles) {
                    # Create a unique destination filename to handle duplicates
                    $baseFileName = $file.Name
                    $destFileName = $baseFileName
                    $counter = 1
                    
                    # Check if the destination file already exists, create a unique name if needed
                    while (Test-Path -Path (Join-Path -Path $backupLogs -ChildPath $destFileName)) {
                        $destFileName = "{0}_{1}{2}" -f $file.BaseName, $counter, $file.Extension
                        $counter++
                    }
                    
                    $destPath = Join-Path -Path $backupLogs -ChildPath $destFileName
                    
                    if ($DryRun) {
                        Write-Log "DRY RUN: Would back up log file: $($file.FullName) to $destPath" -Level "INFO"
                    }
                    else {
                        # Copy the file
                        Copy-Item -Path $file.FullName -Destination $destPath -Force -ErrorAction Continue
                        Write-Log "Backed up: $($file.FullName) to $destPath" -Level "SUCCESS"
                        
                        # Delete the original
                        Remove-Item -Path $file.FullName -Force -ErrorAction Continue
                        Write-Log "Removed original log: $($file.FullName)" -Level "SUCCESS"
                    }
                }
                
                # Process specific folders
                foreach ($folderName in $specificFolders) {
                    $folderPath = Join-Path -Path $expandedBasePath -ChildPath $folderName
                    
                    if (Test-Path -Path $folderPath) {
                        # Create a unique destination foldername to handle duplicates
                        $destFolderName = $folderName
                        $counter = 1
                        
                        # Check if the destination folder already exists, create a unique name if needed
                        while (Test-Path -Path (Join-Path -Path $backupLogs -ChildPath $destFolderName)) {
                            $destFolderName = "{0}_{1}" -f $folderName, $counter
                            $counter++
                        }
                        
                        $destFolderPath = Join-Path -Path $backupLogs -ChildPath $destFolderName
                        
                        if ($DryRun) {
                            Write-Log "DRY RUN: Would back up folder: $folderPath to $destFolderPath" -Level "INFO"
                        }
                        else {
                            # Copy the folder
                            Copy-Item -Path $folderPath -Destination $destFolderPath -Recurse -Force -ErrorAction Continue
                            Write-Log "Backed up folder: $folderPath to $destFolderPath" -Level "SUCCESS"
                            
                            # Delete the original folder
                            Remove-Item -Path $folderPath -Recurse -Force -ErrorAction Continue
                            Write-Log "Removed original folder: $folderPath" -Level "SUCCESS"
                        }
                    }
                }
            }
        }
        
        Write-Log "Xactimate logs backup completed successfully." -Level "SUCCESS"
    }
    catch {
        Write-Log "Error backing up Xactimate logs: $_" -Level "ERROR"
        # Continue execution despite errors
    }
}

function Backup-PKGLOGFiles {
    Write-Log "Backing up PKGLOG files..." -Level "INFO"
    
    try {
        # Special case for PKGLOG - backup only, no deletion
        $pkglogPath = "$env:SystemDrive\PKGLOG"
        if (Test-Path $pkglogPath) {
            # Look for files and folders matching *Xactimate*, *Xactware*, or *Verisk*
            $pkglogItems = Get-ChildItem -Path $pkglogPath -Filter "*Xactimate*" -ErrorAction SilentlyContinue
            $pkglogItems += Get-ChildItem -Path $pkglogPath -Filter "*Xactware*" -ErrorAction SilentlyContinue
            $pkglogItems += Get-ChildItem -Path $pkglogPath -Filter "*Verisk*" -ErrorAction SilentlyContinue
            
            if ($pkglogItems.Count -eq 0) {
                Write-Log "No matching files found in PKGLOG directory" -Level "INFO"
            } else {
                foreach ($item in $pkglogItems) {
                    # Create a unique destination name to handle duplicates
                    $baseName = $item.Name
                    $destName = $baseName
                    $counter = 1
                    
                    # Check if the destination already exists, create a unique name if needed
                    while (Test-Path -Path (Join-Path -Path $backupLogs -ChildPath $destName)) {
                        $destName = "{0}_{1}" -f $baseName, $counter
                        $counter++
                    }
                    
                    $destPath = Join-Path -Path $backupLogs -ChildPath $destName
                    
                    if ($DryRun) {
                        Write-Log "DRY RUN: Would back up PKGLOG item: $($item.FullName) to $destPath" -Level "INFO"
                    }
                    else {
                        # Copy the item (file or folder)
                        if ($item.PSIsContainer) {
                            Copy-Item -Path $item.FullName -Destination $destPath -Recurse -Force -ErrorAction Continue
                        }
                        else {
                            Copy-Item -Path $item.FullName -Destination $destPath -Force -ErrorAction Continue
                        }
                        Write-Log "Backed up PKGLOG item: $($item.FullName) to $destPath" -Level "SUCCESS"
                        
                        # No deletion for PKGLOG items
                    }
                }
            }
            
            Write-Log "PKGLOG backup completed successfully." -Level "SUCCESS"
        }
        else {
            Write-Log "PKGLOG directory not found at $pkglogPath" -Level "INFO"
        }
    }
    catch {
        Write-Log "Error backing up PKGLOG files: $_" -Level "ERROR"
        # Continue execution despite errors
    }
}

function Stop-XactimateProcesses {
    Write-Log "Stopping Xactimate processes..." -Level "INFO"
    
    try {
        # Get all processes that match Xactimate
        $processes = Get-Process | Where-Object { 
            $_.ProcessName -like "*Xactimate*" -or 
            $_.ProcessName -like "*Xactware*" -or 
            $_.ProcessName -eq "x" 
        } -ErrorAction SilentlyContinue
        
        if ($processes) {
            foreach ($process in $processes) {
                if ($DryRun) {
                    Write-Log "DRY RUN: Would stop process: $($process.ProcessName) (PID: $($process.Id))" -Level "INFO"
                }
                else {
                    try {
                        $process | Stop-Process -Force
                        Write-Log "Stopped process: $($process.ProcessName) (PID: $($process.Id))" -Level "SUCCESS"
                    }
                    catch {
                        Write-Log "Failed to stop process: $($process.ProcessName) (PID: $($process.Id)): $_" -Level "ERROR"
                        # Continue despite errors
                    }
                }
            }
        }
        else {
            Write-Log "No Xactimate processes found running." -Level "INFO"
        }
    }
    catch {
        Write-Log "Error stopping Xactimate processes: $_" -Level "ERROR"
        # Continue execution despite errors
    }
}

function Get-XactimateMSIProductCodes {
    Write-Log "Searching for Xactimate MSI product codes..." -Level "INFO"
    
    try {
        $foundProductCodes = @()
        
        # First, add the known product codes from parameters
        foreach ($code in $ProductCodes) {
            # Ensure proper format with braces
            $formattedCode = $code
            if (-not $formattedCode.StartsWith("{")) {
                $formattedCode = "{$formattedCode}"
            }
            if (-not $formattedCode.EndsWith("}")) {
                $formattedCode = "$formattedCode}"
            }
            
            if ($foundProductCodes -notcontains $formattedCode) {
                $foundProductCodes += $formattedCode
                Write-Log "Added known product code: $formattedCode" -Level "INFO"
            }
        }
        
        # Comprehensive search through all registry paths
        foreach ($path in $msiRegistryPaths) {
            if (Test-Path $path) {
                Write-Log "Searching registry path: $path" -Level "INFO"
                
                # Search for Xactimate related entries
                $keys = Get-ChildItem -Path $path -ErrorAction SilentlyContinue
                
                foreach ($key in $keys) {
                    # Try to get properties if available
                    try {
                        $properties = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
                        
                        # Check if it's Xactimate related by name/publisher
                        if ($properties -and (
                            ($properties.DisplayName -like "*Xactimate*" -or $properties.DisplayName -like "*Xactware*") -or 
                            ($properties.Publisher -like "*Xactware*" -or $properties.Publisher -like "*Verisk*") -or
                            ($properties.UninstallString -like "*Xactimate*" -or $properties.UninstallString -like "*Xactware*") -or
                            ($key.Name -like "*Xactimate*" -or $key.Name -like "*Xactware*")
                        )) {
                            # Extract product code if not already the key name
                            $productCode = $key.PSChildName
                            
                            # Ensure it's a valid product code format
                            if ($productCode -match "^\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}$" -or 
                                $productCode -match "^[0-9A-F]{32}$") {
                                
                                # Format if needed
                                if ($productCode -match "^[0-9A-F]{32}$") {
                                    # Convert to standard GUID format
                                    $productCode = "{" + $productCode.Substring(0,8) + "-" + 
                                                         $productCode.Substring(8,4) + "-" + 
                                                         $productCode.Substring(12,4) + "-" + 
                                                         $productCode.Substring(16,4) + "-" + 
                                                         $productCode.Substring(20,12) + "}"
                                }
                                
                                # Add to results if not already there
                                if ($foundProductCodes -notcontains $productCode) {
                                    $foundProductCodes += $productCode
                                    
                                    # Try to get version if available
                                    $version = ""
                                    if ($properties.DisplayVersion) {
                                        $version = "- Version: $($properties.DisplayVersion)"
                                    }
                                    
                                    Write-Log "Found product: $($properties.DisplayName) - $productCode $version" -Level "INFO"
                                    
                                    # Backup registry key handling with DRY RUN check
                                    $regFileName = ($key.PSPath -replace ":", "") -replace "\\", "_"
                                    $regFileName = "$regFileName.reg"
                                    $regFilePath = Join-Path -Path $backupRegistry -ChildPath $regFileName
                                    
                                    if ($DryRun) {
                                        Write-Log "DRY RUN: Would back up registry key: $($key.PSPath) to $regFilePath" -Level "INFO"
                                    }
                                    else {
                                        try {
                                            # Prepare the path for reg export
                                            $regExportPath = $key.PSPath -replace "HKLM:", "HKLM\"
                                            $process = Start-Process -FilePath "reg.exe" -ArgumentList "export", "`"$regExportPath`"", "`"$regFilePath`"", "/y" -NoNewWindow -PassThru -Wait
                                            
                                            if ($process.ExitCode -eq 0) {
                                                Write-Log "Registry key backed up: $($key.PSPath) to $regFilePath" -Level "SUCCESS"
                                            }
                                        }
                                        catch {
                                            Write-Log "Failed to back up registry key: $($key.PSPath) - $_" -Level "WARNING"
                                        }
                                    }
                                }
                            }
                        }
                        
                        # Also search for known product codes in registry values
                        foreach ($knownCode in $foundProductCodes) {
                            # Strip braces for wider matching
                            $codeNoFormat = $knownCode -replace "[{}]", ""
                            
                            # Check if this registry key or any of its values contains the product code
                            $match = $false
                            
                            # Check key name
                            if ($key.PSPath -like "*$codeNoFormat*") {
                                $match = $true
                            }
                            
                            # Check property values
                            if (-not $match -and $properties) {
                                foreach ($prop in $properties.PSObject.Properties) {
                                    if ($prop.Value -is [string] -and $prop.Value -like "*$codeNoFormat*") {
                                        $match = $true
                                        break
                                    }
                                }
                            }
                            
                            if ($match) {
                                Write-Log "Found registry entry for product code: $knownCode at $($key.PSPath)" -Level "INFO"
                                
                                # Back up this key as well with DRY RUN check
                                $regFileName = ("ProductCode_" + $codeNoFormat + "_" + ($key.PSPath -replace ":", "") -replace "\\", "_")
                                $regFileName = "$regFileName.reg"
                                $regFilePath = Join-Path -Path $backupRegistry -ChildPath $regFileName
                                
                                if ($DryRun) {
                                    Write-Log "DRY RUN: Would back up registry key: $($key.PSPath) to $regFilePath" -Level "INFO"
                                }
                                else {
                                    try {
                                        # Prepare the path for reg export
                                        $regExportPath = $key.PSPath -replace "HKLM:", "HKLM\"
                                        $process = Start-Process -FilePath "reg.exe" -ArgumentList "export", "`"$regExportPath`"", "`"$regFilePath`"", "/y" -NoNewWindow -PassThru -Wait
                                        
                                        if ($process.ExitCode -eq 0) {
                                            Write-Log "Registry key backed up: $($key.PSPath) to $regFilePath" -Level "SUCCESS"
                                        }
                                    }
                                    catch {
                                        Write-Log "Failed to back up registry key: $($key.PSPath) - $_" -Level "WARNING"
                                    }
                                }
                            }
                        }
                    }
                    catch {
                        # Continue to next key if there's an issue with this one
                        continue
                    }
                }
            }
        }
        
        # Handle updating global ProductCodes with DRY RUN check
        foreach ($foundCode in $foundProductCodes) {
            if ($ProductCodes -notcontains $foundCode) {
                if ($DryRun) {
                    Write-Log "DRY RUN: Would add newly discovered product code to global list: $foundCode" -Level "INFO"
                }
                else {
                    $ProductCodes += $foundCode
                    Write-Log "Added newly discovered product code to global list: $foundCode" -Level "INFO"
                }
            }
        }
        
        Write-Log "Found $($foundProductCodes.Count) MSI product codes." -Level "INFO"
        return $foundProductCodes
    }
    catch {
        Write-Log "Error searching for MSI product codes: $_" -Level "ERROR"
        return @() # Return empty array in case of error
    }
}

function Backup-XactimateRegistry {
    Write-Log "Backing up Xactimate registry keys..." -Level "INFO"
    
    try {
        # Define registry paths to back up
        $XactwareregistryPaths = @(
            "HKLM:\SOFTWARE\$CompanyName\Packages\*Xactware*",
            "HKLM:\SOFTWARE\$CompanyName\Packages\*Xactimate*",
            "HKLM:\SOFTWARE\WOW6432Node\$CompanyName\Packages\*Xactware*",
            "HKLM:\SOFTWARE\WOW6432Node\$CompanyName\Packages\*Xactimate*",
            "HKLM:\SOFTWARE\Xactware"            
        )
        
        foreach ($path in $XactwareregistryPaths) {
            $registryItems = Get-ChildItem -Path $path -ErrorAction SilentlyContinue
            
            if ($registryItems -or (Test-Path $path)) {
                $regFileName = ($path -replace ":", "") -replace "\\", "_"
                $regFileName = "$regFileName.reg"
                $regFilePath = Join-Path -Path $backupRegistry -ChildPath $regFileName
                
                if ($DryRun) {
                    Write-Log "DRY RUN: Would back up registry key: $path to $regFilePath" -Level "INFO"
                }
                else {
                    # Prepare the path for reg export - remove wildcards
                    $exportPath = $path -replace "\*", ""
                    
                    if (Test-Path $exportPath) {
                        # Use reg.exe to export the registry key
                        $regExportPath = $exportPath -replace "HKLM:", "HKLM\"
                        $process = Start-Process -FilePath "reg.exe" -ArgumentList "export", "`"$regExportPath`"", "`"$regFilePath`"", "/y" -NoNewWindow -PassThru -Wait
                        
                        if ($process.ExitCode -eq 0) {
                            Write-Log "Registry key backed up: $path to $regFilePath" -Level "SUCCESS"
                        }
                        else {
                            Write-Log "Failed to back up registry key: $path. Exit code: $($process.ExitCode)" -Level "WARNING"
                        }
                    }
                    else {
                        Write-Log "Registry path not found: $exportPath" -Level "INFO"
                    }
                }
            }
        }
        
        Write-Log "Registry backup completed." -Level "SUCCESS"
    }
    catch {
        Write-Log "Error backing up registry: $_" -Level "ERROR"
        # Continue execution despite errors
    }
}

function Backup-XactimateProgramData {
    Write-Log "Backing up Xactimate program data..." -Level "INFO"
    
    try {
        # ProgramData location
        $programDataPath = "C:\ProgramData\Xactware"
        
        if (Test-Path $programDataPath) {
            if ($DryRun) {
                Write-Log "DRY RUN: Would back up ProgramData: $programDataPath to $backupProgramData" -Level "INFO"
            }
            else {
                # Create a subfolder with the same name
                $destination = Join-Path -Path $backupProgramData -ChildPath "Xactware"
                
                # Copy the directory
                Copy-Item -Path $programDataPath -Destination $destination -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "Backed up ProgramData: $programDataPath to $destination" -Level "SUCCESS"
            }
        }
        else {
            Write-Log "ProgramData directory not found: $programDataPath" -Level "INFO"
        }
    }
    catch {
        Write-Log "Error backing up ProgramData: $_" -Level "ERROR"
        # Continue execution despite errors
    }
}

function Remove-XactimateMSIProducts {
    param (
        [Parameter(Mandatory = $true)]
        [array]$ProductCodes
    )
    
    Write-Log "Attempting to uninstall Xactimate MSI products..." -Level "INFO"
    
    try {
        foreach ($code in $ProductCodes) {
            # Ensure the product code is properly formatted
            if (-not $code.StartsWith("{")) {
                $code = "{$code}"
            }
            if (-not $code.EndsWith("}")) {
                $code = "$code}"
            }
            
            # Attempt MSI uninstall
            if ($DryRun) {
                Write-Log "DRY RUN: Would uninstall MSI product code: $code" -Level "INFO"
            }
            else {
                Write-Log "Attempting to uninstall product code: $code" -Level "INFO"
                
                $logPath = "$backupDir\MSI_Uninstall_$code.log"
                $arguments = @(
                    "/x",
                    $code,
                    "/qn",
                    "REBOOT=ReallySuppress",
                    "/norestart",
                    "/L*v",
                    "`"$logPath`""
                )
                
                $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -NoNewWindow -PassThru -Wait
                
                if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
                    Write-Log "Successfully uninstalled product: $code" -Level "SUCCESS"
                }
                else {
                    Write-Log "MSI uninstall returned exit code: $($process.ExitCode) for $code" -Level "WARNING"
                    
                    # For persistent MSIs, try using wmic as an alternative
                    Write-Log "Attempting alternative uninstall method for: $code" -Level "INFO"
                    
                    try {
                        $wmicArguments = "product where PackageCode=""$code"" call uninstall /nointeractive"
                        $wmicProcess = Start-Process -FilePath "wmic" -ArgumentList $wmicArguments -NoNewWindow -PassThru -Wait
                        
                        if ($wmicProcess.ExitCode -eq 0) {
                            Write-Log "Alternative uninstall method completed for: $code" -Level "SUCCESS"
                        }
                        else {
                            Write-Log "Alternative uninstall method failed with exit code: $($wmicProcess.ExitCode)" -Level "WARNING"
                        }
                    }
                    catch {
                        Write-Log "Alternative uninstall method failed: $_" -Level "WARNING"
                    }
                }
                
                # Regardless of MSI uninstall outcome, clean up registry
                # Search all registry paths for references to this product code
                foreach ($path in $msiRegistryPaths) {
                    if (Test-Path $path) {
                        # Strip braces for wider matching
                        $codeNoFormat = $code -replace "[{}]", ""
                        
                        # First, try direct path if it exists
                        $directPath = "$path\$code"
                        if (Test-Path $directPath) {
                            try {
                                Remove-Item -Path $directPath -Recurse -Force -ErrorAction SilentlyContinue
                                Write-Log "Removed registry key: $directPath" -Level "SUCCESS"
                            }
                            catch {
                                Write-Log "Failed to remove registry key: $directPath - $_" -Level "ERROR"
                            }
                        }
                        
                        # Search for keys/values containing the product code
                        try {
                            $keys = Get-ChildItem -Path $path -ErrorAction SilentlyContinue
                            
                            foreach ($key in $keys) {
