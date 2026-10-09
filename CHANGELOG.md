# Changelog

History of the procedure [docs/datacore-xcp-ng-deployment.md](docs/datacore-xcp-ng-deployment.md) and of the scripts, most recent revision first. Section numbers refer to the procedure. Revisions earlier than the publication embedded the scripts in the text and are not in the Git history.

*Version française : [CHANGELOG_FR.md](CHANGELOG_FR.md).*

## Changes of 2026-10-08 (revision 8)

Origin: remarks after a full deployment and the complete series of tests of section 8 with the scripts of revision 7 (results in section 8).

| Topic | Change |
| --- | --- |
| Procedure and menus | Every step gives the menu entry, then the direct command (sections 4 to 9); menu column in the command tables (sections 3.2 and 5.2); step tables in sections 4, 4.3 and 7 |
| `datacore-xcp.sh` menu | Entries renumbered: `ssh-setup` (2) and `ha-off` (16) added, 25 entries |
| Windows initiator | `InitiatorPorts` reduced to `DC-MR1` and `DC-MR2`: no more connection between DataCore servers on the front-end ports. The `Initiator` phase removes, after confirmation, the FE connections left by an earlier version; `Test` flags them |
| HA timeout | `ha-on` detects HA enabled with a timeout other than `HA_TIMEOUT` and offers to disable and re-enable it; timeout shown after enablement and by `status` (pool and `xhad.conf`); syslog alert from `check` on the master; new `ha-off` command; HA actions in Xen Orchestra forbidden |
| SR after a cold start or a loss of access to DataCore | Kernel ALUA state re-read by `relogin` (every minute) and `check`: device rescan, then session rescan if needed; `check` returns 1 while a `ready` path is not active for the kernel, so `ha-on` and `start` wait; `status` flags these paths; syslog message only when the situation changes |
| cron | `PATH` exported at the top of the script and set in `/etc/cron.d/datacore-xcp`; checked by `mpverify` |
| SSH between hosts | New `ssh-setup` command (keys and host keys in both directions); `sync` requires it and uses `BatchMode`; SSH state in `status`; clearer messages in `ha-on` and `resume` |
| DataCore VM management | New optional variable `DC_MGMT_NET` (network of VIF 0); `dcvm` checks the 5 networks before creating the VM; commands to move VIF 0 of an existing VM (section 4.4) |
| Management network | Bond required in the prerequisites; xHA behavior on 2 hosts described (section 7); test with a bonded management added |
| `check` | Returns 1 if multipathd does not answer |
| Validation (section 8) | Results of the series of 2026-10-08; expected results of the MR, management and cold start tests; test "HA toggled from Xen Orchestra" |
| `Set-DataCoreNode.ps1` | Menu header written `${env:COMPUTERNAME}:` in the EN version |

Applying to an existing pool:

1. Replace `datacore-xcp.sh` on the master; add `DC_MGMT_NET` to `datacore-xcp.conf` if a dedicated network is used.
2. **2** `ssh-setup`, then **3** `sync`.
3. **5** `host` on each host, one at a time (accept the suggested IQN with Enter): rewrites the cron file with its `PATH`. Then `cat /etc/cron.d/datacore-xcp`.
4. **18** `status` on each host: HA timeout at 120, no ALERT, SSH OK. If the timeout is wrong: **15** `ha-on` on the master, vDisks *Up to date*.
5. On each DataCore VM, one at a time: replace `Set-DataCoreNode.ps1`, set `InitiatorPorts = @('DC-MR1', 'DC-MR2')`, **4** `Initiator`, then **6** `Test` (2 sessions).
6. Move VIF 0 of the DataCore VMs if needed (section 4.4), then replay the MR, management and cold start tests of section 8.

## Changes of 2026-10-07 (revision 7)

Origin: menus requested for both scripts; `stop --ups` shut down the master first after an HA failover; DataCore server order not controlled at shutdown and restart.

| Topic | Change |
| --- | --- |
| Merge | Combines revision 6 of 2026-09-30 and the delivery of 2026-10-07, also released as "revision 6" but built on revision 5; `Set-DataCoreNode.ps1` and `DataCoreNode.psd1` remain those of revision 6 |
| `mpverify` | Added to the `datacore-xcp.sh` menu (entry 18, local host); entries `start` to `rescue` shifted to 19-23 |
| `datacore-xcp.sh` menu | No argument: menu grouped by stage, actual host role, node, LUN and VM selection, direct command shown, back to the menu after each action; direct execution unchanged (section 3.2) |
| `Set-DataCoreNode.ps1` menu | No `-Phase`: phase menu, DataCore service state in the header; `-Node` optional: detection by the MGMT MAC then the Windows name, with confirmation (section 5.1) |
| `iscsi` | SR column: DataCore SR backed by each LUN |
| `protect` | VM given by name or UUID |
| `stop --ups` | Host order from the actual role (other host, then master); wait for the other host to shut down, `SHUTDOWN_TIMEOUT` at most |
| `stop` | DataCore VMs stopped 2 then 1; *Stop DataCore Server* requested one server at a time; last shutdown recorded in `other-config:datacore-last-stopped` (`N:dmc`, `N:ups`, `N:ups-force`) |
| `start` | Last one stopped started first; *Start DataCore Server* requested after a normal `stop`; wait for port 3260 before the other server; uncontrolled shutdown detected; key cleared (section 9) |
| `datacore-xcp.conf` | Comments: node 1 = master at installation; `SHUTDOWN_TIMEOUT` also used to wait for the other host |
| Validation (section 8) | Expected results of `stop` / `start`, `stop --ups` and power loss on both nodes; `stop --ups` test after a master failover |

Applying to an existing pool: `sync`, check the md5. The first `start` without a prior `stop` of this version finds the key missing: it goes through the 'uncontrolled shutdown' branch, to be confirmed.

## Changes of 2026-09-30 (revision 6)

Origin: review of the procedure against the SANsymphony 10.0 PSP22 documentation (Best Practices: *The DataCore Server*, *Hyper-converged Virtual SAN*, *iSCSI Network and Best Practices*, *System Memory Considerations*; host configuration guides *Citrix XenServer* and *Linux*; DataCore cmdlet reference), and automation of the DMC steps through the DataCore cmdlets.

| Topic | Change |
| --- | --- |
| New `Ports` phase | Roles, IQNs and names of the iSCSI ports of both servers through the cmdlets (`Get-DcsPort`, `Set-DcsServerPortProperties`, `Set-DcsPortProperties`), ports identified by their fixed MAC; replaces the manual steps 8 and 10 of section 5.3 |
| New `Hosts` phase | XCP-ng hosts (`Add-DcsClient` / `Set-DcsClientProperties`: Citrix XenServer, Multipathing, ALUA, Preferred Server), dom0 IQN (`Register-DcsClientPort`), serving with redundant paths (`Serve-DcsVirtualDisk -EnableRedundancy`), SCSIids for `sr`/`ha`; validated order kept (dom0 sessions first) |
| DMC hosts | Multipathing and ALUA enabled on the hosts (DataCore XenServer guide), previously missing from section 6 |
| hosts file | Entry for the partner only; entry of the local server removed (DataCore) |
| Windows Update | Drivers excluded (`ExcludeWUDriversInQualityUpdate`); new `PrePatch` / `PostPatch` phases: DataCore Executive service stopped and set to Manual before patching, start type restored afterwards |
| Dumps | User-mode dumps (`LocalDumps\DumpType = 2`) in `Prepare`; kernel dump checked by `Test` |
| vCPU | `DC_VCPU` 8 → 10 (4 + 3 per pair of iSCSI ports); check in `Test` (`MinVcpu`) |
| Multipath | New `mpverify` command (also in `status`); `resume N` runs it before restarting the DataCore VM |
| Prerequisites | BIOS settings of the hosts, switches without STP and with flow control, DataCore cmdlets |
| Disk pools (section 6) | Same SAU on both sides, catalog on 2 fast tier 1 disks, tier reserve, snapshots |
| `Test` | Driver exclusion, dumps, vCPU, hosts file, DataCore state through the cmdlets |
| EN `Set-DataCoreNode.ps1` | Fixed `"$if: ..."` strings that prevented the script from loading (`"${if}: ..."`); the FR version was not affected |

Applying to an existing pool: `sync`, then `./datacore-xcp.sh status` on each host (`Multipath configuration OK` expected). On the Windows side, replace `Set-DataCoreNode.ps1`, add `Hosts`, `VirtualDisks` and `MinVcpu` to `DataCoreNode.psd1`, then `-Phase Test`. Do not replay `Prepare` on a server in service: apply the hosts file, driver exclusion and dumps settings by hand, or during a maintenance window. `DC_VCPU` only applies to a new VM: `xe vm-param-set VCPUs-max=10 VCPUs-at-startup=10` with the VM halted, node in maintenance. `Ports` does not apply to a Server Group that already has vDisks: its checks are shown by `Test`.

## Changes of 2026-09-30 (revision 5)

Origin: host 1 fenced during the "hung DataCore VM" test run after a node 2 crash. Diagnosis established a stale kernel ALUA cache on the standby paths. Fix validated by the sequence crash of DataCore VM 2, hang of DataCore VM 1, crash of node 2, hang of DataCore VM 1: no fence.

| Topic | Change |
| --- | --- |
| Multipath | `hardware_handler "1 alua"` in `custom.conf` (`host N` template); `hwhandler` check shown by `host N` and `status`; section 7 |
| `check` | Re-read (`rescan`) of the kernel ALUA state on any `ready` path not active for the kernel, logged; `--quiet` option |
| `status` | iSCSI session count; paths with checker, multipathd prio and kernel ALUA state |
| New `relogin` command | Restores sessions to portals without a session; lock, no effect if no DataCore SR is attached or if XAPI does not answer |
| Scheduled tasks | `/etc/cron.d/datacore-xcp` installed by `host N` (`relogin` every minute, `check` every 5 minutes); old `datacore-check` removed |
| HA enablement | `ha-on` (hence `ha`, `start`, `resume`) waits, after the *Up to date* confirmation, for 4 `ready` paths per LUN on each host (10 min max); key-based SSH between dom0s is a prerequisite |
| `pci-check` | `grep -q` in pipelines replaced by `grep -c` (possible false negatives under `pipefail`) |
| DataCore Best Practices script | File name fixed: `iSCSI_Best_Practices_3.11.ps1` (prerequisites, delivered files, `DataCoreNode.psd1`, section 5) |
| Validation (section 8) | Pre-test checks extended (sessions, `hwhandler`, ALUA consistency, no `Failing path`); monitoring loop; mandatory sequences without reboot; expected results completed |
| Operations (section 9) | Check after any reboot of a DataCore VM or a host; monitoring through the `host N` cron; `relogin` in the boot-stuck recovery |

Applying to an existing pool: `sync`, then `./datacore-xcp.sh host N` on each host, one at a time (accept the suggested IQN with Enter), then check `hwhandler='1 alua'` and `status`.

## Changes of 2026-09-30 (revision 4)

| Topic | Change |
| --- | --- |
| Prerequisites | Windows Server 2025 qualified by DataCore since PSP21: no more blocking prerequisite |
| DataCore iSCSI ports | Renaming of the ports and their IQNs (suffixes `fe1`, `fe2`, `mr1`, `mr2`) moved to section 5, step 10, before the `Initiator` phase; section 6 reduced to a check |
| `Initiator` phase | Port IQN renamed from `iqn.2000-08.com.datacore:server-NN` to `iqn.2000-08.com.datacore:server-fe1` (etc.); `IqnSuffix` key; portal rediscovery, target selection by IQN suffix, error if the suffix is missing; sessions shown by IQN (also in `Test`) |

## Changes of 2026-09-29 (revision 3)

| Topic | Change |
| --- | --- |
| Generalization | Procedure written with variables (`HOSTS[N]`, DataCore VM N, `SUBNET`/`DC_OCT`/`HOST_OCT`); no more hard-coded site address or name outside the defaults of the variables files; references to tests and to the test pool removed from the procedure |
| Management | No more management address in the procedure or the scripts; `Nodes[N].MgmtIp` empty by default and mandatory; console block of section 5 written with variables |
| XCP-ng variables | `NTP_SERVERS` empty by default and mandatory; `IQN_PREFIX` added (suggested IQN = `IQN_PREFIX:host-name`); `HOST_IQN` empty by default |
| Windows | Template `WIN_TEMPLATE="Windows Server 2025"` (qualified by DataCore since PSP21); `dcvm` checks that the template exists and otherwise lists the Windows templates |
| Page file | Fixed at `PagefileSizeMB` (4096) on C: instead of being removed; `Test` shows the setting |
| MTU | `MTU` / `Mtu` used by `netcheck`, `*JumboPacket`, `NlMtuBytes` and the `Test` pings (no more hard-coded 9000) |
| Validation | Status column removed; all scenarios to be run and recorded before production and after any change |

## Changes of 2026-09-28 (revision 2, feedback from the dry-run deployment)

| Topic | Change |
| --- | --- |
| XCP-ng variables | CONFIGURATION block moved out of the script into `datacore-xcp.conf`, loaded and checked at startup; fill-in table (section 3.1); `sync` command (copy of script + variables, md5); md5 of both files in `status` |
| Windows variables | CONFIGURATION block moved out of the script into `DataCoreNode.psd1` (section 5.1); `$MgmtIp` replaced by `Nodes` |
| NTP | `host N` configures NTP through XAPI (`ntp-custom-servers`, `ntp-mode`) when the host manages it, otherwise `chrony.conf`; manual procedure in section 4.2 |
| PCI hiding | Order xcp-02 then xcp-01, waiting for each host to come back (section 4.3); `pci-hide N` refused if the other host is not reachable; warning on master reboot |
| IQN | `host N` suggests `HOST_IQN[N]`, accepts input, checks the format and applies it with `xe host-param-set iscsi_iqn=`; refused if an iSCSI session is open (section 4.1) |
| Passthrough | Removed from `dcvm`; new `dcpci N` command after Windows and PV tools; HBA state in `status` |
| Windows management adapter | Identification by MAC from the console (section 5, step 3); two-pass renaming; `Prepare` checks the MGMT IP |
| Prerequisites | Visual C++ removed (not needed) |
| Page file | Removed by `Prepare` (`DisablePagefile`); checked by `Test` |
| DataCore iSCSI Best Practices | `iSCSI_Best_Practices_3.11.ps1` script called by `PostInstall` on the 4 storage adapters (filter checked); new `PostUpgrade` phase so it is not replayed after a PSP |
| Windows iSCSI initiator | New `Initiator` phase: persistent connections to FE1, FE2, MR1 and MR2 of the partner |
| DMC | Renaming of the iSCSI ports (section 6, step 2); order dom0 iSCSI sessions → *Refresh* → hosts → vDisk serving (section 6, step 6) |
| PowerShell phases | `Network` renamed `Prepare`; `Initiator` and `PostUpgrade` added |

## Changes of 2026-09-28 (revision 1)

| Topic | Change |
| --- | --- |
| Storage IP plan | 172.16.11/12/21/22.0/24 replaced by 10.200.11/12/21/22.0/24 (last octet unchanged): IP plan table, `SUBNET` in `datacore-xcp.sh`, `$Subnets` in `Set-DataCoreNode.ps1`, path table (section 6), section 5 step 6 |
| IP plan | Addressing rule and non-overlap check added in section 1 |
| iSCSI | Effective `recovery_tmo` measured at 5 s, set by multipathd from `fast_io_fail_tmo` (and not by `iscsid.conf`, which showed 20): explicit `fast_io_fail_tmo 5` in the `defaults` section of `custom.conf` (ignored in `devices`), `iscsid.conf` no longer modified, `status` alerts above `ISCSI_TMO_MAX` (30 s); detection budget brought down to ~15 s. Mechanism validated by test (5 → 10 → 5 after `multipathd reconfigure`) |
| `host N` | Idempotent: an already configured FE PIF is no longer reconfigured (avoids cutting the iSCSI paths); can be rerun to apply a new `custom.conf` |
| Heartbeat SR | Size raised to 10 GB (the HA VDIs take ~3.7 GiB in thick LVM); `HB_MIN_FREE_GIB` check in `ha_on`, only if the HA VDIs do not exist yet; cases added in section 10 |
| SR growth | Procedure validated (rescan and `resize map` on each host, then `sr-scan`; no `pvresize`) |

If the test pool keeps the old plan, do not reapply `host N` or `-Phase Prepare` (formerly `Network`) to it: the FE IPs of the dom0s and VMs would change, while the SRs and DataCore mappings still point to 172.16.x.x.

## Changes of 2026-09-23

| Topic | Change |
| --- | --- |
| XAPI multipathing | Enabled by `host N` (it was enabled manually on the test pool); required by `sr`, `ha`, `start`; shown by `status` |
| HBA BDF | One BDF per node (`PCI_BDF[N]`); `pci-check N` / `pci-hide N`; `dcvm N` uses the BDF of the right host |
| Disk detection | Through `lsblk` (PKNAME) instead of truncating the name; inventory of the dom0 disks in `pci-check` |
| Scope | SAS HBA only; NVMe mention removed |
| iSCSI | `replacement_timeout` set to 20 s (config and existing nodes); effective `recovery_tmo` shown by `iscsi` and `status` |
| Architecture | Local paths through the internal bridge: expected result of the "FE cut" test fixed, PowerShell `Test` clarified |
| `pool-net` | Refused if a DataCore VM is running; networks already configured are skipped |
| `host N` | PIF checks, warning if NTP is managed by XAPI |
| New commands | `netcheck`, `ha-on`, `check`, `stop --ups` |
| `start` | Protected VMs started by order |
| `stop` | Clean shutdown delay then forced shutdown; UPS mode |
| `protect` | Agility check and HA plan display |
| `dcvm` | `has-vendor-device=false`, cores-per-socket, optional vCPU mask |
| Logging | `/var/log/datacore-xcp.log`, script md5 in `status` |
| PowerShell | `PreUpgrade` phase, safeguard on `Network`, non-blocking `*JumboPacket`, Windows Update without automatic reboot |
| Operations | Forbidden actions, Windows and PSP patching, monitoring, backups, SR growth, disk replacement |
| Tests | Hung or crashed DataCore VM, management loss, `stop --ups`, power loss, patching cycle, I/O freeze measurement |
