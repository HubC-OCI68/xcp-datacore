#!/bin/bash
# datacore-xcp.sh - DataCore SANsymphony HCI on an XCP-ng 8.3 pool (2 nodes)
# Usage: ./datacore-xcp.sh [command [args]]      (no argument: menu; ./datacore-xcp.sh help)
# Variables: datacore-xcp.conf in the same folder (or $DATACORE_XCP_CONF). No value to edit here.
set -uo pipefail
shopt -s nullglob
# cron runs with PATH=/usr/bin:/bin: multipathd and iscsiadm (sbin) would not be found
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/xensource/bin

SELF=$(readlink -f "$0")
CONF=${DATACORE_XCP_CONF:-$(dirname "$SELF")/datacore-xcp.conf}
LOG=/var/log/datacore-xcp.log
REQUIRED="HOSTS DC_VMS NIC SUBNET HOST_OCT DC_OCT MGMT_NET MTU NTP_SERVERS PCI_BDF DC_VCPU DC_RAM_GIB
          DC_DISK_GIB WIN_TEMPLATE SR_NAME HB_SR_NAME HA_TIMEOUT HB_MIN_FREE_GIB ISCSI_TMO_MAX SHUTDOWN_TIMEOUT"
CMDS="nics ssh-setup sync pool-net host netcheck pci-check pci-hide dcvm dcpci iscsi relogin sr ha ha-on ha-off protect status check mpverify start stop maint resume rescue help"
# Default values of optional variables (overridden by the variables file)
LOCAL_SR=([1]="" [2]=""); DC_VCPU_MASK=([1]="" [2]=""); HOST_IQN=([1]="" [2]=""); IQN_PREFIX=""; WIN_ISO=""; DC_MGMT_NET=""
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5"

die()  { echo "ERROR: $*" >&2; exit 1; }
ask()  { local r; read -r -p "$* [y/N] " r; [[ $r == [yY] ]]; }

# Loaded at global scope: 'declare -A' inside a function would create local variables
if [[ ${1:-} != help ]]; then
  [[ -r $CONF ]] || die "variables file not found: $CONF"
  # shellcheck source=/dev/null
  . "$CONF"
  for _v in $REQUIRED; do declare -p "$_v" >/dev/null 2>&1 || die "variable $_v missing from $CONF"; done
  for _v in NIC SUBNET; do [[ $(declare -p "$_v") == "declare -A"* ]] || die "$_v must be declared with 'declare -A' in $CONF"; done
  unset _v
fi

node() { [[ ${1:-} == [12] ]] || die "node number expected: 1 or 2"; }
local_host() { ( . /etc/xensource-inventory; echo "$INSTALLATION_UUID" ); }
host_uuid()  { xe host-list name-label="${HOSTS[$1]}" --minimal; }
host_addr()  { xe host-param-get uuid="$(host_uuid "$1")" param-name=address; }
vm_uuid()    { xe vm-list name-label="${DC_VMS[$1]}" --minimal; }
sr_uuid()    { xe sr-list name-label="$1" --minimal; }
master()     { [[ $(xe pool-list params=master --minimal) == $(local_host) ]] || die "must be run on the master"; }
on_node()    { [[ $(local_host) == $(host_uuid "$1") ]] || die "must be run on ${HOSTS[$1]}"; }
local_node() { local n; for n in 1 2; do [[ $(host_uuid "$n") == $(local_host) ]] && { echo "$n"; return; }; done; die "local host not listed in HOSTS"; }
host_live()  { [[ $(xe host-param-get uuid="$(host_uuid "$1")" param-name=host-metrics-live 2>/dev/null) == true ]]; }
pool()       { xe pool-list --minimal; }
sr_pbds()    { local u; u=$(sr_uuid "$1"); [[ -n $u ]] && xe pbd-list sr-uuid="$u" "${@:2}" --minimal | tr , ' '; }
portals()    { local n p o=(); for n in 1 2; do for p in DC-FE1 DC-FE2; do o+=("${SUBNET[$p]}.${DC_OCT[$n]}"); done; done; (IFS=,; echo "${o[*]}"); }
vm_state()   { local u; u=$(vm_uuid "$1"); [[ -n $u ]] && xe vm-param-get uuid="$u" param-name=power-state || echo absent; }
dc_running() { local n; for n in 1 2; do [[ $(vm_state "$n") == running ]] && return 0; done; return 1; }
mp_flag()    { xe host-param-get uuid="$(host_uuid "$1")" param-name=other-config param-key=multipathing 2>/dev/null || echo false; }
mp_check()   { local n; for n in 1 2; do [[ $(mp_flag "$n") == true ]] || die "multipathing disabled on ${HOSTS[$n]}: run 'host $n'"; done; }
rec_tmo()    { local f; for f in /sys/class/iscsi_session/session*/recovery_tmo; do cat "$f"; done | sort | uniq -c | xargs; }
cur_iqn()    { sed -n 's/^InitiatorName=//p' /etc/iscsi/initiatorname.iscsi; }
bdf_set()    { [[ ${PCI_BDF[$1]} != 0000:00:00.0 ]] || die "PCI_BDF[$1] not set in $CONF"; }
ha_enabled() { [[ $(xe pool-param-get uuid="$(pool)" param-name=ha-enabled) == true ]]; }
# HA timeout recorded in the pool (empty = HA enabled without ha-config:timeout, XAPI default) and
# the one actually used by xhad on the local host
ha_tmo()     { xe pool-param-get uuid="$(pool)" param-name=ha-configuration param-key=timeout 2>/dev/null; }
xha_tmo()    { grep -oiE '<StateFileTimeout>[0-9]+' /etc/xensource/xhad.conf 2>/dev/null | grep -oE '[0-9]+$'; }
# Key-based SSH to host N working without any prompt (see 'ssh-setup')
ssh_ok()     { ssh $SSH_OPTS "root@$(host_addr "$1")" true 2>/dev/null; }
# Runs a script command on host N: locally, or over ssh (script copied to /root by 'sync')
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
  echo "Current selection ($CONF): $(for r in DC-FE1 DC-FE2 DC-MR1 DC-MR2; do printf '%s=%s ' "$r" "${NIC[$r]}"; done)"
}
cmd_ssh_setup() {
  # Key-based root SSH between the two dom0s, in both directions, on the management addresses.
  # on_host and sync use BatchMode, which refuses any prompt: a missing key or an unknown host key
  # makes them fail. Asks for the root password of the other host once (twice at most).
  local n p a la pub rpub key=/root/.ssh/id_ed25519 kh=/root/.ssh/known_hosts ak=/root/.ssh/authorized_keys
  n=$(local_node) || exit 1; p=$((3-n))
  host_live "$p" || die "${HOSTS[$p]} unreachable"
  a=$(host_addr "$p"); la=$(host_addr "$n")
  mkdir -p /root/.ssh; chmod 700 /root/.ssh
  [[ -f $key ]] || ssh-keygen -q -t ed25519 -N "" -C "datacore-xcp@${HOSTS[$n]}" -f "$key" || die "ssh-keygen failed"
  # Host key of the other host: replaced if it changed (reinstallation)
  touch "$kh"; ssh-keygen -R "$a" -f "$kh" >/dev/null 2>&1
  ssh-keyscan -T 5 "$a" 2>/dev/null >> "$kh"
  grep -q "^$a " "$kh" || die "no SSH host key obtained from $a (ssh-keyscan)"
  if ssh_ok "$p"; then
    echo "${HOSTS[$n]} -> ${HOSTS[$p]}: key already accepted"
  else
    pub=$(cat "$key.pub")
    echo "Password of root@$a (${HOSTS[$p]}):"
    ssh -o ConnectTimeout=5 "root@$a" "mkdir -p /root/.ssh && chmod 700 /root/.ssh && { grep -qxF '$pub' $ak 2>/dev/null || echo '$pub' >> $ak; } && chmod 600 $ak" \
      || die "key not installed on ${HOSTS[$p]}"
    ssh_ok "$p" || die "key refused by ${HOSTS[$p]}: check PermitRootLogin and PubkeyAuthentication in its sshd_config"
    echo "${HOSTS[$n]} -> ${HOSTS[$p]}: key installed"
  fi
  # Reverse direction, through the connection that now works
  rpub=$(ssh $SSH_OPTS "root@$a" "[ -f $key ] || ssh-keygen -q -t ed25519 -N '' -C datacore-xcp@${HOSTS[$p]} -f $key >/dev/null; touch $kh; ssh-keygen -R $la -f $kh >/dev/null 2>&1; ssh-keyscan -T 5 $la 2>/dev/null >> $kh; cat $key.pub" | tail -1)
  [[ $rpub == ssh-* ]] || die "public key of ${HOSTS[$p]} not read"
  grep -qxF "$rpub" "$ak" 2>/dev/null || echo "$rpub" >> "$ak"; chmod 600 "$ak"
  ssh $SSH_OPTS "root@$a" "ssh $SSH_OPTS root@$la true" 2>/dev/null \
    || die "${HOSTS[$p]} -> ${HOSTS[$n]}: key-based SSH still refused"
  echo "${HOSTS[$p]} -> ${HOSTS[$n]}: OK"
  echo "Key-based SSH working in both directions ($la <-> $a)."
}
cmd_sync() {
  local n p a; n=$(local_node) || exit 1; p=$((3-n))
  host_live "$p" || die "${HOSTS[$p]} unreachable"
  ssh_ok "$p" || die "key-based SSH to ${HOSTS[$p]} not working: run './datacore-xcp.sh ssh-setup' first"
  a=$(host_addr "$p")
  scp -p $SSH_OPTS "$SELF" "$CONF" "root@$a:/root/" || die "copy to ${HOSTS[$p]} ($a) failed"
  ssh $SSH_OPTS "root@$a" "chmod +x /root/${SELF##*/}"
  echo "== ${HOSTS[$n]}"; md5sum "$SELF" "$CONF"
  echo "== ${HOSTS[$p]}"; ssh $SSH_OPTS "root@$a" "md5sum /root/${SELF##*/} /root/${CONF##*/}"
}

# ---------------------------------------------------------------- pool-net
cmd_pool_net() {
  master; local h r n net pif seen=""; h=$(host_uuid 1)
  dc_running && die "DataCore VM running: pool-net would unplug the MR PIFs and break the mirror"
  for r in DC-FE1 DC-FE2 DC-MR1 DC-MR2; do
    [[ " $seen " == *" ${NIC[$r]} "* ]] && die "${NIC[$r]} assigned to two functions"; seen+=" ${NIC[$r]}"
    for n in 1 2; do
      pif=$(xe pif-list host-uuid="$(host_uuid "$n")" device="${NIC[$r]}" physical=true --minimal)
      [[ -n $pif ]] || die "${NIC[$r]} ($r) missing on ${HOSTS[$n]}"
      [[ $(xe pif-param-get uuid="$pif" param-name=management) == false ]] || die "${NIC[$r]} carries management on ${HOSTS[$n]}"
    done
  done
  for r in DC-FE1 DC-FE2 DC-MR1 DC-MR2; do
    net=$(xe pif-list host-uuid="$h" device="${NIC[$r]}" params=network-uuid --minimal)
    [[ -n $net ]] || die "PIF ${NIC[$r]} not found"
    if [[ $(xe network-param-get uuid="$net" param-name=name-label) == "$r" &&
          $(xe network-param-get uuid="$net" param-name=MTU) == "$MTU" ]]; then
      echo "  $r: already configured"; continue
    fi
    xe network-param-set uuid="$net" name-label="$r" MTU="$MTU"
    for pif in $(xe pif-list network-uuid="$net" --minimal | tr , ' '); do
      xe pif-unplug uuid="$pif" 2>/dev/null && xe pif-plug uuid="$pif" \
        || echo "  $r: replug failed (disallow-unplug?) -> MTU applied at reboot"
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
  echo "Current IQN of ${HOSTS[$n]}: $cur"
  if [[ -t 0 ]]; then read -r -p "IQN to apply [Enter = $def]: " new; fi
  new=${new:-$def}; new=${new,,}
  [[ $new == "$cur" ]] && { echo "  IQN unchanged"; return; }
  [[ $new =~ $re ]] || die "invalid IQN: $new (format iqn.YYYY-MM.reversed.domain:name)"
  [[ -z $(iscsiadm -m session 2>/dev/null) ]] \
    || die "iSCSI sessions open: the IQN can only be changed before 'iscsi' and SR creation"
  xe host-param-set uuid="$h" iscsi_iqn="$new" || die "xe host-param-set iscsi_iqn rejected"
  sleep 2
  [[ $(cur_iqn) == "$new" ]] || die "initiatorname.iscsi not updated ($(cur_iqn)): check xensource.log"
  echo "  IQN changed: $new"
}
ntp_setup() {
  local h=$1 m s
  [[ ${#NTP_SERVERS[@]} -gt 0 && -n ${NTP_SERVERS[0]} ]] || die "NTP_SERVERS empty in $CONF"
  if m=$(xe host-param-get uuid="$h" param-name=ntp-mode 2>/dev/null); then
    # XAPI manages chrony.conf: any manual change would be overwritten
    echo "NTP managed by XAPI (current mode: $m): configuring with xe"
    xe host-param-set uuid="$h" ntp-custom-servers="$(IFS=,; echo "${NTP_SERVERS[*]}")" || die "ntp-custom-servers rejected"
    if [[ $m != *[Cc]ustom* ]]; then
      xe host-param-set uuid="$h" ntp-mode=Custom 2>/dev/null \
        || xe host-param-set uuid="$h" ntp-mode=ntp_mode_custom \
        || die "ntp-mode rejected: 'xe host-param-list uuid=$h | grep -i ntp' for accepted values"
    fi
    echo "  ntp-mode: $(xe host-param-get uuid="$h" param-name=ntp-mode)"
    echo "  servers: $(xe host-param-get uuid="$h" param-name=ntp-custom-servers)"
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
    [[ -n $pif && $pif != *,* ]] || die "PIF $r not found on this host: run pool-net on the master"
    ip="${SUBNET[$r]}.${HOST_OCT[$n]}"
    # Idempotent: reconfiguring an already correct PIF would replug it and cut the iSCSI paths
    if [[ $(xe pif-param-get uuid="$pif" param-name=IP-configuration-mode) == Static &&
          $(xe pif-param-get uuid="$pif" param-name=IP) == "$ip" &&
          $(xe pif-param-get uuid="$pif" param-name=netmask) == 255.255.255.0 ]]; then
      echo "  $r: $ip already configured"
    else
      xe pif-reconfigure-ip uuid="$pif" mode=static IP="$ip" netmask=255.255.255.0
    fi
    xe pif-param-set uuid="$pif" disallow-unplug=true other-config:management_purpose="Storage $r"
  done
  # XAPI multipathing: mandatory before sr/ha (host disabled while it is set)
  if [[ $(mp_flag "$n") != true ]]; then
    [[ -z $(xe vm-list resident-on="$h" is-control-domain=false --minimal) ]] \
      || die "VMs running on this host: shut them down or migrate them before enabling multipathing"
    xe host-disable uuid="$h"
    xe host-param-set uuid="$h" other-config:multipathing=true other-config:multipathhandle=dmp
    xe host-enable uuid="$h"
  fi
  echo "XAPI multipathing: $(mp_flag "$n")"
  ntp_setup "$h"
  # Multipath: polling_interval and fast_io_fail_tmo are only read from defaults
  cat > /etc/multipath/conf.d/custom.conf <<'EOC'
# DataCore SANsymphony HCI - no_path_retry 6 x polling 10 s = ~60 s < timeout HA 120 s
# polling_interval and fast_io_fail_tmo are only honoured in defaults
# (fast_io_fail_tmo placed in devices is ignored by the XCP-ng 8.3 multipath-tools)
defaults {
    polling_interval      10
    # multipathd applies fast_io_fail_tmo as the recovery_tmo of iSCSI sessions
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
        # ALUA handler driven by dm-multipath: ALUA state is re-read each time a path group is
        # activated (failover, failback). Without it, the kernel cache can keep paths
        # 'unavailable' after a DataCore VM returns -> I/O silently rejected, fence (section 10)
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
    && echo "WARNING: DataCore map without ALUA handler (hwhandler='0') -> 'multipath -r' with HA disabled, then check 'multipathd show topology'"
  # Scheduled tasks: relogin (sessions and kernel ALUA state) and check (monitoring).
  # PATH is set explicitly: cron's default (/usr/bin:/bin) does not contain multipathd and iscsiadm.
  rm -f /etc/cron.d/datacore-check
  cat > /etc/cron.d/datacore-xcp <<EOC
# datacore-xcp.sh - installed by 'host N' (relogin every minute, check every 5 minutes)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root $SELF relogin >/dev/null 2>&1
*/5 * * * * root $SELF check >/dev/null 2>&1
EOC
  echo "Scheduled tasks: /etc/cron.d/datacore-xcp (relogin, check)"
  echo "IQN to register in DataCore for ${HOSTS[$n]}: $(cur_iqn)"
}

# ---------------------------------------------------------------- mpverify
cmd_mpverify() {
  # Effective multipath configuration still the one written by 'host N'? An XCP-ng update can replace
  # the multipath files (DataCore XenServer guide): defaults, DataCore block, ALUA handler of the maps
  local cfg d bad=0
  [[ -f /etc/multipath/conf.d/custom.conf ]] || { echo "DRIFT: /etc/multipath/conf.d/custom.conf missing"; bad=1; }
  grep -q '^PATH=' /etc/cron.d/datacore-xcp 2>/dev/null || { echo "DRIFT: /etc/cron.d/datacore-xcp missing or without PATH (relogin and check do not run)"; bad=1; }
  cfg=$(multipathd show config 2>/dev/null) || { echo "DRIFT: multipathd does not answer"; return 1; }
  d=$(sed -n '/^defaults {/,/^}/p' <<<"$cfg")
  grep -Eq '^[[:space:]]*polling_interval[[:space:]]+10$' <<<"$d" || { echo "DRIFT: defaults without polling_interval 10"; bad=1; }
  grep -Eq '^[[:space:]]*fast_io_fail_tmo[[:space:]]+5$' <<<"$d" || { echo "DRIFT: defaults without fast_io_fail_tmo 5"; bad=1; }
  d=$(sed -n '/"Virtual Disk"/,/}/p' <<<"$cfg")
  grep -Eq '^[[:space:]]*no_path_retry[[:space:]]+6$' <<<"$d" || { echo "DRIFT: DataCore block without no_path_retry 6"; bad=1; }
  grep -Eq 'hardware_handler[[:space:]]+"1 alua"' <<<"$d" || { echo "DRIFT: DataCore block without hardware_handler \"1 alua\""; bad=1; }
  [[ $(multipathd show topology 2>/dev/null) == *"hwhandler='0'"* ]] && { echo "DRIFT: map with hwhandler='0'"; bad=1; }
  ((bad)) && { echo "-> ./datacore-xcp.sh host $(local_node) on this host (idempotent)"; return 1; }
  echo "Multipath configuration OK"
}

# ---------------------------------------------------------------- netcheck
cmd_netcheck() {
  local n p r ip rc=0; n=$(local_node) || exit 1; p=$((3-n))
  for r in DC-FE1 DC-FE2; do
    ip="${SUBNET[$r]}.${HOST_OCT[$p]}"
    if ping -M do -s $((MTU - 28)) -c 3 -W 2 "$ip" >/dev/null 2>&1; then echo "$r -> $ip (dom0 ${HOSTS[$p]}) MTU $MTU: OK"
    else echo "$r -> $ip (dom0 ${HOSTS[$p]}) MTU $MTU: FAILED"; rc=1; fi
  done
  return $rc
}

# ---------------------------------------------------------------- passthrough
cmd_pci_check() {
  node "${1:-}"; local n=$1 b bad=0 disks d l p pv src; on_node "$n"; bdf_set "$n"; b=${PCI_BDF[$n]}
  lspci -nnk -s "$b"
  xl dmesg | grep -ci 'I/O virtualisation enabled' >/dev/null && echo "IOMMU: enabled" \
    || { echo "BLOCKING: IOMMU/VT-d disabled (BIOS)"; bad=1; }
  disks=$(for l in /dev/disk/by-path/pci-"$b"-*; do
            d=$(readlink -f "$l"); p=$(lsblk -ndo PKNAME "$d" 2>/dev/null); echo "${p:-${d##*/}}"
          done | sort -u)
  echo "Disks behind $b: ${disks:-none (already hidden?)}"
  src=$(findmnt -no SOURCE /)
  for d in $disks; do
    lsblk -nrso NAME "$src" | grep -cx "$d" >/dev/null && { echo "BLOCKING: /dev/$d holds the dom0 root"; bad=1; }
    for pv in $(pvs --noheadings -o pv_name 2>/dev/null); do
      lsblk -nrso NAME "$pv" 2>/dev/null | grep -cx "$d" >/dev/null && { echo "BLOCKING: /dev/$d holds PV $pv (local SR)"; bad=1; }
    done
  done
  echo "== dom0 disks: root and local SR must be on the boot controller"
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT; pvs 2>/dev/null
  echo "Current parameter: $(/opt/xensource/libexec/xen-cmdline --get-dom0 xen-pciback.hide)"
  xl pci-assignable-list
  return $bad
}
cmd_pci_hide() {
  node "${1:-}"; local n=$1 o pci; o=$((3-n))
  # One host rebooting at a time: while the master reboots, the other host has no usable XAPI
  host_live "$o" || die "${HOSTS[$o]} not back yet (host-metrics-live=false): wait for it"
  cmd_pci_check "$n" || die "checks failed, hiding cancelled"
  pci=$(xe pci-list host-uuid="$(local_host)" pci-id="${PCI_BDF[$n]}" --minimal)
  [[ -n $pci && $pci != *,* ]] || die "PCI ${PCI_BDF[$n]} not found or ambiguous"
  xe pci-disable-dom0-access uuid="$pci"
  echo "New parameter: $(/opt/xensource/libexec/xen-cmdline --get-dom0 xen-pciback.hide)"
  [[ $(xe pool-list params=master --minimal) == $(local_host) ]] \
    && echo "WARNING: master reboot; ${HOSTS[$o]} will have no xe commands until it is back"
  ask "Is the BDF shown really the storage HBA? Reboot now" && reboot
}
cmd_dcpci() {
  master; node "${1:-}"; local n=$1 vm; bdf_set "$n"; vm=$(vm_uuid "$n")
  [[ -n $vm ]] || die "${DC_VMS[$n]} missing: run 'dcvm $n'"
  [[ $(vm_state "$n") == halted ]] || die "${DC_VMS[$n]} must be halted (Windows shutdown) before adding the HBA"
  [[ $(xe vm-param-get uuid="$vm" param-name=PV-drivers-detected 2>/dev/null) == true ]] \
    || echo "WARNING: PV tools not detected at last boot: install them before the HBA"
  xe vm-param-set uuid="$vm" other-config:pci=0/"${PCI_BDF[$n]}"
  echo "HBA ${PCI_BDF[$n]} attached to ${DC_VMS[$n]}. Start: xe vm-start uuid=$vm on=${HOSTS[$n]}"
}

# ---------------------------------------------------------------- dcvm N
local_sr() {
  local h=$1 s c=()
  for s in $(xe pbd-list host-uuid="$h" params=sr-uuid --minimal | tr , ' '); do
    [[ $(xe sr-param-get uuid="$s" param-name=shared) == false &&
       $(xe sr-param-get uuid="$s" param-name=content-type) == user ]] && c+=("$s")
  done
  [[ ${#c[@]} -eq 1 ]] || die "ambiguous local SR (${#c[@]} candidates): set LOCAL_SR"
  echo "${c[0]}"
}
cmd_dcvm() {
  master; node "${1:-}"; local n=$1 h sr vm vdi vbd v i r mac ram mg
  h=$(host_uuid "$n"); [[ -z $(vm_uuid "$n") ]] || die "${DC_VMS[$n]} already exists"
  [[ -n $(xe template-list name-label="$WIN_TEMPLATE" --minimal) ]] || {
    xe template-list params=name-label --minimal | tr , '\n' | grep -i windows
    die "template '$WIN_TEMPLATE' not found: copy an exact name from the list above into WIN_TEMPLATE"; }
  # Management VIF of the DataCore VM: DC_MGMT_NET if set (dedicated network, section 2), otherwise MGMT_NET
  mg=${DC_MGMT_NET:-$MGMT_NET}
  for r in "$mg" DC-FE1 DC-FE2 DC-MR1 DC-MR2; do
    v=$(xe network-list name-label="$r" --minimal)
    [[ -n $v && $v != *,* ]] || die "network '$r' not found or ambiguous (xe network-list params=name-label)"
  done
  sr=${LOCAL_SR[$n]:-$(local_sr "$h")} || exit 1
  vm=$(xe vm-install template="$WIN_TEMPLATE" new-name-label="${DC_VMS[$n]}" sr-uuid="$sr") || die "vm-install"
  # System disk as VHD: qcow2 fails at boot with sm 3.2.12 (SR_BACKEND_FAILURE_46)
  for vbd in $(xe vbd-list vm-uuid="$vm" type=Disk --minimal | tr , ' '); do
    vdi=$(xe vbd-param-get uuid="$vbd" param-name=vdi-uuid); xe vbd-destroy uuid="$vbd"; xe vdi-destroy uuid="$vdi"
  done
  vdi=$(xe vdi-create sr-uuid="$sr" name-label="${DC_VMS[$n]}-OS" type=user \
        virtual-size="${DC_DISK_GIB}GiB" sm-config:image-format=vhd)
  xe vbd-create vm-uuid="$vm" vdi-uuid="$vdi" device=0 bootable=true mode=RW type=Disk >/dev/null
  # CPU priority, static RAM (no ballooning), no PV drivers through Windows Update
  ram=$((DC_RAM_GIB * 1024**3))
  xe vm-param-set uuid="$vm" VCPUs-max="$DC_VCPU"
  xe vm-param-set uuid="$vm" VCPUs-at-startup="$DC_VCPU"
  xe vm-memory-limits-set uuid="$vm" static-min=$ram dynamic-min=$ram dynamic-max=$ram static-max=$ram
  xe vm-param-set uuid="$vm" VCPUs-params:weight=65535 affinity="$h" platform:cores-per-socket="$DC_VCPU" \
     has-vendor-device=false other-config:auto_poweron=true ha-restart-priority=""
  [[ -n ${DC_VCPU_MASK[$n]} ]] && xe vm-param-set uuid="$vm" VCPUs-params:mask="${DC_VCPU_MASK[$n]}"
  # VIFs with fixed MACs 02:dc:00:0N:00:0i -> identification and renaming on the Windows side
  for v in $(xe vif-list vm-uuid="$vm" --minimal | tr , ' '); do xe vif-destroy uuid="$v"; done
  i=0
  for r in "$mg" DC-FE1 DC-FE2 DC-MR1 DC-MR2; do
    mac=$(printf '02:dc:00:%02x:00:%02x' "$n" "$i")
    xe vif-create vm-uuid="$vm" network-uuid="$(xe network-list name-label="$r" --minimal)" device=$i mac=$mac >/dev/null
    echo "  VIF $i  $mac  $r"; i=$((i+1))
  done
  [[ -n $WIN_ISO ]] && xe vm-cd-add uuid="$vm" cd-name="$WIN_ISO" device=3
  xe pool-param-set uuid="$(pool)" other-config:auto_poweron=true
  echo "${DC_VMS[$n]} created WITHOUT the HBA (added by 'dcpci $n' after Windows and PV tools)."
  echo "Windows management adapter: MAC $(printf '02-DC-00-%02X-00-00' "$n")"
  echo "Start: xe vm-start uuid=$vm on=${HOSTS[$n]}"
}

# ---------------------------------------------------------------- iSCSI / SR / HA
lun_sr() {   # DataCore SR backed by LUN $1 (empty if none)
  local s p
  for s in "$SR_NAME" "$HB_SR_NAME"; do
    p=$(sr_pbds "$s" | awk '{print $1}')
    [[ -n $p && $(xe pbd-param-get uuid="$p" param-name=device-config param-key=SCSIid 2>/dev/null) == "$1" ]] && echo "$s"
  done
}
dc_luns() {  # one line per DataCore LUN seen by the local host: paths SCSIid size [SR]
  local s d id c sz sid=/usr/lib/udev/scsi_id; [[ -x $sid ]] || sid=/lib/udev/scsi_id
  for s in /sys/block/sd*; do
    d=/dev/${s##*/}; id=$($sid -g -u -d "$d" 2>/dev/null) || continue
    [[ $id == 360030d90* ]] && echo "$id $(( $(blockdev --getsize64 "$d") / 1024**3 ))GiB"
  done | sort | uniq -c | while read -r c id sz; do echo "$c $id $sz $(lun_sr "$id")"; done
}
cmd_iscsi() {
  local p out ns
  echo "Initiator: $(cur_iqn)"
  for p in $(portals | tr , ' '); do
    iscsiadm -m discovery -t sendtargets -p "$p:3260" >/dev/null 2>&1 \
      && iscsiadm -m node -p "$p:3260" --login >/dev/null 2>&1
  done
  iscsiadm -m session --rescan >/dev/null 2>&1; sleep 5
  iscsiadm -m session 2>/dev/null
  ns=$(iscsiadm -m session 2>/dev/null | wc -l)
  echo "Sessions: $ns (4 expected: FE1+FE2 of ${DC_VMS[1]} and ${DC_VMS[2]})"
  out=$(dc_luns)
  if [[ -z $out ]]; then
    echo "No DataCore LUN: normal before vDisks are served -> Refresh the ports in the DMC, then register the host"
  else
    echo; echo "Paths  SCSIid  Size  SR   (4 paths expected per LUN)"; echo "$out"
  fi
  echo "Effective recovery_tmo (session count, value): $(rec_tmo)   expected: 5, alert above $ISCSI_TMO_MAX"
}
alua_stale() {   # 'ready' paths (multipathd) that the kernel ALUA cache does not see as active: "sdX(state) ..."
  local d m t st o=""
  while read -r d m t; do
    [[ $m == 360030d90* && $t == ready ]] || continue
    st=$(cat "/sys/block/$d/device/access_state" 2>/dev/null) || continue
    [[ $st == active* ]] || o+=" $d($st)"
  done < <(multipathd show paths format "%d %m %T" 2>/dev/null | tail -n +2)
  echo "${o# }"
}
alua_heal() {
  # Stale kernel ALUA cache (scsi_dh_alua): after a DataCore VM returns, a cold start or a loss of
  # access to DataCore, paths can stay 'unavailable' for the kernel while multipathd sees them 'ready';
  # the SR is attached with 4 paths but I/O is rejected. Re-read per device, then, if that is not
  # enough, rescan of the iSCSI sessions (what the 'iscsi' command does). Return code 1 if paths
  # are still inconsistent. Logged to syslog only when the situation changes.
  local s d left f=/run/datacore-xcp-alua.state
  s=$(alua_stale); [[ -z $s ]] && { rm -f "$f"; return 0; }
  for d in $s; do echo 1 > "/sys/block/${d%%\(*}/device/rescan"; done 2>/dev/null
  sleep 3
  [[ -n $(alua_stale) ]] && { iscsiadm -m session --rescan >/dev/null 2>&1; sleep 5; }
  left=$(alua_stale)
  echo "Kernel ALUA state re-read: $s${left:+ - still inconsistent: $left}"
  [[ $(cat "$f" 2>/dev/null) == "$s|$left" ]] \
    || logger -t datacore-xcp "Kernel ALUA state re-read: $s${left:+ - still inconsistent: $left}"
  if [[ -n $left ]]; then echo "$s|$left" > "$f"; return 1; fi
  rm -f "$f"
}
cmd_relogin() {
  # At boot, SM tries the 4 portals before the local DataCore VM is listening: the initial
  # connection fails, so there is no session to recover and no retry (SMlog: 'No route to host',
  # 'Connection refused'). Retries the login to every portal with no session that answers on 3260,
  # then re-reads the kernel ALUA state of the paths (alua_heal).
  # Only acts if a DataCore SR is attached on this host (not after 'stop', nor if XAPI does not answer).
  local p s u n=0 h ss
  exec 9>/run/datacore-xcp-relogin.lock; flock -n 9 || return 0
  h=$(local_host)
  for s in "$SR_NAME" "$HB_SR_NAME"; do
    u=$(timeout 20 xe sr-list name-label="$s" --minimal 2>/dev/null); [[ -n $u ]] || continue
    [[ -n $(timeout 20 xe pbd-list host-uuid="$h" sr-uuid="$u" currently-attached=true --minimal 2>/dev/null) ]] && n=1
  done
  ((n)) || { echo "No DataCore SR attached on this host: nothing to do"; return 0; }
  n=0; ss=$(iscsiadm -m session 2>/dev/null)
  for p in $(portals | tr , ' '); do
    [[ $ss == *" $p:3260,"* ]] && continue    # session present (connected or recovering)
    timeout 3 bash -c "</dev/tcp/$p/3260" 2>/dev/null || { echo "$p: port 3260 closed"; continue; }
    if iscsiadm -m discovery -t sendtargets -p "$p:3260" >/dev/null 2>&1 \
       && iscsiadm -m node -p "$p:3260" --login >/dev/null 2>&1; then
      logger -t datacore-xcp "iSCSI session restored to $p"; echo "$p: session restored"; n=$((n+1))
    else
      logger -t datacore-xcp "iSCSI login failed to $p"; echo "$p: login failed"
    fi
  done
  ((n)) && { iscsiadm -m session --rescan >/dev/null 2>&1; sleep 5; }
  alua_heal
  echo "Sessions: $(iscsiadm -m session 2>/dev/null | wc -l) (4 expected)"
}
wait_paths() {
  # Waits for 4 'ready' paths per DataCore LUN, active for the kernel, on host N (relogin on each round), 10 min max
  local n=$1 t rc
  echo "Checking paths on ${HOSTS[$n]} (10 min max)..."
  for t in $(seq 40); do
    on_host "$n" relogin >/dev/null 2>&1
    on_host "$n" check --quiet >/dev/null 2>&1; rc=$?
    ((rc == 0)) && { echo "  ${HOSTS[$n]}: 4 paths per LUN"; return 0; }
    if ((rc == 255)); then
      echo "SSH to ${HOSTS[$n]} failed ('./datacore-xcp.sh ssh-setup' sets up the keys)."
      ask "Does './datacore-xcp.sh check' show 'DataCore multipath OK' on ${HOSTS[$n]}?" && return 0
      die "paths not verified on ${HOSTS[$n]}"
    fi
    sleep 15
  done
  die "${HOSTS[$n]}: paths incomplete after 10 min -> 'check' then 'relogin' (or 'iscsi') on that host"
}
mk_sr() {
  xe sr-create name-label="$1" name-description="$2" shared=true type=lvmoiscsi content-type=user \
     device-config:target="$(portals)" device-config:targetIQN='*' device-config:SCSIid="$3"
}
cmd_sr() {
  master; mp_check; [[ ${1:-} == 3* ]] || die "usage: sr SCSIID (see ./datacore-xcp.sh iscsi)"
  local sr; sr=$(mk_sr "$SR_NAME" "DataCore mirrored vDisk" "$1") || die "sr-create"
  xe pool-param-set uuid="$(pool)" default-SR="$sr"
  xe pbd-list sr-uuid="$sr" params=host-name-label,currently-attached
}
wait_srs() {
  local t s p ok=0
  echo "Waiting for the DataCore SRs (15 min max)..."
  for t in $(seq 60); do
    ok=1
    for s in "$SR_NAME" "$HB_SR_NAME"; do
      for p in $(sr_pbds "$s" currently-attached=false); do xe pbd-plug uuid="$p" 2>/dev/null || ok=0; done
    done
    ((ok)) && break; sleep 15
  done
  ((ok)) || die "SRs not attached: check the DMC (vDisk out of service, double failure?)"
  echo "SRs attached on both hosts."
}
ha_alert() {
  # HA enabled with a timeout other than HA_TIMEOUT: HA disabled then re-enabled from Xen Orchestra
  # goes back to the XAPI default, and a DataCore link cut then ends in a fence. Checked on the
  # master only. $1 = 1: no syslog.
  local p t
  [[ $(timeout 20 xe pool-list params=master --minimal 2>/dev/null) == "$(local_host)" ]] || return 0
  p=$(timeout 20 xe pool-list --minimal 2>/dev/null); [[ -n $p ]] || return 0
  [[ $(timeout 20 xe pool-param-get uuid="$p" param-name=ha-enabled 2>/dev/null) == true ]] || return 0
  t=$(timeout 20 xe pool-param-get uuid="$p" param-name=ha-configuration param-key=timeout 2>/dev/null)
  [[ $t == "$HA_TIMEOUT" ]] && return 0
  echo "ALERT: HA enabled with timeout '${t:-XAPI default}' instead of $HA_TIMEOUT s -> './datacore-xcp.sh ha-on' on the master"
  ((${1:-0})) || logger -t datacore-xcp "HA timeout ${t:-XAPI default} instead of $HA_TIMEOUT s: ha-on on the master"
  return 1
}
ha_on() {
  local p n hb free; p=$(pool); hb=$(sr_uuid "$HB_SR_NAME")
  [[ -n $hb ]] || die "SR $HB_SR_NAME missing: run 'ha SCSIID'"
  if ha_enabled; then
    [[ $(ha_tmo) == "$HA_TIMEOUT" ]] && { echo "HA already enabled, timeout $HA_TIMEOUT s"; return; }
    # The timeout can only be changed by disabling then re-enabling HA
    echo "WARNING: HA enabled with timeout '$(ha_tmo)' (empty = XAPI default) instead of $HA_TIMEOUT s."
    echo "HA was probably enabled outside this script (Xen Orchestra). A low timeout causes a fence when a DataCore link is cut."
    ask "Disable HA and re-enable it with timeout $HA_TIMEOUT s?" || die "HA timeout not fixed"
    xe pool-ha-disable || die "pool-ha-disable"
  fi
  # XAPI (Xha_statefile.ha_fits_sr) allocates ~3.7 GiB (statefile + metadata, thick LVM) on a
  # 2-host pool. Check skipped if these VDIs already exist: XAPI reuses them.
  if [[ -z $(xe vdi-list sr-uuid="$hb" type=ha_statefile --minimal) || -z $(xe vdi-list sr-uuid="$hb" type=redo_log --minimal) ]]; then
    free=$(( $(xe sr-param-get uuid="$hb" param-name=physical-size) - $(xe sr-param-get uuid="$hb" param-name=physical-utilisation) ))
    (( free >= HB_MIN_FREE_GIB * 1024**3 )) \
      || die "SR $HB_SR_NAME: $((free / 1024**2)) MiB free, XAPI requires ~3.7 GiB: grow the heartbeat vDisk (10 GB)"
  fi
  xe host-list params=name-label,enabled,host-metrics-live
  for n in 1 2; do [[ $(vm_state "$n") == running ]] || die "${DC_VMS[$n]} halted: HA not enabled"; done
  ask "Are all vDisks 'Up to date' on both servers in the DMC?" || die "HA not enabled"
  for n in 1 2; do wait_paths "$n"; done
  xe pool-ha-enable heartbeat-sr-uuids="$hb" ha-config:timeout="$HA_TIMEOUT" || die "pool-ha-enable"
  xe pool-param-set uuid="$p" ha-host-failures-to-tolerate=1
  echo "HA enabled; plan covers $(xe pool-param-get uuid="$p" param-name=ha-plan-exists-for) host failure(s)"
  echo "HA timeout: pool '$(ha_tmo)' s, xhad.conf '$(xha_tmo)' s (expected: $HA_TIMEOUT)"
  [[ $(ha_tmo) == "$HA_TIMEOUT" ]] || echo "WARNING: timeout not recorded in the pool: check 'xe pool-param-get uuid=$p param-name=ha-configuration'"
  echo "Reminder: never disable or enable HA from Xen Orchestra (timeout back to the default): 'ha-off' / 'ha-on' only."
}
cmd_ha() {
  master; mp_check; [[ ${1:-} == 3* ]] || die "usage: ha SCSIID_HEARTBEAT"
  [[ -n $(sr_uuid "$HB_SR_NAME") ]] || mk_sr "$HB_SR_NAME" "HA statefile - no VMs" "$1" >/dev/null || die "sr-create"
  local n; for n in 1 2; do xe vm-param-set uuid="$(vm_uuid "$n")" ha-restart-priority=""; done
  ha_on
}
cmd_ha_off() {
  master
  ha_enabled || { echo "HA already disabled"; return 0; }
  xe pool-ha-disable || die "pool-ha-disable"
  echo "HA disabled. Re-enable it with './datacore-xcp.sh ha-on' (timeout $HA_TIMEOUT s), never from Xen Orchestra."
}
cmd_protect() {
  master; local v p vdi s bad=0; p=$(pool)
  v=$(xe vm-list name-label="${1:-}" --minimal)
  [[ -z $v && -n ${1:-} ]] && v=$(xe vm-list uuid="$1" --minimal 2>/dev/null)
  [[ -n $v && $v != *,* ]] || die "VM not found or ambiguous (name or UUID)"
  for vdi in $(xe vbd-list vm-uuid="$v" type=Disk params=vdi-uuid --minimal | tr , ' '); do
    s=$(xe vdi-param-get uuid="$vdi" param-name=sr-uuid)
    [[ $(xe sr-param-get uuid="$s" param-name=shared) == true ]] \
      || { echo "Disk on non-shared SR: $(xe sr-param-get uuid="$s" param-name=name-label)"; bad=1; }
  done
  ((bad)) && die "VM not agile: protection refused"
  [[ -n $(xe vbd-list vm-uuid="$v" type=CD empty=false --minimal) ]] && echo "WARNING: CD inserted, eject it if it is on a local SR"
  xe vm-param-set uuid="$v" ha-restart-priority=restart order="${2:-1}" || die "rejected by XAPI (HA plan capacity?)"
  [[ $(xe pool-param-get uuid="$p" param-name=ha-enabled) == true ]] \
    && echo "HA plan: $(xe pool-param-get uuid="$p" param-name=ha-plan-exists-for) failure(s) covered, 1 expected"
}

# ---------------------------------------------------------------- operations
shutdown_vm() {   # return code 2 if the shutdown had to be forced
  local v=$1 name; name=$(xe vm-param-get uuid="$v" param-name=name-label)
  echo "Shutting down $name"
  timeout "$SHUTDOWN_TIMEOUT" xe vm-shutdown uuid="$v" && { echo "  $name: stopped cleanly"; return 0; }
  echo "  $name: no clean shutdown (guest tools missing, or not done within ${SHUTDOWN_TIMEOUT} s) -> forced shutdown"
  xe vm-shutdown uuid="$v" --force; return 2
}
guests_up() {   # running or paused VMs other than the DataCore VMs ($1 = " uuid1 uuid2 ")
  local v s
  for s in running paused; do
    for v in $(xe vm-list power-state=$s is-control-domain=false --minimal | tr , ' '); do
      [[ $1 == *" $v "* ]] || echo "$v"
    done
  done
}
stop_guests() {
  # Guest (production) VMs first: their disks are on the DataCore SR, so they must all be halted before
  # the SR is detached and before the DataCore VMs stop. Clean shutdown in parallel, forced after
  # SHUTDOWN_TIMEOUT, then a check that none is left. $1 = DataCore VM uuids, $2 = 1 in UPS mode.
  local l v left
  l=$(guests_up "$1")
  [[ -n $l ]] || { echo "Guest VMs: none running"; return 0; }
  echo "Guest VMs: shutting down $(wc -w <<<"$l") VM(s) BEFORE the DataCore VMs (clean shutdown in parallel, ${SHUTDOWN_TIMEOUT} s max, then forced)"
  for v in $l; do shutdown_vm "$v" & done; wait
  left=$(guests_up "$1")
  for v in $left; do
    echo "  still running: $(xe vm-param-get uuid="$v" param-name=name-label) -> forced shutdown"
    xe vm-shutdown uuid="$v" --force
  done
  left=$(guests_up "$1")
  [[ -z $left ]] && { echo "Guest VMs: all halted"; return 0; }
  echo "WARNING: $(wc -w <<<"$left") guest VM(s) could not be stopped: $left"
  (($2)) && { echo "UPS mode: shutdown continues anyway"; return 0; }
  ask "Stop the DataCore VMs anyway?" || die "shutdown aborted: guest VMs still running"
}
# ---------------------------------------------------------------- DataCore order
# Shutdown: DC-02 then DC-01 (DC-01 always last). Restart: last stopped first.
# The last ordered shutdown is recorded in the pool database (replicated, survives a master change):
#   other-config:datacore-last-stopped = N:dmc | N:ups | N:ups-force   (N = node stopped last)
# 'start' clears the key once both DataCore servers are serving: missing = uncontrolled shutdown.
LS_KEY=datacore-last-stopped
ls_get()    { xe pool-param-get uuid="$(pool)" param-name=other-config param-key=$LS_KEY 2>/dev/null; }
ls_set()    { xe pool-param-set uuid="$(pool)" other-config:$LS_KEY="$1"; }
ls_clear()  { xe pool-param-remove uuid="$(pool)" param-name=other-config param-key=$LS_KEY 2>/dev/null || true; }
dc_serves() { timeout 3 bash -c "</dev/tcp/$1/3260" 2>/dev/null; }   # DataCore iSCSI target listening
start_dc() {  # start_dc N dmc|ups: starts DataCore VM N and waits until DataCore serves on FE1
  local n=$1 ip=${SUBNET[DC-FE1]}.${DC_OCT[$1]} t
  [[ $(vm_state "$n") == running ]] || xe vm-start uuid="$(vm_uuid "$n")" on="${HOSTS[$n]}" || die "cannot start ${DC_VMS[$n]}"
  if [[ $2 == dmc ]]; then
    echo "${DC_VMS[$n]} starting: stopped in the DMC, DataCore does not restart by itself at Windows boot."
    until ask "'Start DataCore Server' done on ${DC_VMS[$n]} in the DMC?"; do :; done
  fi
  echo "Waiting for DataCore on ${DC_VMS[$n]} ($ip:3260, 15 min max)..."
  while :; do
    for t in $(seq 90); do dc_serves "$ip" && { echo "${DC_VMS[$n]}: DataCore serving"; return; }; sleep 10; done
    ask "${DC_VMS[$n]} does not answer on $ip:3260. Keep waiting?" || die "start aborted: ${DC_VMS[$n]} not serving"
  done
}
start_protected() {
  local v
  for v in $(xe vm-list ha-restart-priority=restart power-state=halted --minimal | tr , ' '); do
    echo "$(xe vm-param-get uuid="$v" param-name=order) $v"
  done | sort -n | while read -r _ v; do
    echo "Starting $(xe vm-param-get uuid="$v" param-name=name-label)"
    xe vm-start uuid="$v" || echo "  FAILED: handle manually"
  done
}
cmd_status() {
  local n s u
  echo "== Hosts"; xe host-list params=name-label,enabled,host-metrics-live
  echo "== XAPI multipathing"; for n in 1 2; do echo "${HOSTS[$n]}: $(mp_flag "$n")"; done
  echo "== DataCore VMs"
  for n in 1 2; do
    u=$(vm_uuid "$n")
    echo "${DC_VMS[$n]}: $(vm_state "$n")  HBA: $([[ -n $u ]] && xe vm-param-get uuid="$u" param-name=other-config param-key=pci 2>/dev/null || echo 'not attached')"
  done
  for s in "$SR_NAME" "$HB_SR_NAME"; do
    echo "== $s"; [[ -n $(sr_uuid "$s") ]] && xe pbd-list sr-uuid="$(sr_uuid "$s")" params=host-name-label,currently-attached
  done
  echo "== HA enabled: $(xe pool-param-get uuid="$(pool)" param-name=ha-enabled)   timeout: pool '$(ha_tmo)' s, xhad.conf (local host) '$(xha_tmo)' s   expected: $HA_TIMEOUT"
  ha_alert 1
  echo "== IQN (local host): $(cur_iqn)"
  echo "== Multipath (local host)"; multipathd show topology | grep -E 'DataCore|hwhandler|prio='
  echo "== iSCSI sessions (local host): $(iscsiadm -m session 2>/dev/null | wc -l) (4 expected)"
  echo "== Paths (local host): device, checker, multipathd prio, kernel ALUA state"
  multipathd show paths format "%d %m %T %p" | awk 'NR>1 && $2 ~ /^360030d90/ {print $1, $3, $4}' |
    while read -r d t p; do printf "   %-5s %-7s %-3s %s\n" "$d" "$t" "$p" "$(cat "/sys/block/$d/device/access_state" 2>/dev/null)"; done
  s=$(alua_stale); [[ -n $s ]] && echo "   ALERT: 'ready' paths not active for the kernel: $s -> './datacore-xcp.sh check'"
  echo "== iSCSI recovery_tmo (local host, session count then value): $(rec_tmo)"
  for s in /sys/class/iscsi_session/session*/recovery_tmo; do
    (( $(cat "$s") <= ISCSI_TMO_MAX )) || echo "   ALERT: ${s%/recovery_tmo} at $(cat "$s") s (> $ISCSI_TMO_MAX s)"
  done
  echo "== Multipath configuration (local host)"; cmd_mpverify
  echo "== SSH to the other host: $(n=$(local_node) && ssh_ok $((3-n)) && echo OK || echo "FAILED -> './datacore-xcp.sh ssh-setup'")"
  echo "== md5 (identical on both hosts, otherwise './datacore-xcp.sh sync')"; md5sum "$SELF" "$CONF"
}
cmd_check() {
  # 1) Inconsistent kernel ALUA state: path 'ready' for multipathd, not active in the
  #    scsi_dh_alua cache. Re-read by alua_heal (device rescan, then session rescan).
  # 2) DataCore LUN with fewer than 4 'ready' paths (syslog unless --quiet).
  # 3) On the master: HA enabled with a timeout other than HA_TIMEOUT (syslog unless --quiet).
  # Return code 1 if any of the three remains.
  local out p rc=0 q=0; [[ ${1:-} == --quiet ]] && q=1
  p=$(multipathd show paths format "%m %T" 2>/dev/null) || { echo "multipathd does not answer"; return 1; }
  alua_heal || rc=1
  out=$(multipathd show paths format "%m %T" | awk 'NR>1 && $1 ~ /^360030d90/ {t[$1]++; if ($2=="ready") r[$1]++}
        END {for (m in t) if (r[m]+0 < 4) printf "%s: %d/4 paths ready\n", m, r[m]+0}')
  if [[ -n $out ]]; then
    echo "$out"; ((q)) || logger -t datacore-xcp "Multipath degraded: $out"; rc=1
  fi
  ha_alert "$q" || rc=1
  ((rc)) || echo "DataCore multipath OK"
  return $rc
}
cmd_start() {
  master; mp_check; local n k
  k=$(ls_get)
  if dc_running; then
    # A DataCore server is already running: it holds the up-to-date data, order no longer matters
    for n in 1 2; do [[ $(vm_state "$n") == running ]] || xe vm-start uuid="$(vm_uuid "$n")" on="${HOSTS[$n]}"; done
  else
    case $k in
      [12]:dmc|[12]:ups)
        n=${k%%:*}
        echo "Last ordered shutdown (${k#*:}): ${DC_VMS[$n]} stopped last, restarted first"
        start_dc "$n" "${k#*:}"; start_dc $((3-n)) "${k#*:}" ;;
      *)
        echo "WARNING: last shutdown not done by 'stop' (key $LS_KEY: ${k:-missing})."
        echo "Power loss, crash or forced shutdown: the shutdown order of the DataCore servers is unknown."
        echo "Both DataCore VMs will start. In the DMC: identify the server that went down last,"
        echo "bring only its copy back into service ('double failure' procedure)."
        ask "Continue?" || die "start aborted"
        for n in 1 2; do [[ $(vm_state "$n") == running ]] || xe vm-start uuid="$(vm_uuid "$n")" on="${HOSTS[$n]}"; done
        ask "vDisks back in service in the DMC?" || die "run './datacore-xcp.sh start' again once handled in the DMC" ;;
    esac
  fi
  ls_clear
  wait_srs; ha_on; start_protected
  echo "Unprotected VMs: start them manually."
}
cmd_stop() {
  master; local ups=0 p v s n dc h m o a last mode rc; [[ ${1:-} == --ups ]] && ups=1
  # Host shutdown order set by the actual role: the master may have changed (HA failover)
  m=$(local_node) || exit 1; o=$((3-m))
  p=$(pool); dc=" $(vm_uuid 1) $(vm_uuid 2) "
  [[ $(xe pool-param-get uuid="$p" param-name=ha-enabled) == true ]] && xe pool-ha-disable
  stop_guests "$dc" "$ups"
  for s in "$SR_NAME" "$HB_SR_NAME"; do for v in $(sr_pbds "$s" currently-attached=true); do xe pbd-unplug uuid="$v"; done; done
  ((ups)) && echo "UPS mode: Windows shutdown of the DataCore VMs without going through the DMC"
  # DataCore: DC-02 then DC-01; a server already stopped (maintenance) is skipped. Records the last stopped.
  last=""; mode=dmc; ((ups)) && mode=ups
  for n in 2 1; do
    [[ $(vm_state "$n") == running ]] || { echo "${DC_VMS[$n]} already stopped"; continue; }
    ((ups)) || ask "'Stop DataCore Server' done on ${DC_VMS[$n]} in the DMC?" || die "shutdown aborted before ${DC_VMS[$n]}"
    shutdown_vm "$(vm_uuid "$n")"
    rc=$?; last=$n:$mode
    ((rc == 2 && ups)) && last=$n:ups-force   # DataCore cut off without a clean stop
  done
  if [[ -n $last ]]; then ls_set "$last"; echo "Last DataCore shutdown recorded: $last"; fi
  if ((ups)); then
    # Master last: it relays the shutdown to the other host
    if host_live "$o"; then
      h=$(host_uuid "$o"); a=$(xe host-param-get uuid="$h" param-name=address)
      xe host-disable uuid="$h"; xe host-shutdown uuid="$h"
      # host-shutdown returns as soon as the shutdown is accepted, before it actually completes
      echo "Waiting for ${HOSTS[$o]} ($a) to shut down, ${SHUTDOWN_TIMEOUT} s max"
      for _ in $(seq $((SHUTDOWN_TIMEOUT / 5))); do ping -c1 -W2 "$a" >/dev/null 2>&1 || break; sleep 3; done
      ping -c1 -W2 "$a" >/dev/null 2>&1 && echo "WARNING: ${HOSTS[$o]} still answers, shutting down the master anyway"
    else
      echo "${HOSTS[$o]} already down (host-metrics-live=false)"
    fi
    h=$(host_uuid "$m"); xe host-disable uuid="$h"; xe host-shutdown uuid="$h"
  else
    echo "Shut down the hosts: ${HOSTS[$o]} then ${HOSTS[$m]} (master), with xe host-disable + xe host-shutdown."
  fi
}
cmd_maint() {
  master; node "${1:-}"; local n=$1 h o v p; h=$(host_uuid "$n"); o=$(host_uuid $((3-n))); p=$(pool)
  ask "All vDisks 'Up to date' on both servers?" || die "maintenance cancelled"
  [[ $(xe pool-param-get uuid="$p" param-name=ha-enabled) == true ]] && xe pool-ha-disable
  xe host-disable uuid="$h"
  for v in $(xe vm-list resident-on="$h" power-state=running is-control-domain=false --minimal | tr , ' '); do
    [[ $v == $(vm_uuid "$n") ]] && continue
    echo "Migrating $(xe vm-param-get uuid="$v" param-name=name-label)"
    xe vm-migrate uuid="$v" host-uuid="$o" live=true || echo "  FAILED: handle manually"
  done
  ask "'Stop DataCore Server' done on ${DC_VMS[$n]} in the DMC?" || die "aborted"
  xe vm-shutdown uuid="$(vm_uuid "$n")"
  echo "${HOSTS[$n]} ready: yum update, reboot, then ./datacore-xcp.sh resume $n"
}
cmd_resume() {
  master; node "${1:-}"; local n=$1
  xe host-enable uuid="$(host_uuid "$n")"
  # An XCP-ng update can replace the multipath configuration: checked before the DataCore VM restarts
  local rc; on_host "$n" mpverify; rc=$?
  if ((rc == 255)); then
    echo "SSH to ${HOSTS[$n]} failed ('./datacore-xcp.sh ssh-setup' sets up the keys)."
    ask "Does './datacore-xcp.sh mpverify' show 'Multipath configuration OK' on ${HOSTS[$n]}?" \
      || die "multipath configuration not verified on ${HOSTS[$n]}"
  elif ((rc)); then
    die "multipath configuration changed on ${HOSTS[$n]}: './datacore-xcp.sh host $n' on it, then 'resume $n' again"
  fi
  [[ $(vm_state "$n") == running ]] || xe vm-start uuid="$(vm_uuid "$n")" on="${HOSTS[$n]}"
  wait_srs
  echo "Wait for resynchronization to complete in the DMC."; ha_on
  echo "Migrated VMs stay on ${HOSTS[$((3-n))]}: rebalance them manually (xe vm-migrate)."
}
cmd_rescue() {
  echo "Use only if the other node is down or also stuck (split-brain risk)."
  ask "Continue?" || exit 1
  local u uu
  xe host-emergency-ha-disable --force
  uu=$(/opt/xensource/bin/static-vdis list | grep -oE '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' | sort -u)
  echo "Static VDIs: ${uu:-none}"
  if [[ -n $uu ]] && ask "Delete these static VDIs (HA statefile + metadata)?"; then
    for u in $uu; do /opt/xensource/bin/static-vdis del "$u"; done
  fi
  systemctl is-active -q attach-static-vdis && systemctl kill attach-static-vdis
  xe-toolstack-restart; sleep 20
  xe host-enable uuid="$(local_host)"
  echo "Then, on the master: ./datacore-xcp.sh ha-off, then ./datacore-xcp.sh start"
}

# ---------------------------------------------------------------- dispatch
usage() {
  sed -n '2,4p' "$SELF"
  echo "Commands: nics | ssh-setup | sync | pool-net | host N | netcheck | pci-check N | pci-hide N | dcvm N | dcpci N | iscsi | relogin | sr SCSIID | ha SCSIID | ha-on | ha-off | protect VM [order] | status | check | mpverify | start | stop [--ups] | maint N | resume N | rescue"
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
# Each command runs in a subshell: a 'die' aborts the command, not the menu.
# Return code = the command's (pipefail), including 'check' and 'relogin' run by cron.
run() {
  case $1 in
    nics|status|check|relogin|mpverify|help) ( dispatch "$@" ) ;;
    *) { echo "=== $(date '+%F %T') $(hostname) : $*"; dispatch "$@"; } 2>&1 | tee -a "$LOG" ;;
  esac
}

# ---------------------------------------------------------------- menu
pause() { local _; read -r -p "Enter to go back to the menu " _ || true; }
ask_node() {
  local r; read -r -p "Node (1 = ${HOSTS[1]}, 2 = ${HOSTS[2]}): " r
  [[ $r == [12] ]] || { echo "Invalid node" >&2; return 1; }
  echo "$r"
}
pick_lun() {
  local l c; mapfile -t l < <(dc_luns)
  ((${#l[@]})) || { echo "No DataCore LUN seen by this host: run 'iscsi' and check the mappings in the DMC" >&2; return 1; }
  echo "     Paths  SCSIid  Size  SR   (4 paths expected)" >&2
  for c in "${!l[@]}"; do printf '%3d) %s\n' $((c+1)) "${l[$c]}" >&2; done
  read -r -p "LUN number: " c
  [[ $c =~ ^[0-9]+$ ]] && ((c >= 1 && c <= ${#l[@]})) || { echo "Invalid choice" >&2; return 1; }
  set -- ${l[$((c-1))]}; echo "$2"
}
pick_vm() {
  local v dc l c p nm st
  dc=" $(vm_uuid 1) $(vm_uuid 2) "
  mapfile -t l < <(for v in $(xe vm-list is-control-domain=false is-a-template=false is-a-snapshot=false --minimal | tr , ' '); do
      [[ $dc == *" $v "* ]] && continue
      p=$(xe vm-param-get uuid="$v" param-name=ha-restart-priority)
      [[ -n $p ]] && p="$p order $(xe vm-param-get uuid="$v" param-name=order)"
      printf '%s\t%s\t%s\t%s\n' "$(xe vm-param-get uuid="$v" param-name=name-label)" \
        "$(xe vm-param-get uuid="$v" param-name=power-state)" "${p:--}" "$v"
    done | sort -f)
  ((${#l[@]})) || { echo "No VM other than the DataCore VMs" >&2; return 1; }
  printf '     %-32s %-9s %s\n' VM State "HA priority" >&2
  for c in "${!l[@]}"; do
    IFS=$'\t' read -r nm st p _ <<< "${l[$c]}"; printf '%3d) %-32s %-9s %s\n' $((c+1)) "$nm" "$st" "$p" >&2
  done
  read -r -p "VM number: " c
  [[ $c =~ ^[0-9]+$ ]] && ((c >= 1 && c <= ${#l[@]})) || { echo "Invalid choice" >&2; return 1; }
  IFS=$'\t' read -r _ _ _ v <<< "${l[$((c-1))]}"; echo "$v"
}
menu_show() {
  local n role
  n=$( (local_node) 2>/dev/null ) || n="?"
  [[ $(xe pool-list params=master --minimal 2>/dev/null) == "$(local_host)" ]] && role=master || role=member
  cat <<EOM

=== datacore-xcp.sh - $(hostname): node $n, $role ===
 Host preparation
   1) nics         Physical NIC inventory                        [M]
   2) ssh-setup    Key-based SSH between the two hosts           [L]
   3) sync         Copy script and variables to the other host   [L]
   4) pool-net     DC-FE / DC-MR storage networks                [M]
   5) host         IQN, FE IP, multipathing, NTP (local node)    [2]
   6) netcheck     MTU ping on FE to the other dom0              [2]
   7) pci-check    HBA passthrough checks (local node)           [2]
   8) pci-hide     HBA hiding and reboot (local node)            [2]
 DataCore VMs
   9) dcvm         Create a DataCore VM                          [M]
  10) dcpci        Attach the HBA to a DataCore VM               [M]
 iSCSI storage and HA
  11) iscsi        iSCSI sessions and DataCore LUNs              [2]
  12) relogin      Reconnect portals, re-read the ALUA state     [2]
  13) sr           Create the data SR                            [M]
  14) ha           Heartbeat SR and HA enablement                [M]
  15) ha-on        Enable HA, or fix its timeout                 [M]
  16) ha-off       Disable HA before a planned operation         [M]
  17) protect      HA protection of a VM                         [M]
 Operations
  18) status       Overall status                                [L]
  19) check        Paths, kernel ALUA state, HA timeout          [L]
  20) mpverify     Effective multipath configuration             [L]
  21) start        Cold start of the pool                        [M]
  22) stop         Pool shutdown (normal or UPS)                 [M]
  23) maint        Put a host into maintenance                   [M]
  24) resume       Bring a host back from maintenance            [M]
  25) rescue       Unblock attach-static-vdis                    [L]
   h) help    q) quit             [M] master  [L] local host  [2] each host
EOM
}
menu() {
  local c n a id o
  # Ctrl+C aborts the running command and returns to the menu
  trap 'echo " interrupted"' INT
  while :; do
    menu_show
    read -r -p "Choice: " c || { echo; return; }
    a=()
    case $c in
      1) a=(nics) ;;  2) a=(ssh-setup) ;;  3) a=(sync) ;;  4) a=(pool-net) ;;  6) a=(netcheck) ;;
      5|7|8)
        # These commands only run on the target node: N = local node
        n=$( (local_node) 2>/dev/null ) || { echo "Local host missing from HOSTS"; pause; continue; }
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
        read -r -p "Start order [1]: " o; o=${o:-1}
        [[ $o =~ ^[0-9]+$ ]] || { echo "Invalid order"; pause; continue; }
        a=(protect "$id" "$o") ;;
      18) a=(status) ;;  19) a=(check) ;;  20) a=(mpverify) ;;  21) a=(start) ;;
      22)
        read -r -p "Shutdown: 1) normal (Stop DataCore Server in the DMC)  2) UPS (--ups): " o
        case $o in 1) a=(stop) ;; 2) a=(stop --ups) ;; *) echo "Invalid choice"; pause; continue ;; esac ;;
      25) a=(rescue) ;;
      h|H) usage; pause; continue ;;
      q|Q) return ;;
      *) echo "Invalid choice"; continue ;;
    esac
    echo "--> ./${SELF##*/} ${a[*]}"
    run "${a[@]}" || echo "--> return code $?"
    pause
  done
}

# ---------------------------------------------------------------- main
if (($#)); then
  [[ " $CMDS " == *" $1 "* ]] || { usage; exit 1; }
  run "$@"; exit
fi
[[ -t 0 ]] || { usage; exit 1; }
menu
