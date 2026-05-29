# Manual Sources And XG5000 Windows

Use this file as a pointer list. Load official manuals directly when exact instruction semantics, CPU-specific limits, or communication parameter tables are needed.

## Source Pointers

- LS ELECTRIC XG5000 IEC English Manual V2.5:
  `https://www.ls-electric.com/upload/customer/download/1318/XG5000IEC_English_Manual_V2.5.pdf`
- XG5000 User Manual hosted by AutomationDirect:
  `https://cdn.automationdirect.com/static/manuals/lselectric/xg5000usermanual.pdf`
- AutomationDirect XG5000 Software Overview:
  `https://cdn.automationdirect.com/static/helpfiles/ls_plc/Content/A_IntroductionTopics/LP008-SoftwareOverview.htm`

## XG5000 Windows Useful For Diagnosis

The XG5000 overview describes diagnosis-related windows that are important for CUCP work:

- Project window: CPU, I/O, communication settings, and programs.
- P2P window: peer-to-peer connection configuration.
- Monitor windows: real-time variable and memory address values.
- Check Program: program errors, warnings, and messages.
- Find windows: search for device or text.
- Communication window: CPU connection status.
- Cross Reference: application details for devices and variables.
- Used Device: memory address use in the project.
- Duplicate Coil: redundant memory address usage.

## Skill Rule

When possible, use XG5000's own Check Program, Used Device, Cross Reference, and Duplicate Coil windows as authoritative evidence. The local `diagnose-ladder.ps1` script is only a fast first-pass text checker.
