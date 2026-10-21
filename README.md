# IBM Cloud Object Storage Paginated Bulk Deletion

Production-oriented implementation guide for safely deleting a very large number of current objects from an IBM Cloud Object Storage (COS) bucket by using the IBM Cloud CLI, paginated listing, multi-object deletion, retries, checkpointing, and operational validation.

## 1. Scenario

This implementation is intended for a bucket such as:

- **Bucket:** `bucket-demo`
- **Location:** `us-south`
- **Approximate object count:** `7,070,000`
- **Estimated listing pages at 1,000 keys per batch:** approximately `7,070`

At this scale, a per-object command such as `ibmcloud cos object-delete` in a loop is not recommended. The implementation instead uses:

1. `ibmcloud cos list-objects-v2` to list a bounded page of keys.
2. A JSON payload containing up to 1,000 keys.
3. `ibmcloud cos objects-delete` for multi-object deletion.
4. Exponential-backoff retries for transient list and delete failures.
5. A saved pagination token and cumulative count for restartability.
6. Per-object error inspection and retry.

> **Destructive operation:** Object deletion is irreversible unless another retained copy or recoverable object version exists. Validate the target account, COS instance, bucket, location, prefix, retention settings, and backup requirements before using `--execute`.

## 2. Why the earlier command failed

The following command is invalid:

```bash
ibmcloud cos objects-delete \
  --bucket bucket-demo \
  --delete \
  --region us-south
```

`--delete` is not a Boolean flag. It requires a JSON structure, for example:

```json
{
  "Objects": [
    {"Key": "path/object-1.txt"},
    {"Key": "path/object-2.txt"}
  ],
  "Quiet": true
}
```

The JSON can be supplied from a file:

```bash
ibmcloud cos objects-delete \
  --bucket bucket-demo \
  --delete file://delete-payload.json \
  --region us-south \
  --output json
```

## 3. Design summary

The script processes one page at a time:

- List up to 1,000 current objects.
- Build the multi-object deletion payload with `jq`.
- In dry-run mode, show sample keys without deleting anything.
- In execute mode, delete the page as one bulk request.
- Inspect the response for object-level errors.
- Retry failed object keys separately.
- Update the checkpoint only after the page succeeds.
- Continue with the returned pagination token.

This design limits local memory consumption because it never attempts to hold all 7.07 million keys at once.

## 4. Prerequisites

### 4.1 Required software

- A supported Linux or Unix-like shell with Bash.
- IBM Cloud CLI.
- IBM Cloud Object Storage CLI plug-in.
- `jq`.
- `mktemp`, `sed`, `tee`, and standard POSIX utilities.

Verify:

```bash
bash --version
ibmcloud version
ibmcloud plugin list
jq --version
```

Install the COS plug-in if required:

```bash
ibmcloud plugin install cloud-object-storage
```

### 4.2 Authentication

For an interactive session:

```bash
ibmcloud login --sso
```

For controlled automation, use a service ID API key from a protected secret source rather than embedding credentials in the script:

```bash
ibmcloud login --apikey "$IBMCLOUD_API_KEY"
```

Do not place an API key directly in the script, source repository, shell history, log output, or command-line argument visible to other users.

### 4.3 IAM access

The identity executing the script must be able to:

- Access the correct IBM Cloud account and COS service instance.
- Read bucket metadata.
- List objects in the target bucket.
- Delete objects from the target bucket.

Full permissions do not by themselves guarantee that the CLI is targeting the correct account or COS service instance. Confirm the current target and the COS plug-in configuration before deletion.

## 5. Preflight validation

### 5.1 Verify the IBM Cloud target

```bash
ibmcloud target
```

Confirm the account and resource group are correct.

### 5.2 Review COS CLI configuration

```bash
ibmcloud cos config list
```

Review at least:

- Authentication method
- COS CRN/service instance
- Default region
- URL style

### 5.3 Confirm that the bucket exists and is reachable

```bash
ibmcloud cos bucket-head \
  --bucket bucket-demo \
  --region us-south \
  --output json
```

### 5.4 Confirm the bucket location

```bash
ibmcloud cos bucket-location-get \
  --bucket bucket-demo
```

Use the actual returned location if it differs from `us-south`.

### 5.5 Test a bounded listing

```bash
ibmcloud cos list-objects-v2 \
  --bucket bucket-demo \
  --region us-south \
  --page-size 10 \
  --max-items 10 \
  --output json | jq .
```

Do not begin deletion until this command returns the expected object keys.

### 5.6 Capture current bucket controls

Before deletion, review and save relevant configuration:

```bash
ibmcloud cos bucket-versioning-get \
  --bucket bucket-demo \
  --region us-south \
  --output json

ibmcloud cos bucket-lifecycle-configuration-get \
  --bucket bucket-demo \
  --region us-south \
  --output json
```

Also confirm whether Object Lock, legal hold, governance retention, replication, archive workflows, or application dependencies apply. Retention-protected objects may fail deletion until their controls permit it.

## 6. Script installation

Save the supplied script as:

```text
cos-bulk-delete.sh
```

Set restrictive permissions:

```bash
chmod 700 cos-bulk-delete.sh
```

Validate syntax before use:

```bash
bash -n cos-bulk-delete.sh
```

Optional static analysis, if ShellCheck is available:

```bash
shellcheck cos-bulk-delete.sh
```

## 7. Usage

```text
cos-bulk-delete.sh --bucket BUCKET --region REGION [options]
```

Required arguments:

- `--bucket NAME`: COS bucket name.
- `--region REGION`: Bucket location such as `us-south`.

Optional arguments:

- `--prefix PREFIX`: Delete only keys beginning with this prefix.
- `--batch-size NUMBER`: Objects per request, from 1 through 1,000. Default: 1,000.
- `--max-retries NUMBER`: Maximum attempts for each list/delete operation. Default: 8.
- `--state-dir DIRECTORY`: Checkpoint and log directory. Default: `./cos-delete-state`.
- `--resume`: Continue from the token saved in the state directory.
- `--execute`: Perform deletion. Without this flag, the script runs in dry-run mode.
- `--help`: Display usage help.

## 8. Recommended execution workflow

### Step 1: Stop or control writers

Pause applications, scheduled jobs, backup tooling, transfer utilities, or automation that can add objects to the bucket. If producers continue writing, a deletion pass may finish while new objects remain.

### Step 2: Use a dedicated state directory

Use a directory specific to the bucket and change record:

```bash
mkdir -p ./state-bucket-demo
chmod 700 ./state-bucket-demo
```

Do not share a state directory between buckets or concurrent runs.

### Step 3: Run a dry run

```bash
./cos-bulk-delete.sh \
  --bucket bucket-demo \
  --region us-south \
  --state-dir ./state-bucket-demo
```

Review the bucket, region, prefix, object counts, and sample keys in the output and log.

### Step 4: Test with a narrow prefix when possible

If the key structure supports it, validate the implementation against a controlled prefix first:

```bash
./cos-bulk-delete.sh \
  --bucket bucket-demo \
  --region us-south \
  --prefix "approved-test-prefix/" \
  --state-dir ./state-conair-test-prefix \
  --execute
```

Do not use a prefix unless it accurately represents the intended deletion scope.

### Step 5: Execute the complete deletion

```bash
./cos-bulk-delete.sh \
  --bucket bucket-demo \
  --region us-south \
  --batch-size 1000 \
  --max-retries 8 \
  --state-dir ./state-bucket-demo \
  --execute
```

### Step 6: Resume after an interruption

Use the same bucket, location, prefix, and state directory:

```bash
./cos-bulk-delete.sh \
  --bucket bucket-demo \
  --region us-south \
  --batch-size 1000 \
  --max-retries 8 \
  --state-dir ./state-bucket-demo \
  --resume \
  --execute
```

Do not change the prefix or target while reusing an existing checkpoint.

## 9. State and log files

The state directory contains:

- `delete.log`: Timestamped progress, warnings, and failure messages.
- `next-token`: Pagination token for a subsequent list request.
- `deleted-count`: Cumulative number of keys submitted successfully by completed pages.
- `failed-keys.jsonl`: Object-level errors returned by COS.
- `completed`: Completion marker written at the end of an execute-mode pass.
- Temporary `work.*` directory: Removed by the script on normal termination.

Protect this directory because object names may contain business-sensitive information.

## 10. Retry behavior

The script retries failed CLI list and delete calls with exponential backoff:

```text
2, 4, 8, 16, 32, 60, 60, ... seconds
```

The delay is capped at 60 seconds. `--max-retries 8` means a request can be attempted up to eight times by the retry function.

There are two failure layers:

1. **Request-level failure:** The CLI exits unsuccessfully because of authentication, connectivity, throttling, endpoint, or service errors. The full request is retried.
2. **Object-level failure:** The multi-delete request completes but returns errors for individual keys. The script builds a second payload containing only failed keys and retries that subset.

Persistent failures are appended to `failed-keys.jsonl`, and the script exits without advancing the checkpoint past the failed page.

## 11. Important pagination and checkpoint considerations

- The list operation is intentionally limited to one deletion-sized batch.
- The script stores the next token only after successfully processing the current page.
- Do not run multiple copies against the same bucket and state directory.
- Do not edit the token manually.
- Do not remove the state directory during an active or resumable run.
- Keep object writers paused where practical.

### Caution about mutating a paginated collection

Deleting objects while traversing a changing key set can be sensitive to service pagination semantics. The supplied implementation follows the IBM CLI continuation-token model and checkpoints after each successful batch. For the highest assurance on a business-critical bucket, validate the approach against a representative non-production bucket or approved prefix, then perform a final verification pass after deletion.

If a pass ends with objects remaining, run a new deletion pass with a new state directory after confirming that no writers are recreating objects.

## 12. Versioning, delete markers, and retained versions

The base script targets **current objects returned by `list-objects-v2`**.

If bucket versioning is enabled:

- Deleting a current object may create a delete marker rather than permanently removing historical versions.
- Previous versions can continue consuming storage.
- `list-objects-v2` is not a complete inventory of every version and delete marker.
- A separate version-aware process is required to enumerate and delete versions and delete markers.

Check versioning before execution:

```bash
ibmcloud cos bucket-versioning-get \
  --bucket bucket-demo \
  --region us-south \
  --output json
```

Do not claim that the bucket is physically empty based only on a current-object listing when versioning is enabled.

## 13. Retention, governance, and legal hold

Deletion can fail for an object protected by retention, compliance controls, governance mode, or legal hold. Do not automatically bypass these controls.

The COS CLI exposes `--bypass-governance-retention` for applicable operations, but it should be used only when:

- The organization's retention policy permits it.
- The executing identity has the required authorization.
- The deletion is formally approved.
- Audit and change records document the action.

The supplied script does not enable bypass by default.

## 14. Lifecycle expiration alternative

For non-immediate cleanup, a lifecycle expiration rule may be operationally simpler than an active deletion client. IBM documents expiration as an option for emptying a bucket and notes that versioned buckets can create delete markers when expiration rules act on objects.

Use lifecycle expiration when:

- Immediate deletion is not required.
- Policy allows scheduled expiration.
- The lifecycle behavior has been validated for current and noncurrent versions.
- The bucket can remain in service while expiration processing occurs.

Use the paginated deletion script when:

- Deletion must be actively initiated and observed.
- You require page-level logs and checkpoints.
- You need prefix-scoped cleanup.
- You need direct visibility into per-object failures.

## 15. Monitoring during execution

Watch the log:

```bash
tail -f ./state-bucket-demo/delete.log
```

Check the cumulative count:

```bash
cat ./state-bucket-demo/deleted-count
```

Inspect unique object-level errors:

```bash
jq -s 'unique_by(.Key // .key)' \
  ./state-bucket-demo/failed-keys.jsonl
```

Count error records:

```bash
wc -l ./state-bucket-demo/failed-keys.jsonl
```

Avoid aggressive parallelization. It can increase throttling, complicate checkpoint management, and make error reconciliation more difficult. Begin with one worker and 1,000-key batches.

## 16. Post-deletion verification

### 16.1 Re-run a current-object listing

```bash
ibmcloud cos list-objects-v2 \
  --bucket bucket-demo \
  --region us-south \
  --page-size 10 \
  --max-items 10 \
  --output json | jq .
```

Verify that no unexpected current objects remain.

### 16.2 Check for ongoing writers

If objects reappear, inspect application jobs, backup schedules, transfer processes, IBM i/AIX automation, and service credentials that can write to the bucket.

### 16.3 Check versions separately

If versioning is enabled, inventory object versions and delete markers before concluding that storage has been reclaimed or the bucket can be deleted.

### 16.4 Review errors and logs

```bash
cat ./state-bucket-demo/delete.log

jq -s '.' \
  ./state-bucket-demo/failed-keys.jsonl
```

Retain logs according to the organization's change-management and audit requirements.

### 16.5 Delete the bucket only if intended

Bucket deletion is separate from object deletion. Do not delete the bucket unless the change scope explicitly requires it and all current objects, versions, delete markers, retention constraints, and dependent integrations have been addressed.

## 17. Troubleshooting

### `Unexpected number of arguments in command 'objects-delete'`

Cause: `--delete` was supplied without its required JSON structure.

Resolution: use a JSON string or `file://payload.json`.

### Bucket is visible but objects are not listed

Check:

```bash
ibmcloud target
ibmcloud cos config list
ibmcloud cos bucket-location-get --bucket bucket-demo
ibmcloud cos bucket-head --bucket bucket-demo --region us-south
ibmcloud cos list-objects-v2 --bucket bucket-demo --region us-south --max-items 10 --output json
```

Likely areas include the targeted account, COS service-instance CRN, bucket location, IAM scope, plug-in version, output parsing, or an incorrect prefix.

### Authentication or authorization failure

- Re-authenticate to IBM Cloud.
- Confirm the correct account target.
- Confirm the COS service instance in `ibmcloud cos config list`.
- Confirm the service ID or user policy applies to the intended bucket/service instance.
- Confirm the API key has not expired or been revoked.

### Repeated throttling or transient failures

- Keep a single worker.
- Reduce `--batch-size`, for example to 500 or 250.
- Increase `--max-retries` cautiously.
- Preserve the state directory and use `--resume`.
- Inspect service status and CLI error output.

Example:

```bash
./cos-bulk-delete.sh \
  --bucket bucket-demo \
  --region us-south \
  --batch-size 500 \
  --max-retries 10 \
  --state-dir ./state-bucket-demo \
  --resume \
  --execute
```

### Persistent object-level deletion errors

Inspect:

```bash
jq -s '.' ./state-bucket-demo/failed-keys.jsonl
```

Look for retention, legal hold, malformed key handling, authorization, endpoint, and version-specific errors. Do not advance or discard the failed checkpoint until the cause is understood.

### Invalid JSON response

- Run the failing IBM CLI command manually.
- Check whether plugin output or warnings are being mixed into stdout.
- Confirm `--output json` is supported by the installed plug-in version.
- Upgrade the IBM Cloud CLI/COS plug-in through the approved change process.
- Check `ibmcloud cos <command> --help` because command flags can differ by plug-in version.

## 18. Security and governance recommendations

- Use a dedicated IBM Cloud service ID for automation.
- Apply least privilege scoped to the required COS resources.
- Store API keys in an approved secrets manager or protected runtime secret.
- Keep credentials out of scripts and logs.
- Restrict script and state-directory permissions.
- Record the bucket, account, region, CRN, prefix, approver, operator, and change/ticket number.
- Obtain explicit approval for production deletion.
- Disable or pause writers before execution.
- Preserve logs and failed-key records for audit.
- Validate retention and legal-hold requirements.
- Use a dry run and, where possible, a prefix-scoped test.
- Require a second-person review of the final command for production.

## 19. Operational recommendations for this 7.07-million-object bucket

1. Confirm the target account and COS CRN immediately before execution.
2. Capture bucket location, versioning, lifecycle, retention, replication, and dependency information.
3. Pause the process that created or writes the objects.
4. Use one deletion worker, a 1,000-key batch, and eight retries initially.
5. Run the dry run and inspect sample keys.
6. Test against an approved prefix if the object namespace permits it.
7. Use a unique and protected state directory.
8. Run from a stable host or controlled automation runtime with persistent state storage.
9. Monitor errors and cumulative progress.
10. Resume with the same parameters after interruption.
11. Perform a fresh current-object verification pass after completion.
12. Perform a separate version/delete-marker assessment if versioning is enabled.
13. Confirm no objects are being recreated before considering bucket deletion.

## 20. Change record checklist

Before execution:

- [ ] Correct IBM Cloud account confirmed.
- [ ] Correct COS service instance/CRN confirmed.
- [ ] Bucket name and `us-south` location confirmed.
- [ ] Deletion scope approved.
- [ ] Backup or recovery requirement resolved.
- [ ] Versioning state reviewed.
- [ ] Lifecycle configuration reviewed.
- [ ] Retention/Object Lock/legal hold reviewed.
- [ ] Replication and downstream integrations reviewed.
- [ ] Object writers paused or controlled.
- [ ] Dry run reviewed.
- [ ] Prefix test completed where practical.
- [ ] State directory created and protected.
- [ ] Production command peer-reviewed.

After execution:

- [ ] Script completed or checkpoint preserved.
- [ ] `failed-keys.jsonl` reviewed.
- [ ] Current-object listing verified.
- [ ] Versions and delete markers assessed.
- [ ] Writers checked for object recreation.
- [ ] Logs attached to the change record.
- [ ] Bucket deletion performed only if separately approved.

## 21. Official references

- [IBM Cloud Object Storage CLI documentation](https://cloud.ibm.com/docs/cloud-object-storage?topic=cloud-object-storage-ic-cos-cli)
- [IBM Cloud Object Storage: Emptying a bucket](https://cloud.ibm.com/docs/cloud-object-storage?topic=cloud-object-storage-deleting-multiple-objects-patterns)
- [IBM Cloud Object Storage CLI plug-in repository](https://github.com/IBM/ibmcloud-cos-cli)
- [IBM Cloud Object Storage documentation](https://cloud.ibm.com/docs/cloud-object-storage/)

## 22. Scope limitations

This implementation is designed for paginated deletion of current objects through the IBM Cloud COS CLI. It is not, by itself, a complete solution for:

- Historical object versions.
- Delete markers.
- Compliance-protected objects.
- Objects under active legal hold.
- Application-level reconciliation.
- Cross-region replication cleanup.
- Guaranteed storage-cost reclamation without version and retention verification.

Treat those as separate, explicitly approved workstreams.
