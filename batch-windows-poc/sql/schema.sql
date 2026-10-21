CREATE TABLE dbo.jobs
(
    id varchar(64) NOT NULL CONSTRAINT PK_jobs PRIMARY KEY,
    submitted_by nvarchar(128) NOT NULL,
    status varchar(20) NOT NULL CONSTRAINT CK_jobs_status CHECK (status IN ('queued','running','succeeded','failed','mount_failed','upload_failed')),
    copy_mode varchar(16) NOT NULL CONSTRAINT CK_jobs_copy_mode CHECK (copy_mode IN ('azureFiles','blob')),
    executable_blob varchar(1024) NOT NULL,
    executable_version varchar(128) NOT NULL,
    executable_sha256 char(64) NULL,
    arguments_json nvarchar(max) NOT NULL,
    timeout_seconds int NOT NULL,
    created_at datetimeoffset(7) NOT NULL,
    started_at datetimeoffset(7) NULL,
    completed_at datetimeoffset(7) NULL,
    updated_at datetimeoffset(7) NOT NULL,
    error_code varchar(64) NULL,
    error_message nvarchar(2048) NULL
);

CREATE TABLE dbo.job_inputs
(
    id bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_job_inputs PRIMARY KEY,
    job_id varchar(64) NOT NULL CONSTRAINT FK_job_inputs_jobs REFERENCES dbo.jobs(id),
    input_index int NOT NULL,
    blob_name nvarchar(1024) NOT NULL,
    expected_bytes bigint NULL,
    expected_sha256 char(64) NULL,
    status varchar(16) NOT NULL,
    started_at datetimeoffset(7) NULL,
    completed_at datetimeoffset(7) NULL,
    error_code varchar(64) NULL,
    retry_count int NOT NULL CONSTRAINT DF_job_inputs_retry DEFAULT 0,
    CONSTRAINT UQ_job_inputs_job_index UNIQUE(job_id,input_index)
);

CREATE TABLE dbo.job_runs
(
    id bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_job_runs PRIMARY KEY,
    job_id varchar(64) NOT NULL CONSTRAINT FK_job_runs_jobs REFERENCES dbo.jobs(id),
    run_number int NOT NULL,
    status varchar(20) NOT NULL,
    batch_job_id varchar(64) NULL,
    batch_task_id varchar(64) NULL,
    node_id nvarchar(128) NULL,
    queued_at datetimeoffset(7) NOT NULL,
    created_at datetimeoffset(7) NOT NULL,
    submit_started_at datetimeoffset(7) NULL,
    submit_completed_at datetimeoffset(7) NULL,
    submit_error_code varchar(64) NULL,
    submit_retry_count int NOT NULL CONSTRAINT DF_job_runs_submit_retry DEFAULT 0,
    started_at datetimeoffset(7) NULL,
    completed_at datetimeoffset(7) NULL,
    mount_started_at datetimeoffset(7) NULL,
    mount_completed_at datetimeoffset(7) NULL,
    mount_latency_ms bigint NULL,
    mount_error_code varchar(64) NULL,
    mount_retry_count int NOT NULL CONSTRAINT DF_job_runs_mount_retry DEFAULT 0,
    copy_started_at datetimeoffset(7) NULL,
    copy_completed_at datetimeoffset(7) NULL,
    copy_error_code varchar(64) NULL,
    copy_retry_count int NOT NULL CONSTRAINT DF_job_runs_copy_retry DEFAULT 0,
    execute_started_at datetimeoffset(7) NULL,
    execute_completed_at datetimeoffset(7) NULL,
    execute_error_code varchar(64) NULL,
    execute_retry_count int NOT NULL CONSTRAINT DF_job_runs_execute_retry DEFAULT 0,
    upload_started_at datetimeoffset(7) NULL,
    upload_completed_at datetimeoffset(7) NULL,
    upload_error_code varchar(64) NULL,
    upload_retry_count int NOT NULL CONSTRAINT DF_job_runs_upload_retry DEFAULT 0,
    exe_exit_code int NULL,
    error_code varchar(64) NULL,
    error_message nvarchar(2048) NULL,
    CONSTRAINT UQ_job_runs_job_run UNIQUE(job_id,run_number)
);

CREATE TABLE dbo.job_artifacts
(
    id bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_job_artifacts PRIMARY KEY,
    job_id varchar(64) NOT NULL CONSTRAINT FK_job_artifacts_jobs REFERENCES dbo.jobs(id),
    name nvarchar(256) NOT NULL,
    blob_name nvarchar(1024) NOT NULL,
    content_type varchar(128) NOT NULL,
    bytes bigint NOT NULL,
    sha256 char(64) NOT NULL,
    created_at datetimeoffset(7) NOT NULL
);

CREATE TABLE dbo.mount_metrics
(
    id bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_mount_metrics PRIMARY KEY,
    job_id varchar(64) NOT NULL CONSTRAINT FK_mount_metrics_jobs REFERENCES dbo.jobs(id),
    run_id bigint NOT NULL CONSTRAINT FK_mount_metrics_runs REFERENCES dbo.job_runs(id),
    copy_mode varchar(16) NOT NULL,
    operation varchar(32) NOT NULL,
    attempt int NOT NULL,
    started_at datetimeoffset(7) NOT NULL,
    completed_at datetimeoffset(7) NOT NULL,
    latency_ms bigint NOT NULL,
    success bit NOT NULL,
    error_code varchar(64) NULL,
    detail nvarchar(1000) NULL
);

CREATE TABLE dbo.copy_metrics
(
    id bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_copy_metrics PRIMARY KEY,
    job_id varchar(64) NOT NULL CONSTRAINT FK_copy_metrics_jobs REFERENCES dbo.jobs(id),
    run_id bigint NOT NULL CONSTRAINT FK_copy_metrics_runs REFERENCES dbo.job_runs(id),
    copy_mode varchar(16) NOT NULL,
    direction varchar(16) NOT NULL,
    source_name nvarchar(1024) NOT NULL,
    bytes bigint NOT NULL,
    started_at datetimeoffset(7) NOT NULL,
    completed_at datetimeoffset(7) NOT NULL,
    elapsed_ms bigint NOT NULL,
    bytes_per_second float NOT NULL,
    success bit NOT NULL,
    retry_count int NOT NULL,
    sha256 char(64) NULL,
    error_code varchar(64) NULL
);

CREATE TABLE dbo.job_events
(
    id bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_job_events PRIMARY KEY,
    job_id varchar(64) NOT NULL CONSTRAINT FK_job_events_jobs REFERENCES dbo.jobs(id),
    event_type varchar(64) NOT NULL,
    event_time datetimeoffset(7) NOT NULL,
    detail_json nvarchar(max) NULL
);

CREATE TABLE dbo.node_cache
(
    id bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_node_cache PRIMARY KEY,
    pool_id varchar(64) NOT NULL,
    node_id nvarchar(128) NOT NULL,
    executable_blob nvarchar(1024) NOT NULL,
    executable_version varchar(128) NOT NULL,
    sha256 char(64) NOT NULL,
    local_path nvarchar(2048) NOT NULL,
    verified_at datetimeoffset(7) NOT NULL,
    CONSTRAINT UQ_node_cache UNIQUE(pool_id,node_id,executable_blob)
);

CREATE INDEX IX_jobs_status_created ON dbo.jobs(status,created_at);
CREATE INDEX IX_job_runs_job_status ON dbo.job_runs(job_id,status);
CREATE INDEX IX_copy_metrics_mode_started ON dbo.copy_metrics(copy_mode,started_at);

CREATE ROLE poc_api_role;
GRANT SELECT, INSERT, UPDATE ON dbo.jobs TO poc_api_role;
GRANT SELECT, INSERT, UPDATE ON dbo.job_inputs TO poc_api_role;
GRANT SELECT, INSERT, UPDATE ON dbo.job_runs TO poc_api_role;
GRANT SELECT, INSERT ON dbo.job_events TO poc_api_role;
GRANT SELECT ON dbo.job_artifacts TO poc_api_role;
GRANT SELECT ON dbo.mount_metrics TO poc_api_role;
GRANT SELECT ON dbo.copy_metrics TO poc_api_role;
GRANT SELECT ON dbo.node_cache TO poc_api_role;

CREATE ROLE poc_worker_role;
GRANT SELECT, INSERT, UPDATE ON dbo.jobs TO poc_worker_role;
GRANT SELECT, UPDATE ON dbo.job_inputs TO poc_worker_role;
GRANT SELECT, UPDATE ON dbo.job_runs TO poc_worker_role;
GRANT INSERT ON dbo.job_events TO poc_worker_role;
GRANT INSERT ON dbo.job_artifacts TO poc_worker_role;
GRANT INSERT ON dbo.mount_metrics TO poc_worker_role;
GRANT INSERT ON dbo.copy_metrics TO poc_worker_role;
GRANT SELECT, INSERT, UPDATE ON dbo.node_cache TO poc_worker_role;
