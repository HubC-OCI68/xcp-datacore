#Requires -RunAsAdministrator
<#
  Set-DataCoreNode.ps1 - Network, system and iSCSI setup of a SANsymphony server (XCP-ng VM)
  Variables: DataCoreNode.psd1 (same folder, or -ConfigFile). No value to edit here.

  .\Set-DataCoreNode.ps1                             # interactive menu (node detected, to be confirmed)
  .\Set-DataCoreNode.ps1 -Phase Test                 # -Node omitted: node detected, to be confirmed

  .\Set-DataCoreNode.ps1 -Node 1 -Phase Prepare      # before SANsymphony installation (then reboot)
  .\Set-DataCoreNode.ps1 -Node 1 -Phase Ports        # once, after installation: roles, names, IQNs of the ports of BOTH servers
  .\Set-DataCoreNode.ps1 -Node 1 -Phase PostInstall  # after the Ports phase, BEFORE any vDisk is served
  .\Set-DataCoreNode.ps1 -Node 1 -Phase Initiator    # after PostInstall on both servers: mirror links (MR) only
  .\Set-DataCoreNode.ps1 -Node 1 -Phase Hosts        # once, after 'iscsi' on the dom0s: XCP-ng hosts, serving of the vDisks
  .\Set-DataCoreNode.ps1 -Node 1 -Phase Test
  .\Set-DataCoreNode.ps1 -Node 1 -Phase PreUpgrade   # before a SANsymphony update (PSP)
  .\Set-DataCoreNode.ps1 -Node 1 -Phase PostUpgrade  # after a SANsymphony update (PSP)
  .\Set-DataCoreNode.ps1 -Node 1 -Phase PrePatch     # before Windows Update, after 'Stop DataCore Server'
  .\Set-DataCoreNode.ps1 -Node 1 -Phase PostPatch    # after Windows Update and reboot
#>
param(
    [ValidateSet(1,2)][int]$Node,
    [ValidateSet('Prepare','Ports','PostInstall','Initiator','Hosts','Test','PreUpgrade','PostUpgrade','PrePatch','PostPatch')][string]$Phase,
    [string]$ConfigFile = (Join-Path $PSScriptRoot 'DataCoreNode.psd1'),
    [switch]$Force
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ConfigFile)) { throw "Variables file not found: $ConfigFile" }
$Cfg = Import-PowerShellDataFile -Path $ConfigFile
foreach ($k in 'Nodes','Subnets','DcOct','HostOct','Mtu','Metric','BestPracticeScript','BestPracticeFilter','InitiatorPorts','IqnSuffix','PagefileSizeMB') {
    if (-not $Cfg.ContainsKey($k)) { throw "Variable $k missing from $ConfigFile" }
}
$ByIndex = @('MGMT','DC-FE1','DC-FE2','DC-MR1','DC-MR2')   # VIF index = last octet of the MAC
$Storage = @('DC-FE1','DC-FE2','DC-MR1','DC-MR2')
$WuKey   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$AuKey   = "$WuKey\AU"
$DumpKey = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps'
$StartTypeFile = Join-Path $PSScriptRoot 'DcsExecutive-StartType.txt'   # start type saved by PrePatch

function Resolve-Node {
    # Detection by the MGMT adapter MAC (02-DC-00-0N-00-00, datacore-xcp.sh dcvm) and by the Windows name
    $byMac  = @(Get-NetAdapter | ForEach-Object { if ($_.MacAddress -match '^02-DC-00-0([12])-00-00$') { [int]$Matches[1] } })
    $byName = @(1, 2 | Where-Object { $Cfg.Nodes[$_].Name -ieq $env:COMPUTERNAME })
    $guess  = @($byMac + $byName | Sort-Object -Unique)
    if ($Node) {
        if ($guess.Count -eq 1 -and $guess[0] -ne $Node) { Write-Warning "-Node $Node, but the MGMT MAC or the name point to node $($guess[0])" }
        return $Node
    }
    if ($guess.Count -gt 1) { Write-Warning "Conflicting detection: MGMT MAC -> node $($byMac -join ','), name -> node $($byName -join ',')" }
    $def  = if ($guess.Count -eq 1) { $guess[0] } else { 0 }
    $hint = if ($def) { " [Enter = $def]" } else { '' }
    while ($true) {
        $r = Read-Host ('Node (1 = {0}, 2 = {1}){2}' -f $Cfg.Nodes[1].Name, $Cfg.Nodes[2].Name, $hint)
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
    "Resolution of $env:COMPUTERNAME (expected: management IP only):"
    [System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) | ForEach-Object IPAddressToString
    Get-NetIPAddress -InterfaceAlias $Storage -AddressFamily IPv4 |
        Format-Table InterfaceAlias, IPAddress, SkipAsSource -AutoSize
}

function Assert-DataCoreStopped {
    # Prepare recreates the storage IPs: forbidden while SANsymphony serves vDisks
    $svc = Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'DataCore*' -and $_.Status -eq 'Running' }
    if ($svc) { throw "DataCore services running ($($svc.DisplayName -join ', ')): Prepare phase forbidden" }
}

function Rename-Adapters {
    # Renaming by fixed MAC 02:dc:00:0N:00:0i (datacore-xcp.sh dcvm), in 2 passes to
    # fix an adapter already renamed wrongly (e.g. an FE adapter manually named MGMT)
    $nics = @{}
    for ($i = 0; $i -lt $ByIndex.Count; $i++) {
        $nic = Get-NetAdapter | Where-Object MacAddress -eq (Get-Mac $i)
        if (-not $nic) { throw "No adapter with MAC $(Get-Mac $i) (VIF $i, $($ByIndex[$i]))" }
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
    if (-not $want) { throw "MgmtIp of node $Node not set in $ConfigFile" }
    $have = @(Get-NetIPAddress -InterfaceAlias MGMT -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    if ($have -notcontains $want) {
        $wrong = Get-NetIPAddress -IPAddress $want -ErrorAction SilentlyContinue
        if ($wrong) { throw "IP $want is set on $($wrong.InterfaceAlias), not on MGMT (MAC $(Get-Mac 0)): move it (section 5, step 3)" }
        throw "MGMT (MAC $(Get-Mac 0)) does not have IP $want (current: $($have -join ', ')): section 5, step 3"
    }
    "MGMT: $want (MAC $(Get-Mac 0)) OK"
}

function Set-UpdatePolicy {
    # No automatic reboot: the 2 servers must never reboot at the same time
    if (-not (Test-Path $AuKey)) { New-Item -Path $AuKey -Force | Out-Null }
    Set-ItemProperty -Path $AuKey -Name AUOptions -Value 2 -Type DWord                      # notify before download
    Set-ItemProperty -Path $AuKey -Name NoAutoRebootWithLoggedOnUsers -Value 1 -Type DWord
    # DataCore: no third-party drivers through Windows Update (HBA, NIC)
    Set-ItemProperty -Path $WuKey -Name ExcludeWUDriversInQualityUpdate -Value 1 -Type DWord
    Write-Warning "A domain GPO can override this setting: check with gpresult /h"
}

function Set-Pagefile {
    # Fixed size on C: only (initial = maximum), automatic management disabled
    $size = [uint32]$Cfg.PagefileSizeMB
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.AutomaticManagedPagefile) { $cs | Set-CimInstance -Property @{ AutomaticManagedPagefile = $false } }
    Get-CimInstance Win32_PageFileSetting | Where-Object Name -ine 'C:\pagefile.sys' | Remove-CimInstance
    $pf = Get-CimInstance Win32_PageFileSetting | Where-Object Name -ieq 'C:\pagefile.sys'
    if (-not $pf) { $pf = New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = 'C:\pagefile.sys' } }
    $pf | Set-CimInstance -Property @{ InitialSize = $size; MaximumSize = $size }
    "Page file: C:\pagefile.sys fixed at $size MB (effective at reboot)"
}

function Set-UserDumps {
    # DataCore: user-mode dumps (DMC and console crashes), full dump
    if (-not (Test-Path $DumpKey)) { New-Item -Path $DumpKey -Force | Out-Null }
    Set-ItemProperty -Path $DumpKey -Name DumpType -Value 2 -Type DWord
    "User-mode dumps: LocalDumps\DumpType = 2"
}

function Set-StorageNetwork {
    foreach ($if in $Storage) {
        $ip = Get-PortIp $if $Cfg.DcOct[$Node]
        try {
            if (Get-NetAdapterAdvancedProperty -Name $if -RegistryKeyword '*JumboPacket' -ErrorAction SilentlyContinue) {
                Set-NetAdapterAdvancedProperty -Name $if -RegistryKeyword '*JumboPacket' -RegistryValue ($Cfg.Mtu + 14) -NoRestart
            }
        } catch { Write-Warning "${if}: *JumboPacket cannot be changed ($($_.Exception.Message)); IP MTU set to $($Cfg.Mtu) below" }
        foreach ($b in 'ms_msclient','ms_server','ms_tcpip6','ms_lldp','ms_lltdio','ms_rspndr','ms_pacer') {
            Disable-NetAdapterBinding -Name $if -ComponentID $b -ErrorAction SilentlyContinue
        }
        Get-NetIPAddress -InterfaceAlias $if -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false
        Remove-NetRoute -InterfaceAlias $if -Confirm:$false -ErrorAction SilentlyContinue
        Set-NetIPInterface -InterfaceAlias $if -AddressFamily IPv4 -Dhcp Disabled -NlMtuBytes $Cfg.Mtu -InterfaceMetric $Cfg.Metric[$if]
        # SkipAsSource: the server name must not resolve to the storage IPs (DataCore wizard)
        New-NetIPAddress -InterfaceAlias $if -IPAddress $ip -PrefixLength 24 -SkipAsSource $true | Out-Null
        Set-DnsClientServerAddress -InterfaceAlias $if -ResetServerAddresses
        Set-DnsClient -InterfaceAlias $if -RegisterThisConnectionsAddress $false
        $idx = (Get-NetAdapter -Name $if).ifIndex
        Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex=$idx" |
            Invoke-CimMethod -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = 2 } | Out-Null
    }
}

function Set-HostsFile {
    # DataCore: an entry for the remote DataCore Server only, never for the local server
    $hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
    $local = [regex]::Escape($Cfg.Nodes[$Node].Name)
    $lines = @(Get-Content $hosts)
    $keep  = @($lines | Where-Object { $_ -notmatch "^\s*[^#\s]+\s+(.*\s)?$local(\s|$)" })
    if ($keep.Count -ne $lines.Count) { Set-Content -Path $hosts -Value $keep -Encoding ASCII; "hosts: entry of the local server removed" }
    $ip = $Cfg.Nodes[$Peer].MgmtIp
    if (-not $ip) { Write-Warning "IP of $PeerName not set: hosts entry skipped"; return }
    if (-not (Select-String -Path $hosts -Pattern "\s$([regex]::Escape($PeerName))(\s|$)" -Quiet)) { Add-Content $hosts "$ip`t$PeerName" }
    "hosts: $PeerName -> $ip"
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
    Write-Warning "Reboot $env:COMPUTERNAME before the next step (page file)"
}

function Set-SkipAsSource([bool]$Value) {
    Get-NetIPAddress -InterfaceAlias $Storage -AddressFamily IPv4 | Set-NetIPAddress -SkipAsSource $Value
    Show-Resolution
}

function Invoke-BestPractice {
    $bp = $Cfg.BestPracticeScript
    if (-not (Test-Path $bp)) { throw "DataCore iSCSI Best Practices script not found: $bp" }
    $match = @(Get-NetAdapter | Where-Object Name -match $Cfg.BestPracticeFilter | ForEach-Object Name | Sort-Object)
    if ($match.Count -eq 0 -or (Compare-Object $match ($Storage | Sort-Object))) {
        throw "Filter '$($Cfg.BestPracticeFilter)' selects [$($match -join ', ')] instead of [$($Storage -join ', ')]"
    }
    Write-Warning "The DataCore script restarts $($match -join ', '): iSCSI outage on these ports"
    if (-not $Force -and (Read-Host 'No vDisk served and mirror not established? Continue (y/N)') -ne 'y') {
        Write-Warning 'Best Practices not applied'; return
    }
    Unblock-File -Path $bp
    & $bp -adapterIdentifier $Cfg.BestPracticeFilter -Force
}

function Get-PartnerSessions([string]$If) {
    # Sessions of the local Microsoft initiator to the partner port of function $If (target IQN ending with its suffix)
    $suffix = $Cfg.IqnSuffix[$If]
    @(Get-IscsiSession -ErrorAction SilentlyContinue | Where-Object { $_.TargetNodeAddress -like "*$suffix" })
}

function Remove-ExtraPartnerSessions {
    # Storage ports outside InitiatorPorts (the front-end ports): no initiator connection between the
    # DataCore servers. Removes the sessions, their persistence and the portals left by an earlier version.
    foreach ($if in ($Storage | Where-Object { $_ -notin $Cfg.InitiatorPorts })) {
        $dst    = Get-PortIp $if $Cfg.DcOct[$Peer]
        $sess   = @(Get-PartnerSessions $if)
        $portal = @(Get-IscsiTargetPortal -ErrorAction SilentlyContinue | Where-Object TargetPortalAddress -eq $dst)
        if ($sess.Count -eq 0 -and $portal.Count -eq 0) { "${if}: no connection to $PeerName (expected)"; continue }
        Write-Warning "${if}: $($sess.Count) session(s) and $($portal.Count) portal(s) to $PeerName ($dst): not needed, the mirror only uses the MR ports"
        if (-not $Force -and (Read-Host "vDisks Up to date and mirror paths on the MR ports in the DMC? Remove the $if connection (y/N)") -ne 'y') {
            Write-Warning "${if}: connection kept"; continue
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
            } catch { Write-Warning "${if}: portal $dst not removed ($($_.Exception.Message))" }
        }
        "${if}: connection to $PeerName removed"
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
            "${if}: $src -> $dst already connected"; continue
        }
        $portal = Get-IscsiTargetPortal -ErrorAction SilentlyContinue |
            Where-Object { $_.TargetPortalAddress -eq $dst -and $_.InitiatorPortalAddress -eq $src }
        if (-not $portal) { $portal = New-IscsiTargetPortal -TargetPortalAddress $dst -InitiatorPortalAddress $src }
        $portal | Update-IscsiTargetPortal | Out-Null      # rediscovery: picks up an IQN renamed in the DMC
        $all = @($portal | Get-IscsiTarget | Where-Object { -not $_.IsConnected })
        if ($all.Count -eq 0) { Write-Warning "${if}: no target discovered on $dst (partner port role?)"; $failed++; continue }
        # Selection by the IQN suffix set by the Ports phase (section 5, step 8)
        $suffix  = $Cfg.IqnSuffix[$if]
        $targets = @($all | Where-Object { $_.NodeAddress -like "*$suffix" })
        if ($targets.Count -eq 0) {
            Write-Warning "${if}: no '*$suffix' target on $dst (advertised: $($all.NodeAddress -join ', ')). Run the Ports phase (or rename the IQN of port $if of $PeerName in the DMC), then rerun the phase"
            $failed++; continue
        }
        $t = $targets[0]
        if ($targets.Count -gt 1) {
            "${if}: several '*$suffix' targets advertised by ${dst}:"
            for ($i = 0; $i -lt $targets.Count; $i++) { "  [$i] $($targets[$i].NodeAddress)" }
            $t = $targets[[int](Read-Host "Number of the target to connect")]
        }
        Connect-IscsiTarget -NodeAddress $t.NodeAddress -TargetPortalAddress $dst -InitiatorPortalAddress $src -IsPersistent $true | Out-Null
        "${if}: $src -> $dst connected to $($t.NodeAddress)"
    }
    # Only once the mirror connections are in place: removal of the connections on the other ports (FE)
    if ($failed) { Show-Sessions; throw "$failed port(s) not connected: see the warnings above (front-end connections left untouched)" }
    Remove-ExtraPartnerSessions
    Show-Sessions
}

function Show-Sessions {
    Get-IscsiSession -ErrorAction SilentlyContinue | Sort-Object TargetNodeAddress |
        Format-Table InitiatorPortalAddress, TargetNodeAddress, IsConnected, IsPersistent -AutoSize
}


# ---------------------------------------------------------------- DataCore cmdlets
function Connect-Dcs {
    # DataCore.Executive.Cmdlets module from the SANsymphony installation folder, local connection (current account)
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
    if ($s.Count -ne 1) { throw "DataCore Server $name not found in the server group (Get-DcsServer)" }
    $s[0]
}

function Get-PortAlias([object]$Srv, [string]$If, [int]$n) {
    if ($If -eq 'MGMT') { return "$($Srv.Caption) MGMT" }
    '{0} {1} {2}' -f $Srv.Caption, ($If -replace '^DC-', ''), (Get-PortIp $If $Cfg.DcOct[$n])
}

function Set-DcsPorts {
    # Roles, names and IQNs of the iSCSI ports of BOTH servers, identified by their fixed MAC
    # (02-DC-00-0N-00-0i, datacore-xcp.sh dcvm). A role or IQN change resets the port.
    Connect-Dcs
    if (@(Get-DcsVirtualDisk -ErrorAction SilentlyContinue).Count) {
        throw 'Virtual disks exist: roles and IQNs are only set before any vDisk is created (section 5.3, step 8)'
    }
    $sessions = @(Get-IscsiSession -ErrorAction SilentlyContinue)
    foreach ($n in 1, 2) {
        $srv = Get-DcsNodeServer $n
        if ("$($srv.State)" -ne 'Online') { throw "$($srv.Caption): state $($srv.State), expected Online (DataCore Server started)" }
        $ports = @(Get-DcsPort -Machine $srv.Id -Type iSCSI)
        for ($i = 0; $i -lt $ByIndex.Count; $i++) {
            $if  = $ByIndex[$i]
            $mac = '02-DC-00-{0:X2}-00-{1:X2}' -f $n, $i
            $p   = @($ports | Where-Object PhysicalName -eq "MAC:$mac")
            if ($p.Count -ne 1) {
                if ($if -eq 'MGMT') { Write-Warning "$($srv.Caption): no iSCSI port on MGMT ($mac), nothing to do"; continue }
                throw "$($srv.Caption): no iSCSI port with MAC $mac ($if). Refresh the ports in the DMC"
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
                    if ($sessions.Count -and -not $Force) { throw "Microsoft initiator sessions open: IQN of $if not changed (Initiator phase already run). -Force to override" }
                    $set.NodeName = $iqn
                }
            }
            if ($set.Count) {
                Set-DcsServerPortProperties -Server $srv.Id -Port $p.Id @set | Out-Null
                '{0} {1}: {2} applied (port reset)' -f $srv.Caption, $if, (($set.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')
            } else { '{0} {1}: role and IQN already correct' -f $srv.Caption, $if }
            $alias = Get-PortAlias $srv $if $n
            if ($p.Alias -ne $alias) { Set-DcsPortProperties -Machine $srv.Id -Port $p.Id -NewName $alias | Out-Null }
        }
        $ini = @($ports | Where-Object { "$($_.PortMode)" -eq 'Initiator' -and $_.PhysicalName -like 'MSFT*' })
        foreach ($p in $ini) {
            $alias = "$($srv.Caption) Initiator"
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
    # XCP-ng hosts (type Citrix XenServer, MPIO, ALUA, Preferred Server = local DataCore VM), dom0 IQN,
    # then serving of the mirrored vDisks on FE1 and FE2 of both servers (4 paths per host)
    Connect-Dcs
    foreach ($k in 'Hosts', 'VirtualDisks') { if (-not $Cfg.ContainsKey($k)) { throw "Variable $k missing from $ConfigFile (Hosts phase)" } }
    $vds = foreach ($name in $Cfg.VirtualDisks) {
        $vd = @(Get-DcsVirtualDisk -VirtualDisk $name -ErrorAction SilentlyContinue)
        if ($vd.Count -ne 1) { throw "vDisk '$name' not found or ambiguous: create it in the DMC first (section 6, step 5)" }
        if ("$($vd[0].Type)" -ne 'MultiPathMirrored') { throw "vDisk '$name' is not mirrored (type $($vd[0].Type))" }
        # DataCore: a vDisk is served for the first time only when it is Online and up to date
        if ("$($vd[0].DiskStatus)" -ne 'Online') { throw "vDisk '$name': status $($vd[0].DiskStatus), expected Online (Up to date)" }
        $vd[0]
    }
    # Assigned and unassigned initiator ports (an initiator not yet assigned to a host is 'unassigned')
    $initiators = @(@(Get-DcsPort -Type iSCSI) + @(Get-DcsPort -Type iSCSI -Unassigned) | Where-Object { "$($_.PortMode)" -eq 'Initiator' })
    foreach ($n in 1, 2) {
        $h = $Cfg.Hosts[$n]; $iqn = "$($h.Iqn)".ToLower()
        if (-not $h.Name -or -not $iqn) { throw "Hosts[$n] incomplete in $ConfigFile (Name and Iqn)" }
        $pref = Get-DcsNodeServer $n
        # Validated order: the DMC knows the initiator only after a dom0 session (section 6, step 6)
        $port = @($initiators | Where-Object PortName -eq $iqn)
        if (-not $port) {
            throw "Initiator $iqn ($($h.Name)) unknown to the DMC: './datacore-xcp.sh iscsi' on $($h.Name), then Refresh the iSCSI ports of both servers in the DMC"
        }
        $cli = @(Get-DcsClient | Where-Object HostName -eq $h.Name)
        if (-not $cli) {
            $cli = Add-DcsClient -Name $h.Name -ClientType CitrixXenServer -PreferredServer $pref.Id -Multipath $true -ALUA $true
            "$($h.Name): host created (Citrix XenServer, Multipathing, ALUA, Preferred Server $($pref.Caption))"
        } else {
            $cli = $cli[0]
            if ("$($cli.Type)" -ne 'CitrixXenServer' -or -not $cli.MpioCapable -or -not $cli.AluaSupport -or "$($cli.PreferredServerId)" -ne "$($pref.Id)") {
                $cli = Set-DcsClientProperties -Client $cli.Id -ClientType CitrixXenServer -PreferredServer $pref.Id -Multipath $true -ALUA $true
                "$($h.Name): host corrected (Citrix XenServer, Multipathing, ALUA, Preferred Server $($pref.Caption))"
            } else { "$($h.Name): host already correct" }
        }
        if (-not $port[0].HostId) {
            Register-DcsClientPort -Port $iqn -Client $cli.Id | Out-Null
            "$($h.Name): initiator $iqn assigned"
        } elseif ("$($port[0].HostId)" -ne "$($cli.Id)") {
            throw "Initiator $iqn already assigned to another host in the DMC"
        }
        $served = @(Get-DcsVirtualDisk -Machine $cli.Id -ErrorAction SilentlyContinue | ForEach-Object Id)
        foreach ($vd in $vds) {
            if ($served -contains $vd.Id) { "$($h.Name): $($vd.Alias) already served"; continue }
            $paths = @(Serve-DcsVirtualDisk -Machine $cli.Id -VirtualDisk $vd.Id -EnableRedundancy)
            "$($h.Name): $($vd.Alias) served, $($paths.Count) path(s) created (4 expected: FE1 and FE2 of each server)"
            if ($paths.Count -ne 4) { Write-Warning "$($vd.Alias) -> $($h.Name): $($paths.Count) path(s) instead of 4, check the mappings in the DMC" }
        }
    }
    ''
    'Next, on each XCP-ng host: ./datacore-xcp.sh iscsi (4 paths per LUN expected). SCSIids for the master:'
    foreach ($vd in $vds) { '  {0,-20} 3{1}' -f $vd.Alias, "$($vd.ScsiDeviceIdString)".ToLower() }
}

function Show-DcsState {
    # DataCore state seen from the cmdlets (skipped if the Executive service is not running)
    try { Connect-Dcs } catch { "DataCore cmdlets unavailable: $($_.Exception.Message)"; return }
    Get-DcsServer | Format-Table Caption, State, CacheState, CacheSize, TotalSystemMemory -AutoSize
    Show-DcsPorts
    Get-DcsClient | Format-Table HostName, Type, MpioCapable, AluaSupport,
        @{ n = 'PreferredServer'; e = { $id = "$($_.PreferredServerId)"; (Get-DcsServer | Where-Object { "$($_.Id)" -eq $id }).Caption } } -AutoSize
    Get-DcsVirtualDisk | Format-Table Alias, Type, DiskStatus, Size, IsServed, @{ n = 'SCSIid'; e = { '3' + "$($_.ScsiDeviceIdString)".ToLower() } } -AutoSize
}

# ---------------------------------------------------------------- Windows patching
function Get-ExecutiveService {
    $s = @(Get-Service -ErrorAction SilentlyContinue | Where-Object DisplayName -like 'DataCore Executive*')
    if ($s.Count -ne 1) { throw 'DataCore Executive service not found' }
    $s[0]
}

function Invoke-PrePatch {
    # DataCore: DataCore Server stopped in the DMC, then Executive service stopped and set to Manual
    Connect-Dcs
    $srv = Get-DcsNodeServer $Node
    if ("$($srv.State)" -ne 'Offline') { throw "$($srv.Caption): state $($srv.State). 'Stop DataCore Server' in the DMC first (HA disabled, section 9)" }
    $svc = Get-ExecutiveService
    $reg = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.Name)"
    $type = if ($reg.DelayedAutostart -eq 1) { 'delayed-auto' } else { 'auto' }
    Set-Content -Path $StartTypeFile -Value $type -Encoding ASCII
    Set-Service -Name $svc.Name -StartupType Manual
    Stop-Service -Name $svc.Name -Force
    "$($svc.DisplayName): stopped, startup type Manual (previous type '$type' saved)"
    'Next: Windows Update, reboot even if not requested, check again for updates, then -Phase PostPatch'
}

function Invoke-PostPatch {
    $svc  = Get-ExecutiveService
    $type = if (Test-Path $StartTypeFile) { (Get-Content $StartTypeFile -TotalCount 1).Trim() } else { 'auto' }
    sc.exe config $svc.Name start= $type | Out-Null
    if ($LASTEXITCODE) { throw "sc.exe config $($svc.Name) start= $type failed" }
    Start-Service -Name $svc.Name
    Remove-Item $StartTypeFile -ErrorAction SilentlyContinue
    "$($svc.DisplayName): started, startup type $type"
    'Next: start the DataCore Server in the DMC if it is stopped, wait for Up to date, then ./datacore-xcp.sh ha-on'
}

function Test-Node {
    foreach ($if in $Storage) {
        $src  = Get-PortIp $if $Cfg.DcOct[$Node]
        $dsts = @(@{ Ip = Get-PortIp $if $Cfg.DcOct[$Peer]; What = $PeerName })
        if ($if -like 'DC-FE*') { foreach ($h in 1,2) { $dsts += @{ Ip = Get-PortIp $if $Cfg.HostOct[$h]; What = "dom0 $h" } } }
        foreach ($d in $dsts) {
            $out = ping.exe -n 2 -f -l ($Cfg.Mtu - 28) -S $src $d.Ip
            $ok  = ($LASTEXITCODE -eq 0) -and ($out -match 'TTL=')
            '{0,-7} {1,-14} {2,-10} MTU {3} : {4}' -f $if, $d.Ip, $d.What, $Cfg.Mtu, $(if ($ok) { 'OK' } else { 'FAILED' })
        }
    }
    Get-NetAdapter -Name $ByIndex | Format-Table Name, Status, LinkSpeed, MacAddress -AutoSize
    "Microsoft initiator sessions (expected: $($Cfg.InitiatorPorts.Count), one per port in InitiatorPorts: $($Cfg.InitiatorPorts -join ', ')):"
    Show-Sessions
    foreach ($if in ($Storage | Where-Object { $_ -notin $Cfg.InitiatorPorts })) {
        if (@(Get-PartnerSessions $if).Count) { Write-Warning "${if}: initiator session to $PeerName (not needed: the mirror only uses the MR ports). Rerun -Phase Initiator to remove it" }
    }
    "Page file (expected: C:\pagefile.sys, fixed $($Cfg.PagefileSizeMB) MB, automatic management disabled):"
    "  automatic management: $((Get-CimInstance Win32_ComputerSystem).AutomaticManagedPagefile)"
    Get-CimInstance Win32_PageFileSetting | Format-Table Name, InitialSize, MaximumSize -AutoSize
    Get-CimInstance Win32_PageFileUsage | Format-Table Name, AllocatedBaseSize -AutoSize
    w32tm /query /status | Select-String 'Source|Stratum'
    Get-ItemProperty -Path $AuKey -ErrorAction SilentlyContinue | Format-List AUOptions, NoAutoRebootWithLoggedOnUsers
    "Drivers through Windows Update excluded (expected 1): $((Get-ItemProperty -Path $WuKey -ErrorAction SilentlyContinue).ExcludeWUDriversInQualityUpdate)"
    "User-mode dumps DumpType (expected 2): $((Get-ItemProperty -Path $DumpKey -ErrorAction SilentlyContinue).DumpType)"
    "Kernel dump CrashDumpEnabled (expected 2, set by the SANsymphony installer): $((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl').CrashDumpEnabled)"
    $cpu = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    $min = if ($Cfg.ContainsKey('MinVcpu')) { $Cfg.MinVcpu } else { 10 }
    "vCPU: $cpu (DataCore minimum for this layout: $min)"
    if ($cpu -lt $min) { Write-Warning "vCPU below ${min}: DC_VCPU in datacore-xcp.conf (4 + 3 per pair of iSCSI ports)" }
    $local = [regex]::Escape($env:COMPUTERNAME)
    if (Select-String -Path "$env:SystemRoot\System32\drivers\etc\hosts" -Pattern "^\s*[^#\s]+\s+(.*\s)?$local(\s|$)" -Quiet) {
        Write-Warning 'hosts file: entry for the local server present (DataCore: remote servers only)'
    }
    Show-DcsState
}

function Invoke-Phase([string]$Name) {
    switch ($Name) {
        'Prepare'     { Invoke-Prepare }
        'Ports'       { Set-DcsPorts }
        'PostInstall' { Set-SkipAsSource $false; Invoke-BestPractice }   # SkipAsSource removed: otherwise unpredictable source IP selection
        'Initiator'   { Connect-PartnerTargets }
        'Hosts'       { Register-XcpHosts }
        'Test'        { Test-Node }
        'PreUpgrade'  { Set-SkipAsSource $true }    # the update wizard gets the same name resolution as at installation
        'PostUpgrade' { Set-SkipAsSource $false }   # Best Practices not replayed: they survive updates
        'PrePatch'    { Invoke-PrePatch }
        'PostPatch'   { Invoke-PostPatch }
    }
}

# ---------------------------------------------------------------- menu
$Menu = [ordered]@{
    '1'  = 'Prepare',     'Adapters, storage IPs, system (before SANsymphony installation, then reboot)'
    '2'  = 'Ports',       'Roles, names, IQNs of the ports of both servers (once, before any vDisk)'
    '3'  = 'PostInstall', 'DataCore iSCSI Best Practices (after the Ports phase, before any vDisk)'
    '4'  = 'Initiator',   'iSCSI connections to the partner, mirror links only (after PostInstall on both sides)'
    '5'  = 'Hosts',       'XCP-ng hosts and serving of the vDisks (once, after iscsi on the dom0s)'
    '6'  = 'Test',        'Network checks, iSCSI sessions, system settings, DataCore state'
    '7'  = 'PreUpgrade',  'Before a SANsymphony update'
    '8'  = 'PostUpgrade', 'After a SANsymphony update'
    '9'  = 'PrePatch',    'Before Windows Update (DataCore Server stopped in the DMC)'
    '10' = 'PostPatch',   'After Windows Update and reboot'
}

function Show-Menu {
    $svc   = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'DataCore*' })
    $state = if (-not $svc) { 'absent' } elseif ($svc | Where-Object Status -eq 'Running') { 'running' } else { 'stopped' }
    ''
    "=== Set-DataCoreNode.ps1 - ${env:COMPUTERNAME}: node $Node (partner $PeerName), DataCore services $state ==="
    foreach ($k in $Menu.Keys) { ' {0,2}) {1,-12} {2}' -f $k, $Menu[$k][0], $Menu[$k][1] }
    '  q) quit'
}

if ($Phase) { Invoke-Phase $Phase; return }

while ($true) {
    Show-Menu | Out-Host
    $c = Read-Host 'Choice'
    if ($c -eq 'q') { break }
    if (-not $Menu.Contains($c)) { Write-Host 'Invalid choice'; continue }
    $p = $Menu[$c][0]
    Write-Host "--> .\Set-DataCoreNode.ps1 -Node $Node -Phase $p" -ForegroundColor Cyan
    # An error (throw) stops the phase, not the menu
    try   { Invoke-Phase $p | Out-Host }
    catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red }
    Read-Host 'Enter to return to the menu' | Out-Null
}
