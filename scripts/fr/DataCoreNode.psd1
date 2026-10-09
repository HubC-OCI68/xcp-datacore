# DataCoreNode.psd1 - variables de Set-DataCoreNode.ps1 (identique sur les 2 VM DataCore)
# Placer ce fichier a cote du script, ou le designer par -ConfigFile.
@{
    # Nom Windows et IP de la carte MGMT de chaque noeud (fichier hosts, controle de la carte MGMT)
    # Name = DC_VMS[N] de datacore-xcp.conf ; MgmtIp = IP de management de la VM (OBLIGATOIRE)
    Nodes = @{
        1 = @{ Name = 'DC-01'; MgmtIp = '' }
        2 = @{ Name = 'DC-02'; MgmtIp = '' }
    }

    # Reseaux de stockage : 3 premiers octets (/24), identiques a SUBNET de datacore-xcp.conf
    Subnets = @{
        'DC-FE1' = '10.200.11'
        'DC-FE2' = '10.200.12'
        'DC-MR1' = '10.200.21'
        'DC-MR2' = '10.200.22'
    }
    # Dernier octet des VM DataCore et des dom0 : identiques a DC_OCT et HOST_OCT de datacore-xcp.conf
    DcOct   = @{ 1 = 21; 2 = 22 }
    HostOct = @{ 1 = 11; 2 = 12 }
    # MTU des reseaux de stockage : identique a MTU de datacore-xcp.conf
    Mtu = 9000

    # Metrique des interfaces de stockage (MGMT reste en automatique, donc prioritaire)
    Metric = @{ 'DC-FE1' = 500; 'DC-FE2' = 500; 'DC-MR1' = 600; 'DC-MR2' = 600 }

    # Script DataCore iSCSI Best Practices (copie locale) et filtre de noms de cartes transmis a -adapterIdentifier
    # Le filtre est une expression reguliere : il doit selectionner exactement DC-FE1, DC-FE2, DC-MR1 et DC-MR2
    BestPracticeScript = 'C:\DataCore\Scripts\iSCSI_Best_Practices_3.11.ps1'
    BestPracticeFilter = 'DC-'

    # Ports locaux dont l'initiateur iSCSI Microsoft se connecte au port homologue du partenaire :
    # les liens miroir uniquement. Les ports front-end servent les dom0 ; aucune connexion entre serveurs
    # DataCore sur FE (la phase Initiator retire celles laissees par une version anterieure)
    InitiatorPorts = @('DC-MR1', 'DC-MR2')
    # Suffixe des IQN des ports cibles, applique par la phase Ports (cmdlets DataCore) avant la phase Initiator :
    # iqn.2000-08.com.datacore:dc-02-01 (defaut DataCore) -> iqn.2000-08.com.datacore:dc-02-fe1
    # La phase Initiator ne connecte que la cible dont l'IQN se termine par le suffixe du port
    IqnSuffix = @{ 'DC-FE1' = 'fe1'; 'DC-FE2' = 'fe2'; 'DC-MR1' = 'mr1'; 'DC-MR2' = 'mr2' }

    # Fichier d'echange de taille fixe sur C: (Mo), effectif apres redemarrage
    PagefileSizeMB = 4096

    # Hotes XCP-ng enregistres par la phase Hosts : Name = HOSTS[N] de datacore-xcp.conf,
    # Iqn = IQN final affiche par 'datacore-xcp.sh host N' (minuscules). Preferred Server = VM DataCore N
    Hosts = @{
        1 = @{ Name = 'xcp-01'; Iqn = '' }
        2 = @{ Name = 'xcp-02'; Iqn = '' }
    }
    # Noms (DMC) des vDisks miroirs servis aux 2 hotes par la phase Hosts : donnees, puis heartbeat
    VirtualDisks = @('SR-DataCore', 'SR-HA-Heartbeat')

    # vCPU minimum controle par la phase Test (DataCore : 4 + 3 par paire de ports iSCSI -> paire FE + paire MR = 10)
    MinVcpu = 10
}
