<#
Start-Toolkit.ps1
Outil interactif AD / GPO / SMB pour Windows Server AD.

À lancer sur :
- Contrôleur de domaine
ou
- Serveur Windows avec RSAT ActiveDirectory + GroupPolicy

Modules nécessaires :
- ActiveDirectory
- GroupPolicy
- SmbShare
#>

# =========================
# INITIALISATION
# =========================

Clear-Host

$ErrorActionPreference = "Stop"

$Global:DryRun = $false
$Global:LogPath = "C:\Logs\AD-GPO-Toolkit.log"

if (-not (Test-Path "C:\Logs")) {
    New-Item -ItemType Directory -Path "C:\Logs" -Force | Out-Null
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Add-Content -Path $Global:LogPath -Value $Line
}

function Write-Info {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
    Write-Log $Message "INFO"
}

function Write-Success {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Green
    Write-Log $Message "SUCCESS"
}

function Write-WarningMsg {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Yellow
    Write-Log $Message "WARNING"
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Red
    Write-Log $Message "ERROR"
}

function Pause-Toolkit {
    Write-Host ""
    Read-Host "Appuie sur Entrée pour continuer"
}

function Confirm-Action {
    param([string]$Message)

    $Answer = Read-Host "$Message [O/N]"
    return $Answer -match "^[OoYy]$"
}

function Invoke-SafeAction {
    param(
        [string]$Description,
        [scriptblock]$Action
    )

    if ($Global:DryRun) {
        Write-WarningMsg "[DRY-RUN] $Description"
        return $true
    }

    try {
        Write-Info $Description
        & $Action
        return $true
    } catch {
        Write-ErrorMsg "Erreur pendant '$Description' : $($_.Exception.Message)"
        return $false
    }
}

function Read-RequiredValue {
    param([string]$Prompt)

    $Value = Read-Host $Prompt

    if ([string]::IsNullOrWhiteSpace($Value)) {
        Write-ErrorMsg "Valeur obligatoire."
        return $null
    }

    return $Value.Trim()
}

function Get-SafeFileName {
    param([string]$Name)

    # Nettoie un nom de GPO avant de l'utiliser comme nom de fichier dans SYSVOL.
    return (($Name -replace '[\\/:*?"<>|]', '_') -replace '\s+', '_')
}

function Get-UNCPathFromShareName {
    param([string]$ShareName)

    return "\\$env:COMPUTERNAME\$ShareName"
}

function Test-UNCPathFormat {
    param([string]$UNCPath)

    return $UNCPath -match '^\\\\[^\\]+\\[^\\]+'
}

function Test-UNCPathExists {
    param([string]$UNCPath)

    if (-not (Test-UNCPathFormat -UNCPath $UNCPath)) {
        Write-WarningMsg "Format UNC invalide. Exemple attendu : \\SERVEUR\Partage"
        return $false
    }

    try {
        return (Test-Path -Path $UNCPath)
    } catch {
        Write-ErrorMsg "Impossible de tester $UNCPath : $($_.Exception.Message)"
        return $false
    }
}

function Read-DriveLetter {
    $DriveLetter = Read-RequiredValue "Lettre du lecteur réseau, exemple S"
    if (-not $DriveLetter) { return $null }

    $DriveLetter = $DriveLetter.TrimEnd(":").ToUpper()

    if ($DriveLetter -notmatch '^[A-Z]$') {
        Write-ErrorMsg "Lettre de lecteur invalide."
        return $null
    }

    return $DriveLetter
}

try {
    Import-Module ActiveDirectory
    Import-Module GroupPolicy
    Import-Module SmbShare
} catch {
    Write-ErrorMsg "Impossible de charger les modules nécessaires : $($_.Exception.Message)"
    Pause-Toolkit
    exit
}

try {
    $Global:Domain = Get-ADDomain
    $Global:DomainDN = $Global:Domain.DistinguishedName
    $Global:DomainDNS = $Global:Domain.DNSRoot
    $Global:NetBIOS = $Global:Domain.NetBIOSName
    $Global:SysvolScripts = "\\$($Global:DomainDNS)\SYSVOL\$($Global:DomainDNS)\scripts"
} catch {
    Write-ErrorMsg "Impossible de détecter le domaine AD."
    Pause-Toolkit
    exit
}

# =========================
# SELECTEURS
# =========================

function Select-OU {
    Clear-Host
    Write-Host "=== SELECTION OU ===" -ForegroundColor Cyan

    $OUs = Get-ADOrganizationalUnit -Filter * | Sort-Object DistinguishedName

    if (-not $OUs) {
        Write-ErrorMsg "Aucune OU trouvée."
        return $null
    }

    for ($i = 0; $i -lt $OUs.Count; $i++) {
        Write-Host "$($i + 1). $($OUs[$i].DistinguishedName)"
    }

    Write-Host ""
    $Choice = Read-Host "Numéro de l'OU"

    if ($Choice -match '^\d+$' -and [int]$Choice -ge 1 -and [int]$Choice -le $OUs.Count) {
        return $OUs[[int]$Choice - 1].DistinguishedName
    }

    Write-ErrorMsg "Choix invalide."
    return $null
}

function Select-GPO {
    Clear-Host
    Write-Host "=== SELECTION GPO EXISTANTE ===" -ForegroundColor Cyan

    $GPOs = Get-GPO -All | Sort-Object DisplayName

    if (-not $GPOs) {
        Write-ErrorMsg "Aucune GPO trouvée."
        return $null
    }

    for ($i = 0; $i -lt $GPOs.Count; $i++) {
        Write-Host "$($i + 1). $($GPOs[$i].DisplayName)"
    }

    Write-Host ""
    $Choice = Read-Host "Numéro de la GPO"

    if ($Choice -match '^\d+$' -and [int]$Choice -ge 1 -and [int]$Choice -le $GPOs.Count) {
        return $GPOs[[int]$Choice - 1].DisplayName
    }

    Write-ErrorMsg "Choix invalide."
    return $null
}

function Select-Group {
    Clear-Host
    Write-Host "=== SELECTION GROUPE ===" -ForegroundColor Cyan

    try {
        $Groups = @(Get-ADGroup -Filter * | Sort-Object Name)
    } catch {
        Write-ErrorMsg "Impossible de lister les groupes AD : $($_.Exception.Message)"
        return $null
    }

    if (-not $Groups) {
        Write-ErrorMsg "Aucun groupe AD trouvé."
        return $null
    }

    for ($i = 0; $i -lt $Groups.Count; $i++) {
        Write-Host "$($i + 1). $($Groups[$i].Name)"
    }

    Write-Host ""
    $Choice = Read-Host "Numéro du groupe"

    if ($Choice -match '^\d+$' -and [int]$Choice -ge 1 -and [int]$Choice -le $Groups.Count) {
        return $Groups[[int]$Choice - 1].Name
    }

    Write-ErrorMsg "Choix invalide."
    return $null
}

function Get-ToolkitSmbShares {
    try {
        return @(Get-SmbShare | Where-Object { -not $_.Special } | Sort-Object Name)
    } catch {
        Write-ErrorMsg "Impossible de lister les partages SMB : $($_.Exception.Message)"
        return @()
    }
}

function Show-ToolkitSmbShares {
    Clear-Host
    Write-Host "=== PARTAGES SMB EXISTANTS ===" -ForegroundColor Cyan

    $Shares = @(Get-ToolkitSmbShares)

    if (-not $Shares) {
        Write-WarningMsg "Aucun partage SMB utilisateur trouvé sur ce serveur."
    } else {
        $Shares |
            Select-Object Name, Path, Description |
            Format-Table -AutoSize
    }

    Pause-Toolkit
}

function Select-SmbShare {
    Clear-Host
    Write-Host "=== SELECTION PARTAGE SMB ===" -ForegroundColor Cyan

    $Shares = @(Get-ToolkitSmbShares)

    if (-not $Shares) {
        Write-WarningMsg "Aucun partage SMB utilisateur trouvé sur ce serveur."
        return $null
    }

    for ($i = 0; $i -lt $Shares.Count; $i++) {
        $UNCPath = Get-UNCPathFromShareName -ShareName $Shares[$i].Name
        Write-Host "$($i + 1). $UNCPath -> $($Shares[$i].Path)"
    }

    Write-Host ""
    $Choice = Read-Host "Numéro du partage"

    if ($Choice -match '^\d+$' -and [int]$Choice -ge 1 -and [int]$Choice -le $Shares.Count) {
        return (Get-UNCPathFromShareName -ShareName $Shares[[int]$Choice - 1].Name)
    }

    Write-ErrorMsg "Choix invalide."
    return $null
}

function Test-ToolkitUNCPath {
    Clear-Host
    Write-Host "=== TEST CHEMIN UNC ===" -ForegroundColor Cyan

    $UNCPath = Read-RequiredValue "Chemin UNC, exemple \\SERVEUR\Partage"
    if (-not $UNCPath) {
        Pause-Toolkit
        return
    }

    if (Test-UNCPathExists -UNCPath $UNCPath) {
        Write-Success "Chemin UNC accessible : $UNCPath"
    } else {
        Write-WarningMsg "Chemin UNC inaccessible ou introuvable : $UNCPath"
    }

    Pause-Toolkit
}

function Read-UNCPathForMappedDrive {
    Write-Host ""
    Write-Host "Source du lecteur réseau :"
    Write-Host "1. Utiliser un partage SMB existant sur ce serveur"
    Write-Host "2. Saisir un chemin UNC manuellement"
    Write-Host ""

    $Choice = Read-Host "Choix"

    switch ($Choice) {
        "1" {
            return (Select-SmbShare)
        }
        "2" {
            $UNCPath = Read-RequiredValue "Chemin UNC, exemple \\SRV-FICHIERS\Compta"
            if (-not $UNCPath) { return $null }

            if (-not (Test-UNCPathFormat -UNCPath $UNCPath)) {
                Write-WarningMsg "Le chemin ne ressemble pas à un UNC valide."
                return $null
            }

            if (-not (Test-UNCPathExists -UNCPath $UNCPath)) {
                if (-not (Confirm-Action "Le chemin n'est pas accessible depuis ce serveur. Continuer quand même ?")) {
                    return $null
                }
            }

            return $UNCPath
        }
        default {
            Write-ErrorMsg "Choix invalide."
            return $null
        }
    }
}

# =========================
# FONCTIONS COMMUNES GPO
# =========================

function Ensure-GPO {
    param([string]$GPOName)

    try {
        $Existing = Get-GPO -Name $GPOName -ErrorAction SilentlyContinue
    } catch {
        Write-ErrorMsg "Impossible de vérifier la GPO $GPOName : $($_.Exception.Message)"
        return $null
    }

    if ($Existing) {
        Write-WarningMsg "GPO déjà existante : $GPOName"
        return $Existing
    }

    if (-not (Confirm-Action "Créer la GPO $GPOName ?")) {
        return $null
    }

    if (-not (Invoke-SafeAction "Création de la GPO : $GPOName" {
        New-GPO -Name $GPOName | Out-Null
    })) {
        return $null
    }

    if ($Global:DryRun) {
        return [pscustomobject]@{
            DisplayName = $GPOName
        }
    }

    try {
        return Get-GPO -Name $GPOName
    } catch {
        Write-ErrorMsg "La GPO $GPOName n'a pas pu être relue après création : $($_.Exception.Message)"
        return $null
    }
}

function Link-GPO-ToOU {
    param(
        [string]$GPOName,
        [string]$OUPath
    )

    try {
        $Links = Get-GPInheritance -Target $OUPath | Select-Object -ExpandProperty GpoLinks
        $AlreadyLinked = $Links | Where-Object { $_.DisplayName -eq $GPOName }
    } catch {
        Write-ErrorMsg "Impossible de vérifier les liens GPO de $OUPath : $($_.Exception.Message)"
        return $false
    }

    if ($AlreadyLinked) {
        Write-WarningMsg "La GPO $GPOName est déjà liée à cette OU."
        return $true
    }

    if (-not (Confirm-Action "Lier la GPO $GPOName à $OUPath ?")) {
        return $false
    }

    if (Invoke-SafeAction "Liaison de la GPO $GPOName vers $OUPath" {
        New-GPLink -Name $GPOName -Target $OUPath -LinkEnabled Yes | Out-Null
    }) {
        Write-Success "GPO liée avec succès."
        return $true
    }

    return $false
}

function Complete-GPOConfiguration {
    param(
        [hashtable]$Context,
        [string]$SuccessMessage
    )

    $Linked = Link-GPO-ToOU -GPOName $Context.GPOName -OUPath $Context.OUPath

    if ($Linked) {
        Write-Success $SuccessMessage
    } else {
        Write-WarningMsg "$SuccessMessage La GPO n'a pas été liée à une OU."
    }
}

function Create-GPO-With-Target {
    param([string]$DefaultName)

    $GPOName = Read-Host "Nom de la GPO [$DefaultName]"
    if ([string]::IsNullOrWhiteSpace($GPOName)) {
        $GPOName = $DefaultName
    }

    $OUPath = Select-OU
    if (-not $OUPath) {
        return $null
    }

    $GPO = Ensure-GPO -GPOName $GPOName
    if (-not $GPO) {
        return $null
    }

    return @{
        GPOName = $GPOName
        OUPath = $OUPath
    }
}

# =========================
# AD : OU / GROUPES / USERS
# =========================

function New-ToolkitOU {
    Clear-Host
    Write-Host "=== CREER UNE OU ===" -ForegroundColor Cyan

    $OUName = Read-Host "Nom de l'OU"

    Write-Host ""
    Write-Host "Emplacement :"
    Write-Host "1. Racine du domaine"
    Write-Host "2. Sous une OU existante"

    $Choice = Read-Host "Choix"

    if ($Choice -eq "1") {
        $ParentPath = $Global:DomainDN
    } elseif ($Choice -eq "2") {
        $ParentPath = Select-OU
        if (-not $ParentPath) { return }
    } else {
        Write-ErrorMsg "Choix invalide."
        Pause-Toolkit
        return
    }

    $OUPath = "OU=$OUName,$ParentPath"

    $Exists = Get-ADOrganizationalUnit -LDAPFilter "(distinguishedName=$OUPath)" -ErrorAction SilentlyContinue

    if ($Exists) {
        Write-WarningMsg "OU déjà existante : $OUPath"
    } else {
        if (Confirm-Action "Créer l'OU $OUPath ?") {
            if (Invoke-SafeAction "Création OU : $OUPath" {
                New-ADOrganizationalUnit -Name $OUName -Path $ParentPath -ProtectedFromAccidentalDeletion $true
            }) {
                Write-Success "OU créée."
            }
        }
    }

    Pause-Toolkit
}

function New-ToolkitGroup {
    Clear-Host
    Write-Host "=== CREER UN GROUPE AD ===" -ForegroundColor Cyan

    $GroupName = Read-Host "Nom du groupe"
    $Description = Read-Host "Description"

    Write-Host ""
    Write-Host "Portée du groupe :"
    Write-Host "1. Global"
    Write-Host "2. DomainLocal"
    Write-Host "3. Universal"

    $ScopeChoice = Read-Host "Choix"

    switch ($ScopeChoice) {
        "1" { $Scope = "Global" }
        "2" { $Scope = "DomainLocal" }
        "3" { $Scope = "Universal" }
        default { $Scope = "Global" }
    }

    $OUPath = Select-OU
    if (-not $OUPath) { return }

    $Exists = Get-ADGroup -Filter "SamAccountName -eq '$GroupName'" -ErrorAction SilentlyContinue

    if ($Exists) {
        Write-WarningMsg "Groupe déjà existant."
    } else {
        if (Confirm-Action "Créer le groupe $GroupName dans $OUPath ?") {
            if (Invoke-SafeAction "Création groupe : $GroupName" {
                New-ADGroup `
                    -Name $GroupName `
                    -SamAccountName $GroupName `
                    -GroupScope $Scope `
                    -GroupCategory Security `
                    -Description $Description `
                    -Path $OUPath
            }) {
                Write-Success "Groupe créé."
            }
        }
    }

    Pause-Toolkit
}

function New-ToolkitUser {
    Clear-Host
    Write-Host "=== CREER UN UTILISATEUR AD ===" -ForegroundColor Cyan

    $FirstName = Read-Host "Prénom"
    $LastName = Read-Host "Nom"
    $Login = Read-Host "Login"
    $Password = Read-Host "Mot de passe temporaire" -AsSecureString

    $OUPath = Select-OU
    if (-not $OUPath) { return }

    $Exists = Get-ADUser -Filter "SamAccountName -eq '$Login'" -ErrorAction SilentlyContinue

    if ($Exists) {
        Write-WarningMsg "Utilisateur déjà existant."
    } else {
        if (Confirm-Action "Créer l'utilisateur $Login dans $OUPath ?") {
            if (Invoke-SafeAction "Création utilisateur : $Login" {
                New-ADUser `
                    -Name "$FirstName $LastName" `
                    -GivenName $FirstName `
                    -Surname $LastName `
                    -SamAccountName $Login `
                    -UserPrincipalName "$Login@$($Global:DomainDNS)" `
                    -Path $OUPath `
                    -AccountPassword $Password `
                    -Enabled $true `
                    -ChangePasswordAtLogon $true
            }) {
                Write-Success "Utilisateur créé."
            }
        }
    }

    $AddGroup = Confirm-Action "Ajouter cet utilisateur à un groupe maintenant ?"
    if ($AddGroup) {
        $GroupName = Select-Group
        if ($GroupName) {
            if (Invoke-SafeAction "Ajout de $Login au groupe $GroupName" {
                Add-ADGroupMember -Identity $GroupName -Members $Login
            }) {
                Write-Success "Utilisateur ajouté au groupe."
            }
        }
    }

    Pause-Toolkit
}

function Add-ToolkitUserToGroup {
    Clear-Host
    Write-Host "=== AJOUTER UTILISATEUR A GROUPE ===" -ForegroundColor Cyan

    $Login = Read-Host "Login utilisateur"
    $GroupName = Select-Group

    if (-not $GroupName) { return }

    if (Confirm-Action "Ajouter $Login au groupe $GroupName ?") {
        if (Invoke-SafeAction "Ajout utilisateur au groupe" {
            Add-ADGroupMember -Identity $GroupName -Members $Login
        }) {
            Write-Success "Utilisateur ajouté au groupe."
        }
    }

    Pause-Toolkit
}

# =========================
# PARTAGE SMB
# =========================

function New-ToolkitSharedFolder {
    Clear-Host
    Write-Host "=== CREER UN DOSSIER PARTAGE SMB ===" -ForegroundColor Cyan

    $FolderPath = Read-RequiredValue "Chemin local du dossier, exemple D:\Partages\Compta"
    if (-not $FolderPath) { return $null }

    $ShareName = Read-RequiredValue "Nom du partage SMB, exemple Compta"
    if (-not $ShareName) { return $null }

    try {
        $ExistingShare = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
    } catch {
        Write-ErrorMsg "Impossible de vérifier le partage $ShareName : $($_.Exception.Message)"
        return $null
    }

    if ($ExistingShare) {
        $UNCPath = Get-UNCPathFromShareName -ShareName $ShareName
        Write-WarningMsg "Partage déjà existant : $ShareName"
        Write-Info "Chemin UNC existant : $UNCPath"
        return $UNCPath
    }

    Write-Host ""
    Write-Host "Choix du groupe autorisé :"
    Write-Host "1. Sélectionner un groupe existant"
    Write-Host "2. Saisir manuellement"

    $GroupChoice = Read-Host "Choix"

    if ($GroupChoice -eq "1") {
        $GroupName = Select-Group
    } else {
        $GroupName = Read-RequiredValue "Nom du groupe AD"
    }

    if (-not $GroupName) { return $null }

    $AdGroupName = $GroupName
    if ($GroupName -match '^[^\\]+\\[^\\]+$') {
        $AdGroupName = ($GroupName -split '\\')[-1]
        $Identity = $GroupName
    } else {
        $Identity = "$($Global:NetBIOS)\$GroupName"
    }

    try {
        $GroupExists = Get-ADGroup -Identity $AdGroupName -ErrorAction SilentlyContinue
    } catch {
        $GroupExists = $null
    }

    if (-not $GroupExists) {
        Write-WarningMsg "Groupe AD introuvable : $AdGroupName"
        if (-not (Confirm-Action "Continuer quand même avec l'identité $Identity ?")) {
            return $null
        }
    }

    Write-Host ""
    Write-Host "Droits :"
    Write-Host "1. Lecture"
    Write-Host "2. Modification"
    Write-Host "3. Contrôle total"

    $AccessChoice = Read-Host "Choix"

    switch ($AccessChoice) {
        "1" {
            $SmbAccess = "Read"
            $NtfsRights = "ReadAndExecute"
        }
        "3" {
            $SmbAccess = "Full"
            $NtfsRights = "FullControl"
        }
        default {
            $SmbAccess = "Change"
            $NtfsRights = "Modify"
        }
    }

    $UNCPath = Get-UNCPathFromShareName -ShareName $ShareName

    Write-Host ""
    Write-Host "Résumé :" -ForegroundColor Yellow
    Write-Host "Dossier : $FolderPath"
    Write-Host "Partage : $UNCPath"
    Write-Host "Groupe : $Identity"
    Write-Host "Droits SMB : $SmbAccess"
    Write-Host "Droits NTFS : $NtfsRights"
    Write-Host ""

    if (-not (Confirm-Action "Créer/configurer ce partage ?")) {
        return
    }

    if (-not (Invoke-SafeAction "Création dossier si absent : $FolderPath" {
        if (-not (Test-Path $FolderPath)) {
            New-Item -ItemType Directory -Path $FolderPath -Force | Out-Null
        }
    })) {
        return $null
    }

    if (-not (Invoke-SafeAction "Application droits NTFS pour $Identity" {
        $Acl = Get-Acl $FolderPath

        $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $Identity,
            $NtfsRights,
            "ContainerInherit,ObjectInherit",
            "None",
            "Allow"
        )

        $Acl.SetAccessRule($Rule)
        Set-Acl -Path $FolderPath -AclObject $Acl
    })) {
        return $null
    }

    if (-not (Invoke-SafeAction "Création partage SMB : $ShareName" {
        if ($SmbAccess -eq "Read") {
            New-SmbShare -Name $ShareName -Path $FolderPath -ReadAccess $Identity | Out-Null
        } elseif ($SmbAccess -eq "Full") {
            New-SmbShare -Name $ShareName -Path $FolderPath -FullAccess $Identity | Out-Null
        } else {
            New-SmbShare -Name $ShareName -Path $FolderPath -ChangeAccess $Identity | Out-Null
        }
    })) {
        return $null
    }

    Write-Success "Partage créé : $UNCPath"

    return $UNCPath
}

# =========================
# BIBLIOTHEQUE GPO
# =========================

function Set-GPO-MappedDriveUsingRunKey {
    param(
        [string]$GPOName,
        [string]$DriveLetter,
        [string]$UNCPath
    )

    # Point de remplacement futur : cette fonction pourra devenir une vraie GPP Drive Map.
    # Pour l'instant, elle publie un script dans SYSVOL et le lance au logon via HKCU\...\Run.
    $SafeGPOName = Get-SafeFileName -Name $GPOName
    $ScriptName = "${SafeGPOName}_MapDrive_$DriveLetter.cmd"
    $ScriptPath = Join-Path $Global:SysvolScripts $ScriptName

    $ScriptContent = @"
@echo off
net use $DriveLetter`: /delete /yes >nul 2>&1
net use $DriveLetter`: "$UNCPath" /persistent:yes
"@

    if (-not (Invoke-SafeAction "Création script lecteur mappé dans SYSVOL : $ScriptName" {
        Set-Content -Path $ScriptPath -Value $ScriptContent -Encoding ASCII
    })) {
        return $false
    }

    if (-not (Invoke-SafeAction "Ajout du lancement du script via GPO" {
        Set-GPRegistryValue `
            -Name $GPOName `
            -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" `
            -ValueName "MapDrive_$DriveLetter" `
            -Type String `
            -Value "cmd.exe /c `"$ScriptPath`""
    })) {
        return $false
    }

    return $true
}

function New-GPO-MappedDrive {
    Clear-Host
    Write-Host "=== GPO : LECTEUR RESEAU MAPPE ===" -ForegroundColor Cyan

    $SharePath = Read-UNCPathForMappedDrive
    if (-not $SharePath) {
        Pause-Toolkit
        return
    }

    $DriveLetter = Read-DriveLetter
    if (-not $DriveLetter) {
        Pause-Toolkit
        return
    }

    $DefaultGPOName = "GPO_Lecteur_$DriveLetter"
    if ($SharePath -match '^\\\\[^\\]+\\([^\\]+)') {
        $DefaultGPOName = "GPO_Lecteur_$($Matches[1])"
    }

    $Context = Create-GPO-With-Target -DefaultName $DefaultGPOName
    if (-not $Context) {
        Pause-Toolkit
        return
    }

    Write-Host ""
    Write-Host "Résumé lecteur mappé :" -ForegroundColor Yellow
    Write-Host "Chemin UNC : $SharePath"
    Write-Host "Lecteur    : $DriveLetter`:"
    Write-Host "GPO        : $($Context.GPOName)"
    Write-Host "OU cible   : $($Context.OUPath)"
    Write-Host ""

    if (-not (Confirm-Action "Configurer ce mappage de lecteur réseau ?")) {
        Pause-Toolkit
        return
    }

    if (Set-GPO-MappedDriveUsingRunKey -GPOName $Context.GPOName -DriveLetter $DriveLetter -UNCPath $SharePath) {
        $Linked = Link-GPO-ToOU -GPOName $Context.GPOName -OUPath $Context.OUPath

        if ($Linked) {
            Write-Success "GPO lecteur réseau configurée et liée pour $DriveLetter`: -> $SharePath"
        } else {
            Write-WarningMsg "GPO lecteur réseau configurée, mais non liée à une OU."
        }
    }

    Pause-Toolkit
}

function New-GPO-BlockCMD {
    Clear-Host
    Write-Host "=== GPO : BLOQUER CMD ===" -ForegroundColor Cyan
    Write-WarningMsg "GPO restrictive. À tester sur une OU de test."

    $Context = Create-GPO-With-Target -DefaultName "GPO_Bloquer_CMD"
    if (-not $Context) { return }

    if (-not (Invoke-SafeAction "Configuration blocage CMD" {
        Set-GPRegistryValue `
            -Name $Context.GPOName `
            -Key "HKCU\Software\Policies\Microsoft\Windows\System" `
            -ValueName "DisableCMD" `
            -Type DWord `
            -Value 1
    })) {
        Pause-Toolkit
        return
    }

    Complete-GPOConfiguration -Context $Context -SuccessMessage "GPO CMD configurée."
    Pause-Toolkit
}

function New-GPO-BlockRegedit {
    Clear-Host
    Write-Host "=== GPO : BLOQUER REGEDIT ===" -ForegroundColor Cyan
    Write-WarningMsg "GPO restrictive. À tester sur une OU de test."

    $Context = Create-GPO-With-Target -DefaultName "GPO_Bloquer_Regedit"
    if (-not $Context) { return }

    if (-not (Invoke-SafeAction "Configuration blocage Regedit" {
        Set-GPRegistryValue `
            -Name $Context.GPOName `
            -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" `
            -ValueName "DisableRegistryTools" `
            -Type DWord `
            -Value 1
    })) {
        Pause-Toolkit
        return
    }

    Complete-GPOConfiguration -Context $Context -SuccessMessage "GPO Regedit configurée."
    Pause-Toolkit
}

function New-GPO-BlockControlPanel {
    Clear-Host
    Write-Host "=== GPO : BLOQUER PANNEAU DE CONFIGURATION ===" -ForegroundColor Cyan

    $Context = Create-GPO-With-Target -DefaultName "GPO_Bloquer_Panneau_Config"
    if (-not $Context) { return }

    if (-not (Invoke-SafeAction "Configuration blocage panneau de configuration" {
        Set-GPRegistryValue `
            -Name $Context.GPOName `
            -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" `
            -ValueName "NoControlPanel" `
            -Type DWord `
            -Value 1
    })) {
        Pause-Toolkit
        return
    }

    Complete-GPOConfiguration -Context $Context -SuccessMessage "GPO panneau de configuration configurée."
    Pause-Toolkit
}

function New-GPO-BlockTaskManager {
    Clear-Host
    Write-Host "=== GPO : BLOQUER GESTIONNAIRE DES TACHES ===" -ForegroundColor Cyan
    Write-WarningMsg "GPO restrictive. À tester sur une OU de test."

    $Context = Create-GPO-With-Target -DefaultName "GPO_Bloquer_TaskManager"
    if (-not $Context) { return }

    if (-not (Invoke-SafeAction "Configuration blocage gestionnaire des tâches" {
        Set-GPRegistryValue `
            -Name $Context.GPOName `
            -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" `
            -ValueName "DisableTaskMgr" `
            -Type DWord `
            -Value 1
    })) {
        Pause-Toolkit
        return
    }

    Complete-GPOConfiguration -Context $Context -SuccessMessage "GPO gestionnaire des tâches configurée."
    Pause-Toolkit
}

function New-GPO-DisableAutorunUSB {
    Clear-Host
    Write-Host "=== GPO : DESACTIVER AUTORUN USB ===" -ForegroundColor Cyan

    $Context = Create-GPO-With-Target -DefaultName "GPO_Desactiver_Autorun_USB"
    if (-not $Context) { return }

    if (-not (Invoke-SafeAction "Configuration désactivation autorun USB" {
        Set-GPRegistryValue `
            -Name $Context.GPOName `
            -Key "HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" `
            -ValueName "NoDriveTypeAutoRun" `
            -Type DWord `
            -Value 255
    })) {
        Pause-Toolkit
        return
    }

    Complete-GPOConfiguration -Context $Context -SuccessMessage "GPO autorun USB configurée."
    Pause-Toolkit
}

function New-GPO-BlockUSBStorage {
    Clear-Host
    Write-Host "=== GPO : BLOQUER STOCKAGE USB ===" -ForegroundColor Cyan
    Write-WarningMsg "Bloque les clés/disques USB. À tester avant prod."

    $Context = Create-GPO-With-Target -DefaultName "GPO_Bloquer_Stockage_USB"
    if (-not $Context) { return }

    if (-not (Invoke-SafeAction "Configuration blocage USBSTOR" {
        Set-GPRegistryValue `
            -Name $Context.GPOName `
            -Key "HKLM\System\CurrentControlSet\Services\USBSTOR" `
            -ValueName "Start" `
            -Type DWord `
            -Value 4
    })) {
        Pause-Toolkit
        return
    }

    Complete-GPOConfiguration -Context $Context -SuccessMessage "GPO stockage USB configurée."
    Pause-Toolkit
}

function New-GPO-EnableFirewall {
    Clear-Host
    Write-Host "=== GPO : ACTIVER PARE-FEU WINDOWS ===" -ForegroundColor Cyan

    $Context = Create-GPO-With-Target -DefaultName "GPO_Activer_PareFeu_Windows"
    if (-not $Context) { return }

    $Profiles = @("DomainProfile", "PrivateProfile", "PublicProfile")

    if (-not (Invoke-SafeAction "Configuration pare-feu Windows" {
        foreach ($Profile in $Profiles) {
            Set-GPRegistryValue `
                -Name $Context.GPOName `
                -Key "HKLM\Software\Policies\Microsoft\WindowsFirewall\$Profile" `
                -ValueName "EnableFirewall" `
                -Type DWord `
                -Value 1
        }
    })) {
        Pause-Toolkit
        return
    }

    Complete-GPOConfiguration -Context $Context -SuccessMessage "GPO pare-feu configurée."
    Pause-Toolkit
}

function New-GPO-BlockRDPPasswordSaving {
    Clear-Host
    Write-Host "=== GPO : BLOQUER ENREGISTREMENT MDP RDP ===" -ForegroundColor Cyan

    $Context = Create-GPO-With-Target -DefaultName "GPO_Bloquer_MDP_RDP"
    if (-not $Context) { return }

    if (-not (Invoke-SafeAction "Configuration blocage sauvegarde MDP RDP" {
        Set-GPRegistryValue `
            -Name $Context.GPOName `
            -Key "HKLM\Software\Policies\Microsoft\Windows NT\Terminal Services" `
            -ValueName "DisablePasswordSaving" `
            -Type DWord `
            -Value 1
    })) {
        Pause-Toolkit
        return
    }

    Complete-GPOConfiguration -Context $Context -SuccessMessage "GPO RDP configurée."
    Pause-Toolkit
}

function New-GPO-Wallpaper {
    Clear-Host
    Write-Host "=== GPO : FOND D'ECRAN IMPOSE ===" -ForegroundColor Cyan

    $Context = Create-GPO-With-Target -DefaultName "GPO_Fond_Ecran"
    if (-not $Context) { return }

    $WallpaperPath = Read-Host "Chemin UNC image, exemple \\SRV-FICHIERS\Commun\wallpaper.jpg"

    if (-not (Invoke-SafeAction "Configuration fond d'écran" {
        Set-GPRegistryValue `
            -Name $Context.GPOName `
            -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" `
            -ValueName "Wallpaper" `
            -Type String `
            -Value $WallpaperPath

        Set-GPRegistryValue `
            -Name $Context.GPOName `
            -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" `
            -ValueName "WallpaperStyle" `
            -Type String `
            -Value "2"
    })) {
        Pause-Toolkit
        return
    }

    Complete-GPOConfiguration -Context $Context -SuccessMessage "GPO fond d'écran configurée."
    Pause-Toolkit
}

function New-GPO-LockScreenTimeout {
    Clear-Host
    Write-Host "=== GPO : VERROUILLAGE SESSION ===" -ForegroundColor Cyan

    $Context = Create-GPO-With-Target -DefaultName "GPO_Verrouillage_Session"
    if (-not $Context) { return }

    $Seconds = Read-Host "Délai en secondes, exemple 900 pour 15 minutes"

    if (-not (Invoke-SafeAction "Configuration délai verrouillage session" {
        Set-GPRegistryValue `
            -Name $Context.GPOName `
            -Key "HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop" `
            -ValueName "ScreenSaveActive" `
            -Type String `
            -Value "1"

        Set-GPRegistryValue `
            -Name $Context.GPOName `
            -Key "HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop" `
            -ValueName "ScreenSaveTimeOut" `
            -Type String `
            -Value $Seconds

        Set-GPRegistryValue `
            -Name $Context.GPOName `
            -Key "HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop" `
            -ValueName "ScreenSaverIsSecure" `
            -Type String `
            -Value "1"
    })) {
        Pause-Toolkit
        return
    }

    Complete-GPOConfiguration -Context $Context -SuccessMessage "GPO verrouillage session configurée."
    Pause-Toolkit
}

function New-GPO-DisableMicrosoftStore {
    Clear-Host
    Write-Host "=== GPO : DESACTIVER MICROSOFT STORE ===" -ForegroundColor Cyan

    $Context = Create-GPO-With-Target -DefaultName "GPO_Desactiver_Microsoft_Store"
    if (-not $Context) { return }

    if (-not (Invoke-SafeAction "Configuration désactivation Microsoft Store" {
        Set-GPRegistryValue `
            -Name $Context.GPOName `
            -Key "HKLM\Software\Policies\Microsoft\WindowsStore" `
            -ValueName "RemoveWindowsStore" `
            -Type DWord `
            -Value 1
    })) {
        Pause-Toolkit
        return
    }

    Complete-GPOConfiguration -Context $Context -SuccessMessage "GPO Microsoft Store configurée."
    Pause-Toolkit
}

function Link-ExistingGPO {
    Clear-Host
    Write-Host "=== LIER UNE GPO EXISTANTE A UNE OU ===" -ForegroundColor Cyan

    $GPOName = Select-GPO
    if (-not $GPOName) { return }

    $OUPath = Select-OU
    if (-not $OUPath) { return }

    Link-GPO-ToOU -GPOName $GPOName -OUPath $OUPath

    Pause-Toolkit
}

# =========================
# RAPPORTS / OUTILS
# =========================

function Show-OUs {
    Clear-Host
    Write-Host "=== OU EXISTANTES ===" -ForegroundColor Cyan

    Get-ADOrganizationalUnit -Filter * |
        Sort-Object DistinguishedName |
        Select-Object Name, DistinguishedName |
        Format-Table -AutoSize

    Pause-Toolkit
}

function Show-Groups {
    Clear-Host
    Write-Host "=== GROUPES EXISTANTS ===" -ForegroundColor Cyan

    Get-ADGroup -Filter * |
        Sort-Object Name |
        Select-Object Name, GroupScope, DistinguishedName |
        Format-Table -AutoSize

    Pause-Toolkit
}

function Show-GPOs {
    Clear-Host
    Write-Host "=== GPO EXISTANTES ===" -ForegroundColor Cyan

    Get-GPO -All |
        Sort-Object DisplayName |
        Select-Object DisplayName, Owner, CreationTime, ModificationTime |
        Format-Table -AutoSize

    Pause-Toolkit
}

function Backup-AllGPOs {
    Clear-Host
    Write-Host "=== SAUVEGARDE GPO ===" -ForegroundColor Cyan

    $BackupPath = Read-Host "Chemin sauvegarde, exemple C:\GPO_Backup"

    if (Confirm-Action "Sauvegarder toutes les GPO dans $BackupPath ?") {
        if (-not (Invoke-SafeAction "Création dossier sauvegarde" {
            if (-not (Test-Path $BackupPath)) {
                New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
            }
        })) {
            Pause-Toolkit
            return
        }

        if (Invoke-SafeAction "Sauvegarde de toutes les GPO" {
            Backup-GPO -All -Path $BackupPath | Out-Null
        }) {
            Write-Success "Sauvegarde terminée : $BackupPath"
        }
    }

    Pause-Toolkit
}

function Export-GPOReport {
    Clear-Host
    Write-Host "=== RAPPORT HTML GPO ===" -ForegroundColor Cyan

    $ReportPath = Read-Host "Chemin rapport HTML, exemple C:\GPO_Report.html"

    if (Invoke-SafeAction "Génération rapport HTML GPO" {
        Get-GPOReport -All -ReportType Html -Path $ReportPath
    }) {
        Write-Success "Rapport créé : $ReportPath"
    }

    Pause-Toolkit
}

function Toggle-DryRun {
    $Global:DryRun = -not $Global:DryRun

    if ($Global:DryRun) {
        Write-WarningMsg "Mode simulation ACTIVÉ. Aucune modification ne sera appliquée."
    } else {
        Write-Success "Mode simulation DÉSACTIVÉ."
    }

    Pause-Toolkit
}

# =========================
# MENUS COHERENTS
# =========================

function Menu-ADObjects {
    do {
        Clear-Host
        Write-Host "===== OBJETS ACTIVE DIRECTORY =====" -ForegroundColor Cyan
        Write-Host "1. Créer une OU"
        Write-Host "2. Créer un groupe"
        Write-Host "3. Créer un utilisateur"
        Write-Host "4. Ajouter un utilisateur à un groupe"
        Write-Host "5. Voir les OU"
        Write-Host "6. Voir les groupes"
        Write-Host "7. Retour"
        Write-Host ""

        $Choice = Read-Host "Choix"

        switch ($Choice) {
            "1" { New-ToolkitOU }
            "2" { New-ToolkitGroup }
            "3" { New-ToolkitUser }
            "4" { Add-ToolkitUserToGroup }
            "5" { Show-OUs }
            "6" { Show-Groups }
            "7" { return }
            default {
                Write-ErrorMsg "Choix invalide."
                Pause-Toolkit
            }
        }
    } while ($true)
}

function Menu-SharedFolders {
    do {
        Clear-Host
        Write-Host "===== DOSSIERS PARTAGES =====" -ForegroundColor Cyan
        Write-Host "1. Créer un dossier partagé SMB"
        Write-Host "2. Voir les partages SMB existants"
        Write-Host "3. Tester un chemin UNC"
        Write-Host "4. Retour"
        Write-Host ""

        $Choice = Read-Host "Choix"

        switch ($Choice) {
            "1" {
                $UNCPath = New-ToolkitSharedFolder
                if ($UNCPath) {
                    Write-Success "Chemin UNC : $UNCPath"
                }
                Pause-Toolkit
            }
            "2" { Show-ToolkitSmbShares }
            "3" { Test-ToolkitUNCPath }
            "4" { return }
            default {
                Write-ErrorMsg "Choix invalide."
                Pause-Toolkit
            }
        }
    } while ($true)
}

function Menu-GPO {
    do {
        Clear-Host
        Write-Host "===== GPO =====" -ForegroundColor Cyan
        Write-Host "1. Créer une GPO lecteur réseau mappé"
        Write-Host "2. Bloquer CMD"
        Write-Host "3. Bloquer Regedit"
        Write-Host "4. Bloquer panneau de configuration"
        Write-Host "5. Bloquer gestionnaire des tâches"
        Write-Host "6. Désactiver autorun USB"
        Write-Host "7. Bloquer stockage USB"
        Write-Host "8. Activer pare-feu Windows"
        Write-Host "9. Bloquer sauvegarde mots de passe RDP"
        Write-Host "10. Imposer fond d'écran"
        Write-Host "11. Verrouillage session automatique"
        Write-Host "12. Désactiver Microsoft Store"
        Write-Host "13. Lier une GPO existante à une OU"
        Write-Host "14. Voir les GPO existantes"
        Write-Host "15. Retour"
        Write-Host ""

        $Choice = Read-Host "Choix"

        switch ($Choice) {
            "1" { New-GPO-MappedDrive }
            "2" { New-GPO-BlockCMD }
            "3" { New-GPO-BlockRegedit }
            "4" { New-GPO-BlockControlPanel }
            "5" { New-GPO-BlockTaskManager }
            "6" { New-GPO-DisableAutorunUSB }
            "7" { New-GPO-BlockUSBStorage }
            "8" { New-GPO-EnableFirewall }
            "9" { New-GPO-BlockRDPPasswordSaving }
            "10" { New-GPO-Wallpaper }
            "11" { New-GPO-LockScreenTimeout }
            "12" { New-GPO-DisableMicrosoftStore }
            "13" { Link-ExistingGPO }
            "14" { Show-GPOs }
            "15" { return }
            default {
                Write-ErrorMsg "Choix invalide."
                Pause-Toolkit
            }
        }
    } while ($true)
}

function Menu-Reports {
    do {
        Clear-Host
        Write-Host "===== RAPPORTS / MAINTENANCE =====" -ForegroundColor Cyan
        Write-Host "1. Sauvegarder toutes les GPO"
        Write-Host "2. Générer un rapport HTML GPO"
        Write-Host "3. Voir les OU"
        Write-Host "4. Voir les groupes"
        Write-Host "5. Voir les GPO"
        Write-Host "6. Retour"
        Write-Host ""

        $Choice = Read-Host "Choix"

        switch ($Choice) {
            "1" { Backup-AllGPOs }
            "2" { Export-GPOReport }
            "3" { Show-OUs }
            "4" { Show-Groups }
            "5" { Show-GPOs }
            "6" { return }
            default {
                Write-ErrorMsg "Choix invalide."
                Pause-Toolkit
            }
        }
    } while ($true)
}

function Main-Menu {
    do {
        Clear-Host
        Write-Host "=========================================" -ForegroundColor Cyan
        Write-Host "           AD / GPO TOOLKIT              " -ForegroundColor Cyan
        Write-Host "=========================================" -ForegroundColor Cyan
        Write-Host "Domaine : $($Global:DomainDNS)"
        Write-Host "Serveur : $env:COMPUTERNAME"
        Write-Host "DryRun  : $Global:DryRun"
        Write-Host "Logs    : $Global:LogPath"
        Write-Host ""
        Write-Host "1. Gérer les objets AD"
        Write-Host "2. Gérer les dossiers partagés"
        Write-Host "3. Gérer les GPO"
        Write-Host "4. Rapports / sauvegarde"
        Write-Host "5. Activer / désactiver mode simulation"
        Write-Host "6. Quitter"
        Write-Host ""

        $Choice = Read-Host "Choix"

        switch ($Choice) {
            "1" { Menu-ADObjects }
            "2" { Menu-SharedFolders }
            "3" { Menu-GPO }
            "4" { Menu-Reports }
            "5" { Toggle-DryRun }
            "6" {
                Write-Success "Fermeture du toolkit."
                break
            }
            default {
                Write-ErrorMsg "Choix invalide."
                Pause-Toolkit
            }
        }
    } while ($true)
}

Main-Menu
