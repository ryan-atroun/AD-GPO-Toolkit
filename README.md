# AD-GPO-Toolkit

Outil PowerShell interactif pour administrer des actions courantes dans un Active Directory :
OU, groupes, utilisateurs, dossiers partages SMB et GPO.

Le script separe volontairement deux responsabilites :

- le menu **Dossiers partages** cree uniquement un dossier local, ses droits NTFS et son partage SMB ;
- le menu **GPO** cree ou modifie des GPO, dont une GPO de lecteur reseau mappe a partir d'un chemin UNC existant.

Tous les textes visibles sont en ASCII pour eviter les problemes d'affichage dans les consoles Windows Server.

## Pre-requis

- Windows Server joint au domaine ou controleur de domaine
- PowerShell lance en administrateur
- Compte disposant des droits necessaires dans Active Directory, GPO et SMB
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

Commencer par l'option :

```text
Verifier l'environnement
```

## Menus principaux

### 1. Gerer les objets AD

- Creer une OU
- Creer un groupe
- Creer un utilisateur
- Ajouter un utilisateur a un groupe
- Voir les OU
- Voir les groupes

Le script verifie l'existence des objets avant creation et ne supprime aucun objet AD.

### 2. Gerer les dossiers partages

- Creer un dossier partage SMB
- Voir les partages SMB existants
- Tester un chemin UNC

Lors de la creation d'un partage SMB, le script demande :

- le chemin local du dossier, par exemple `D:\Partages\Compta` ;
- le nom du partage, par exemple `Compta` ;
- le groupe AD autorise ;
- les droits : Lecture, Modification ou Controle total.

Si le partage existe deja, le script propose :

- ne rien faire ;
- mettre a jour les droits ;
- choisir un autre nom de partage.

Le script verifie le disque, cree le dossier si besoin, applique les droits NTFS puis cree ou met a jour le partage SMB.
Le chemin UNC final est affiche, par exemple :

```text
\\SERVEUR\Compta
```

Cette partie ne cree jamais de GPO automatiquement.

### 3. Gerer les GPO

- Creer une GPO lecteur reseau mappe
- Bloquer CMD
- Bloquer Regedit
- Bloquer panneau de configuration
- Bloquer gestionnaire des taches
- Desactiver autorun USB
- Bloquer stockage USB
- Activer pare-feu Windows
- Bloquer sauvegarde mots de passe RDP
- Imposer fond d'ecran
- Verrouillage session automatique
- Desactiver Microsoft Store
- Lier une GPO existante a une OU
- Voir les GPO existantes

Pour une GPO de lecteur reseau mappe, le script propose :

- utiliser un partage SMB existant sur le serveur ;
- ou saisir un chemin UNC manuellement.

Il demande ensuite la lettre du lecteur, le nom de la GPO et l'OU cible.
La methode actuelle cree un script `.cmd` dans SYSVOL et le lance via la cle `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
Le code est isole dans une fonction dediee afin de pouvoir remplacer plus tard cette methode par une vraie Group Policy Preferences Drive Map.

### 4. Rapports / sauvegarde

- Sauvegarder toutes les GPO
- Generer un rapport HTML GPO
- Voir les OU
- Voir les groupes
- Voir les GPO

### 5. Outils GPO client

- Lancer `gpupdate /force` localement
- Lancer `gpresult /r` localement
- Generer un rapport HTML local avec `gpresult /h C:\Logs\gpresult.html /f`
- Tester l'application des GPO sur le serveur actuel

Le rapport HTML local est genere ici :

```text
C:\Logs\gpresult.html
```

### 6. Verifier l'environnement

Cette option controle :

- execution en administrateur ;
- modules ActiveDirectory, GroupPolicy et SmbShare ;
- acces au domaine AD ;
- acces au chemin SYSVOL scripts ;
- dossier `C:\Logs` ;
- service LanmanServer ;
- acces aux partages SMB ;
- commandes `gpupdate` et `gpresult`.

Chaque controle affiche `[OK]` ou `[ERREUR]`.

### Mode simulation

Le mode simulation, ou DryRun, affiche les actions prevues sans appliquer les modifications.
Il est utile pour relire le scenario avant de creer des objets, des partages ou des GPO.

## Checklist de tests Windows Server

1. Lancer PowerShell en administrateur.
2. Lancer le script avec `.\Start-Toolkit.ps1`.
3. Executer `Verifier l'environnement`.
4. Creer une OU de test.
5. Creer un groupe de test.
6. Creer un utilisateur de test.
7. Creer un dossier partage de test.
8. Verifier le partage :

```powershell
Get-SmbShare
Test-Path \\SERVEUR\NomDuPartage
```

9. Creer une GPO lecteur mappe vers ce partage.
10. Lier la GPO a une OU de test.
11. Lancer la mise a jour GPO :

```cmd
gpupdate /force
```

12. Verifier le resultat :

```cmd
gpresult /r
gpresult /h C:\Logs\gpresult.html /f
rsop.msc
net use
```

13. Consulter les logs :

```powershell
Get-Content C:\Logs\AD-GPO-Toolkit.log -Tail 100
```
