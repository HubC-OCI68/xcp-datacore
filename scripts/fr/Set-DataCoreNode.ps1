#Requires -RunAsAdministrator
<#
  Set-DataCoreNode.ps1 - Reseau, systeme et iSCSI d'un serveur SANsymphony (VM XCP-ng)
  Variables : DataCoreNode.psd1 (meme dossier, ou -ConfigFile). Aucune valeur a modifier ici.

  .\Set-DataCoreNode.ps1                             # menu interactif (noeud detecte, a confirmer)
  .\Set-DataCoreNode.ps1 -Phase Test                 # -Node absent : noeud detecte, a confirmer

  .\Set-DataCoreNode.ps1 -Node 1 -Phase Prepare      # avant installation SANsymphony (puis redemarrage)
  .\Set-DataCoreNode.ps1 -Node 1 -Phase Ports        # une fois, apres installation : roles, noms, IQN des ports des 2 serveurs
  .\Set-DataCoreNode.ps1 -Node 1 -Phase PostInstall  # apres la phase Ports, AVANT tout service de vDisk
  .\Set-DataCoreNode.ps1 -Node 1 -Phase Initiator    # apres PostInstall sur les 2 serveurs : liens miroir (MR) uniquement
  .\Set-DataCoreNode.ps1 -Node 1 -Phase Hosts        # une fois, apres 'iscsi' sur les dom0 : hotes XCP-ng, service des vDisks
  .\Set-DataCoreNode.ps1 -Node 1 -Phase Test
  .\Set-DataCoreNode.ps1 -Node 1 -Phase PreUpgrade   # avant une mise a jour SANsymphony (PSP)
  .\Set-DataCoreNode.ps1 -Node 1 -Phase PostUpgrade  # apres une mise a jour SANsymphony (PSP)
  .\Set-DataCoreNode.ps1 -Node 1 -Phase PrePatch     # avant Windows Update, apres 'Stop DataCore Server'
  .\Set-DataCoreNode.ps1 -Node 1 -Phase PostPatch    # apres Windows Update et redemarrage
#>
param(
    [ValidateSet(1,2)][int]$Node,
    [ValidateSet('Prepare','Ports','PostInstall','Initiator','Hosts','Test','PreUpgrade','PostUpgrade','PrePatch','PostPatch')][string]$Phase,
    [string]$ConfigFile = (Join-Path $PSScriptRoot 'DataCoreNode.psd1'),
    [switch]$Force
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ConfigFile)) { throw "Fichier de variables introuvable : $ConfigFile" }
$Cfg = Import-PowerShellDataFile -Path $ConfigFile
foreach ($k in 'Nodes','Subnets','DcOct','HostOct','Mtu','Metric','BestPracticeScript','BestPracticeFilter','InitiatorPorts','IqnSuffix','PagefileSizeMB') {
    if (-not $Cfg.ContainsKey($k)) { throw "Variable $k absente de $ConfigFile" }
}
$ByIndex = @('MGMT','DC-FE1','DC-FE2','DC-MR1','DC-MR2')   # index du VIF = dernier octet de la MAC
$Storage = @('DC-FE1','DC-FE2','DC-MR1','DC-MR2')
$WuKey   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$AuKey   = "$WuKey\AU"
$DumpKey = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps'
$StartTypeFile = Join-Path $PSScriptRoot 'DcsExecutive-StartType.txt'   # type de demarrage sauve par PrePatch

function Resolve-Node {
    # Detection par la MAC de la carte MGMT (02-DC-00-0N-00-00, datacore-xcp.sh dcvm) et par le nom Windows
    $byMac  = @(Get-NetAdapter | ForEach-Object { if ($_.MacAddress -match '^02-DC-00-0([12])-00-00$') { [int]$Matches[1] } })
    $byName = @(1, 2 | Where-Object { $Cfg.Nodes[$_].Name -ieq $env:COMPUTERNAME })
    $guess  = @($byMac + $byName | Sort-Object -Unique)
    if ($Node) {
        if ($guess.Count -eq 1 -and $guess[0] -ne $Node) { Write-Warning "-Node $Node, mais la MAC MGMT ou le nom designent le noeud $($guess[0])" }
        return $Node
    }
    if ($guess.Count -gt 1) { Write-Warning "Detection contradictoire : MAC MGMT -> noeud $($byMac -join ','), nom -> noeud $($byName -join ',')" }
    $def  = if ($guess.Count -eq 1) { $guess[0] } else { 0 }
    $hint = if ($def) { " [Entree = $def]" } else { '' }
    while ($true) {
        $r = Read-Host ('Noeud (1 = {0}, 2 = {1}){2}' -f $Cfg.Nodes[1].Name, $Cfg.Nodes[2].Name, $hint)
        if (-not $r -and $def) { return $def }
        if ($r -in '1', '2') { return [int]$r }
    }
}
$Node     = Resolve-Node
$Peer     = 3 - $Node
$PeerName = $Cfg.Nodes[$Peer].Name

function Get-PortIp([string]$If, [int]$Oct) { '{0}.{1}' -f $Cfg.Subnets[$If], $Oct }
function Get-Mac([int]$Index) { '02-DC-00-{0:X2}-00-{1:X2}' -f $Node, $Index }

function Show-Resolution {
    "Resolution de $env:COMPUTERNAME (attendu : IP de management seule) :"
    [System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) | ForEach-Object IPAddressToString
    Get-NetIPAddress -InterfaceAlias $Storage -AddressFamily IPv4 |
        Format-Table InterfaceAlias, IPAddress, SkipAsSource -AutoSize
}

function Assert-DataCoreStopped {
    # Prepare recree les IP de stockage : interdite quand SANsymphony sert des vDisks
    $svc = Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'DataCore*' -and $_.Status -eq 'Running' }
    if ($svc) { throw "Services DataCore actifs ($($svc.DisplayName -join ', ')) : phase Prepare interdite" }
}

function Rename-Adapters {
    # Renommage par MAC fixe 02:dc:00:0N:00:0i (datacore-xcp.sh dcvm), en 2 passes pour
    # corriger une carte deja renommee a tort (ex. une FE nommee MGMT a la main)
    $nics = @{}
    for ($i = 0; $i -lt $ByIndex.Count; $i++) {
        $nic = Get-NetAdapter | Where-Object MacAddress -eq (Get-Mac $i)
        if (-not $nic) { throw "Aucune carte avec la MAC $(Get-Mac $i) (VIF $i, $($ByIndex[$i]))" }
        $nics[$i] = $nic
    }
    for ($i = 0; $i -lt $ByIndex.Count; $i++) {
        if ($nics[$i].Name -ne $ByIndex[$i]) { Rename-NetAdapter -Name $nics[$i].Name -NewName "tmp-dc-$i" }
    }
    for ($i = 0; $i -lt $ByIndex.Count; $i++) {
        if (Get-NetAdapter -Name "tmp-dc-$i" -ErrorAction SilentlyContinue) { Rename-NetAdapter -Name "tmp-dc-$i" -NewName $ByIndex[$i] }
    }
    Get-NetAdapter -Name $ByIndex | Sort-Object MacAddress | Format-Table Name, MacAddress, Status -AutoSize
}

function Assert-Mgmt {
    $want = $Cfg.Nodes[$Node].MgmtIp
    if (-not $want) { throw "MgmtIp du noeud $Node non renseignee dans $ConfigFile" }
    $have = @(Get-NetIPAddress -InterfaceAlias MGMT -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    if ($have -notcontains $want) {
        $wrong = Get-NetIPAddress -IPAddress $want -ErrorAction SilentlyContinue
        if ($wrong) { throw "L'IP $want est posee sur $($wrong.InterfaceAlias), pas sur MGMT (MAC $(Get-Mac 0)) : la deplacer (section 5, etape 3)" }
        throw "MGMT (MAC $(Get-Mac 0)) n'a pas l'IP $want (actuelle : $($have -join ', ')) : section 5, etape 3"
    }
    "MGMT : $want (MAC $(Get-Mac 0)) OK"
}

function Set-UpdatePolicy {
    # Pas de redemarrage automatique : les 2 serveurs ne doivent jamais redemarrer ensemble
    if (-not (Test-Path $AuKey)) { New-Item -Path $AuKey -Force | Out-Null }
    Set-ItemProperty -Path $AuKey -Name AUOptions -Value 2 -Type DWord                      # notifier avant telechargement
    Set-ItemProperty -Path $AuKey -Name NoAutoRebootWithLoggedOnUsers -Value 1 -Type DWord
    # DataCore : pas de pilotes tiers par Windows Update (HBA, cartes reseau)
    Set-ItemProperty -Path $WuKey -Name ExcludeWUDriversInQualityUpdate -Value 1 -Type DWord
    Write-Warning "Une GPO de domaine peut ecraser ce reglage : verifier avec gpresult /h"
}

function Set-Pagefile {
    # Taille fixe sur C: uniquement (initiale = maximale), gestion automatique desactivee
    $size = [uint32]$Cfg.PagefileSizeMB
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.AutomaticManagedPagefile) { $cs | Set-CimInstance -Property @{ AutomaticManagedPagefile = $false } }
    Get-CimInstance Win32_PageFileSetting | Where-Object Name -ine 'C:\pagefile.sys' | Remove-CimInstance
    $pf = Get-CimInstance Win32_PageFileSetting | Where-Object Name -ieq 'C:\pagefile.sys'
    if (-not $pf) { $pf = New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = 'C:\pagefile.sys' } }
    $pf | Set-CimInstance -Property @{ InitialSize = $size; MaximumSize = $size }
    "Fichier d'echange : C:\pagefile.sys fixe a $size Mo (effectif au redemarrage)"
}

function Set-UserDumps {
    # DataCore : dumps en mode utilisateur (plantages DMC et console), dump complet
    if (-not (Test-Path $DumpKey)) { New-Item -Path $DumpKey -Force | Out-Null }
    Set-ItemProperty -Path $DumpKey -Name DumpType -Value 2 -Type DWord
    "Dumps en mode utilisateur : LocalDumps\DumpType = 2"
}

function Set-StorageNetwork {
    foreach ($if in $Storage) {
        $ip = Get-PortIp $if $Cfg.DcOct[$Node]
        try {
            if (Get-NetAdapterAdvancedProperty -Name $if -RegistryKeyword '*JumboPacket' -ErrorAction SilentlyContinue) {
                Set-NetAdapterAdvancedProperty -Name $if -RegistryKeyword '*JumboPacket' -RegistryValue ($Cfg.Mtu + 14) -NoRestart
            }
        } catch { Write-Warning "$if : *JumboPacket non modifiable ($($_.Exception.Message)) ; MTU IP fixee a $($Cfg.Mtu) ci-dessous" }
        foreach ($b in 'ms_msclient','ms_server','ms_tcpip6','ms_lldp','ms_lltdio','ms_rspndr','ms_pacer') {
            Disable-NetAdapterBinding -Name $if -ComponentID $b -ErrorAction SilentlyContinue
        }
        Get-NetIPAddress -InterfaceAlias $if -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false
        Remove-NetRoute -InterfaceAlias $if -Confirm:$false -ErrorAction SilentlyContinue
        Set-NetIPInterface -InterfaceAlias $if -AddressFamily IPv4 -Dhcp Disabled -NlMtuBytes $Cfg.Mtu -InterfaceMetric $Cfg.Metric[$if]
        # SkipAsSource : le nom du serveur ne doit pas resoudre vers le stockage (assistant DataCore)
        New-NetIPAddress -InterfaceAlias $if -IPAddress $ip -PrefixLength 24 -SkipAsSource $true | Out-Null
        Set-DnsClientServerAddress -InterfaceAlias $if -ResetServerAddresses
        Set-DnsClient -InterfaceAlias $if -RegisterThisConnectionsAddress $false
        $idx = (Get-NetAdapter -Name $if).ifIndex
        Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex=$idx" |
            Invoke-CimMethod -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = 2 } | Out-Null
    }
}

function Set-HostsFile {
    # DataCore : une entree pour le serveur DataCore distant uniquement, jamais pour le serveur local
    $hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
    $local = [regex]::Escape($Cfg.Nodes[$Node].Name)
    $lines = @(Get-Content $hosts)
    $keep  = @($lines | Where-Object { $_ -notmatch "^\s*[^#\s]+\s+(.*\s)?$local(\s|$)" })
    if ($keep.Count -ne $lines.Count) { Set-Content -Path $hosts -Value $keep -Encoding ASCII; "hosts : entree du serveur local supprimee" }
    $ip = $Cfg.Nodes[$Peer].MgmtIp
    if (-not $ip) { Write-Warning "IP de $PeerName non renseignee : entree hosts ignoree"; return }
    if (-not (Select-String -Path $hosts -Pattern "\s$([regex]::Escape($PeerName))(\s|$)" -Quiet)) { Add-Content $hosts "$ip`t$PeerName" }
    "hosts : $PeerName -> $ip"
}

function Invoke-Prepare {
    Assert-DataCoreStopped
    Rename-Adapters
    Assert-Mgmt
    Set-StorageNetwork
    Set-HostsFile
    powercfg /setactive SCHEME_MIN
    Set-UpdatePolicy
    Set-Pagefile
    Set-UserDumps
    Show-Resolution
    Write-Warning "Redemarrer $env:COMPUTERNAME avant l'etape suivante (fichier d'echange)"
}

function Set-SkipAsSource([bool]$Value) {
    Get-NetIPAddress -InterfaceAlias $Storage -AddressFamily IPv4 | Set-NetIPAddress -SkipAsSource $Value
    Show-Resolution
}

function Invoke-BestPractice {
    $bp = $Cfg.BestPracticeScript
    if (-not (Test-Path $bp)) { throw "Script DataCore iSCSI Best Practices introuvable : $bp" }
    $match = @(Get-NetAdapter | Where-Object Name -match $Cfg.BestPracticeFilter | ForEach-Object Name | Sort-Object)
    if ($match.Count -eq 0 -or (Compare-Object $match ($Storage | Sort-Object))) {
        throw "Le filtre '$($Cfg.BestPracticeFilter)' selectionne [$($match -join ', ')] au lieu de [$($Storage -join ', ')]"
    }
    Write-Warning "Le script DataCore redemarre $($match -join ', ') : coupure iSCSI sur ces ports"
    if (-not $Force -and (Read-Host 'Aucun vDisk servi et miroir non etabli ? Continuer (o/N)') -ne 'o') {
        Write-Warning 'Best Practices non appliquees'; return
    }
    Unblock-File -Path $bp
    & $bp -adapterIdentifier $Cfg.BestPracticeFilter -Force
}

function Get-PartnerSessions([string]$If) {
    # Sessions de l'initiateur Microsoft local vers le port du partenaire de fonction $If (IQN cible termine par son suffixe)
    $suffix = $Cfg.IqnSuffix[$If]
    @(Get-IscsiSession -ErrorAction SilentlyContinue | Where-Object { $_.TargetNodeAddress -like "*$suffix" })
}

function Remove-ExtraPartnerSessions {
    # Ports de stockage hors InitiatorPorts (les ports front-end) : aucune connexion d'initiateur entre les
    # serveurs DataCore. Retire les sessions, leur persistance et les portails laisses par une version anterieure.
    foreach ($if in ($Storage | Where-Object { $_ -notin $Cfg.InitiatorPorts })) {
        $dst    = Get-PortIp $if $Cfg.DcOct[$Peer]
        $sess   = @(Get-PartnerSessions $if)
        $portal = @(Get-IscsiTargetPortal -ErrorAction SilentlyContinue | Where-Object TargetPortalAddress -eq $dst)
        if ($sess.Count -eq 0 -and $portal.Count -eq 0) { "$if : aucune connexion vers $PeerName (attendu)"; continue }
        Write-Warning "$if : $($sess.Count) session(s) et $($portal.Count) portail(s) vers $PeerName ($dst) : inutiles, le miroir n'utilise que les ports MR"
        if (-not $Force -and (Read-Host "vDisks Up to date et chemins miroir sur les ports MR dans la DMC ? Retirer la connexion $if (o/N)") -ne 'o') {
            Write-Warning "$if : connexion conservee"; continue
        }
        foreach ($s in $sess) {
            if ($s.IsPersistent) { Unregister-IscsiSession -SessionIdentifier $s.SessionIdentifier -ErrorAction SilentlyContinue }
            if ($s.IsConnected)  { Disconnect-IscsiTarget -SessionIdentifier $s.SessionIdentifier -Confirm:$false }
        }
        foreach ($tp in $portal) {
            try {
                if ($tp.InitiatorPortalAddress) {
                    Remove-IscsiTargetPortal -TargetPortalAddress $tp.TargetPortalAddress -InitiatorPortalAddress $tp.InitiatorPortalAddress -Confirm:$false
                } else {
                    Remove-IscsiTargetPortal -TargetPortalAddress $tp.TargetPortalAddress -Confirm:$false
                }
            } catch { Write-Warning "$if : portail $dst non retire ($($_.Exception.Message))" }
        }
        "$if : connexion vers $PeerName retiree"
    }
}

function Connect-PartnerTargets {
    Set-Service -Name MSiSCSI -StartupType Automatic
    Start-Service -Name MSiSCSI
    $failed = 0
    foreach ($if in $Cfg.InitiatorPorts) {
        $src = Get-PortIp $if $Cfg.DcOct[$Node]
        $dst = Get-PortIp $if $Cfg.DcOct[$Peer]
        if (Get-IscsiConnection -ErrorAction SilentlyContinue | Where-Object { $_.InitiatorAddress -eq $src -and $_.TargetAddress -eq $dst }) {
            "$if : $src -> $dst deja connecte"; continue
        }
        $portal = Get-IscsiTargetPortal -ErrorAction SilentlyContinue |
            Where-Object { $_.TargetPortalAddress -eq $dst -and $_.InitiatorPortalAddress -eq $src }
        if (-not $portal) { $portal = New-IscsiTargetPortal -TargetPortalAddress $dst -InitiatorPortalAddress $src }
        $portal | Update-IscsiTargetPortal | Out-Null      # redecouverte : prend en compte un IQN renomme dans la DMC
        $all = @($portal | Get-IscsiTarget | Where-Object { -not $_.IsConnected })
        if ($all.Count -eq 0) { Write-Warning "$if : aucune cible decouverte sur $dst (role du port partenaire ?)"; $failed++; continue }
        # Selection par le suffixe d'IQN pose par la phase Ports (section 5, etape 8)
        $suffix  = $Cfg.IqnSuffix[$if]
        $targets = @($all | Where-Object { $_.NodeAddress -like "*$suffix" })
        if ($targets.Count -eq 0) {
            Write-Warning "$if : aucune cible en '*$suffix' sur $dst (annoncees : $($all.NodeAddress -join ', ')). Lancer la phase Ports (ou renommer l'IQN du port $if de $PeerName dans la DMC), puis relancer la phase"
            $failed++; continue
        }
        $t = $targets[0]
        if ($targets.Count -gt 1) {
            "$if : plusieurs cibles en '*$suffix' annoncees par $dst :"
            for ($i = 0; $i -lt $targets.Count; $i++) { "  [$i] $($targets[$i].NodeAddress)" }
            $t = $targets[[int](Read-Host "Numero de la cible a connecter")]
        }
        Connect-IscsiTarget -NodeAddress $t.NodeAddress -TargetPortalAddress $dst -InitiatorPortalAddress $src -IsPersistent $true | Out-Null
        "$if : $src -> $dst connecte a $($t.NodeAddress)"
    }
    # Une fois les connexions miroir en place seulement : retrait des connexions sur les autres ports (FE)
    if ($failed) { Show-Sessions; throw "$failed port(s) non connecte(s) : voir les avertissements ci-dessus (connexions front-end laissees en l'etat)" }
    Remove-ExtraPartnerSessions
    Show-Sessions
}

function Show-Sessions {
    Get-IscsiSession -ErrorAction SilentlyContinue | Sort-Object TargetNodeAddress |
        Format-Table InitiatorPortalAddress, TargetNodeAddress, IsConnected, IsPersistent -AutoSize
}


# ---------------------------------------------------------------- cmdlets DataCore
function Connect-Dcs {
    # Module DataCore.Executive.Cmdlets du dossier d'installation SANsymphony, connexion locale (compte courant)
    if (-not (Get-Command Connect-DcsServer -ErrorAction SilentlyContinue)) {
        $key  = (Get-Item 'HKLM:\Software\DataCore\Executive' -ErrorAction Stop).GetValue('BaseProductKey')
        $path = (Get-Item "HKLM:\$key").GetValue('InstallPath')
        Import-Module (Join-Path $path 'DataCore.Executive.Cmdlets.dll') -ErrorAction Stop -WarningAction SilentlyContinue
    }
    if (-not (Get-DcsConnection -ErrorAction SilentlyContinue)) { Connect-DcsServer | Out-Null }
}

function Get-DcsNodeServer([int]$n) {
    $name = $Cfg.Nodes[$n].Name
    $s = @(Get-DcsServer | Where-Object { $_.Caption -ieq $name -or $_.HostName -ieq $name -or $_.HostName -like "$name.*" })
    if ($s.Count -ne 1) { throw "Serveur DataCore $name introuvable dans le Server Group (Get-DcsServer)" }
    $s[0]
}

function Get-PortAlias([object]$Srv, [string]$If, [int]$n) {
    if ($If -eq 'MGMT') { return "$($Srv.Caption) MGMT" }
    '{0} {1} {2}' -f $Srv.Caption, ($If -replace '^DC-', ''), (Get-PortIp $If $Cfg.DcOct[$n])
}

function Set-DcsPorts {
    # Roles, noms et IQN des ports iSCSI des 2 serveurs, identifies par leur MAC fixe
    # (02-DC-00-0N-00-0i, datacore-xcp.sh dcvm). Un changement de role ou d'IQN reinitialise le port.
    Connect-Dcs
    if (@(Get-DcsVirtualDisk -ErrorAction SilentlyContinue).Count) {
        throw 'Des vDisks existent : roles et IQN se posent uniquement avant la creation de tout vDisk (section 5.3, etape 8)'
    }
    $sessions = @(Get-IscsiSession -ErrorAction SilentlyContinue)
    foreach ($n in 1, 2) {
        $srv = Get-DcsNodeServer $n
        if ("$($srv.State)" -ne 'Online') { throw "$($srv.Caption) : etat $($srv.State), attendu Online (serveur DataCore demarre)" }
        $ports = @(Get-DcsPort -Machine $srv.Id -Type iSCSI)
        for ($i = 0; $i -lt $ByIndex.Count; $i++) {
            $if  = $ByIndex[$i]
            $mac = '02-DC-00-{0:X2}-00-{1:X2}' -f $n, $i
            $p   = @($ports | Where-Object PhysicalName -eq "MAC:$mac")
            if ($p.Count -ne 1) {
                if ($if -eq 'MGMT') { Write-Warning "$($srv.Caption) : pas de port iSCSI sur MGMT ($mac), rien a faire"; continue }
                throw "$($srv.Caption) : aucun port iSCSI de MAC $mac ($if). Faire un Refresh des ports dans la DMC"
            }
            $p    = $p[0]
            $role = switch -Wildcard ($if) { 'DC-FE*' { 'Frontend' } 'DC-MR*' { 'Mirror' } default { 'None' } }
            $set  = @{}
            $cur  = "$($p.ServerPortProperties.Role)"; if (-not $cur) { $cur = 'None' }
            if ($cur -ne $role) { $set.PortRole = $role }
            if ($if -ne 'MGMT') {
                # iqn.2000-08.com.datacore:dc-01-01 -> iqn.2000-08.com.datacore:dc-01-fe1
                $iqn = ($p.PortName -replace '-[a-z0-9]+$', ('-' + $Cfg.IqnSuffix[$if])).ToLower()
                if ($iqn -ne $p.PortName) {
                    if ($sessions.Count -and -not $Force) { throw "Sessions de l'initiateur Microsoft ouvertes : IQN de $if non modifie (phase Initiator deja passee). -Force pour passer outre" }
                    $set.NodeName = $iqn
                }
            }
            if ($set.Count) {
                Set-DcsServerPortProperties -Server $srv.Id -Port $p.Id @set | Out-Null
                '{0} {1} : {2} applique (reinitialisation du port)' -f $srv.Caption, $if, (($set.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')
            } else { '{0} {1} : role et IQN deja corrects' -f $srv.Caption, $if }
            $alias = Get-PortAlias $srv $if $n
            if ($p.Alias -ne $alias) { Set-DcsPortProperties -Machine $srv.Id -Port $p.Id -NewName $alias | Out-Null }
        }
        $ini = @($ports | Where-Object { "$($_.PortMode)" -eq 'Initiator' -and $_.PhysicalName -like 'MSFT*' })
        foreach ($p in $ini) {
            $alias = "$($srv.Caption) Initiateur"
            if ($p.Alias -ne $alias) { Set-DcsPortProperties -Machine $srv.Id -Port $p.Id -NewName $alias | Out-Null }
        }
    }
    Show-DcsPorts
}

function Show-DcsPorts {
    foreach ($n in 1, 2) {
        $srv = Get-DcsNodeServer $n
        Get-DcsPort -Machine $srv.Id -Type iSCSI | Sort-Object Alias |
            Format-Table Alias, PortName, PhysicalName, PortMode, @{ n = 'Role'; e = { "$($_.ServerPortProperties.Role)" } } -AutoSize
    }
}

function Register-XcpHosts {
    # Hotes XCP-ng (type Citrix XenServer, MPIO, ALUA, Preferred Server = VM DataCore locale), IQN du dom0,
    # puis service des vDisks miroirs sur FE1 et FE2 des 2 serveurs (4 chemins par hote)
    Connect-Dcs
    foreach ($k in 'Hosts', 'VirtualDisks') { if (-not $Cfg.ContainsKey($k)) { throw "Variable $k absente de $ConfigFile (phase Hosts)" } }
    $vds = foreach ($name in $Cfg.VirtualDisks) {
        $vd = @(Get-DcsVirtualDisk -VirtualDisk $name -ErrorAction SilentlyContinue)
        if ($vd.Count -ne 1) { throw "vDisk '$name' introuvable ou ambigu : le creer d'abord dans la DMC (section 6, etape 5)" }
        if ("$($vd[0].Type)" -ne 'MultiPathMirrored') { throw "vDisk '$name' non miroir (type $($vd[0].Type))" }
        # DataCore : un vDisk n'est servi la premiere fois que s'il est Online et a jour
        if ("$($vd[0].DiskStatus)" -ne 'Online') { throw "vDisk '$name' : etat $($vd[0].DiskStatus), attendu Online (Up to date)" }
        $vd[0]
    }
    # Ports initiateurs affectes et non affectes (un initiateur pas encore rattache a un hote est 'unassigned')
    $initiators = @(@(Get-DcsPort -Type iSCSI) + @(Get-DcsPort -Type iSCSI -Unassigned) | Where-Object { "$($_.PortMode)" -eq 'Initiator' })
    foreach ($n in 1, 2) {
        $h = $Cfg.Hosts[$n]; $iqn = "$($h.Iqn)".ToLower()
        if (-not $h.Name -or -not $iqn) { throw "Hosts[$n] incomplet dans $ConfigFile (Name et Iqn)" }
        $pref = Get-DcsNodeServer $n
        # Ordre valide : la DMC ne connait l'initiateur qu'apres une session du dom0 (section 6, etape 6)
        $port = @($initiators | Where-Object PortName -eq $iqn)
        if (-not $port) {
            throw "Initiateur $iqn ($($h.Name)) inconnu de la DMC : './datacore-xcp.sh iscsi' sur $($h.Name), puis Refresh des ports iSCSI des 2 serveurs dans la DMC"
        }
        $cli = @(Get-DcsClient | Where-Object HostName -eq $h.Name)
        if (-not $cli) {
            $cli = Add-DcsClient -Name $h.Name -ClientType CitrixXenServer -PreferredServer $pref.Id -Multipath $true -ALUA $true
            "$($h.Name) : hote cree (Citrix XenServer, Multipathing, ALUA, Preferred Server $($pref.Caption))"
        } else {
            $cli = $cli[0]
            if ("$($cli.Type)" -ne 'CitrixXenServer' -or -not $cli.MpioCapable -or -not $cli.AluaSupport -or "$($cli.PreferredServerId)" -ne "$($pref.Id)") {
                $cli = Set-DcsClientProperties -Client $cli.Id -ClientType CitrixXenServer -PreferredServer $pref.Id -Multipath $true -ALUA $true
                "$($h.Name) : hote corrige (Citrix XenServer, Multipathing, ALUA, Preferred Server $($pref.Caption))"
            } else { "$($h.Name) : hote deja correct" }
        }
        if (-not $port[0].HostId) {
            Register-DcsClientPort -Port $iqn -Client $cli.Id | Out-Null
            "$($h.Name) : initiateur $iqn affecte"
        } elseif ("$($port[0].HostId)" -ne "$($cli.Id)") {
            throw "Initiateur $iqn deja affecte a un autre hote dans la DMC"
        }
        $served = @(Get-DcsVirtualDisk -Machine $cli.Id -ErrorAction SilentlyContinue | ForEach-Object Id)
        foreach ($vd in $vds) {
            if ($served -contains $vd.Id) { "$($h.Name) : $($vd.Alias) deja servi"; continue }
            $paths = @(Serve-DcsVirtualDisk -Machine $cli.Id -VirtualDisk $vd.Id -EnableRedundancy)
            "$($h.Name) : $($vd.Alias) servi, $($paths.Count) chemin(s) cree(s) (4 attendus : FE1 et FE2 de chaque serveur)"
            if ($paths.Count -ne 4) { Write-Warning "$($vd.Alias) -> $($h.Name) : $($paths.Count) chemin(s) au lieu de 4, verifier les mappings dans la DMC" }
        }
    }
    ''
    'Ensuite, sur chaque hote XCP-ng : ./datacore-xcp.sh iscsi (4 chemins par LUN attendus). SCSIid pour le master :'
    foreach ($vd in $vds) { '  {0,-20} 3{1}' -f $vd.Alias, "$($vd.ScsiDeviceIdString)".ToLower() }
}

function Show-DcsState {
    # Etat DataCore vu par les cmdlets (ignore si le service Executive ne tourne pas)
    try { Connect-Dcs } catch { "Cmdlets DataCore indisponibles : $($_.Exception.Message)"; return }
    Get-DcsServer | Format-Table Caption, State, CacheState, CacheSize, TotalSystemMemory -AutoSize
    Show-DcsPorts
    Get-DcsClient | Format-Table HostName, Type, MpioCapable, AluaSupport,
        @{ n = 'PreferredServer'; e = { $id = "$($_.PreferredServerId)"; (Get-DcsServer | Where-Object { "$($_.Id)" -eq $id }).Caption } } -AutoSize
    Get-DcsVirtualDisk | Format-Table Alias, Type, DiskStatus, Size, IsServed, @{ n = 'SCSIid'; e = { '3' + "$($_.ScsiDeviceIdString)".ToLower() } } -AutoSize
}

# ---------------------------------------------------------------- correctifs Windows
function Get-ExecutiveService {
    $s = @(Get-Service -ErrorAction SilentlyContinue | Where-Object DisplayName -like 'DataCore Executive*')
    if ($s.Count -ne 1) { throw 'Service DataCore Executive introuvable' }
    $s[0]
}

function Invoke-PrePatch {
    # DataCore : serveur DataCore arrete dans la DMC, puis service Executive arrete et passe en Manuel
    Connect-Dcs
    $srv = Get-DcsNodeServer $Node
    if ("$($srv.State)" -ne 'Offline') { throw "$($srv.Caption) : etat $($srv.State). Faire d'abord 'Stop DataCore Server' dans la DMC (HA desactivee, section 9)" }
    $svc = Get-ExecutiveService
    $reg = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.Name)"
    $type = if ($reg.DelayedAutostart -eq 1) { 'delayed-auto' } else { 'auto' }
    Set-Content -Path $StartTypeFile -Value $type -Encoding ASCII
    Set-Service -Name $svc.Name -StartupType Manual
    Stop-Service -Name $svc.Name -Force
    "$($svc.DisplayName) : arrete, demarrage Manuel (type precedent '$type' sauve)"
    'Ensuite : Windows Update, redemarrage meme s''il n''est pas demande, nouvelle recherche de mises a jour, puis -Phase PostPatch'
}

function Invoke-PostPatch {
    $svc  = Get-ExecutiveService
    $type = if (Test-Path $StartTypeFile) { (Get-Content $StartTypeFile -TotalCount 1).Trim() } else { 'auto' }
    sc.exe config $svc.Name start= $type | Out-Null
    if ($LASTEXITCODE) { throw "sc.exe config $($svc.Name) start= $type en echec" }
    Start-Service -Name $svc.Name
    Remove-Item $StartTypeFile -ErrorAction SilentlyContinue
    "$($svc.DisplayName) : demarre, demarrage $type"
    'Ensuite : demarrer le serveur DataCore dans la DMC s''il est arrete, attendre Up to date, puis ./datacore-xcp.sh ha-on'
}

function Test-Node {
    foreach ($if in $Storage) {
        $src  = Get-PortIp $if $Cfg.DcOct[$Node]
        $dsts = @(@{ Ip = Get-PortIp $if $Cfg.DcOct[$Peer]; What = $PeerName })
        if ($if -like 'DC-FE*') { foreach ($h in 1,2) { $dsts += @{ Ip = Get-PortIp $if $Cfg.HostOct[$h]; What = "dom0 $h" } } }
        foreach ($d in $dsts) {
            $out = ping.exe -n 2 -f -l ($Cfg.Mtu - 28) -S $src $d.Ip
            $ok  = ($LASTEXITCODE -eq 0) -and ($out -match 'TTL=')
            '{0,-7} {1,-14} {2,-10} MTU {3} : {4}' -f $if, $d.Ip, $d.What, $Cfg.Mtu, $(if ($ok) { 'OK' } else { 'ECHEC' })
        }
    }
    Get-NetAdapter -Name $ByIndex | Format-Table Name, Status, LinkSpeed, MacAddress -AutoSize
    "Sessions de l'initiateur Microsoft (attendu : $($Cfg.InitiatorPorts.Count), une par port de InitiatorPorts : $($Cfg.InitiatorPorts -join ', ')) :"
    Show-Sessions
    foreach ($if in ($Storage | Where-Object { $_ -notin $Cfg.InitiatorPorts })) {
        if (@(Get-PartnerSessions $if).Count) { Write-Warning "$if : session de l'initiateur vers $PeerName (inutile : le miroir n'utilise que les ports MR). Relancer -Phase Initiator pour la retirer" }
    }
    "Fichier d'echange (attendu : C:\pagefile.sys, $($Cfg.PagefileSizeMB) Mo fixe, gestion automatique desactivee) :"
    "  gestion automatique : $((Get-CimInstance Win32_ComputerSystem).AutomaticManagedPagefile)"
    Get-CimInstance Win32_PageFileSetting | Format-Table Name, InitialSize, MaximumSize -AutoSize
    Get-CimInstance Win32_PageFileUsage | Format-Table Name, AllocatedBaseSize -AutoSize
    w32tm /query /status | Select-String 'Source|Stratum'
    Get-ItemProperty -Path $AuKey -ErrorAction SilentlyContinue | Format-List AUOptions, NoAutoRebootWithLoggedOnUsers
    "Pilotes par Windows Update exclus (attendu 1) : $((Get-ItemProperty -Path $WuKey -ErrorAction SilentlyContinue).ExcludeWUDriversInQualityUpdate)"
    "Dumps en mode utilisateur DumpType (attendu 2) : $((Get-ItemProperty -Path $DumpKey -ErrorAction SilentlyContinue).DumpType)"
    "Dump noyau CrashDumpEnabled (attendu 2, pose par l'installeur SANsymphony) : $((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl').CrashDumpEnabled)"
    $cpu = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    $min = if ($Cfg.ContainsKey('MinVcpu')) { $Cfg.MinVcpu } else { 10 }
    "vCPU : $cpu (minimum DataCore pour cette architecture : $min)"
    if ($cpu -lt $min) { Write-Warning "vCPU sous $min : DC_VCPU dans datacore-xcp.conf (4 + 3 par paire de ports iSCSI)" }
    $local = [regex]::Escape($env:COMPUTERNAME)
    if (Select-String -Path "$env:SystemRoot\System32\drivers\etc\hosts" -Pattern "^\s*[^#\s]+\s+(.*\s)?$local(\s|$)" -Quiet) {
        Write-Warning 'Fichier hosts : entree presente pour le serveur local (DataCore : serveurs distants uniquement)'
    }
    Show-DcsState
}

function Invoke-Phase([string]$Name) {
    switch ($Name) {
        'Prepare'     { Invoke-Prepare }
        'Ports'       { Set-DcsPorts }
        'PostInstall' { Set-SkipAsSource $false; Invoke-BestPractice }   # SkipAsSource retire : sinon choix d'IP source imprevisible
        'Initiator'   { Connect-PartnerTargets }
        'Hosts'       { Register-XcpHosts }
        'Test'        { Test-Node }
        'PreUpgrade'  { Set-SkipAsSource $true }    # l'assistant de mise a jour retrouve la resolution de l'installation
        'PostUpgrade' { Set-SkipAsSource $false }   # Best Practices non rejouees : elles survivent aux mises a jour
        'PrePatch'    { Invoke-PrePatch }
        'PostPatch'   { Invoke-PostPatch }
    }
}

# ---------------------------------------------------------------- menu
$Menu = [ordered]@{
    '1'  = 'Prepare',     'Cartes, IP de stockage, systeme (avant installation SANsymphony, puis redemarrage)'
    '2'  = 'Ports',       'Roles, noms, IQN des ports des 2 serveurs (une fois, avant tout vDisk)'
    '3'  = 'PostInstall', 'Best Practices iSCSI DataCore (apres la phase Ports, avant tout vDisk)'
    '4'  = 'Initiator',   'Connexions iSCSI vers le partenaire, liens miroir uniquement (apres PostInstall des 2 cotes)'
    '5'  = 'Hosts',       'Hotes XCP-ng et service des vDisks (une fois, apres iscsi sur les dom0)'
    '6'  = 'Test',        'Controles reseau, sessions iSCSI, reglages systeme, etat DataCore'
    '7'  = 'PreUpgrade',  'Avant une mise a jour SANsymphony'
    '8'  = 'PostUpgrade', 'Apres une mise a jour SANsymphony'
    '9'  = 'PrePatch',    'Avant Windows Update (serveur DataCore arrete dans la DMC)'
    '10' = 'PostPatch',   'Apres Windows Update et redemarrage'
}

function Show-Menu {
    $svc   = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'DataCore*' })
    $state = if (-not $svc) { 'absents' } elseif ($svc | Where-Object Status -eq 'Running') { 'actifs' } else { 'arretes' }
    ''
    "=== Set-DataCoreNode.ps1 - $env:COMPUTERNAME : noeud $Node (partenaire $PeerName), services DataCore $state ==="
    foreach ($k in $Menu.Keys) { ' {0,2}) {1,-12} {2}' -f $k, $Menu[$k][0], $Menu[$k][1] }
    '  q) quitter'
}

if ($Phase) { Invoke-Phase $Phase; return }

while ($true) {
    Show-Menu | Out-Host
    $c = Read-Host 'Choix'
    if ($c -eq 'q') { break }
    if (-not $Menu.Contains($c)) { Write-Host 'Choix invalide'; continue }
    $p = $Menu[$c][0]
    Write-Host "--> .\Set-DataCoreNode.ps1 -Node $Node -Phase $p" -ForegroundColor Cyan
    # Une erreur (throw) interrompt la phase, pas le menu
    try   { Invoke-Phase $p | Out-Host }
    catch { Write-Host "ERREUR : $($_.Exception.Message)" -ForegroundColor Red }
    Read-Host 'Entree pour revenir au menu' | Out-Null
}
