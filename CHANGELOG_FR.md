# Historique des modifications

Historique de la procédure [docs/datacore-xcp-ng-deployment_FR.md](docs/datacore-xcp-ng-deployment_FR.md) et des scripts, de la plus récente à la plus ancienne révision. Les numéros de section renvoient à la procédure. Les révisions antérieures à la publication embarquaient les scripts dans le texte et ne sont pas dans l'historique Git.

*English version: [CHANGELOG.md](CHANGELOG.md).*

## Validation du 2026-10-09 (révision 9, scripts inchangés)

Origine : retour de tests sur le pool avec les scripts de la révision 9.

| Sujet | Résultat |
| --- | --- |
| `ssh-setup` | Validé : SSH root par clé en place entre les deux dom0. Point ouvert de la révision 8 levé |
| `stop --ups` | Validé avec des VM de production en marche : arrêt propre des VM invitées, puis arrêt du cluster (VM DataCore, puis hôtes). Point ouvert de la révision 9 levé |
| Procédure | Résultats ajoutés en section 8 ; section 11 : points validés listés, points ouverts correspondants retirés, révision publiée corrigée (9) |

## Modifications du 2026-10-09 (révision 9)

Origine : en arrêt sur onduleur, les VM de production n'étaient pas prises en compte avant l'arrêt des VM DataCore.

| Sujet | Modification |
| --- | --- |
| `stop` / `stop --ups` | Arrêt des VM invitées isolé dans une étape explicite et tracée, avant le détachement des SR et l'arrêt des VM DataCore ; VM en pause prises en compte ; contrôle qu'aucune VM invitée ne reste en marche (arrêt forcé sinon ; question en mode normal, poursuite en mode onduleur) ; message distinct pour un arrêt propre et pour un arrêt forcé (outils invités absents ou délai dépassé) |
| Procédure (section 9) | Ordre d'arrêt décrit étape par étape ; outils invités exigés dans les VM de production ; budget d'autonomie de l'onduleur (4 × `SHUTDOWN_TIMEOUT` au pire) |
| Prérequis, sections 3.2, 8 et 10 | Autonomie de l'onduleur ; description de `stop` ; résultat attendu du test `stop --ups` avec des VM de production ; piège ajouté |

Application sur un pool existant : remplacer `datacore-xcp.sh` sur le master, puis **3** `sync`. Vérifier les outils invités : `xe vm-list params=name-label,PV-drivers-detected`.

## Modifications du 2026-10-08 (révision 8)

Origine : remarques après un déploiement complet et la série complète des tests de la section 8 avec les scripts de la révision 7 (résultats en section 8).

| Sujet | Modification |
| --- | --- |
| Procédure et menus | Chaque étape donne l'entrée du menu, puis la commande directe (sections 4 à 9) ; colonne Menu dans les tableaux de commandes (sections 3.2 et 5.2) ; tableaux d'étapes en sections 4, 4.3 et 7 |
| Menu `datacore-xcp.sh` | Entrées renumérotées : ajout de `ssh-setup` (2) et de `ha-off` (16), 25 entrées |
| Initiateur Windows | `InitiatorPorts` réduit à `DC-MR1` et `DC-MR2` : plus de connexion entre serveurs DataCore sur les ports front-end. La phase `Initiator` retire, après confirmation, les connexions FE laissées par une version antérieure ; `Test` les signale |
| Timeout HA | `ha-on` détecte une HA active avec un timeout différent de `HA_TIMEOUT` et propose de la désactiver puis de la réactiver ; timeout affiché après l'activation et par `status` (pool et `xhad.conf`) ; alerte syslog de `check` sur le master ; nouvelle commande `ha-off` ; actions HA dans Xen Orchestra interdites |
| SR après un démarrage à froid ou une coupure d'accès à DataCore | État ALUA du noyau relu par `relogin` (chaque minute) et `check` : rescan du device, puis rescan des sessions si nécessaire ; `check` rend 1 tant qu'un chemin `ready` n'est pas actif pour le noyau, donc `ha-on` et `start` attendent ; `status` signale ces chemins ; message syslog seulement quand la situation change |
| cron | `PATH` exporté en tête du script et fixé dans `/etc/cron.d/datacore-xcp` ; contrôlé par `mpverify` |
| SSH entre hôtes | Nouvelle commande `ssh-setup` (clés et clés d'hôte dans les deux sens) ; `sync` l'exige et utilise `BatchMode` ; état du SSH dans `status` ; messages plus clairs dans `ha-on` et `resume` |
| Management des VM DataCore | Nouvelle variable optionnelle `DC_MGMT_NET` (réseau du VIF 0) ; `dcvm` contrôle les 5 réseaux avant de créer la VM ; commandes de déplacement du VIF 0 d'une VM existante (section 4.4) |
| Réseau de management | Bond exigé dans les prérequis ; comportement xHA à 2 hôtes décrit (section 7) ; test avec management en bond ajouté |
| `check` | Rend 1 si multipathd ne répond pas |
| Validation (section 8) | Résultats de la série du 2026-10-08 ; résultats attendus des tests MR, management et démarrage à froid ; test « HA manipulée depuis Xen Orchestra » |

Application sur un pool existant :

1. Remplacer `datacore-xcp.sh` sur le master ; ajouter `DC_MGMT_NET` à `datacore-xcp.conf` si un réseau dédié est utilisé.
2. **2** `ssh-setup`, puis **3** `sync`.
3. **5** `host` sur chaque hôte, un à la fois (valider l'IQN proposé par Entrée) : réécrit le fichier cron avec son `PATH`. Puis `cat /etc/cron.d/datacore-xcp`.
4. **18** `status` sur chaque hôte : timeout HA à 120, aucune ALERTE, SSH OK. Si le timeout est faux : **15** `ha-on` sur le master, vDisks *Up to date*.
5. Sur chaque VM DataCore, une à la fois : remplacer `Set-DataCoreNode.ps1`, mettre `InitiatorPorts = @('DC-MR1', 'DC-MR2')`, **4** `Initiator`, puis **6** `Test` (2 sessions).
6. Déplacer le VIF 0 des VM DataCore si nécessaire (section 4.4), puis rejouer les tests MR, management et démarrage à froid de la section 8.

## Modifications du 2026-10-07 (révision 7)

Origine : menus demandés pour les deux scripts ; `stop --ups` a arrêté le master en premier après une bascule HA ; ordre des serveurs DataCore non maîtrisé à l'arrêt et au redémarrage.

| Sujet | Modification |
| --- | --- |
| Fusion | Réunit la révision 6 du 2026-09-30 et la livraison du 2026-10-07, diffusée elle aussi sous le nom « révision 6 » mais construite sur la révision 5 ; `Set-DataCoreNode.ps1` et `DataCoreNode.psd1` restent ceux de la révision 6 |
| `mpverify` | Ajoutée au menu de `datacore-xcp.sh` (entrée 18, hôte local) ; entrées `start` à `rescue` décalées de 19 à 23 |
| Menu `datacore-xcp.sh` | Sans argument : menu groupé par étape, rôle réel de l'hôte, sélection du nœud, de la LUN et de la VM, commande directe affichée, retour au menu après chaque action ; exécution directe inchangée (section 3.2) |
| Menu `Set-DataCoreNode.ps1` | Sans `-Phase` : menu des phases, état des services DataCore dans l'en-tête ; `-Node` facultatif : détection par la MAC MGMT puis le nom Windows, avec confirmation (section 5.1) |
| `iscsi` | Colonne SR : SR DataCore porté par chaque LUN |
| `protect` | VM désignée par nom ou UUID |
| `stop --ups` | Ordre des hôtes selon le rôle réel (autre hôte, puis master) ; attente de l'arrêt de l'autre hôte, `SHUTDOWN_TIMEOUT` au plus |
| `stop` | VM DataCore arrêtées 2 puis 1 ; *Stop DataCore Server* demandé serveur par serveur ; dernier arrêt mémorisé dans `other-config:datacore-last-stopped` (`N:dmc`, `N:ups`, `N:ups-force`) |
| `start` | Dernier arrêté démarré en premier ; *Start DataCore Server* demandé après un `stop` normal ; attente du port 3260 avant l'autre serveur ; arrêt non maîtrisé détecté ; clé effacée (section 9) |
| `datacore-xcp.conf` | Commentaires : nœud 1 = master à l'installation ; `SHUTDOWN_TIMEOUT` sert aussi à l'attente de l'autre hôte |
| Validation (section 8) | Résultats attendus de `stop` / `start`, `stop --ups` et coupure des 2 nœuds ; test `stop --ups` après bascule du master |

Application sur un pool existant : `sync`, contrôle des md5. Le premier `start` sans `stop` préalable de cette version trouve la clé absente : il passe par la branche « arrêt non maîtrisé », à confirmer.

## Modifications du 2026-09-30 (révision 6)

Origine : revue de la procédure face à la documentation SANsymphony 10.0 PSP22 (Best Practices : *The DataCore Server*, *Hyper-converged Virtual SAN*, *iSCSI Network and Best Practices*, *System Memory Considerations* ; guides de configuration des hôtes *Citrix XenServer* et *Linux* ; référence des cmdlets DataCore), et automatisation des étapes DMC par les cmdlets DataCore.

| Sujet | Modification |
| --- | --- |
| Nouvelle phase `Ports` | Rôles, IQN et noms des ports iSCSI des deux serveurs par les cmdlets (`Get-DcsPort`, `Set-DcsServerPortProperties`, `Set-DcsPortProperties`), ports identifiés par leur MAC fixe ; remplace les étapes manuelles 8 et 10 de la section 5.3 |
| Nouvelle phase `Hosts` | Hôtes XCP-ng (`Add-DcsClient` / `Set-DcsClientProperties` : Citrix XenServer, Multipathing, ALUA, Preferred Server), IQN du dom0 (`Register-DcsClientPort`), service avec chemins redondants (`Serve-DcsVirtualDisk -EnableRedundancy`), SCSIid pour `sr`/`ha` ; ordre validé conservé (sessions des dom0 d'abord) |
| Hôtes DMC | Multipathing et ALUA activés sur les hôtes (guide DataCore XenServer), absents jusqu'ici de la section 6 |
| Fichier hosts | Entrée du partenaire uniquement ; entrée du serveur local supprimée (DataCore) |
| Windows Update | Pilotes exclus (`ExcludeWUDriversInQualityUpdate`) ; nouvelles phases `PrePatch` / `PostPatch` : service DataCore Executive arrêté et passé en Manuel avant les correctifs, type de démarrage rétabli ensuite |
| Dumps | Dumps en mode utilisateur (`LocalDumps\DumpType = 2`) dans `Prepare` ; dump noyau contrôlé par `Test` |
| vCPU | `DC_VCPU` 8 → 10 (4 + 3 par paire de ports iSCSI) ; contrôle dans `Test` (`MinVcpu`) |
| Multipath | Nouvelle commande `mpverify` (aussi dans `status`) ; `resume N` la lance avant de relancer la VM DataCore |
| Prérequis | Réglages BIOS des hôtes, switchs sans STP et avec contrôle de flux, cmdlets DataCore |
| Pools de disques (section 6) | Même SAU des deux côtés, catalogue sur 2 disques rapides en tier 1, réserve de tier, snapshots |
| `Test` | Exclusion des pilotes, dumps, vCPU, fichier hosts, état DataCore par les cmdlets |
| Version anglaise | `Set-DataCoreNode.ps1` EN corrigé : chaînes `"$if: ..."` qui empêchaient le chargement du script (`"${if}: ..."`) ; la version FR n'était pas touchée |

Application sur un pool existant : `sync`, puis `./datacore-xcp.sh status` sur chaque hôte (`Configuration multipath OK` attendu). Côté Windows, remplacer `Set-DataCoreNode.ps1`, ajouter `Hosts`, `VirtualDisks` et `MinVcpu` à `DataCoreNode.psd1`, puis `-Phase Test`. Ne pas rejouer `Prepare` sur un serveur en service : appliquer à la main, ou lors d'une maintenance, les réglages du fichier hosts, de l'exclusion des pilotes et des dumps. `DC_VCPU` ne s'applique qu'à une nouvelle VM : `xe vm-param-set VCPUs-max=10 VCPUs-at-startup=10` VM arrêtée, nœud en maintenance. `Ports` ne s'applique pas à un Server Group qui a déjà des vDisks : ses contrôles sont affichés par `Test`.

## Modifications du 2026-09-30 (révision 5)

Origine : fence de l'hôte 1 au test « VM DataCore figée » exécuté après un crash du nœud 2. Le diagnostic a établi un cache ALUA du noyau périmé sur les chemins de secours. Correctif validé par la série crash de la VM DataCore 2, gel de la VM DataCore 1, crash du nœud 2, gel de la VM DataCore 1 : aucun fence.

| Sujet | Modification |
| --- | --- |
| Multipath | `hardware_handler "1 alua"` dans `custom.conf` (modèle de `host N`) ; contrôle `hwhandler` affiché par `host N` et `status` ; section 7 |
| `check` | Relecture (`rescan`) de l'état ALUA du noyau sur tout chemin `ready` non actif pour le noyau, journalisée ; option `--quiet` |
| `status` | Nombre de sessions iSCSI ; chemins avec checker, prio multipathd et état ALUA du noyau |
| Nouvelle commande `relogin` | Rétablit les sessions vers les portails sans session ; verrou, sans effet si aucun SR DataCore n'est attaché ou si XAPI ne répond pas |
| Tâches planifiées | `/etc/cron.d/datacore-xcp` installé par `host N` (`relogin` chaque minute, `check` toutes les 5 minutes) ; ancien `datacore-check` supprimé |
| Activation de la HA | `ha-on` (donc `ha`, `start`, `resume`) attend, après la confirmation *Up to date*, 4 chemins `ready` par LUN sur chaque hôte (10 min max) ; prérequis SSH par clé entre dom0 |
| `pci-check` | `grep -q` en pipeline remplacé par `grep -c` (faux négatifs possibles sous `pipefail`) |
| Script DataCore Best Practices | Nom de fichier corrigé : `iSCSI_Best_Practices_3.11.ps1` (prérequis, fichiers livrés, `DataCoreNode.psd1`, section 5) |
| Validation (section 8) | Contrôles avant tests étendus (sessions, `hwhandler`, cohérence ALUA, absence de `Failing path`) ; boucle de suivi ; enchaînements obligatoires sans reboot ; résultats attendus complétés |
| Exploitation (section 9) | Contrôle après tout redémarrage d'une VM DataCore ou d'un hôte ; supervision par le cron de `host N` ; `relogin` dans la sortie de blocage au boot |

Application sur un pool existant : `sync`, puis `./datacore-xcp.sh host N` sur chaque hôte, un à la fois (valider l'IQN proposé par Entrée), puis contrôle `hwhandler='1 alua'` et `status`.

## Modifications du 2026-09-30 (révision 4)

| Sujet | Modification |
| --- | --- |
| Prérequis | Windows Server 2025 qualifié par DataCore depuis PSP21 : plus de prérequis bloquant |
| Ports iSCSI DataCore | Renommage des ports et de leurs IQN (suffixes `fe1`, `fe2`, `mr1`, `mr2`) déplacé en section 5, étape 10, avant la phase `Initiator` ; section 6 réduite à une vérification |
| Phase `Initiator` | IQN de port renommé de `iqn.2000-08.com.datacore:serveur-NN` en `iqn.2000-08.com.datacore:serveur-fe1` (etc.) ; clé `IqnSuffix` ; redécouverte du portail, sélection de la cible par suffixe d'IQN, erreur si le suffixe est absent ; affichage des sessions par IQN (aussi dans `Test`) |

## Modifications du 2026-09-29 (révision 3)

| Sujet | Modification |
| --- | --- |
| Généralisation | Procédure écrite en variables (`HOSTS[N]`, VM DataCore N, `SUBNET`/`DC_OCT`/`HOST_OCT`) ; plus aucune adresse ni aucun nom de site en dur hors valeurs par défaut des fichiers de variables ; références aux tests et au pool de test retirées de la procédure |
| Management | Plus aucune adresse de management dans la procédure ni dans les scripts ; `Nodes[N].MgmtIp` vide par défaut et obligatoire ; bloc console de la section 5 en variables |
| Variables XCP-ng | `NTP_SERVERS` vide par défaut et obligatoire ; `IQN_PREFIX` ajouté (IQN proposé = `IQN_PREFIX:nom-de-l-hôte`) ; `HOST_IQN` vide par défaut |
| Windows | Modèle `WIN_TEMPLATE="Windows Server 2025"` (qualifié par DataCore depuis PSP21) ; `dcvm` vérifie l'existence du modèle et liste les modèles Windows sinon |
| Fichier d'échange | Fixé à `PagefileSizeMB` (4096) sur C: au lieu d'être supprimé ; `Test` affiche le réglage |
| MTU | `MTU` / `Mtu` utilisé par `netcheck`, `*JumboPacket`, `NlMtuBytes` et les pings de `Test` (plus de 9000 en dur) |
| Validation | Colonne de statut retirée ; tous les scénarios à exécuter et consigner avant production et après modification |

## Modifications du 2026-09-28 (révision 2, retour du déploiement à blanc)

| Sujet | Modification |
| --- | --- |
| Variables XCP-ng | Bloc CONFIGURATION sorti du script vers `datacore-xcp.conf`, chargé et contrôlé au lancement ; tableau de renseignement (section 3.1) ; commande `sync` (copie script + variables, md5) ; md5 des deux fichiers dans `status` |
| Variables Windows | Bloc CONFIGURATION sorti du script vers `DataCoreNode.psd1` (section 5.1) ; `$MgmtIp` remplacé par `Nodes` |
| NTP | `host N` configure le NTP par XAPI (`ntp-custom-servers`, `ntp-mode`) quand l'hôte le gère, sinon `chrony.conf` ; procédure manuelle en section 4.2 |
| Masquage PCI | Ordre xcp-02 puis xcp-01, attente du retour de chaque hôte (section 4.3) ; `pci-hide N` refusé si l'autre hôte n'est pas joignable ; avertissement au reboot du master |
| IQN | `host N` propose `HOST_IQN[N]`, accepte une saisie, contrôle le format et applique par `xe host-param-set iscsi_iqn=` ; refusé si une session iSCSI est ouverte (section 4.1) |
| Passthrough | Retiré de `dcvm` ; nouvelle commande `dcpci N` après Windows et PV tools ; état du HBA dans `status` |
| Carte de management Windows | Identification par MAC dès la console (section 5, étape 3) ; renommage en deux passes ; `Prepare` contrôle l'IP de MGMT |
| Prérequis | Visual C++ retiré (non nécessaire) |
| Fichier d'échange | Supprimé par `Prepare` (`DisablePagefile`) ; contrôlé par `Test` |
| Best Practices iSCSI DataCore | Script `iSCSI_Best_Practices_3.11.ps1` appelé par `PostInstall` sur les 4 cartes de stockage (filtre contrôlé) ; nouvelle phase `PostUpgrade` pour ne pas le rejouer après une PSP |
| Initiateur iSCSI Windows | Nouvelle phase `Initiator` : connexions persistantes vers FE1, FE2, MR1 et MR2 du partenaire |
| DMC | Renommage des ports iSCSI (section 6, étape 2) ; ordre sessions iSCSI des dom0 → *Refresh* → hôtes → service des vDisks (section 6, étape 6) |
| Phases PowerShell | `Network` renommée `Prepare` ; ajout de `Initiator` et `PostUpgrade` |

## Modifications du 2026-09-28 (révision 1)

| Sujet | Modification |
| --- | --- |
| Plan IP de stockage | 172.16.11/12/21/22.0/24 remplacés par 10.200.11/12/21/22.0/24 (dernier octet inchangé) : tableau du plan IP, `SUBNET` de `datacore-xcp.sh`, `$Subnets` de `Set-DataCoreNode.ps1`, tableau des chemins (section 6), section 5 étape 6 |
| Plan IP | Règle d'adressage et contrôle de non-chevauchement ajoutés en section 1 |
| iSCSI | `recovery_tmo` effectif mesuré à 5 s, fixé par multipathd depuis `fast_io_fail_tmo` (et non par `iscsid.conf`, qui indiquait 20) : `fast_io_fail_tmo 5` explicite dans la section `defaults` de `custom.conf` (ignoré dans `devices`), `iscsid.conf` plus modifié, `status` alerte au-delà de `ISCSI_TMO_MAX` (30 s) ; budget de détection ramené à ~15 s. Mécanisme validé par test (5 → 10 → 5 après `multipathd reconfigure`) |
| `host N` | Idempotent : une PIF FE déjà configurée n'est plus reconfigurée (évite la coupure des chemins iSCSI) ; relançable pour appliquer un nouveau `custom.conf` |
| SR heartbeat | Taille portée à 10 Go (les VDI HA occupent ~3,7 GiB en LVM thick) ; contrôle `HB_MIN_FREE_GIB` dans `ha_on`, uniquement si les VDI HA n'existent pas encore ; cas ajoutés en section 10 |
| Agrandissement de SR | Procédure validée (rescan et `resize map` sur chaque hôte, puis `sr-scan` ; pas de `pvresize`) |

Si le pool de test garde l'ancien plan, ne pas y réappliquer `host N` ni `-Phase Prepare` (ex-`Network`) : les IP FE des dom0 et des VM changeraient, alors que les SR et les mappings DataCore pointent encore vers 172.16.x.x.

## Modifications du 2026-09-23

| Sujet | Modification |
| --- | --- |
| Multipathing XAPI | Activé par `host N` (il l'était à la main sur le pool de test) ; exigé par `sr`, `ha`, `start` ; affiché par `status` |
| BDF du HBA | Un BDF par nœud (`PCI_BDF[N]`) ; `pci-check N` / `pci-hide N` ; `dcvm N` utilise le BDF du bon hôte |
| Détection des disques | Via `lsblk` (PKNAME) au lieu d'une troncature du nom ; inventaire des disques de dom0 dans `pci-check` |
| Périmètre | HBA SAS uniquement ; mention NVMe retirée |
| iSCSI | `replacement_timeout` réglé à 20 s (config et nœuds existants) ; `recovery_tmo` effectif affiché par `iscsi` et `status` |
| Architecture | Chemins locaux via bridge interne : résultat attendu du test « coupure FE » corrigé, test `Test` PowerShell précisé |
| `pool-net` | Refusé si une VM DataCore tourne ; réseaux déjà configurés ignorés |
| `host N` | Contrôle des PIF, avertissement si NTP géré par XAPI |
| Nouvelles commandes | `netcheck`, `ha-on`, `check`, `stop --ups` |
| `start` | Démarrage des VM protégées par ordre |
| `stop` | Délai d'arrêt propre puis arrêt forcé ; mode onduleur |
| `protect` | Contrôle d'agilité et affichage du plan HA |
| `dcvm` | `has-vendor-device=false`, cores-per-socket, masque vCPU optionnel |
| Journalisation | `/var/log/datacore-xcp.log`, md5 du script dans `status` |
| PowerShell | Phase `PreUpgrade`, garde-fou sur `Network`, `*JumboPacket` non bloquant, Windows Update sans redémarrage automatique |
| Exploitation | Interdits, patching Windows et PSP, supervision, sauvegardes, agrandissement de SR, remplacement de disque |
| Tests | VM DataCore figée ou plantée, perte du management, `stop --ups`, coupure électrique, cycle de patching, mesure du gel I/O |
