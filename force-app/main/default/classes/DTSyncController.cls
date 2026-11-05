// Apex behind the dtSyncConsole Lightning Web Component.
public with sharing class DTSyncController {

    public class TableRow {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public String usageType;
        @AuraEnabled public Datetime lastSyncAt;
        @AuraEnabled public String lastSyncStatus;
        @AuraEnabled public String errorDetail;
    }

    @AuraEnabled
    public static String syncAll() {
        return System.enqueueJob(new DTSyncQueueable(DTSyncService.TRIGGER_USER, UserInfo.getUserId()));
    }

    // Refreshes one table now, in the user's transaction.
    @AuraEnabled
    public static DTSync_Log__c refreshTable(String tableApiName) {
        try {
            return DTSyncService.runSync(
                new List<String>{ tableApiName }, DTSyncService.TRIGGER_USER, UserInfo.getUserId(), DTSyncService.TYPE_SINGLE
            );
        } catch (Exception e) {
            throw new AuraHandledException('Could not refresh ' + tableApiName + ': ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static Map<String, Object> getJobStatus(String jobId) {
        List<AsyncApexJob> jobs = [
            SELECT Id, Status, NumberOfErrors, ExtendedStatus, CompletedDate
            FROM AsyncApexJob
            WHERE Id = :jobId
            LIMIT 1
        ];
        if (jobs.isEmpty()) {
            return new Map<String, Object>{ 'found' => false };
        }
        AsyncApexJob j = jobs[0];
        return new Map<String, Object>{
            'found' => true,
            'status' => j.Status,
            'errors' => j.NumberOfErrors,
            'detail' => j.ExtendedStatus,
            'completed' => j.CompletedDate
        };
    }

    // Every active table, joined with its last sync result.
    @AuraEnabled
    public static List<TableRow> getTables() {
        Map<String, DTSync_Table_Status__c> statusByName = new Map<String, DTSync_Table_Status__c>();
        for (DTSync_Table_Status__c s : [
            SELECT Name, Last_Sync_At__c, Last_Sync_Status__c, Error_Detail__c
            FROM DTSync_Table_Status__c
        ]) {
            statusByName.put(s.Name, s);
        }
        List<TableRow> rows = new List<TableRow>();
        for (DTSync_Table__mdt t : DTSyncService.activeTables()) {
            TableRow row = new TableRow();
            row.apiName = t.Table_API_Name__c;
            row.label = t.MasterLabel;
            row.usageType = t.Usage_Type__c;
            DTSync_Table_Status__c s = statusByName.get(t.Table_API_Name__c);
            if (s != null) {
                row.lastSyncAt = s.Last_Sync_At__c;
                row.lastSyncStatus = s.Last_Sync_Status__c;
                row.errorDetail = s.Error_Detail__c;
            }
            rows.add(row);
        }
        return rows;
    }

    @AuraEnabled
    public static List<DTSync_Log__c> getHistory(Integer pageSize, Integer pageOffset) {
        Integer size = pageSize == null ? 10 : Math.min(pageSize, 200);
        Integer offset = pageOffset == null ? 0 : pageOffset;
        return [
            SELECT Id, Name, Status__c, Triggered_By__c, Triggered_By_User__r.Name, Sync_Type__c,
                   Start_Time__c, Duration_Seconds__c, Tables_Succeeded__c, Tables_Failed__c, Error_Message__c
            FROM DTSync_Log__c
            ORDER BY Start_Time__c DESC
            LIMIT :size
            OFFSET :offset
        ];
    }

    @AuraEnabled
    public static Map<String, Object> getSchedule() {
        List<CronTrigger> triggers = findSchedule();
        if (triggers.isEmpty()) {
            return new Map<String, Object>{ 'exists' => false };
        }
        CronTrigger ct = triggers[0];
        return new Map<String, Object>{
            'exists' => true,
            'cronExpression' => ct.CronExpression,
            'nextFireTime' => ct.NextFireTime,
            'state' => ct.State
        };
    }

    @AuraEnabled
    public static String setSchedule(String cronExpression) {
        disableSchedule();
        try {
            return System.schedule(DTSyncService.SCHEDULE_JOB_NAME, cronExpression, new DTSyncScheduler());
        } catch (Exception e) {
            throw new AuraHandledException('Invalid schedule "' + cronExpression + '": ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static void disableSchedule() {
        for (CronTrigger ct : findSchedule()) {
            System.abortJob(ct.Id);
        }
    }

    private static List<CronTrigger> findSchedule() {
        return [
            SELECT Id, CronExpression, NextFireTime, State
            FROM CronTrigger
            WHERE CronJobDetail.Name = :DTSyncService.SCHEDULE_JOB_NAME
        ];
    }
}
