@IsTest
private class DTSyncTest {

    // Stands in for the flow so tests run in orgs without Revenue Cloud.
    private class StubRefresher implements DTSyncService.Refresher {
        Set<String> failing;
        StubRefresher(Set<String> failing) {
            this.failing = failing;
        }
        public DTSyncService.Result refresh(String tableApiName) {
            return failing.contains(tableApiName)
                ? new DTSyncService.Result(false, 'Simulated failure')
                : new DTSyncService.Result(true, null);
        }
    }

    private static void stub(Set<String> failing) {
        DTSyncService.refresher = new StubRefresher(failing);
    }

    @IsTest
    static void fullSuccessLogsAndUpsertsStatuses() {
        stub(new Set<String>());
        DTSync_Log__c log = DTSyncService.runSync(
            new List<String>{ 'Table_A', 'Table_B' }, DTSyncService.TRIGGER_USER, UserInfo.getUserId(), DTSyncService.TYPE_FULL
        );
        log = [SELECT Status__c, Tables_Succeeded__c, Tables_Failed__c FROM DTSync_Log__c WHERE Id = :log.Id];
        Assert.areEqual('Success', log.Status__c);
        Assert.areEqual(2, log.Tables_Succeeded__c);
        Assert.areEqual(2, [SELECT COUNT() FROM DTSync_Table_Status__c WHERE Last_Sync_Status__c = 'Success']);

        // A second run updates the same status rows instead of adding new ones.
        DTSyncService.runSync(new List<String>{ 'Table_A' }, DTSyncService.TRIGGER_USER, null, DTSyncService.TYPE_SINGLE);
        Assert.areEqual(2, [SELECT COUNT() FROM DTSync_Table_Status__c]);
    }

    @IsTest
    static void partialFailureRecordsError() {
        stub(new Set<String>{ 'Table_B' });
        DTSync_Log__c log = DTSyncService.runSync(
            new List<String>{ 'Table_A', 'Table_B' }, DTSyncService.TRIGGER_API, null, DTSyncService.TYPE_FULL
        );
        log = [SELECT Status__c, Error_Message__c FROM DTSync_Log__c WHERE Id = :log.Id];
        Assert.areEqual('Partial', log.Status__c);
        Assert.isTrue(log.Error_Message__c.contains('Table_B'));
        DTSync_Table_Status__c b = [SELECT Last_Sync_Status__c, Error_Detail__c FROM DTSync_Table_Status__c WHERE Name = 'Table_B'];
        Assert.areEqual('Failed', b.Last_Sync_Status__c);
    }

    @IsTest
    static void hourlyLimitSkipsRemainingTables() {
        stub(new Set<String>());
        insert new DTSync_Log__c(
            Status__c = 'Success', Start_Time__c = System.now(),
            Tables_Succeeded__c = DTSyncService.HOURLY_REFRESH_LIMIT - 1, Tables_Failed__c = 0
        );
        DTSync_Log__c log = DTSyncService.runSync(
            new List<String>{ 'Table_A', 'Table_B', 'Table_C' }, DTSyncService.TRIGGER_USER, null, DTSyncService.TYPE_FULL
        );
        log = [SELECT Status__c, Tables_Succeeded__c FROM DTSync_Log__c WHERE Id = :log.Id];
        Assert.areEqual(1, log.Tables_Succeeded__c);
        Assert.areEqual('Partial', log.Status__c);
        Assert.areEqual(2, [SELECT COUNT() FROM DTSync_Table_Status__c WHERE Last_Sync_Status__c = 'Skipped']);
    }

    @IsTest
    static void overallStatusCoversEveryCase() {
        Assert.areEqual('Success', DTSyncService.overallStatus(2, 0, 0));
        Assert.areEqual('Failed', DTSyncService.overallStatus(0, 2, 0));
        Assert.areEqual('Skipped', DTSyncService.overallStatus(0, 0, 2));
        Assert.areEqual('Partial', DTSyncService.overallStatus(1, 1, 0));
    }

    @IsTest
    static void queueableRunsSync() {
        stub(new Set<String>());
        Test.startTest();
        System.enqueueJob(new DTSyncQueueable(
            new List<String>{ 'Table_A' }, DTSyncService.TRIGGER_USER, null, DTSyncService.TYPE_FULL
        ));
        Test.stopTest();
        Assert.areEqual(1, [SELECT COUNT() FROM DTSync_Log__c]);
    }

    @IsTest
    static void controllerEndpoints() {
        stub(new Set<String>());
        Test.startTest();
        String jobId = DTSyncController.syncAll();
        Test.stopTest();
        Assert.areEqual(true, DTSyncController.getJobStatus(jobId).get('found'));
        Assert.isNotNull(DTSyncController.getTables());
        Assert.isNotNull(DTSyncController.refreshTable('Table_A'));
        Assert.isFalse(DTSyncController.getHistory(5, 0).isEmpty());
    }

    @IsTest
    static void scheduleLifecycle() {
        Assert.areEqual(false, DTSyncController.getSchedule().get('exists'));
        DTSyncController.setSchedule('0 0 2 * * ?');
        Assert.areEqual(true, DTSyncController.getSchedule().get('exists'));
        DTSyncController.disableSchedule();
        Assert.areEqual(false, DTSyncController.getSchedule().get('exists'));
    }

    @IsTest
    static void schedulerEnqueuesSync() {
        stub(new Set<String>());
        Test.startTest();
        new DTSyncScheduler().execute(null);
        Test.stopTest();
        Assert.areEqual(1, [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'DTSyncQueueable']);
    }

    @IsTest
    static void restEndpoints() {
        stub(new Set<String>());
        RestContext.response = new RestResponse();

        RestContext.request = request('POST', '/dtsync/refresh-table', '{"tableApiName":"Table_A"}');
        DTSyncRestResource.doPost();
        Assert.areEqual(200, RestContext.response.statusCode);

        RestContext.request = request('POST', '/dtsync/refresh-table', '{}');
        DTSyncRestResource.doPost();
        Assert.areEqual(400, RestContext.response.statusCode);

        RestContext.request = request('GET', '/dtsync/history', null);
        DTSyncRestResource.doGet();
        Assert.areEqual(200, RestContext.response.statusCode);

        RestContext.request = request('GET', '/dtsync/tables', null);
        DTSyncRestResource.doGet();
        Assert.areEqual(200, RestContext.response.statusCode);

        RestContext.request = request('GET', '/dtsync/nope', null);
        DTSyncRestResource.doGet();
        Assert.areEqual(404, RestContext.response.statusCode);

        Test.startTest();
        RestContext.request = request('POST', '/dtsync/sync', null);
        DTSyncRestResource.doPost();
        Test.stopTest();
        Assert.areEqual(200, RestContext.response.statusCode);
    }

    private static RestRequest request(String method, String path, String body) {
        RestRequest req = new RestRequest();
        req.httpMethod = method;
        req.requestURI = '/services/apexrest' + path;
        if (body != null) {
            req.requestBody = Blob.valueOf(body);
        }
        return req;
    }
}
