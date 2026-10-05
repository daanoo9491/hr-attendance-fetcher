# HR Auto Attendance Fetcher

Two independent apps in one repo:

| Folder        | What it is                                   | Runs where                              |
|---------------|----------------------------------------------|-----------------------------------------|
| `worker/`     | Attendance Fetcher SaaS (API + dashboard)    | Cloudflare Workers + D1                 |
| `connector/`  | ZKT Connector - reads K50 attendance logs    | A Windows PC on the same LAN as the K50 |

Flow: Worker cron (every 2 days) creates a sync job -> Connector polls the
Worker API -> reads ONLY attendance logs from the ZKTeco K50 -> uploads them
to the Worker -> stored in D1.

The connector only makes OUTBOUND HTTPS calls, so no port forwarding is
needed and the K50 is never exposed to the internet.