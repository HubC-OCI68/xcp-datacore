# DataCore SANsymphony on XCP-ng 8.3 (2-node hyperconverged pool)

Procedure and scripts to deploy DataCore SANsymphony 10.0 PSP22 in a hyperconverged setup on an XCP-ng 8.3 pool of 2 hosts: one SANsymphony Windows VM per host with its SAS HBA in passthrough, mirrored vDisks presented over iSCSI to both dom0s, and XCP-ng HA on top.

*Version française : [docs/datacore-xcp-ng-deployment_FR.md](docs/datacore-xcp-ng-deployment_FR.md) — scripts en français dans [scripts/fr/](scripts/fr/).*

> **Read this first.** XCP-ng is not in the DataCore compatibility matrix: mirrored vDisks are "Not Qualified" on it, with no contractual support for high availability. This work comes from a test pool; several points are still to be validated (section 11 of the procedure). Use it at your own risk, and run the validation tests of section 8 on your own hardware before any production use.

## Contents

| Path | What |
| --- | --- |
| [docs/datacore-xcp-ng-deployment.md](docs/datacore-xcp-ng-deployment.md) | The procedure (English) |
| [docs/datacore-xcp-ng-deployment_FR.md](docs/datacore-xcp-ng-deployment_FR.md) | The procedure (French) |
| [CHANGELOG.md](CHANGELOG.md) / [CHANGELOG_FR.md](CHANGELOG_FR.md) | Change history, revisions 1 to 8 |
| [scripts/en/](scripts/en/) | Scripts and variables files with English messages |
| [scripts/fr/](scripts/fr/) | The same scripts with French messages |

Each `scripts/` folder holds the same four files; pick one language, the logic is identical.

| File | Runs on | Role |
| --- | --- | --- |
| `datacore-xcp.sh` | each XCP-ng host (`/root`) | Network, IQN, NTP, multipath, iSCSI, HBA passthrough, DataCore VMs, SRs, HA, start/stop, maintenance, monitoring |
| `datacore-xcp.conf` | next to the script | All site values for the XCP-ng side |
| `Set-DataCoreNode.ps1` | each DataCore VM (`C:\DataCore\Scripts`) | Windows network and system settings, iSCSI initiator (mirror links), DataCore ports and hosts through the DataCore cmdlets, patching, tests |
| `DataCoreNode.psd1` | next to the script | All site values for the Windows side |

Not included: the DataCore script `iSCSI_Best_Practices_3.11.ps1`, to be obtained from DataCore.

## Quick start

1. Read the procedure, at least sections 1 (architecture) and 2 (prerequisites).
2. Copy `datacore-xcp.sh` and `datacore-xcp.conf` to `/root` on the pool master, fill in `datacore-xcp.conf` (table in section 3.1), then:

   ```bash
   chmod +x datacore-xcp.sh
   ./datacore-xcp.sh          # menu; ./datacore-xcp.sh help lists the direct commands
   ```
3. Follow the procedure from section 4. Both scripts are menu-driven and contain no site value: all of them live in the two variables files.

## License

[MIT](LICENSE). DataCore and SANsymphony are trademarks of DataCore Software; this project is not affiliated with or endorsed by DataCore or the XCP-ng project.
