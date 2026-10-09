# DataCoreNode.psd1 - variables for Set-DataCoreNode.ps1 (identical on both DataCore VMs)
# Place this file next to the script, or point to it with -ConfigFile.
@{
    # Windows name and MGMT adapter IP of each node (hosts file, MGMT adapter check)
    # Name = DC_VMS[N] from datacore-xcp.conf; MgmtIp = management IP of the VM (MANDATORY)
    Nodes = @{
        1 = @{ Name = 'DC-01'; MgmtIp = '' }
        2 = @{ Name = 'DC-02'; MgmtIp = '' }
    }

    # Storage networks: first 3 octets (/24), identical to SUBNET in datacore-xcp.conf
    Subnets = @{
        'DC-FE1' = '10.200.11'
        'DC-FE2' = '10.200.12'
        'DC-MR1' = '10.200.21'
        'DC-MR2' = '10.200.22'
    }
    # Last octet of the DataCore VMs and the dom0s: identical to DC_OCT and HOST_OCT in datacore-xcp.conf
    DcOct   = @{ 1 = 21; 2 = 22 }
    HostOct = @{ 1 = 11; 2 = 12 }
    # MTU of the storage networks: identical to MTU in datacore-xcp.conf
    Mtu = 9000

    # Metric of the storage interfaces (MGMT stays automatic, hence preferred)
    Metric = @{ 'DC-FE1' = 500; 'DC-FE2' = 500; 'DC-MR1' = 600; 'DC-MR2' = 600 }

    # DataCore iSCSI Best Practices script (local copy) and adapter-name filter passed to -adapterIdentifier
    # The filter is a regular expression: it must select exactly DC-FE1, DC-FE2, DC-MR1 and DC-MR2
    BestPracticeScript = 'C:\DataCore\Scripts\iSCSI_Best_Practices_3.11.ps1'
    BestPracticeFilter = 'DC-'

    # Local ports whose Microsoft iSCSI initiator connects to the matching port of the partner:
    # the mirror links only. The front-end ports serve the dom0s; no connection between DataCore servers on FE
    # (the Initiator phase removes any such connection left by an earlier version)
    InitiatorPorts = @('DC-MR1', 'DC-MR2')
    # IQN suffix of the target ports, applied by the Ports phase (DataCore cmdlets) before the Initiator phase:
    # iqn.2000-08.com.datacore:dc-02-01 (DataCore default) -> iqn.2000-08.com.datacore:dc-02-fe1
    # The Initiator phase only connects the target whose IQN ends with the port suffix
    IqnSuffix = @{ 'DC-FE1' = 'fe1'; 'DC-FE2' = 'fe2'; 'DC-MR1' = 'mr1'; 'DC-MR2' = 'mr2' }

    # Fixed-size page file on C: (MB), effective after reboot
    PagefileSizeMB = 4096

    # XCP-ng hosts registered by the Hosts phase: Name = HOSTS[N] of datacore-xcp.conf,
    # Iqn = final IQN shown by 'datacore-xcp.sh host N' (lowercase). Preferred Server = DataCore VM N
    Hosts = @{
        1 = @{ Name = 'xcp-01'; Iqn = '' }
        2 = @{ Name = 'xcp-02'; Iqn = '' }
    }
    # Names (DMC) of the mirrored vDisks served to both hosts by the Hosts phase: data, then heartbeat
    VirtualDisks = @('SR-DataCore', 'SR-HA-Heartbeat')

    # Minimum vCPU checked by the Test phase (DataCore: 4 + 3 per pair of iSCSI ports -> FE pair + MR pair = 10)
    MinVcpu = 10
}
