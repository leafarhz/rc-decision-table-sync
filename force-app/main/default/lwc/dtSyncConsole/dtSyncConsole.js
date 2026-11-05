import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTables from '@salesforce/apex/DTSyncController.getTables';
import getHistory from '@salesforce/apex/DTSyncController.getHistory';
import getSchedule from '@salesforce/apex/DTSyncController.getSchedule';
import setSchedule from '@salesforce/apex/DTSyncController.setSchedule';
import disableSchedule from '@salesforce/apex/DTSyncController.disableSchedule';
import syncAll from '@salesforce/apex/DTSyncController.syncAll';
import refreshTable from '@salesforce/apex/DTSyncController.refreshTable';
import getJobStatus from '@salesforce/apex/DTSyncController.getJobStatus';

const POLL_MS = 3000;
const DONE = ['Completed', 'Failed', 'Aborted'];
const DATE_TIME = {
    type: 'date',
    typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }
};

export default class DtSyncConsole extends LightningElement {
    tables = [];
    history = [];
    schedule = { exists: false };
    cronExpression = '0 0 2 * * ?';
    jobMessage;
    isBusy = false;
    pollTimer;

    tableColumns = [
        { label: 'Table', fieldName: 'label' },
        { label: 'API name', fieldName: 'apiName' },
        { label: 'Usage', fieldName: 'usageType', initialWidth: 150 },
        { label: 'Last sync', fieldName: 'lastSyncAt', ...DATE_TIME },
        { label: 'Status', fieldName: 'lastSyncStatus', initialWidth: 110 },
        { label: 'Error', fieldName: 'errorDetail', wrapText: true },
        { type: 'action', typeAttributes: { rowActions: [{ label: 'Refresh now', name: 'refresh' }] } }
    ];

    historyColumns = [
        { label: 'Sync', fieldName: 'Name', initialWidth: 110 },
        { label: 'Started', fieldName: 'Start_Time__c', ...DATE_TIME },
        { label: 'Status', fieldName: 'Status__c', initialWidth: 100 },
        { label: 'Type', fieldName: 'Sync_Type__c', initialWidth: 90 },
        { label: 'Triggered by', fieldName: 'triggeredBy' },
        { label: 'OK', fieldName: 'Tables_Succeeded__c', type: 'number', initialWidth: 70 },
        { label: 'Failed', fieldName: 'Tables_Failed__c', type: 'number', initialWidth: 80 },
        { label: 'Seconds', fieldName: 'Duration_Seconds__c', type: 'number', initialWidth: 90 },
        { label: 'Errors', fieldName: 'Error_Message__c', wrapText: true }
    ];

    presets = [
        { label: 'Every day at 2:00', value: '0 0 2 * * ?' },
        { label: 'Every 6 hours', value: '0 0 0,6,12,18 * * ?' },
        { label: 'Weekdays at 6:00', value: '0 0 6 ? * MON-FRI' },
        { label: 'Sundays at 1:00', value: '0 0 1 ? * SUN' }
    ];

    connectedCallback() {
        this.loadAll();
    }

    disconnectedCallback() {
        clearInterval(this.pollTimer);
    }

    get noSchedule() {
        return !this.schedule.exists;
    }

    get scheduleSummary() {
        if (!this.schedule.exists) {
            return 'No schedule. Tables only sync when someone runs them.';
        }
        const next = this.schedule.nextFireTime ? new Date(this.schedule.nextFireTime).toLocaleString() : 'not set';
        return `Scheduled with "${this.schedule.cronExpression}". Next run: ${next}.`;
    }

    loadAll = async () => {
        try {
            const [tables, history, schedule] = await Promise.all([getTables(), getHistory({ pageSize: 10, pageOffset: 0 }), getSchedule()]);
            this.tables = tables;
            this.history = history.map((h) => ({
                ...h,
                triggeredBy: h.Triggered_By_User__r ? `${h.Triggered_By__c} (${h.Triggered_By_User__r.Name})` : h.Triggered_By__c
            }));
            this.schedule = schedule;
            if (schedule.exists) {
                this.cronExpression = schedule.cronExpression;
            }
        } catch (e) {
            this.toast('Could not load sync data', this.errorText(e), 'error');
        }
    };

    async handleSyncAll() {
        this.isBusy = true;
        try {
            const jobId = await syncAll();
            this.jobMessage = 'Sync queued. Waiting for it to start…';
            this.poll(jobId);
        } catch (e) {
            this.isBusy = false;
            this.toast('Sync did not start', this.errorText(e), 'error');
        }
    }

    poll(jobId) {
        clearInterval(this.pollTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.pollTimer = setInterval(async () => {
            try {
                const job = await getJobStatus({ jobId });
                this.jobMessage = `Sync job: ${job.status}`;
                if (DONE.includes(job.status)) {
                    clearInterval(this.pollTimer);
                    this.isBusy = false;
                    this.jobMessage = undefined;
                    this.toast(
                        job.status === 'Completed' ? 'Sync finished' : 'Sync job ended: ' + job.status,
                        job.detail || 'See History for per-table results.',
                        job.status === 'Completed' ? 'success' : 'error'
                    );
                    this.loadAll();
                }
            } catch (e) {
                clearInterval(this.pollTimer);
                this.isBusy = false;
                this.toast('Lost track of the sync job', this.errorText(e), 'warning');
            }
        }, POLL_MS);
    }

    async handleRowAction(event) {
        const row = event.detail.row;
        if (event.detail.action.name !== 'refresh') {
            return;
        }
        this.isBusy = true;
        try {
            const log = await refreshTable({ tableApiName: row.apiName });
            const ok = log.Status__c === 'Success';
            this.toast(ok ? `${row.label} refreshed` : `${row.label}: ${log.Status__c}`, log.Error_Message__c || '', ok ? 'success' : 'warning');
            await this.loadAll();
        } catch (e) {
            this.toast(`Could not refresh ${row.label}`, this.errorText(e), 'error');
        } finally {
            this.isBusy = false;
        }
    }

    handlePreset(event) {
        this.cronExpression = event.detail.value;
    }

    handleCron(event) {
        this.cronExpression = event.detail.value;
    }

    async handleSaveSchedule() {
        try {
            await setSchedule({ cronExpression: this.cronExpression });
            this.toast('Schedule saved', this.cronExpression, 'success');
            await this.loadAll();
        } catch (e) {
            this.toast('Schedule not saved', this.errorText(e), 'error');
        }
    }

    async handleDisableSchedule() {
        try {
            await disableSchedule();
            this.toast('Schedule turned off', '', 'success');
            await this.loadAll();
        } catch (e) {
            this.toast('Could not turn off the schedule', this.errorText(e), 'error');
        }
    }

    errorText(e) {
        return e?.body?.message || e?.message || 'Unknown error';
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
