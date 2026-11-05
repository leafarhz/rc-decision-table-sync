public with sharing class DTSyncScheduler implements Schedulable {
    public void execute(SchedulableContext ctx) {
        System.enqueueJob(new DTSyncQueueable(DTSyncService.TRIGGER_SCHEDULED, null));
    }
}
