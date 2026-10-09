#!/bin/bash
# datacore-xcp.sh - DataCore SANsymphony HCI sur pool XCP-ng 8.3 (2 noeuds)
# Usage : ./datacore-xcp.sh [commande [args]]      (sans argument : menu ; ./datacore-xcp.sh help)
# Variables : datacore-xcp.conf dans le meme dossier (ou $DATACORE_XCP_CONF). Aucune valeur a modifier ici.
set -uo pipefail
shopt -s nullglob
# cron s'execute avec PATH=/usr/bin:/bin : multipathd et iscsiadm (sbin) y seraient introuvables
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/xensource/bin

SELF=$(readlink -f "$0")
CONF=${DATACORE_XCP_CONF:-$(dirname "$SELF")/datacore-xcp.conf}
LOG=/var/log/datacore-xcp.log
REQUIRED="HOSTS DC_VMS NIC SUBNET HOST_OCT DC_OCT MGMT_NET MTU NTP_SERVERS PCI_BDF DC_VCPU DC_RAM_GIB
          DC_DISK_GIB WIN_TEMPLATE SR_NAME HB_SR_NAME HA_TIMEOUT HB_MIN_FREE_GIB ISCSI_TMO_MAX SHUTDOWN_TIMEOUT"
CMDS="nics ssh-setup sync pool-net host netcheck pci-check pci-hide dcvm dcpci iscsi relogin sr ha ha-on ha-off protect status check mpverify start stop maint resume rescue help"
# Valeurs par defaut des variables optionnelles (le fichier de variables les remplace)
LOCAL_SR=([1]="" [2]=""); DC_VCPU_MASK=([1]="" [2]=""); HOST_IQN=([1]="" [2]=""); IQN_PREFIX=""; WIN_ISO=""; DC_MGMT_NET=""
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5"

die()  { echo "ERREUR : $*" >&2; exit 1; }
ask()  { local r; read -r -p "$* [o/N] " r; [[ $r == [oO] ]]; }

# Chargement au niveau global : 'declare -A' dans une fonction creerait des variables locales
if [[ ${1:-} != help ]]; then
  [[ -r $CONF ]] || die "fichier de variables introuvable : $CONF"
  # shellcheck source=/dev/null
  . "$CONF"
  for _v in $REQUIRED; do declare -p "$_v" >/dev/null 2>&1 || die "variable $_v absente de $CONF"; done
  for _v in NIC SUBNET; do [[ $(declare -p "$_v") == "declare -A"* ]] || die "$_v doit etre declaree par 'declare -A' dans $CONF"; done
  unset _v
fi

node() { [[ ${1:-} == [12] ]] || die "numero de noeud attendu : 1 ou 2"; }
local_host() { ( . /etc/xensource-inventory; echo "$INSTALLATION_UUID" ); }
host_uuid()  { xe host-list name-label="${HOSTS[$1]}" --minimal; }
host_addr()  { xe host-param-get uuid="$(host_uuid "$1")" param-name=address; }
vm_uuid()    { xe vm-list name-label="${DC_VMS[$1]}" --minimal; }
sr_uuid()    { xe sr-list name-label="$1" --minimal; }
master()     { [[ $(xe pool-list params=master --minimal) == $(local_host) ]] || die "a lancer sur le master"; }
on_node()    { [[ $(local_host) == $(host_uuid "$1") ]] || die "a lancer sur ${HOSTS[$1]}"; }
local_node() { local n; for n in 1 2; do [[ $(host_uuid "$n") == $(local_host) ]] && { echo "$n"; return; }; done; die "hote local absent de HOSTS"; }
host_live()  { [[ $(xe host-param-get uuid="$(host_uuid "$1")" param-name=host-metrics-live 2>/dev/null) == true ]]; }
pool()       { xe pool-list --minimal; }
sr_pbds()    { local u; u=$(sr_uuid "$1"); [[ -n $u ]] && xe pbd-list sr-uuid="$u" "${@:2}" --minimal | tr , ' '; }
portals()    { local n p o=(); for n in 1 2; do for p in DC-FE1 DC-FE2; do o+=("${SUBNET[$p]}.${DC_OCT[$n]}"); done; done; (IFS=,; echo "${o[*]}"); }
vm_state()   { local u; u=$(vm_uuid "$1"); [[ -n $u ]] && xe vm-param-get uuid="$u" param-name=power-state || echo absente; }
dc_running() { local n; for n in 1 2; do [[ $(vm_state "$n") == running ]] && return 0; done; return 1; }
mp_flag()    { xe host-param-get uuid="$(host_uuid "$1")" param-name=other-config param-key=multipathing 2>/dev/null || echo false; }
mp_check()   { local n; for n in 1 2; do [[ $(mp_flag "$n") == true ]] || die "multipathing inactif sur ${HOSTS[$n]} : lancer 'host $n'"; done; }
rec_tmo()    { local f; for f in /sys/class/iscsi_session/session*/recovery_tmo; do cat "$f"; done | sort | uniq -c | xargs; }
cur_iqn()    { sed -n 's/^InitiatorName=//p' /etc/iscsi/initiatorname.iscsi; }
bdf_set()    { [[ ${PCI_BDF[$1]} != 0000:00:00.0 ]] || die "PCI_BDF[$1] non renseigne dans $CONF"; }
ha_enabled() { [[ $(xe pool-param-get uuid="$(pool)" param-name=ha-enabled) == true ]]; }
# Timeout HA enregistre dans le pool (vide = HA activee sans ha-config:timeout, defaut XAPI) et
# celui reellement utilise par xhad sur l'hote local
ha_tmo()     { xe pool-param-get uuid="$(pool)" param-name=ha-configuration param-key=timeout 2>/dev/null; }
xha_tmo()    { grep -oiE '<StateFileTimeout>[0-9]+' /etc/xensource/xhad.conf 2>/dev/null | grep -oE '[0-9]+$'; }
# SSH par cle vers l'hote N fonctionnel sans aucune question (voir 'ssh-setup')
ssh_ok()     { ssh $SSH_OPTS "root@$(host_addr "$1")" true 2>/dev/null; }
# Execute une commande du script sur l'hote N : localement, ou par ssh (script copie dans /root par 'sync')
on_host()    {
  local n=$1; shift
  if [[ $(host_uuid "$n") == $(local_host) ]]; then "$SELF" "$@"
  else ssh $SSH_OPTS "root@$(host_addr "$n")" "/root/${SELF##*/} $*"; fi
}

# ---------------------------------------------------------------- nics / ssh-setup / sync
cmd_nics() {
  local n r; for n in 1 2; do
    echo "== ${HOSTS[$n]}"
    xe pif-list host-uuid="$(host_uuid "$n")" physical=true params=device,MAC,network-name-label,IP,management
  done
  echo "Selection actuelle ($CONF) : $(for r in DC-FE1 DC-FE2 DC-MR1 DC-MR2; do printf '%s=%s ' "$r" "${NIC[$r]}"; done)"
}
cmd_ssh_setup() {
  # SSH root par cle entre les deux dom0, dans les deux sens, sur les adresses de management.
  # on_host et sync utilisent BatchMode, qui refuse toute question : une cle absente ou une cle
  # d'hote inconnue les fait echouer. Demande une fois (deux au plus) le mot de passe root de l'autre hote.
  local n p a la pub rpub key=/root/.ssh/id_ed25519 kh=/root/.ssh/known_hosts ak=/root/.ssh/authorized_keys
  n=$(local_node) || exit 1; p=$((3-n))
  host_live "$p" || die "${HOSTS[$p]} injoignable"
  a=$(host_addr "$p"); la=$(host_addr "$n")
  mkdir -p /root/.ssh; chmod 700 /root/.ssh
  [[ -f $key ]] || ssh-keygen -q -t ed25519 -N "" -C "datacore-xcp@${HOSTS[$n]}" -f "$key" || die "ssh-keygen en echec"
  # Cle d'hote de l'autre hote : remplacee si elle a change (reinstallation)
  touch "$kh"; ssh-keygen -R "$a" -f "$kh" >/dev/null 2>&1
  ssh-keyscan -T 5 "$a" 2>/dev/null >> "$kh"
  grep -q "^$a " "$kh" || die "aucune cle d'hote SSH obtenue de $a (ssh-keyscan)"
  if ssh_ok "$p"; then
    echo "${HOSTS[$n]} -> ${HOSTS[$p]} : cle deja acceptee"
  else
    pub=$(cat "$key.pub")
    echo "Mot de passe de root@$a (${HOSTS[$p]}) :"
    ssh -o ConnectTimeout=5 "root@$a" "mkdir -p /root/.ssh && chmod 700 /root/.ssh && { grep -qxF '$pub' $ak 2>/dev/null || echo '$pub' >> $ak; } && chmod 600 $ak" \
      || die "cle non installee sur ${HOSTS[$p]}"
    ssh_ok "$p" || die "cle refusee par ${HOSTS[$p]} : verifier PermitRootLogin et PubkeyAuthentication dans son sshd_config"
    echo "${HOSTS[$n]} -> ${HOSTS[$p]} : cle installee"
  fi
  # Sens inverse, par la connexion qui fonctionne maintenant
  rpub=$(ssh $SSH_OPTS "root@$a" "[ -f $key ] || ssh-keygen -q -t ed25519 -N '' -C datacore-xcp@${HOSTS[$p]} -f $key >/dev/null; touch $kh; ssh-keygen -R $la -f $kh >/dev/null 2>&1; ssh-keyscan -T 5 $la 2>/dev/null >> $kh; cat $key.pub" | tail -1)
  [[ $rpub == ssh-* ]] || die "cle publique de ${HOSTS[$p]} non lue"
  grep -qxF "$rpub" "$ak" 2>/dev/null || echo "$rpub" >> "$ak"; chmod 600 "$ak"
  ssh $SSH_OPTS "root@$a" "ssh $SSH_OPTS root@$la true" 2>/dev/null \
    || die "${HOSTS[$p]} -> ${HOSTS[$n]} : SSH par cle toujours refuse"
  echo "${HOSTS[$p]} -> ${HOSTS[$n]} : OK"
  echo "SSH par cle fonctionnel dans les deux sens ($la <-> $a)."
}
cmd_sync() {
  local n p a; n=$(local_node) || exit 1; p=$((3-n))
  host_live "$p" || die "${HOSTS[$p]} injoignable"
  ssh_ok "$p" || die "SSH par cle vers ${HOSTS[$p]} non fonctionnel : lancer d'abord './datacore-xcp.sh ssh-setup'"
  a=$(host_addr "$p")
  scp -p $SSH_OPTS "$SELF" "$CONF" "root@$a:/root/" || die "copie vers ${HOSTS[$p]} ($a) impossible"
  ssh $SSH_OPTS "root@$a" "chmod +x /root/${SELF##*/}"
  echo "== ${HOSTS[$n]}"; md5sum "$SELF" "$CONF"
  echo "== ${HOSTS[$p]}"; ssh $SSH_OPTS "root@$a" "md5sum /root/${SELF##*/} /root/${CONF##*/}"
}

# ---------------------------------------------------------------- pool-net
cmd_pool_net() {
  master; local h r n net pif seen=""; h=$(host_uuid 1)
  dc_running && die "VM DataCore en marche : pool-net debrancherait les PIF MR et couperait le miroir"
  for r in DC-FE1 DC-FE2 DC-MR1 DC-MR2; do
    [[ " $seen " == *" ${NIC[$r]} "* ]] && die "${NIC[$r]} affectee a deux fonctions"; seen+=" ${NIC[$r]}"
    for n in 1 2; do
      pif=$(xe pif-list host-uuid="$(host_uuid "$n")" device="${NIC[$r]}" physical=true --minimal)
      [[ -n $pif ]] || die "${NIC[$r]} ($r) absente sur ${HOSTS[$n]}"
      [[ $(xe pif-param-get uuid="$pif" param-name=management) == false ]] || die "${NIC[$r]} porte le management sur ${HOSTS[$n]}"
    done
  done
  for r in DC-FE1 DC-FE2 DC-MR1 DC-MR2; do
    net=$(xe pif-list host-uuid="$h" device="${NIC[$r]}" params=network-uuid --minimal)
    [[ -n $net ]] || die "PIF ${NIC[$r]} introuvable"
    if [[ $(xe network-param-get uuid="$net" param-name=name-label) == "$r" &&
          $(xe network-param-get uuid="$net" param-name=MTU) == "$MTU" ]]; then
      echo "  $r : deja configure"; continue
    fi
    xe network-param-set uuid="$net" name-label="$r" MTU="$MTU"
    for pif in $(xe pif-list network-uuid="$net" --minimal | tr , ' '); do
      xe pif-unplug uuid="$pif" 2>/dev/null && xe pif-plug uuid="$pif" \
        || echo "  $r : replug impossible (disallow-unplug ?) -> MTU applique au reboot"
    done
  done
  xe pif-list params=host-name-label,device,network-name-label,MTU | grep -B1 -A2 'DC-'
}

# ---------------------------------------------------------------- host N
iqn_setup() {
  local n=$1 h=$2 cur def new re
  cur=$(cur_iqn); def=${HOST_IQN[$n]:-}
  [[ -z $def && -n $IQN_PREFIX ]] && def="$IQN_PREFIX:${HOSTS[$n],,}"
  def=${def:-$cur}
  re='^iqn\.[0-9]{4}-(0[1-9]|1[0-2])\.[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:[a-z0-9._:-]+)?$'
  echo "IQN actuel de ${HOSTS[$n]} : $cur"
  if [[ -t 0 ]]; then read -r -p "IQN a appliquer [Entree = $def] : " new; fi
  new=${new:-$def}; new=${new,,}
  [[ $new == "$cur" ]] && { echo "  IQN inchange"; return; }
  [[ $new =~ $re ]] || die "IQN invalide : $new (format iqn.AAAA-MM.domaine.inverse:nom)"
  [[ -z $(iscsiadm -m session 2>/dev/null) ]] \
    || die "sessions iSCSI ouvertes : l'IQN ne se change qu'avant 'iscsi' et la creation des SR"
  xe host-param-set uuid="$h" iscsi_iqn="$new" || die "xe host-param-set iscsi_iqn refuse"
  sleep 2
  [[ $(cur_iqn) == "$new" ]] || die "initiatorname.iscsi non mis a jour ($(cur_iqn)) : verifier xensource.log"
  echo "  IQN modifie : $new"
}
ntp_setup() {
  local h=$1 m s
  [[ ${#NTP_SERVERS[@]} -gt 0 && -n ${NTP_SERVERS[0]} ]] || die "NTP_SERVERS vide dans $CONF"
  if m=$(xe host-param-get uuid="$h" param-name=ntp-mode 2>/dev/null); then
    # XAPI gere chrony.conf : toute modification manuelle serait ecrasee
    echo "NTP gere par XAPI (mode actuel : $m) : configuration par xe"
    xe host-param-set uuid="$h" ntp-custom-servers="$(IFS=,; echo "${NTP_SERVERS[*]}")" || die "ntp-custom-servers refuse"
    if [[ $m != *[Cc]ustom* ]]; then
      xe host-param-set uuid="$h" ntp-mode=Custom 2>/dev/null \
        || xe host-param-set uuid="$h" ntp-mode=ntp_mode_custom \
        || die "ntp-mode refuse : 'xe host-param-list uuid=$h | grep -i ntp' pour les valeurs acceptees"
    fi
    echo "  ntp-mode : $(xe host-param-get uuid="$h" param-name=ntp-mode)"
    echo "  serveurs : $(xe host-param-get uuid="$h" param-name=ntp-custom-servers)"
  else
    sed -i -E '/^(server|pool) /d' /etc/chrony.conf
    for s in "${NTP_SERVERS[@]}"; do echo "server $s iburst" >> /etc/chrony.conf; done
    systemctl enable chronyd >/dev/null 2>&1; systemctl restart chronyd
  fi
  sleep 5; chronyc -a makestep >/dev/null; chronyc sources
}
cmd_host() {
  node "${1:-}"; local n=$1 h r pif ip; on_node "$n"; h=$(local_host)
  iqn_setup "$n" "$h"
  for r in DC-FE1 DC-FE2; do
    pif=$(xe pif-list host-uuid="$h" network-name-label="$r" --minimal)
    [[ -n $pif && $pif != *,* ]] || die "PIF $r introuvable sur cet hote : lancer pool-net sur le master"
    ip="${SUBNET[$r]}.${HOST_OCT[$n]}"
    # Idempotent : reconfigurer une PIF deja correcte la rebrancherait et couperait les chemins iSCSI
    if [[ $(xe pif-param-get uuid="$pif" param-name=IP-configuration-mode) == Static &&
          $(xe pif-param-get uuid="$pif" param-name=IP) == "$ip" &&
          $(xe pif-param-get uuid="$pif" param-name=netmask) == 255.255.255.0 ]]; then
      echo "  $r : $ip deja configuree"
    else
      xe pif-reconfigure-ip uuid="$pif" mode=static IP="$ip" netmask=255.255.255.0
    fi
    xe pif-param-set uuid="$pif" disallow-unplug=true other-config:management_purpose="Storage $r"
  done
  # Multipathing XAPI : obligatoire avant sr/ha (hote desactive le temps du reglage)
  if [[ $(mp_flag "$n") != true ]]; then
    [[ -z $(xe vm-list resident-on="$h" is-control-domain=false --minimal) ]] \
      || die "VM en marche sur cet hote : les arreter ou migrer avant d'activer le multipathing"
    xe host-disable uuid="$h"
    xe host-param-set uuid="$h" other-config:multipathing=true other-config:multipathhandle=dmp
    xe host-enable uuid="$h"
  fi
  echo "Multipathing XAPI : $(mp_flag "$n")"
  ntp_setup "$h"
  # Multipath : polling_interval et fast_io_fail_tmo ne sont lus que dans defaults
  cat > /etc/multipath/conf.d/custom.conf <<'EOC'
# DataCore SANsymphony HCI - no_path_retry 6 x polling 10 s = ~60 s < timeout HA 120 s
# polling_interval et fast_io_fail_tmo ne sont pris en compte que dans defaults
# (fast_io_fail_tmo place dans devices est ignore par multipath-tools de XCP-ng 8.3)
defaults {
    polling_interval      10
    # multipathd applique fast_io_fail_tmo comme recovery_tmo des sessions iSCSI
    fast_io_fail_tmo      5
}
devices {
    device {
        vendor                "DataCore"
        product               "Virtual Disk"
        path_grouping_policy  group_by_prio
        path_selector         "round-robin 0"
        path_checker          tur
        prio                  alua
        # Handler ALUA pilote par dm-multipath : relecture de l'etat ALUA a chaque activation d'un
        # groupe de chemins (bascule, failback). Sans lui, le cache du noyau peut garder des chemins
        # 'unavailable' apres le retour d'une VM DataCore -> I/O rejetee en silence, fence (section 10)
        hardware_handler      "1 alua"
        failback              immediate
        features              "0"
        no_path_retry         6
    }
}
EOC
  multipathd reconfigure
  multipathd show config | sed -n '/^defaults {/,/^}/p' | grep -E 'polling_interval|fast_io_fail_tmo'
  multipathd show config | sed -n '/"Virtual Disk"/,/}/p' | grep -E 'no_path_retry|hardware_handler'
  [[ $(multipathd show topology) == *"hwhandler='0'"* ]] \
    && echo "ATTENTION : map DataCore sans handler ALUA (hwhandler='0') -> 'multipath -r' hors HA, puis controler 'multipathd show topology'"
  # Taches planifiees : relogin (sessions et etat ALUA du noyau) et check (supervision).
  # PATH fixe explicitement : celui de cron par defaut (/usr/bin:/bin) ne contient ni multipathd ni iscsiadm.
  rm -f /etc/cron.d/datacore-check
  cat > /etc/cron.d/datacore-xcp <<EOC
# datacore-xcp.sh - installe par 'host N' (relogin chaque minute, check toutes les 5 minutes)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root $SELF relogin >/dev/null 2>&1
*/5 * * * * root $SELF check >/dev/null 2>&1
EOC
  echo "Taches planifiees : /etc/cron.d/datacore-xcp (relogin, check)"
  echo "IQN a declarer dans DataCore pour ${HOSTS[$n]} : $(cur_iqn)"
}

# ---------------------------------------------------------------- mpverify
cmd_mpverify() {
  # La configuration multipath effective est-elle toujours celle ecrite par 'host N' ? Une mise a jour
  # XCP-ng peut remplacer les fichiers multipath (guide DataCore XenServer) : defaults, bloc DataCore,
  # handler ALUA des maps
  local cfg d bad=0
  [[ -f /etc/multipath/conf.d/custom.conf ]] || { echo "ECART : /etc/multipath/conf.d/custom.conf absent"; bad=1; }
  grep -q '^PATH=' /etc/cron.d/datacore-xcp 2>/dev/null || { echo "ECART : /etc/cron.d/datacore-xcp absent ou sans PATH (relogin et check ne s'executent pas)"; bad=1; }
  cfg=$(multipathd show config 2>/dev/null) || { echo "ECART : multipathd ne repond pas"; return 1; }
  d=$(sed -n '/^defaults {/,/^}/p' <<<"$cfg")
  grep -Eq '^[[:space:]]*polling_interval[[:space:]]+10$' <<<"$d" || { echo "ECART : defaults sans polling_interval 10"; bad=1; }
  grep -Eq '^[[:space:]]*fast_io_fail_tmo[[:space:]]+5$' <<<"$d" || { echo "ECART : defaults sans fast_io_fail_tmo 5"; bad=1; }
  d=$(sed -n '/"Virtual Disk"/,/}/p' <<<"$cfg")
  grep -Eq '^[[:space:]]*no_path_retry[[:space:]]+6$' <<<"$d" || { echo "ECART : bloc DataCore sans no_path_retry 6"; bad=1; }
  grep -Eq 'hardware_handler[[:space:]]+"1 alua"' <<<"$d" || { echo "ECART : bloc DataCore sans hardware_handler \"1 alua\""; bad=1; }
  [[ $(multipathd show topology 2>/dev/null) == *"hwhandler='0'"* ]] && { echo "ECART : map avec hwhandler='0'"; bad=1; }
  ((bad)) && { echo "-> ./datacore-xcp.sh host $(local_node) sur cet hote (idempotent)"; return 1; }
  echo "Configuration multipath OK"
}

# ---------------------------------------------------------------- netcheck
cmd_netcheck() {
  local n p r ip rc=0; n=$(local_node) || exit 1; p=$((3-n))
  for r in DC-FE1 DC-FE2; do
    ip="${SUBNET[$r]}.${HOST_OCT[$p]}"
    if ping -M do -s $((MTU - 28)) -c 3 -W 2 "$ip" >/dev/null 2>&1; then echo "$r -> $ip (dom0 ${HOSTS[$p]}) MTU $MTU : OK"
    else echo "$r -> $ip (dom0 ${HOSTS[$p]}) MTU $MTU : ECHEC"; rc=1; fi
  done
  return $rc
}

# ---------------------------------------------------------------- passthrough
cmd_pci_check() {
  node "${1:-}"; local n=$1 b bad=0 disks d l p pv src; on_node "$n"; bdf_set "$n"; b=${PCI_BDF[$n]}
  lspci -nnk -s "$b"
  xl dmesg | grep -ci 'I/O virtualisation enabled' >/dev/null && echo "IOMMU : actif" \
    || { echo "BLOQUANT : IOMMU/VT-d inactif (BIOS)"; bad=1; }
  disks=$(for l in /dev/disk/by-path/pci-"$b"-*; do
            d=$(readlink -f "$l"); p=$(lsblk -ndo PKNAME "$d" 2>/dev/null); echo "${p:-${d##*/}}"
          done | sort -u)
  echo "Disques derriere $b : ${disks:-aucun (deja masque ?)}"
  src=$(findmnt -no SOURCE /)
  for d in $disks; do
    lsblk -nrso NAME "$src" | grep -cx "$d" >/dev/null && { echo "BLOQUANT : /dev/$d porte la racine dom0"; bad=1; }
    for pv in $(pvs --noheadings -o pv_name 2>/dev/null); do
      lsblk -nrso NAME "$pv" 2>/dev/null | grep -cx "$d" >/dev/null && { echo "BLOQUANT : /dev/$d porte le PV $pv (SR local)"; bad=1; }
    done
  done
  echo "== Disques de dom0 : racine et SR local doivent etre sur le controleur de boot"
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT; pvs 2>/dev/null
  echo "Parametre actuel : $(/opt/xensource/libexec/xen-cmdline --get-dom0 xen-pciback.hide)"
  xl pci-assignable-list
  return $bad
}
cmd_pci_hide() {
  node "${1:-}"; local n=$1 o pci; o=$((3-n))
  # Un seul hote en reboot a la fois : pendant le reboot du master, l'autre hote n'a plus de XAPI utilisable
  host_live "$o" || die "${HOSTS[$o]} pas encore revenu (host-metrics-live=false) : attendre son retour"
  cmd_pci_check "$n" || die "controles en echec, masquage annule"
  pci=$(xe pci-list host-uuid="$(local_host)" pci-id="${PCI_BDF[$n]}" --minimal)
  [[ -n $pci && $pci != *,* ]] || die "PCI ${PCI_BDF[$n]} introuvable ou ambigu"
  xe pci-disable-dom0-access uuid="$pci"
  echo "Nouveau parametre : $(/opt/xensource/libexec/xen-cmdline --get-dom0 xen-pciback.hide)"
  [[ $(xe pool-list params=master --minimal) == $(local_host) ]] \
    && echo "ATTENTION : reboot du master ; ${HOSTS[$o]} n'aura plus de commandes xe jusqu'a son retour"
  ask "Le BDF affiche est-il bien celui du HBA de stockage ? Redemarrer maintenant" && reboot
}
cmd_dcpci() {
  master; node "${1:-}"; local n=$1 vm; bdf_set "$n"; vm=$(vm_uuid "$n")
  [[ -n $vm ]] || die "${DC_VMS[$n]} absente : lancer 'dcvm $n'"
  [[ $(vm_state "$n") == halted ]] || die "${DC_VMS[$n]} doit etre arretee (arret Windows) avant l'ajout du HBA"
  [[ $(xe vm-param-get uuid="$vm" param-name=PV-drivers-detected 2>/dev/null) == true ]] \
    || echo "ATTENTION : PV tools non detectees au dernier demarrage : les installer avant le HBA"
  xe vm-param-set uuid="$vm" other-config:pci=0/"${PCI_BDF[$n]}"
  echo "HBA ${PCI_BDF[$n]} attache a ${DC_VMS[$n]}. Demarrage : xe vm-start uuid=$vm on=${HOSTS[$n]}"
}

# ---------------------------------------------------------------- dcvm N
local_sr() {
  local h=$1 s c=()
  for s in $(xe pbd-list host-uuid="$h" params=sr-uuid --minimal | tr , ' '); do
    [[ $(xe sr-param-get uuid="$s" param-name=shared) == false &&
       $(xe sr-param-get uuid="$s" param-name=content-type) == user ]] && c+=("$s")
  done
  [[ ${#c[@]} -eq 1 ]] || die "SR local ambigu (${#c[@]} candidats) : renseigner LOCAL_SR"
  echo "${c[0]}"
}
cmd_dcvm() {
  master; node "${1:-}"; local n=$1 h sr vm vdi vbd v i r mac ram mg
  h=$(host_uuid "$n"); [[ -z $(vm_uuid "$n") ]] || die "${DC_VMS[$n]} existe deja"
  [[ -n $(xe template-list name-label="$WIN_TEMPLATE" --minimal) ]] || {
    xe template-list params=name-label --minimal | tr , '\n' | grep -i windows
    die "modele '$WIN_TEMPLATE' introuvable : reprendre un nom exact de la liste ci-dessus dans WIN_TEMPLATE"; }
  # VIF de management de la VM DataCore : DC_MGMT_NET s'il est renseigne (reseau dedie, section 2), sinon MGMT_NET
  mg=${DC_MGMT_NET:-$MGMT_NET}
  for r in "$mg" DC-FE1 DC-FE2 DC-MR1 DC-MR2; do
    v=$(xe network-list name-label="$r" --minimal)
    [[ -n $v && $v != *,* ]] || die "reseau '$r' introuvable ou ambigu (xe network-list params=name-label)"
  done
  sr=${LOCAL_SR[$n]:-$(local_sr "$h")} || exit 1
  vm=$(xe vm-install template="$WIN_TEMPLATE" new-name-label="${DC_VMS[$n]}" sr-uuid="$sr") || die "vm-install"
  # Disque systeme en VHD : qcow2 echoue au demarrage avec sm 3.2.12 (SR_BACKEND_FAILURE_46)
  for vbd in $(xe vbd-list vm-uuid="$vm" type=Disk --minimal | tr , ' '); do
    vdi=$(xe vbd-param-get uuid="$vbd" param-name=vdi-uuid); xe vbd-destroy uuid="$vbd"; xe vdi-destroy uuid="$vdi"
  done
  vdi=$(xe vdi-create sr-uuid="$sr" name-label="${DC_VMS[$n]}-OS" type=user \
        virtual-size="${DC_DISK_GIB}GiB" sm-config:image-format=vhd)
  xe vbd-create vm-uuid="$vm" vdi-uuid="$vdi" device=0 bootable=true mode=RW type=Disk >/dev/null
  # CPU prioritaire, RAM statique (pas de ballooning), pas de pilotes PV via Windows Update
  ram=$((DC_RAM_GIB * 1024**3))
  xe vm-param-set uuid="$vm" VCPUs-max="$DC_VCPU"
  xe vm-param-set uuid="$vm" VCPUs-at-startup="$DC_VCPU"
  xe vm-memory-limits-set uuid="$vm" static-min=$ram dynamic-min=$ram dynamic-max=$ram static-max=$ram
  xe vm-param-set uuid="$vm" VCPUs-params:weight=65535 affinity="$h" platform:cores-per-socket="$DC_VCPU" \
     has-vendor-device=false other-config:auto_poweron=true ha-restart-priority=""
  [[ -n ${DC_VCPU_MASK[$n]} ]] && xe vm-param-set uuid="$vm" VCPUs-params:mask="${DC_VCPU_MASK[$n]}"
  # VIF a MAC fixes 02:dc:00:0N:00:0i -> identification et renommage cote Windows
  for v in $(xe vif-list vm-uuid="$vm" --minimal | tr , ' '); do xe vif-destroy uuid="$v"; done
  i=0
  for r in "$mg" DC-FE1 DC-FE2 DC-MR1 DC-MR2; do
    mac=$(printf '02:dc:00:%02x:00:%02x' "$n" "$i")
    xe vif-create vm-uuid="$vm" network-uuid="$(xe network-list name-label="$r" --minimal)" device=$i mac=$mac >/dev/null
    echo "  VIF $i  $mac  $r"; i=$((i+1))
  done
  [[ -n $WIN_ISO ]] && xe vm-cd-add uuid="$vm" cd-name="$WIN_ISO" device=3
  xe pool-param-set uuid="$(pool)" other-config:auto_poweron=true
  echo "${DC_VMS[$n]} creee SANS le HBA (ajout par 'dcpci $n' apres Windows et PV tools)."
  echo "Carte de management Windows : MAC $(printf '02-DC-00-%02X-00-00' "$n")"
  echo "Demarrage : xe vm-start uuid=$vm on=${HOSTS[$n]}"
}

# ---------------------------------------------------------------- iSCSI / SR / HA
lun_sr() {   # SR DataCore portant la LUN $1 (vide si aucun)
  local s p
  for s in "$SR_NAME" "$HB_SR_NAME"; do
    p=$(sr_pbds "$s" | awk '{print $1}')
    [[ -n $p && $(xe pbd-param-get uuid="$p" param-name=device-config param-key=SCSIid 2>/dev/null) == "$1" ]] && echo "$s"
  done
}
dc_luns() {  # une ligne par LUN DataCore vue par l'hote local : chemins SCSIid taille [SR]
  local s d id c sz sid=/usr/lib/udev/scsi_id; [[ -x $sid ]] || sid=/lib/udev/scsi_id
  for s in /sys/block/sd*; do
    d=/dev/${s##*/}; id=$($sid -g -u -d "$d" 2>/dev/null) || continue
    [[ $id == 360030d90* ]] && echo "$id $(( $(blockdev --getsize64 "$d") / 1024**3 ))GiB"
  done | sort | uniq -c | while read -r c id sz; do echo "$c $id $sz $(lun_sr "$id")"; done
}
cmd_iscsi() {
  local p out ns
  echo "Initiateur : $(cur_iqn)"
  for p in $(portals | tr , ' '); do
    iscsiadm -m discovery -t sendtargets -p "$p:3260" >/dev/null 2>&1 \
      && iscsiadm -m node -p "$p:3260" --login >/dev/null 2>&1
  done
  iscsiadm -m session --rescan >/dev/null 2>&1; sleep 5
  iscsiadm -m session 2>/dev/null
  ns=$(iscsiadm -m session 2>/dev/null | wc -l)
  echo "Sessions : $ns (4 attendues : FE1+FE2 de ${DC_VMS[1]} et ${DC_VMS[2]})"
  out=$(dc_luns)
  if [[ -z $out ]]; then
    echo "Aucune LUN DataCore : normal avant le service des vDisks -> Refresh des ports dans la DMC, puis declaration de l'hote"
  else
    echo; echo "Chemins  SCSIid  Taille  SR   (4 chemins attendus par LUN)"; echo "$out"
  fi
  echo "recovery_tmo effectif (nb sessions, valeur) : $(rec_tmo)   attendu : 5, alerte au-dela de $ISCSI_TMO_MAX"
}
alua_stale() {   # chemins 'ready' (multipathd) que le cache ALUA du noyau ne voit pas actifs : "sdX(etat) ..."
  local d m t st o=""
  while read -r d m t; do
    [[ $m == 360030d90* && $t == ready ]] || continue
    st=$(cat "/sys/block/$d/device/access_state" 2>/dev/null) || continue
    [[ $st == active* ]] || o+=" $d($st)"
  done < <(multipathd show paths format "%d %m %T" 2>/dev/null | tail -n +2)
  echo "${o# }"
}
alua_heal() {
  # Cache ALUA du noyau perime (scsi_dh_alua) : apres le retour d'une VM DataCore, un demarrage a froid
  # ou une coupure d'acces a DataCore, des chemins peuvent rester 'unavailable' pour le noyau alors que
  # multipathd les voit 'ready' ; le SR est attache avec 4 chemins mais l'I/O est rejetee. Relecture par
  # device, puis, si cela ne suffit pas, rescan des sessions iSCSI (ce que fait la commande 'iscsi').
  # Code retour 1 si des chemins restent incoherents. Syslog uniquement quand la situation change.
  local s d left f=/run/datacore-xcp-alua.state
  s=$(alua_stale); [[ -z $s ]] && { rm -f "$f"; return 0; }
  for d in $s; do echo 1 > "/sys/block/${d%%\(*}/device/rescan"; done 2>/dev/null
  sleep 3
  [[ -n $(alua_stale) ]] && { iscsiadm -m session --rescan >/dev/null 2>&1; sleep 5; }
  left=$(alua_stale)
  echo "Etat ALUA du noyau relu : $s${left:+ - encore incoherent : $left}"
  [[ $(cat "$f" 2>/dev/null) == "$s|$left" ]] \
    || logger -t datacore-xcp "Etat ALUA du noyau relu : $s${left:+ - encore incoherent : $left}"
  if [[ -n $left ]]; then echo "$s|$left" > "$f"; return 1; fi
  rm -f "$f"
}
cmd_relogin() {
  # Au boot, SM tente les 4 portails avant que la VM DataCore locale ecoute : echec de connexion
  # initiale, donc aucune session a recuperer et aucune nouvelle tentative (SMlog : 'No route to host',
  # 'Connection refused'). Relance le login vers tout portail sans session qui repond sur 3260,
  # puis relit l'etat ALUA du noyau sur les chemins (alua_heal).
  # N'agit que si un SR DataCore est attache sur cet hote (pas apres 'stop', ni si XAPI ne repond pas).
  local p s u n=0 h ss
  exec 9>/run/datacore-xcp-relogin.lock; flock -n 9 || return 0
  h=$(local_host)
  for s in "$SR_NAME" "$HB_SR_NAME"; do
    u=$(timeout 20 xe sr-list name-label="$s" --minimal 2>/dev/null); [[ -n $u ]] || continue
    [[ -n $(timeout 20 xe pbd-list host-uuid="$h" sr-uuid="$u" currently-attached=true --minimal 2>/dev/null) ]] && n=1
  done
  ((n)) || { echo "Aucun SR DataCore attache sur cet hote : rien a faire"; return 0; }
  n=0; ss=$(iscsiadm -m session 2>/dev/null)
  for p in $(portals | tr , ' '); do
    [[ $ss == *" $p:3260,"* ]] && continue    # session presente (connectee ou en recuperation)
    timeout 3 bash -c "</dev/tcp/$p/3260" 2>/dev/null || { echo "$p : port 3260 ferme"; continue; }
    if iscsiadm -m discovery -t sendtargets -p "$p:3260" >/dev/null 2>&1 \
       && iscsiadm -m node -p "$p:3260" --login >/dev/null 2>&1; then
      logger -t datacore-xcp "Session iSCSI retablie vers $p"; echo "$p : session retablie"; n=$((n+1))
    else
      logger -t datacore-xcp "Echec du login iSCSI vers $p"; echo "$p : echec du login"
    fi
  done
  ((n)) && { iscsiadm -m session --rescan >/dev/null 2>&1; sleep 5; }
  alua_heal
  echo "Sessions : $(iscsiadm -m session 2>/dev/null | wc -l) (4 attendues)"
}
wait_paths() {
  # Attend 4 chemins 'ready' par LUN DataCore, actifs pour le noyau, sur l'hote N (relogin a chaque tour), 10 min max
  local n=$1 t rc
  echo "Controle des chemins sur ${HOSTS[$n]} (10 min max)..."
  for t in $(seq 40); do
    on_host "$n" relogin >/dev/null 2>&1
    on_host "$n" check --quiet >/dev/null 2>&1; rc=$?
    ((rc == 0)) && { echo "  ${HOSTS[$n]} : 4 chemins par LUN"; return 0; }
    if ((rc == 255)); then
      echo "SSH vers ${HOSTS[$n]} impossible ('./datacore-xcp.sh ssh-setup' installe les cles)."
      ask "'./datacore-xcp.sh check' affiche-t-il 'Multipath DataCore OK' sur ${HOSTS[$n]} ?" && return 0
      die "chemins non verifies sur ${HOSTS[$n]}"
    fi
    sleep 15
  done
  die "${HOSTS[$n]} : chemins incomplets apres 10 min -> 'check' puis 'relogin' (ou 'iscsi') sur cet hote"
}
mk_sr() {
  xe sr-create name-label="$1" name-description="$2" shared=true type=lvmoiscsi content-type=user \
     device-config:target="$(portals)" device-config:targetIQN='*' device-config:SCSIid="$3"
}
cmd_sr() {
  master; mp_check; [[ ${1:-} == 3* ]] || die "usage : sr SCSIID (voir ./datacore-xcp.sh iscsi)"
  local sr; sr=$(mk_sr "$SR_NAME" "vDisk DataCore miroir" "$1") || die "sr-create"
  xe pool-param-set uuid="$(pool)" default-SR="$sr"
  xe pbd-list sr-uuid="$sr" params=host-name-label,currently-attached
}
wait_srs() {
  local t s p ok=0
  echo "Attente des SR DataCore (15 min max)..."
  for t in $(seq 60); do
    ok=1
    for s in "$SR_NAME" "$HB_SR_NAME"; do
      for p in $(sr_pbds "$s" currently-attached=false); do xe pbd-plug uuid="$p" 2>/dev/null || ok=0; done
    done
    ((ok)) && break; sleep 15
  done
  ((ok)) || die "SR non attaches : verifier la DMC (vDisk hors service, double panne ?)"
  echo "SR attaches sur les 2 hotes."
}
ha_alert() {
  # HA active avec un timeout different de HA_TIMEOUT : une HA desactivee puis reactivee depuis
  # Xen Orchestra revient au defaut XAPI, et une coupure de lien DataCore finit alors en fence.
  # Controle sur le master uniquement. $1 = 1 : pas de syslog.
  local p t
  [[ $(timeout 20 xe pool-list params=master --minimal 2>/dev/null) == "$(local_host)" ]] || return 0
  p=$(timeout 20 xe pool-list --minimal 2>/dev/null); [[ -n $p ]] || return 0
  [[ $(timeout 20 xe pool-param-get uuid="$p" param-name=ha-enabled 2>/dev/null) == true ]] || return 0
  t=$(timeout 20 xe pool-param-get uuid="$p" param-name=ha-configuration param-key=timeout 2>/dev/null)
  [[ $t == "$HA_TIMEOUT" ]] && return 0
  echo "ALERTE : HA active avec le timeout '${t:-defaut XAPI}' au lieu de $HA_TIMEOUT s -> './datacore-xcp.sh ha-on' sur le master"
  ((${1:-0})) || logger -t datacore-xcp "Timeout HA ${t:-defaut XAPI} au lieu de $HA_TIMEOUT s : ha-on sur le master"
  return 1
}
ha_on() {
  local p n hb free; p=$(pool); hb=$(sr_uuid "$HB_SR_NAME")
  [[ -n $hb ]] || die "SR $HB_SR_NAME absent : lancer 'ha SCSIID'"
  if ha_enabled; then
    [[ $(ha_tmo) == "$HA_TIMEOUT" ]] && { echo "HA deja active, timeout $HA_TIMEOUT s"; return; }
    # Le timeout ne se change qu'en desactivant puis reactivant la HA
    echo "ATTENTION : HA active avec le timeout '$(ha_tmo)' (vide = defaut XAPI) au lieu de $HA_TIMEOUT s."
    echo "La HA a probablement ete activee hors de ce script (Xen Orchestra). Un timeout bas provoque un fence a la coupure d'un lien DataCore."
    ask "Desactiver la HA et la reactiver avec le timeout $HA_TIMEOUT s ?" || die "timeout HA non corrige"
    xe pool-ha-disable || die "pool-ha-disable"
  fi
  # XAPI (Xha_statefile.ha_fits_sr) alloue ~3,7 Gio (statefile + metadonnees, LVM thick) sur un pool
  # de 2 hotes. Controle inutile si ces VDI existent deja : XAPI les reutilise.
  if [[ -z $(xe vdi-list sr-uuid="$hb" type=ha_statefile --minimal) || -z $(xe vdi-list sr-uuid="$hb" type=redo_log --minimal) ]]; then
    free=$(( $(xe sr-param-get uuid="$hb" param-name=physical-size) - $(xe sr-param-get uuid="$hb" param-name=physical-utilisation) ))
    (( free >= HB_MIN_FREE_GIB * 1024**3 )) \
      || die "SR $HB_SR_NAME : $((free / 1024**2)) Mio libres, XAPI en exige ~3,7 Gio : agrandir le vDisk heartbeat (10 Go)"
  fi
  xe host-list params=name-label,enabled,host-metrics-live
  for n in 1 2; do [[ $(vm_state "$n") == running ]] || die "${DC_VMS[$n]} arretee : HA non activee"; done
  ask "Tous les vDisks sont-ils 'Up to date' sur les 2 serveurs dans la DMC ?" || die "HA non activee"
  for n in 1 2; do wait_paths "$n"; done
  xe pool-ha-enable heartbeat-sr-uuids="$hb" ha-config:timeout="$HA_TIMEOUT" || die "pool-ha-enable"
  xe pool-param-set uuid="$p" ha-host-failures-to-tolerate=1
  echo "HA active ; plan pour $(xe pool-param-get uuid="$p" param-name=ha-plan-exists-for) panne d'hote"
  echo "Timeout HA : pool '$(ha_tmo)' s, xhad.conf '$(xha_tmo)' s (attendu : $HA_TIMEOUT)"
  [[ $(ha_tmo) == "$HA_TIMEOUT" ]] || echo "ATTENTION : timeout non enregistre dans le pool : controler 'xe pool-param-get uuid=$p param-name=ha-configuration'"
  echo "Rappel : ne jamais desactiver ni activer la HA depuis Xen Orchestra (timeout remis au defaut) : 'ha-off' / 'ha-on' uniquement."
}
cmd_ha() {
  master; mp_check; [[ ${1:-} == 3* ]] || die "usage : ha SCSIID_HEARTBEAT"
  [[ -n $(sr_uuid "$HB_SR_NAME") ]] || mk_sr "$HB_SR_NAME" "Statefile HA - aucune VM" "$1" >/dev/null || die "sr-create"
  local n; for n in 1 2; do xe vm-param-set uuid="$(vm_uuid "$n")" ha-restart-priority=""; done
  ha_on
}
cmd_ha_off() {
  master
  ha_enabled || { echo "HA deja desactivee"; return 0; }
  xe pool-ha-disable || die "pool-ha-disable"
  echo "HA desactivee. La reactiver par './datacore-xcp.sh ha-on' (timeout $HA_TIMEOUT s), jamais depuis Xen Orchestra."
}
cmd_protect() {
  master; local v p vdi s bad=0; p=$(pool)
  v=$(xe vm-list name-label="${1:-}" --minimal)
  [[ -z $v && -n ${1:-} ]] && v=$(xe vm-list uuid="$1" --minimal 2>/dev/null)
  [[ -n $v && $v != *,* ]] || die "VM introuvable ou ambigue (nom ou UUID)"
  for vdi in $(xe vbd-list vm-uuid="$v" type=Disk params=vdi-uuid --minimal | tr , ' '); do
    s=$(xe vdi-param-get uuid="$vdi" param-name=sr-uuid)
    [[ $(xe sr-param-get uuid="$s" param-name=shared) == true ]] \
      || { echo "Disque sur SR non partage : $(xe sr-param-get uuid="$s" param-name=name-label)"; bad=1; }
  done
  ((bad)) && die "VM non agile : protection refusee"
  [[ -n $(xe vbd-list vm-uuid="$v" type=CD empty=false --minimal) ]] && echo "ATTENTION : CD monte, a ejecter s'il est sur un SR local"
  xe vm-param-set uuid="$v" ha-restart-priority=restart order="${2:-1}" || die "refuse par XAPI (capacite du plan HA ?)"
  [[ $(xe pool-param-get uuid="$p" param-name=ha-enabled) == true ]] \
    && echo "Plan HA : $(xe pool-param-get uuid="$p" param-name=ha-plan-exists-for) panne(s) couverte(s), 1 attendu"
}

# ---------------------------------------------------------------- exploitation
shutdown_vm() {   # code retour 2 si l'arret a du etre force
  local v=$1 name; name=$(xe vm-param-get uuid="$v" param-name=name-label)
  echo "Arret $name"
  timeout "$SHUTDOWN_TIMEOUT" xe vm-shutdown uuid="$v" && return
  echo "  $name : pas d'arret propre en ${SHUTDOWN_TIMEOUT} s -> arret force"
  xe vm-shutdown uuid="$v" --force; return 2
}
# ---------------------------------------------------------------- ordre DataCore
# Arret : DC-02 puis DC-01 (DC-01 toujours en dernier). Redemarrage : dernier arrete en premier.
# Le dernier arret ordonne est memorise dans la base du pool (repliquee, survit a un changement de master) :
#   other-config:datacore-last-stopped = N:dmc | N:ups | N:ups-force   (N = noeud arrete en dernier)
# 'start' efface la cle une fois les 2 serveurs DataCore en service : absente = arret non maitrise.
LS_KEY=datacore-last-stopped
ls_get()    { xe pool-param-get uuid="$(pool)" param-name=other-config param-key=$LS_KEY 2>/dev/null; }
ls_set()    { xe pool-param-set uuid="$(pool)" other-config:$LS_KEY="$1"; }
ls_clear()  { xe pool-param-remove uuid="$(pool)" param-name=other-config param-key=$LS_KEY 2>/dev/null || true; }
dc_serves() { timeout 3 bash -c "</dev/tcp/$1/3260" 2>/dev/null; }   # cible iSCSI DataCore a l'ecoute
start_dc() {  # start_dc N dmc|ups : demarre la VM DataCore N et attend que DataCore serve sur FE1
  local n=$1 ip=${SUBNET[DC-FE1]}.${DC_OCT[$1]} t
  [[ $(vm_state "$n") == running ]] || xe vm-start uuid="$(vm_uuid "$n")" on="${HOSTS[$n]}" || die "demarrage de ${DC_VMS[$n]} impossible"
  if [[ $2 == dmc ]]; then
    echo "${DC_VMS[$n]} demarre : arrete dans la DMC, DataCore ne repart pas seul au boot de Windows."
    until ask "'Start DataCore Server' fait sur ${DC_VMS[$n]} dans la DMC ?"; do :; done
  fi
  echo "Attente de DataCore sur ${DC_VMS[$n]} ($ip:3260, 15 min max)..."
  while :; do
    for t in $(seq 90); do dc_serves "$ip" && { echo "${DC_VMS[$n]} : DataCore en service"; return; }; sleep 10; done
    ask "${DC_VMS[$n]} ne repond pas sur $ip:3260. Continuer d'attendre ?" || die "demarrage interrompu : ${DC_VMS[$n]} hors service"
  done
}
start_protected() {
  local v
  for v in $(xe vm-list ha-restart-priority=restart power-state=halted --minimal | tr , ' '); do
    echo "$(xe vm-param-get uuid="$v" param-name=order) $v"
  done | sort -n | while read -r _ v; do
    echo "Demarrage $(xe vm-param-get uuid="$v" param-name=name-label)"
    xe vm-start uuid="$v" || echo "  ECHEC : a traiter a la main"
  done
}
cmd_status() {
  local n s u
  echo "== Hotes"; xe host-list params=name-label,enabled,host-metrics-live
  echo "== Multipathing XAPI"; for n in 1 2; do echo "${HOSTS[$n]} : $(mp_flag "$n")"; done
  echo "== VM DataCore"
  for n in 1 2; do
    u=$(vm_uuid "$n")
    echo "${DC_VMS[$n]} : $(vm_state "$n")  HBA : $([[ -n $u ]] && xe vm-param-get uuid="$u" param-name=other-config param-key=pci 2>/dev/null || echo 'non attache')"
  done
  for s in "$SR_NAME" "$HB_SR_NAME"; do
    echo "== $s"; [[ -n $(sr_uuid "$s") ]] && xe pbd-list sr-uuid="$(sr_uuid "$s")" params=host-name-label,currently-attached
  done
  echo "== HA active : $(xe pool-param-get uuid="$(pool)" param-name=ha-enabled)   timeout : pool '$(ha_tmo)' s, xhad.conf (hote local) '$(xha_tmo)' s   attendu : $HA_TIMEOUT"
  ha_alert 1
  echo "== IQN (hote local) : $(cur_iqn)"
  echo "== Multipath (hote local)"; multipathd show topology | grep -E 'DataCore|hwhandler|prio='
  echo "== Sessions iSCSI (hote local) : $(iscsiadm -m session 2>/dev/null | wc -l) (4 attendues)"
  echo "== Chemins (hote local) : device, checker, prio multipathd, etat ALUA du noyau"
  multipathd show paths format "%d %m %T %p" | awk 'NR>1 && $2 ~ /^360030d90/ {print $1, $3, $4}' |
    while read -r d t p; do printf "   %-5s %-7s %-3s %s\n" "$d" "$t" "$p" "$(cat "/sys/block/$d/device/access_state" 2>/dev/null)"; done
  s=$(alua_stale); [[ -n $s ]] && echo "   ALERTE : chemins 'ready' non actifs pour le noyau : $s -> './datacore-xcp.sh check'"
  echo "== recovery_tmo iSCSI (hote local, nb sessions puis valeur) : $(rec_tmo)"
  for s in /sys/class/iscsi_session/session*/recovery_tmo; do
    (( $(cat "$s") <= ISCSI_TMO_MAX )) || echo "   ALERTE : ${s%/recovery_tmo} a $(cat "$s") s (> $ISCSI_TMO_MAX s)"
  done
  echo "== Configuration multipath (hote local)"; cmd_mpverify
  echo "== SSH vers l'autre hote : $(n=$(local_node) && ssh_ok $((3-n)) && echo OK || echo "ECHEC -> './datacore-xcp.sh ssh-setup'")"
  echo "== md5 (identiques sur les 2 hotes, sinon './datacore-xcp.sh sync')"; md5sum "$SELF" "$CONF"
}
cmd_check() {
  # 1) Etat ALUA du noyau incoherent : chemin 'ready' pour multipathd, non actif dans le cache
  #    scsi_dh_alua. Relecture par alua_heal (rescan du device, puis rescan des sessions).
  # 2) LUN DataCore avec moins de 4 chemins 'ready' (syslog sauf --quiet).
  # 3) Sur le master : HA active avec un timeout different de HA_TIMEOUT (syslog sauf --quiet).
  # Code retour 1 si l'un des trois subsiste.
  local out p rc=0 q=0; [[ ${1:-} == --quiet ]] && q=1
  p=$(multipathd show paths format "%m %T" 2>/dev/null) || { echo "multipathd ne repond pas"; return 1; }
  alua_heal || rc=1
  out=$(multipathd show paths format "%m %T" | awk 'NR>1 && $1 ~ /^360030d90/ {t[$1]++; if ($2=="ready") r[$1]++}
        END {for (m in t) if (r[m]+0 < 4) printf "%s : %d/4 chemins ready\n", m, r[m]+0}')
  if [[ -n $out ]]; then
    echo "$out"; ((q)) || logger -t datacore-xcp "Multipath degrade : $out"; rc=1
  fi
  ha_alert "$q" || rc=1
  ((rc)) || echo "Multipath DataCore OK"
  return $rc
}
cmd_start() {
  master; mp_check; local n k
  k=$(ls_get)
  if dc_running; then
    # Un serveur DataCore tourne deja : il porte les donnees a jour, l'ordre n'importe plus
    for n in 1 2; do [[ $(vm_state "$n") == running ]] || xe vm-start uuid="$(vm_uuid "$n")" on="${HOSTS[$n]}"; done
  else
    case $k in
      [12]:dmc|[12]:ups)
        n=${k%%:*}
        echo "Dernier arret ordonne (${k#*:}) : ${DC_VMS[$n]} arrete en dernier, redemarre en premier"
        start_dc "$n" "${k#*:}"; start_dc $((3-n)) "${k#*:}" ;;
      *)
        echo "ATTENTION : dernier arret non fait par 'stop' (cle $LS_KEY : ${k:-absente})."
        echo "Coupure, crash ou arret force : l'ordre d'arret des serveurs DataCore est inconnu."
        echo "Les 2 VM DataCore vont demarrer. Dans la DMC : identifier le serveur tombe en dernier,"
        echo "remettre en service sa copie uniquement (procedure 'double panne')."
        ask "Continuer ?" || die "demarrage interrompu"
        for n in 1 2; do [[ $(vm_state "$n") == running ]] || xe vm-start uuid="$(vm_uuid "$n")" on="${HOSTS[$n]}"; done
        ask "vDisks remis en service dans la DMC ?" || die "reprendre './datacore-xcp.sh start' apres traitement dans la DMC" ;;
    esac
  fi
  ls_clear
  wait_srs; ha_on; start_protected
  echo "VM non protegees : a demarrer a la main."
}
cmd_stop() {
  master; local ups=0 p v s n dc h m o a last mode rc; [[ ${1:-} == --ups ]] && ups=1
  # Ordre d'arret des hotes fixe par le role reel : le master peut avoir change (bascule HA)
  m=$(local_node) || exit 1; o=$((3-m))
  p=$(pool); dc=" $(vm_uuid 1) $(vm_uuid 2) "
  [[ $(xe pool-param-get uuid="$p" param-name=ha-enabled) == true ]] && xe pool-ha-disable
  for v in $(xe vm-list power-state=running is-control-domain=false --minimal | tr , ' '); do
    [[ $dc == *" $v "* ]] || shutdown_vm "$v" &
  done; wait
  for s in "$SR_NAME" "$HB_SR_NAME"; do for v in $(sr_pbds "$s" currently-attached=true); do xe pbd-unplug uuid="$v"; done; done
  ((ups)) && echo "Mode onduleur : arret Windows des VM DataCore sans passage par la DMC"
  # DataCore : DC-02 puis DC-01 ; un serveur deja arrete (maintenance) est saute. Memorise le dernier arrete.
  last=""; mode=dmc; ((ups)) && mode=ups
  for n in 2 1; do
    [[ $(vm_state "$n") == running ]] || { echo "${DC_VMS[$n]} deja arrete"; continue; }
    ((ups)) || ask "'Stop DataCore Server' fait sur ${DC_VMS[$n]} dans la DMC ?" || die "arret interrompu avant ${DC_VMS[$n]}"
    shutdown_vm "$(vm_uuid "$n")"
    rc=$?; last=$n:$mode
    ((rc == 2 && ups)) && last=$n:ups-force   # DataCore coupe sans arret propre
  done
  if [[ -n $last ]]; then ls_set "$last"; echo "Dernier arret DataCore memorise : $last"; fi
  if ((ups)); then
    # Master en dernier : c'est lui qui transmet l'arret a l'autre hote
    if host_live "$o"; then
      h=$(host_uuid "$o"); a=$(xe host-param-get uuid="$h" param-name=address)
      xe host-disable uuid="$h"; xe host-shutdown uuid="$h"
      # host-shutdown rend la main des l'arret accepte, avant l'arret effectif
      echo "Attente de l'arret de ${HOSTS[$o]} ($a), ${SHUTDOWN_TIMEOUT} s max"
      for _ in $(seq $((SHUTDOWN_TIMEOUT / 5))); do ping -c1 -W2 "$a" >/dev/null 2>&1 || break; sleep 3; done
      ping -c1 -W2 "$a" >/dev/null 2>&1 && echo "ATTENTION : ${HOSTS[$o]} repond encore, arret du master quand meme"
    else
      echo "${HOSTS[$o]} deja arrete (host-metrics-live=false)"
    fi
    h=$(host_uuid "$m"); xe host-disable uuid="$h"; xe host-shutdown uuid="$h"
  else
    echo "Arreter les hotes : ${HOSTS[$o]} puis ${HOSTS[$m]} (master), par xe host-disable + xe host-shutdown."
  fi
}
cmd_maint() {
  master; node "${1:-}"; local n=$1 h o v p; h=$(host_uuid "$n"); o=$(host_uuid $((3-n))); p=$(pool)
  ask "Tous les vDisks 'Up to date' sur les 2 serveurs ?" || die "maintenance annulee"
  [[ $(xe pool-param-get uuid="$p" param-name=ha-enabled) == true ]] && xe pool-ha-disable
  xe host-disable uuid="$h"
  for v in $(xe vm-list resident-on="$h" power-state=running is-control-domain=false --minimal | tr , ' '); do
    [[ $v == $(vm_uuid "$n") ]] && continue
    echo "Migration $(xe vm-param-get uuid="$v" param-name=name-label)"
    xe vm-migrate uuid="$v" host-uuid="$o" live=true || echo "  ECHEC : a traiter a la main"
  done
  ask "'Stop DataCore Server' fait sur ${DC_VMS[$n]} dans la DMC ?" || die "interrompu"
  xe vm-shutdown uuid="$(vm_uuid "$n")"
  echo "${HOSTS[$n]} pret : yum update, reboot, puis ./datacore-xcp.sh resume $n"
}
cmd_resume() {
  master; node "${1:-}"; local n=$1
  xe host-enable uuid="$(host_uuid "$n")"
  # Une mise a jour XCP-ng peut remplacer la configuration multipath : controle avant de relancer la VM DataCore
  local rc; on_host "$n" mpverify; rc=$?
  if ((rc == 255)); then
    echo "SSH vers ${HOSTS[$n]} en echec ('./datacore-xcp.sh ssh-setup' installe les cles)."
    ask "'./datacore-xcp.sh mpverify' affiche-t-il 'Configuration multipath OK' sur ${HOSTS[$n]} ?" \
      || die "configuration multipath non verifiee sur ${HOSTS[$n]}"
  elif ((rc)); then
    die "configuration multipath modifiee sur ${HOSTS[$n]} : './datacore-xcp.sh host $n' sur cet hote, puis relancer 'resume $n'"
  fi
  [[ $(vm_state "$n") == running ]] || xe vm-start uuid="$(vm_uuid "$n")" on="${HOSTS[$n]}"
  wait_srs
  echo "Attendre la fin de resynchronisation dans la DMC."; ha_on
  echo "Les VM migrees restent sur ${HOSTS[$((3-n))]} : les redistribuer a la main (xe vm-migrate)."
}
cmd_rescue() {
  echo "A utiliser uniquement si l'autre noeud est arrete ou lui aussi bloque (risque de split-brain)."
  ask "Continuer ?" || exit 1
  local u uu
  xe host-emergency-ha-disable --force
  uu=$(/opt/xensource/bin/static-vdis list | grep -oE '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' | sort -u)
  echo "VDI statiques : ${uu:-aucun}"
  if [[ -n $uu ]] && ask "Supprimer ces VDI statiques (statefile + metadonnees HA) ?"; then
    for u in $uu; do /opt/xensource/bin/static-vdis del "$u"; done
  fi
  systemctl is-active -q attach-static-vdis && systemctl kill attach-static-vdis
  xe-toolstack-restart; sleep 20
  xe host-enable uuid="$(local_host)"
  echo "Ensuite, sur le master : ./datacore-xcp.sh ha-off, puis ./datacore-xcp.sh start"
}

# ---------------------------------------------------------------- aiguillage
usage() {
  sed -n '2,4p' "$SELF"
  echo "Commandes : nics | ssh-setup | sync | pool-net | host N | netcheck | pci-check N | pci-hide N | dcvm N | dcpci N | iscsi | relogin | sr SCSIID | ha SCSIID | ha-on | ha-off | protect VM [ordre] | status | check | mpverify | start | stop [--ups] | maint N | resume N | rescue"
}
dispatch() {
  case $1 in
    nics)      cmd_nics ;;                  ssh-setup) cmd_ssh_setup ;;
    sync)      cmd_sync ;;
    pool-net)  cmd_pool_net ;;              host)     cmd_host "${2:-}" ;;
    netcheck)  cmd_netcheck ;;
    pci-check) cmd_pci_check "${2:-}" ;;    pci-hide) cmd_pci_hide "${2:-}" ;;
    dcvm)      cmd_dcvm "${2:-}" ;;         dcpci)    cmd_dcpci "${2:-}" ;;
    iscsi)     cmd_iscsi ;;                 relogin)  cmd_relogin ;;
    sr)        cmd_sr "${2:-}" ;;           ha)       cmd_ha "${2:-}" ;;
    ha-on)     master; ha_on ;;             ha-off)   cmd_ha_off ;;
    protect)   cmd_protect "${2:-}" "${3:-1}" ;;
    status)    cmd_status ;;                check)    cmd_check "${2:-}" ;;
    mpverify)  cmd_mpverify ;;
    start)     cmd_start ;;                 stop)     cmd_stop "${2:-}" ;;
    maint)     cmd_maint "${2:-}" ;;        resume)   cmd_resume "${2:-}" ;;
    rescue)    cmd_rescue ;;
    help)      usage ;;
  esac
}
# Chaque commande tourne dans un sous-shell : un 'die' interrompt la commande, pas le menu.
# Code retour = celui de la commande (pipefail), y compris pour 'check' et 'relogin' lances par cron.
run() {
  case $1 in
    nics|status|check|relogin|mpverify|help) ( dispatch "$@" ) ;;
    *) { echo "=== $(date '+%F %T') $(hostname) : $*"; dispatch "$@"; } 2>&1 | tee -a "$LOG" ;;
  esac
}

# ---------------------------------------------------------------- menu
pause() { local _; read -r -p "Entree pour revenir au menu " _ || true; }
ask_node() {
  local r; read -r -p "Noeud (1 = ${HOSTS[1]}, 2 = ${HOSTS[2]}) : " r
  [[ $r == [12] ]] || { echo "Noeud invalide" >&2; return 1; }
  echo "$r"
}
pick_lun() {
  local l c; mapfile -t l < <(dc_luns)
  ((${#l[@]})) || { echo "Aucune LUN DataCore vue par cet hote : lancer 'iscsi' et verifier les mappings dans la DMC" >&2; return 1; }
  echo "     Chemins  SCSIid  Taille  SR   (4 chemins attendus)" >&2
  for c in "${!l[@]}"; do printf '%3d) %s\n' $((c+1)) "${l[$c]}" >&2; done
  read -r -p "Numero de la LUN : " c
  [[ $c =~ ^[0-9]+$ ]] && ((c >= 1 && c <= ${#l[@]})) || { echo "Choix invalide" >&2; return 1; }
  set -- ${l[$((c-1))]}; echo "$2"
}
pick_vm() {
  local v dc l c p nm st
  dc=" $(vm_uuid 1) $(vm_uuid 2) "
  mapfile -t l < <(for v in $(xe vm-list is-control-domain=false is-a-template=false is-a-snapshot=false --minimal | tr , ' '); do
      [[ $dc == *" $v "* ]] && continue
      p=$(xe vm-param-get uuid="$v" param-name=ha-restart-priority)
      [[ -n $p ]] && p="$p ordre $(xe vm-param-get uuid="$v" param-name=order)"
      printf '%s\t%s\t%s\t%s\n' "$(xe vm-param-get uuid="$v" param-name=name-label)" \
        "$(xe vm-param-get uuid="$v" param-name=power-state)" "${p:--}" "$v"
    done | sort -f)
  ((${#l[@]})) || { echo "Aucune VM hors VM DataCore" >&2; return 1; }
  printf '     %-32s %-9s %s\n' VM Etat "Priorite HA" >&2
  for c in "${!l[@]}"; do
    IFS=$'\t' read -r nm st p _ <<< "${l[$c]}"; printf '%3d) %-32s %-9s %s\n' $((c+1)) "$nm" "$st" "$p" >&2
  done
  read -r -p "Numero de la VM : " c
  [[ $c =~ ^[0-9]+$ ]] && ((c >= 1 && c <= ${#l[@]})) || { echo "Choix invalide" >&2; return 1; }
  IFS=$'\t' read -r _ _ _ v <<< "${l[$((c-1))]}"; echo "$v"
}
menu_show() {
  local n role
  n=$( (local_node) 2>/dev/null ) || n="?"
  [[ $(xe pool-list params=master --minimal 2>/dev/null) == "$(local_host)" ]] && role=master || role=membre
  cat <<EOM

=== datacore-xcp.sh - $(hostname) : noeud $n, $role ===
 Preparation des hotes
   1) nics         Inventaire des cartes physiques               [M]
   2) ssh-setup    SSH par cle entre les deux hotes              [L]
   3) sync         Copie script et variables vers l'autre hote   [L]
   4) pool-net     Reseaux de stockage DC-FE / DC-MR             [M]
   5) host         IQN, IP FE, multipathing, NTP (noeud local)   [2]
   6) netcheck     Ping MTU FE vers l'autre dom0                 [2]
   7) pci-check    Controles passthrough HBA (noeud local)       [2]
   8) pci-hide     Masquage HBA et reboot (noeud local)          [2]
 VM DataCore
   9) dcvm         Creation d'une VM DataCore                    [M]
  10) dcpci        Attachement du HBA a une VM DataCore          [M]
 Stockage iSCSI et HA
  11) iscsi        Sessions iSCSI et LUN DataCore                [2]
  12) relogin      Reconnexion des portails, relecture ALUA      [2]
  13) sr           Creation du SR de donnees                     [M]
  14) ha           SR heartbeat et activation HA                 [M]
  15) ha-on        Activation HA, ou correction de son timeout   [M]
  16) ha-off       Desactivation HA avant operation planifiee    [M]
  17) protect      Protection HA d'une VM                        [M]
 Exploitation
  18) status       Etat general                                  [L]
  19) check        Chemins, etat ALUA du noyau, timeout HA       [L]
  20) mpverify     Configuration multipath effective             [L]
  21) start        Demarrage a froid du pool                     [M]
  22) stop         Arret du pool (normal ou onduleur)            [M]
  23) maint        Mise en maintenance d'un hote                 [M]
  24) resume       Retour de maintenance d'un hote               [M]
  25) rescue       Sortie de blocage attach-static-vdis          [L]
   h) aide    q) quitter          [M] master  [L] hote local  [2] chaque hote
EOM
}
menu() {
  local c n a id o
  # Ctrl+C interrompt la commande en cours et revient au menu
  trap 'echo " interrompu"' INT
  while :; do
    menu_show
    read -r -p "Choix : " c || { echo; return; }
    a=()
    case $c in
      1) a=(nics) ;;  2) a=(ssh-setup) ;;  3) a=(sync) ;;  4) a=(pool-net) ;;  6) a=(netcheck) ;;
      5|7|8)
        # Ces commandes ne s'executent que sur le noeud vise : N = noeud local
        n=$( (local_node) 2>/dev/null ) || { echo "Hote local absent de HOSTS"; pause; continue; }
        case $c in 5) a=(host "$n") ;; 7) a=(pci-check "$n") ;; 8) a=(pci-hide "$n") ;; esac ;;
      9|10|23|24)
        n=$(ask_node) || { pause; continue; }
        case $c in 9) a=(dcvm "$n") ;; 10) a=(dcpci "$n") ;; 23) a=(maint "$n") ;; 24) a=(resume "$n") ;; esac ;;
      11) a=(iscsi) ;;  12) a=(relogin) ;;
      13|14)
        id=$(pick_lun) || { pause; continue; }
        if [[ $c == 13 ]]; then a=(sr "$id"); else a=(ha "$id"); fi ;;
      15) a=(ha-on) ;;  16) a=(ha-off) ;;
      17)
        id=$(pick_vm) || { pause; continue; }
        read -r -p "Ordre de demarrage [1] : " o; o=${o:-1}
        [[ $o =~ ^[0-9]+$ ]] || { echo "Ordre invalide"; pause; continue; }
        a=(protect "$id" "$o") ;;
      18) a=(status) ;;  19) a=(check) ;;  20) a=(mpverify) ;;  21) a=(start) ;;
      22)
        read -r -p "Arret : 1) normal (Stop DataCore Server dans la DMC)  2) onduleur (--ups) : " o
        case $o in 1) a=(stop) ;; 2) a=(stop --ups) ;; *) echo "Choix invalide"; pause; continue ;; esac ;;
      25) a=(rescue) ;;
      h|H) usage; pause; continue ;;
      q|Q) return ;;
      *) echo "Choix invalide"; continue ;;
    esac
    echo "--> ./${SELF##*/} ${a[*]}"
    run "${a[@]}" || echo "--> code retour $?"
    pause
  done
}

# ---------------------------------------------------------------- principal
if (($#)); then
  [[ " $CMDS " == *" $1 "* ]] || { usage; exit 1; }
  run "$@"; exit
fi
[[ -t 0 ]] || { usage; exit 1; }
menu
