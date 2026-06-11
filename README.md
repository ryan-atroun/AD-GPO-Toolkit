# AD-GPO-Toolkit

Outil PowerShell interactif pour administrer des actions courantes dans un Active Directory :
OU, groupes, utilisateurs, dossiers partagés SMB et GPO.

Le script sépare volontairement deux responsabilités :

- le menu **Dossiers partagés** crée uniquement un dossier local, ses droits NTFS et son partage SMB ;
- le menu **GPO** crée ou modifie des GPO, dont une GPO de lecteur réseau mappé à partir d'un chemin UNC existant.

## Pré-requis

- Windows Server joint au domaine ou contrôleur de domaine
- PowerShell lancé en administrateur
- Compte disposant des droits nécessaires dans Active Directory, GPO et SMB
- Modules PowerShell :
  - ActiveDirectory
  - GroupPolicy
  - SmbShare

Le script conserve ses logs dans :

```powershell
C:\Logs\AD-GPO-Toolkit.log
```

## Lancement

Depuis une console PowerShell administrateur :

```powershell
Set-ExecutionPolicy RemoteSigned -Scope Process
.\Start-Toolkit.ps1
```

## Menus principaux

### 1. Gérer les objets AD

- Créer une OU
- Créer un groupe
- Créer un utilisateur
- Ajouter un utilisateur à un groupe
- Voir les OU
- Voir les groupes

Le script vérifie l'existence des objets avant création et ne supprime aucun objet AD.

### 2. Gérer les dossiers partagés

- Créer un dossier partagé SMB
- Voir les partages SMB existants
- Tester un chemin UNC

Lors de la création d'un partage SMB, le script demande :

- le chemin local du dossier, par exemple `D:\Partages\Compta` ;
- le nom du partage, par exemple `Compta` ;
- le groupe AD autorisé ;
- les droits : Lecture, Modification ou Contrôle total.

Si le dossier local n'existe pas, il est créé. Les droits NTFS sont appliqués puis le partage SMB est créé.
À la fin, le script affiche le chemin UNC généré, par exemple :

```text
\\SERVEUR\Compta
```

Cette partie ne crée jamais de GPO automatiquement.

### 3. Gérer les GPO

- Créer une GPO lecteur réseau mappé
- Bloquer CMD
- Bloquer Regedit
- Bloquer panneau de configuration
- Bloquer gestionnaire des tâches
- Désactiver autorun USB
- Bloquer stockage USB
- Activer pare-feu Windows
- Bloquer sauvegarde mots de passe RDP
- Imposer fond d'écran
- Verrouillage session automatique
- Désactiver Microsoft Store
- Lier une GPO existante à une OU
- Voir les GPO existantes

Pour une GPO de lecteur réseau mappé, le script propose :

- utiliser un partage SMB existant sur le serveur ;
- ou saisir un chemin UNC manuellement.

Il demande ensuite la lettre du lecteur, le nom de la GPO et l'OU cible.
La méthode actuelle crée un script `.cmd` dans SYSVOL et le lance via la clé `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
Le code est isolé dans une fonction dédiée afin de pouvoir remplacer plus tard cette méthode par une vraie Group Policy Preferences Drive Map.

### 4. Rapports / sauvegarde

- Sauvegarder toutes les GPO
- Générer un rapport HTML GPO
- Voir les OU
- Voir les groupes
- Voir les GPO

### 5. Mode simulation

Le mode simulation, ou DryRun, affiche les actions prévues sans appliquer les modifications.
Il est utile pour relire le scénario avant de créer des objets, des partages ou des GPO.

## Validation sur Windows Server

Après avoir créé ou lié une GPO, lancer sur un poste cible ou une session de test :

```cmd
gpupdate /force
gpresult /r
rsop.msc
```

Pour vérifier un lecteur réseau mappé :

```cmd
net use
```

Pour vérifier les partages côté serveur :

```powershell
Get-SmbShare
Test-Path \\SERVEUR\NomDuPartage
```
