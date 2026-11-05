# Revenue Cloud Decision Table Sync

Refresh Salesforce Revenue Cloud pricing **decision tables** on demand, on a schedule, or from CI, and keep a log of every run.

## Why

In Revenue Cloud, decision tables (price book entries, volume tiers, attribute adjustments, contract pricing and more) cache their source rows. When prices change, the pricing engine keeps using the old rows until each table is **refreshed**.

- Decision table rows are data, not metadata. They don't travel in change sets or packages.
- Refreshing is a manual Setup task, one table at a time.
- Salesforce throttles refreshes per org per hour.

This project turns that chore into one button, a schedule and a REST endpoint.

## What you get

| Piece | What it does |
|---|---|
| `DTSync_Refresh_Decision_Table` (flow) | Wraps the standard `refreshDecisionTable` action and returns `$Flow.FaultMessage` instead of an "unhandled fault". |
| `DTSync_Table__mdt` (custom metadata) | The list of tables to refresh. Ships with 11 standard Revenue Cloud pricing tables. Add, remove or deactivate tables without touching code. |
| `DTSyncService` | Refreshes the tables, guards the hourly limit, logs the run, and records each table's last status. |
| `DTSyncQueueable` / `DTSyncScheduler` | Runs a full sync asynchronously, or on a cron schedule. |
| `DTSyncController` + `dtSyncConsole` (LWC) | Console tab with **Sync all tables**, a per-table **Refresh now** action, schedule settings and run history. |
| `DTSyncRestResource` | `/services/apexrest/dtsync/*` endpoints for pipelines and external tools. |
| `DTSync_Log__c`, `DTSync_Table_Status__c` | Run history and per-table status. |
| `DTSync_Admin` (permission set) | Access to the tab, classes, objects and flow. |

## Install

Prerequisites: an org with Revenue Cloud (Revenue Lifecycle Management) and the decision tables you want to refresh. You also need the Salesforce CLI.

```bash
git clone https://github.com/leafarhz/rc-decision-table-sync.git
cd rc-decision-table-sync
sf project deploy start --target-org <alias> --test-level RunSpecifiedTests --tests DTSyncTest
sf org assign permset --name DTSync_Admin --target-org <alias>
```

Then open the **Decision Table Sync** tab from the App Launcher.

## Check your table names first

The action needs each table's **DeveloperName**, not its label. The shipped list uses the standard Revenue Cloud names, but confirm them in your org:

```bash
sf data query --target-org <alias> \
  --query "SELECT DeveloperName, SetupName, Status FROM DecisionTable ORDER BY SetupName"
```

If you see a mismatch, edit the records in **Setup → Custom Metadata Types → Decision Table Sync Table**, or edit `force-app/main/default/customMetadata/` and redeploy. Untick **Active** on any table you don't use.

## REST

```bash
# Full sync (async). Returns {"jobId": "..."}
sf api request rest /services/apexrest/dtsync/sync --method POST --target-org <alias>

# Refresh one table now
sf api request rest /services/apexrest/dtsync/refresh-table --method POST \
  --body '{"tableApiName":"Price_Book_Entry_Decision_Table_v2"}' --target-org <alias>

# Read
sf api request rest "/services/apexrest/dtsync/tables" --target-org <alias>
sf api request rest "/services/apexrest/dtsync/history?pageSize=10" --target-org <alias>
sf api request rest "/services/apexrest/dtsync/job?jobId=<id>" --target-org <alias>
```

A typical pipeline step: deploy pricing data with your data tool, then `POST /dtsync/sync`.

## Things that will bite you

- **Use Flow, not Apex, to call the action.** `refreshDecisionTable` isn't reliably invocable from Apex, so this project calls it through an autolaunched flow.
- **Always add a fault connector.** Without one you only get "An unhandled fault has occurred". The flow stores `$Flow.FaultMessage` in an output variable.
- **Do DML after the refreshes.** `DTSyncService` refreshes every table first and writes logs at the end, to avoid "uncommitted work pending" errors.
- **Mind the hourly limit.** `DTSyncService.HOURLY_REFRESH_LIMIT` (default 20) is checked against the last hour of logs. Tables over the budget are marked **Skipped** instead of failing. Confirm the current limit for your release and adjust the constant.
- **A refresh is not instant.** A refresh request can succeed while the table is still rebuilding. Give large tables a few minutes before testing prices.

## Tests

`DTSyncTest` swaps the flow for a stub, so the tests also pass in orgs without Revenue Cloud:

```bash
sf apex run test --class-names DTSyncTest --result-format human --code-coverage --target-org <alias>
```

## License

MIT
