# DataCore SANsymphony on XCP-ng 8.3 (2-node hyperconverged pool)

Procedure and scripts to deploy DataCore SANsymphony 10.0 PSP22 in a hyperconverged setup on an XCP-ng 8.3 pool of 2 hosts: one SANsymphony Windows VM per host with its SAS HBA in passthrough, mirrored vDisks presented over iSCSI to both dom0s, and XCP-ng HA on top.

*Version française : [docs/datacore-xcp-ng-deployment_FR.md](docs/datacore-xcp-ng-deployment_FR.md) — scripts en français dans [scripts/fr/](scripts/fr/).*

> **Read this first.** XCP-ng is not in the DataCore compatibility matrix: mirrored vDisks are "Not Qualified" on it, with no contractual support for high availability. This work comes from a test pool and was written with the help of an AI assistant (see the disclosure below); several points are still to be validated (section 11 of the procedure). Use it at your own risk, and run the validation tests of section 8 on your own hardware before any production use.

## AI assistance disclosure

The procedure and all the scripts in this repository were written with the help of an AI assistant (Claude, by Anthropic), over several working sessions directed by the author. This covers the bash and PowerShell code, the documentation in both languages, the translations and this README.

What that means in practice:

- **Human part**: the architecture choices, the hardware, the deployment on a test pool, the execution of the validation tests (section 8) and the feedback that drove each revision ([CHANGELOG.md](CHANGELOG.md)) come from the author.
- **AI part**: the text and the code were drafted and revised by the assistant from that feedback and from the DataCore and XCP-ng documentation. The author is an infrastructure administrator, not a professional developer: the code has not been through an independent human code review.
- **Not everything has been run for real**: some parts were only syntax-checked or tested against simulated cmdlets, and some explanations are deductions rather than observations. They are listed as open items in section 11 of the procedure.

Read the scripts before running them, test on non-production hardware first, and report anything wrong through the repository issues.

*Français : la procédure et l'ensemble des scripts de ce dépôt ont été rédigés avec l'aide d'un assistant IA (Claude, d'Anthropic), sous la direction de l'auteur, qui a fait les choix d'architecture, le déploiement sur un pool de test et les tests de validation. Le code n'a pas fait l'objet d'une revue humaine indépendante, et certaines parties n'ont été contrôlées qu'en syntaxe ou avec des cmdlets simulées (points ouverts, section 11 de la procédure). Lisez les scripts avant de les exécuter et testez hors production.*

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
