// Core of the decision table sync: reads the table list from DTSync_Table__mdt,
// refreshes each table through the DTSync_Refresh_Decision_Table flow, and logs the result.
//
// Why a flow? refreshDecisionTable cannot be invoked from Apex directly in every release,
// so the flow wraps it and returns any fault message in its ErrorMessage output.
//
// All DML happens after every refresh has run. Mixing DML and refreshes in one
// transaction can fail with "uncommitted work pending".
public with sharing class DTSyncService {

    public static final String FLOW_NAME = 'DTSync_Refresh_Decision_Table';
    public static final String SCHEDULE_JOB_NAME = 'DTSync_Scheduled';

    // Salesforce throttles decision table refreshes per org. Check the current limit
    // for your release and adjust. The guard skips tables rather than failing them.
    public static final Integer HOURLY_REFRESH_LIMIT = 20;

    public static final String TRIGGER_USER = 'User';
    public static final String TRIGGER_SCHEDULED = 'Scheduled';
    public static final String TRIGGER_API = 'API';
    public static final String TYPE_FULL = 'Full';
    public static final String TYPE_SINGLE = 'Single';

    public class Result {
        public Boolean success;
        public String message;
        public Result(Boolean success, String message) {
            this.success = success;
            this.message = message;
        }
    }

    public interface Refresher {
        Result refresh(String tableApiName);
    }

    public class FlowRefresher implements Refresher {
        public Result refresh(String tableApiName) {
            try {
                Flow.Interview interview = Flow.Interview.createInterview(
                    FLOW_NAME, new Map<String, Object>{ 'DecisionTableApiName' => tableApiName }
                );
                interview.start();
                String error = (String) interview.getVariableValue('ErrorMessage');
                return new Result(String.isBlank(error), error);
            } catch (Exception e) {
                return new Result(false, e.getMessage());
            }
        }
    }

    @TestVisible
    private static Refresher refresher = new FlowRefresher();

    // Active tables from custom metadata, in sort order.
    public static List<DTSync_Table__mdt> activeTables() {
        return [
            SELECT DeveloperName, MasterLabel, Table_API_Name__c, Usage_Type__c, Sort_Order__c
            FROM DTSync_Table__mdt
            WHERE Active__c = true
            ORDER BY Sort_Order__c ASC
        ];
    }

    public static List<String> activeTableApiNames() {
        List<String> names = new List<String>();
        for (DTSync_Table__mdt t : activeTables()) {
            names.add(t.Table_API_Name__c);
        }
        return names;
    }

    // Refreshes counted from sync logs started in the last hour.
    public static Integer refreshesInLastHour() {
        AggregateResult agg = [
            SELECT SUM(Tables_Succeeded__c) ok, SUM(Tables_Failed__c) failed
            FROM DTSync_Log__c
            WHERE Start_Time__c >= :System.now().addHours(-1)
        ];
        Decimal ok = (Decimal) agg.get('ok');
        Decimal failed = (Decimal) agg.get('failed');
        return (ok == null ? 0 : ok.intValue()) + (failed == null ? 0 : failed.intValue());
    }

    public static DTSync_Log__c runSync(List<String> tableApiNames, String triggeredBy, Id userId, String syncType) {
        Datetime startTime = System.now();
        Map<String, DTSync_Table__mdt> config = new Map<String, DTSync_Table__mdt>();
        for (DTSync_Table__mdt t : activeTables()) {
            config.put(t.Table_API_Name__c, t);
        }

        Integer budget = HOURLY_REFRESH_LIMIT - refreshesInLastHour();
        Integer succeeded = 0;
        Integer failed = 0;
        Integer skipped = 0;
        List<String> errors = new List<String>();
        Map<String, Result> results = new Map<String, Result>();

        for (String apiName : tableApiNames) {
            if (budget <= 0) {
                skipped++;
                results.put(apiName, null);
                continue;
            }
            Result r = refresher.refresh(apiName);
            budget--;
            results.put(apiName, r);
            if (r.success) {
                succeeded++;
            } else {
                failed++;
                errors.add(apiName + ': ' + r.message);
            }
        }
        if (skipped > 0) {
            errors.add(skipped + ' table(s) skipped: hourly refresh limit (' + HOURLY_REFRESH_LIMIT + ') reached.');
        }

        DTSync_Log__c log = new DTSync_Log__c(
            Status__c = overallStatus(succeeded, failed, skipped),
            Triggered_By__c = triggeredBy,
            Triggered_By_User__c = userId,
            Sync_Type__c = syncType,
            Start_Time__c = startTime,
            End_Time__c = System.now(),
            Tables_Succeeded__c = succeeded,
            Tables_Failed__c = failed,
            Error_Message__c = errors.isEmpty() ? null : String.join(errors, '\n')
        );
        insert log;

        List<DTSync_Table_Status__c> statuses = new List<DTSync_Table_Status__c>();
        for (String apiName : results.keySet()) {
            Result r = results.get(apiName);
            DTSync_Table__mdt t = config.get(apiName);
            statuses.add(new DTSync_Table_Status__c(
                Name = apiName,
                Table_Label__c = t == null ? apiName : t.MasterLabel,
                Usage_Type__c = t == null ? null : t.Usage_Type__c,
                Last_Sync_At__c = System.now(),
                Last_Sync_Status__c = r == null ? 'Skipped' : (r.success ? 'Success' : 'Failed'),
                Last_Sync_Log__c = log.Id,
                Error_Detail__c = r == null ? 'Hourly refresh limit reached.' : (r.success ? null : r.message)
            ));
        }
        upsert statuses Name;
        return log;
    }

    @TestVisible
    private static String overallStatus(Integer succeeded, Integer failed, Integer skipped) {
        if (failed == 0 && skipped == 0) {
            return 'Success';
        }
        if (succeeded == 0 && failed == 0) {
            return 'Skipped';
        }
        if (succeeded == 0) {
            return 'Failed';
        }
        return 'Partial';
    }
}
