ZKT Connector
=============

The ZKT Connector reads attendance from your ZKTeco machine (K40 / K50) and
sends it to your HR Attendance dashboard. It only READS the machine: it never
changes, clears or restarts it.

This download is already set up for your company. The file ".env" contains
your connector token - keep this folder private.


INSTALL (about 2 minutes)
-------------------------
Use a Windows PC that stays on and is on the same network as the machine.

  1. Right-click the ZIP file and choose "Extract All...".
  2. Open the extracted folder and double-click  Install.cmd
  3. Click "Yes" when Windows asks for administrator permission.
     If Windows shows "Windows protected your PC", click "More info"
     and then "Run anyway".
  4. Wait for "INSTALLED". Node.js is installed automatically if needed.

The connector then runs in the background and starts with Windows, even
before anyone logs in. You can delete the extracted folder afterwards.

Installed to : C:\ProgramData\ZKTConnector
Log file     : C:\ProgramData\ZKTConnector\logs\connector.log


START, STOP AND STATUS
----------------------
After installing, use Start menu > ZKT Connector, or these files:
  Start-Connector.cmd   start (or restart) the connector
  Stop-Connector.cmd    stop it (it starts again when Windows restarts)
  Connector-Status.cmd  is it running? shows the latest log lines


CHECK THE MACHINE CONNECTION
----------------------------
Double-click  Test-Connection.cmd  (in the extracted folder). It reads the
machine once and shows the serial number, number of punches and names.


UPDATE
------
Download the installer again from the dashboard and run Install.cmd.
It replaces the old version automatically.


REMOVE
------
Double-click  Uninstall.cmd


TROUBLESHOOTING
---------------
- "Cannot connect": ping the machine's IP from this PC, and make sure this
  PC is on the same network (for example 192.168.10.x).
- Close ZKTime / ZKBio Time if it is open: the machine often allows only one
  connection at a time.
- "Connector token is not valid": download the installer again from the
  dashboard and run Install.cmd.