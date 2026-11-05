// REST access for CI pipelines or external tools.
//   POST /services/apexrest/dtsync/sync          -> { "jobId": "..." }
//   POST /services/apexrest/dtsync/refresh-table  body { "tableApiName": "..." }
//   GET  /services/apexrest/dtsync/tables
//   GET  /services/apexrest/dtsync/history?pageSize=10&pageOffset=0
//   GET  /services/apexrest/dtsync/job?jobId=...
@RestResource(urlMapping='/dtsync/*')
global with sharing class DTSyncRestResource {

    @HttpGet
    global static void doGet() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        String action = action(req);
        try {
            if (action == 'tables') {
                respond(res, 200, DTSyncController.getTables());
            } else if (action == 'history') {
                respond(res, 200, DTSyncController.getHistory(intParam(req, 'pageSize', 10), intParam(req, 'pageOffset', 0)));
            } else if (action == 'job') {
                respond(res, 200, DTSyncController.getJobStatus(req.params.get('jobId')));
            } else {
                respond(res, 404, new Map<String, String>{ 'error' => 'Unknown action: ' + action });
            }
        } catch (Exception e) {
            respond(res, 500, new Map<String, String>{ 'error' => e.getMessage() });
        }
    }

    @HttpPost
    global static void doPost() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        String action = action(req);
        try {
            if (action == 'sync') {
                Id jobId = System.enqueueJob(new DTSyncQueueable(DTSyncService.TRIGGER_API, UserInfo.getUserId()));
                respond(res, 200, new Map<String, String>{ 'jobId' => jobId });
            } else if (action == 'refresh-table') {
                String table = (String) body(req).get('tableApiName');
                if (String.isBlank(table)) {
                    respond(res, 400, new Map<String, String>{ 'error' => 'tableApiName is required.' });
                    return;
                }
                DTSync_Log__c log = DTSyncService.runSync(
                    new List<String>{ table }, DTSyncService.TRIGGER_API, UserInfo.getUserId(), DTSyncService.TYPE_SINGLE
                );
                respond(res, 200, log);
            } else {
                respond(res, 404, new Map<String, String>{ 'error' => 'Unknown action: ' + action });
            }
        } catch (Exception e) {
            respond(res, 500, new Map<String, String>{ 'error' => e.getMessage() });
        }
    }

    private static String action(RestRequest req) {
        return req.requestURI.substringAfterLast('/');
    }

    private static Integer intParam(RestRequest req, String name, Integer fallback) {
        String value = req.params.get(name);
        return String.isBlank(value) ? fallback : Integer.valueOf(value);
    }

    private static Map<String, Object> body(RestRequest req) {
        if (req.requestBody == null || req.requestBody.size() == 0) {
            return new Map<String, Object>();
        }
        return (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());
    }

    private static void respond(RestResponse res, Integer status, Object data) {
        res.statusCode = status;
        res.addHeader('Content-Type', 'application/json');
        res.responseBody = Blob.valueOf(JSON.serialize(data));
    }
}
