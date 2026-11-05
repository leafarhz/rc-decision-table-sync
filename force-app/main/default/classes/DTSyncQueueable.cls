// Runs a sync off the user's transaction. Enqueued by DTSyncController, DTSyncScheduler and DTSyncRestResource.
public with sharing class DTSyncQueueable implements Queueable, Database.AllowsCallouts {

    private List<String> tableApiNames;
    private String triggeredBy;
    private Id userId;
    private String syncType;

    public DTSyncQueueable(List<String> tableApiNames, String triggeredBy, Id userId, String syncType) {
        this.tableApiNames = tableApiNames;
        this.triggeredBy = triggeredBy;
        this.userId = userId;
        this.syncType = syncType;
    }

    // Full sync of every active table.
    public DTSyncQueueable(String triggeredBy, Id userId) {
        this(DTSyncService.activeTableApiNames(), triggeredBy, userId, DTSyncService.TYPE_FULL);
    }

    public void execute(QueueableContext ctx) {
        DTSyncService.runSync(tableApiNames, triggeredBy, userId, syncType);
    }
}
