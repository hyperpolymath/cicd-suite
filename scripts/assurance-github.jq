# SPDX-License-Identifier: MPL-2.0
# Finite direct-head GitHub execution policy. This module cannot authorize
# exemptions, advisory findings, PR merge contexts, reusable workflows or writes.

def keys_are($names): type == "object" and keys == ($names | sort);
def text_value: type == "string" and length > 0 and test("[^[:space:]]");
def sha: type == "string" and test("^[0-9a-f]{40}$");
def natural: type == "number" and . >= 0 and . <= 9007199254740991 and floor == .;
def positive: natural and . > 0;
def epoch:
  . as $value
  | if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
    then try (fromdateiso8601 as $seconds | if ($seconds | todateiso8601) == $value then $seconds else null end) catch null
    else null end;
def time_value: (epoch | type) == "number";
def optional_time: . == null or time_value;
def unique_values: length == (unique | length);
def approved_repository:
  keys_are(["full_name","id","owner_id"])
  and .owner_id == 6759885
  and ((.full_name == "hyperpolymath/proven-cicd" and .id == 1446155688)
       or (.full_name == "hyperpolymath/echidna" and .id == 1101572347));
def policy_job:
  keys_are(["name","steps"])
  and (.name | text_value)
  and (.steps | type == "array" and length > 0 and length <= 128
       and unique_values and all(.[]; text_value));
def policy_run:
  keys_are(["id","attempt","workflow_id","path","workflow_blob_sha","event","head_branch","jobs"])
  and (.id | positive) and (.attempt | positive) and (.workflow_id | positive)
  and (.path | type == "string" and test("^\\.github/workflows/[A-Za-z0-9_.-]+\\.ya?ml$"))
  and (.workflow_blob_sha | sha)
  and (.event == "push" or .event == "workflow_dispatch")
  and (.head_branch | type == "string" and test("^[A-Za-z0-9_./-]+$"))
  and (.jobs | type == "array" and length > 0 and length <= 16 and all(.[]; policy_job))
  and ([.jobs[].name] | unique_values);
def valid_policy:
  keys_are(["schema","category","route","repository","subject_sha","issued_at","expires_at","max_age_seconds","runs"])
  and .schema == "proven-cicd/github-execution/v1"
  and .category == "experimental"
  and .route == "direct-head"
  and (.repository | approved_repository)
  and (.subject_sha | sha)
  and (.issued_at | time_value) and (.expires_at | time_value)
  and ((.expires_at | epoch) > (.issued_at | epoch))
  and ((.expires_at | epoch) - (.issued_at | epoch) <= 86400)
  and (.max_age_seconds | positive and . <= 86400)
  and (.runs | type == "array" and length == 1 and all(.[]; policy_run))
  and ([.runs[].id] | unique_values)
  and ([.runs[].workflow_id] | unique_values);

def require($condition; $reason):
  if $condition then . else error($reason) end;

def repository_matches($p):
  type == "object" and .id == $p.repository.id
  and .full_name == $p.repository.full_name
  and .owner.id == $p.repository.owner_id and .private == false;

def run_status:
  .status == "completed" or .status == "queued" or .status == "in_progress"
  or .status == "waiting" or .status == "pending" or .status == "requested";
def conclusion_value:
  . == null or . == "success" or . == "failure" or . == "skipped"
  or . == "cancelled" or . == "timed_out" or . == "neutral"
  or . == "action_required" or . == "stale" or . == "startup_failure";
def status_consistent:
  run_status and (.conclusion | conclusion_value)
  and (if .status == "completed" then .conclusion != null else .conclusion == null end);
def run_identity($p; $r):
  type == "object" and .id == $r.id and .run_attempt == $r.attempt
  and .workflow_id == $r.workflow_id and .path == $r.path
  and .event == $r.event and .head_branch == $r.head_branch
  and .head_sha == $p.subject_sha and .head_commit.id == $p.subject_sha
  and (.run_number | positive)
  and (.repository | repository_matches($p))
  and (.head_repository | repository_matches($p))
  and (.referenced_workflows | type == "array" and length == 0)
  and (.created_at | time_value) and (.updated_at | time_value)
  and (.run_started_at | optional_time)
  and status_consistent
  and ((.updated_at | epoch) >= (.created_at | epoch));
def run_projection:
  {id, run_attempt, workflow_id, path, event, head_branch, head_sha, run_number,
   status, conclusion, created_at, updated_at, run_started_at, referenced_workflows,
   head_commit: .head_commit.id, repository: [.repository.id,.repository.full_name,.repository.owner.id,.repository.private],
   head_repository: [.head_repository.id,.head_repository.full_name,.head_repository.owner.id,.head_repository.private]};

def run_page:
  type == "object" and (.total_count | natural and . <= 100)
  and (.workflow_runs | type == "array") and .total_count == (.workflow_runs | length)
  and ([.workflow_runs[].id] | unique_values)
  and all(.workflow_runs[];
    type == "object" and (.id | positive) and (.workflow_id | positive)
    and (.run_number | positive) and (.run_attempt | positive)
    and (.head_sha | sha) and (.head_branch | text_value) and (.event | text_value)
    and (.repository.id | positive) and (.head_repository.id | positive)
    and (.created_at | time_value) and status_consistent);
def latest_run($p; $r):
  [.workflow_runs[]
   | select(.workflow_id == $r.workflow_id and .event == $r.event
            and .head_branch == $r.head_branch and .head_sha == $p.subject_sha)]
  | if length > 0 then max_by([.run_number,.run_attempt,.id]) else null end;

def workflow_blob_matches($r):
  .tree as $entries
  | ([$entries[] | select(.path == ".github" and .type == "tree" and .mode == "040000")] | length) == 1
    and ([$entries[] | select(.path == ".github/workflows" and .type == "tree" and .mode == "040000")] | length) == 1
    and ([$entries[] | select(.path == $r.path and .type == "blob"
                             and (.mode == "100644" or .mode == "100755")
                             and .sha == $r.workflow_blob_sha)] | length) == 1;
def tree_shape:
  type == "object" and (.sha | sha) and .truncated == false
  and (.tree | type == "array" and length > 0 and length <= 50000)
  and all(.tree[]; (.path | text_value) and (.sha | sha)
          and (.mode | type == "string") and (.type | type == "string"))
  and ([.tree[].path] | unique_values);

def step_shape:
  type == "object" and (.name | text_value) and (.number | positive)
  and status_consistent and (.started_at | optional_time) and (.completed_at | optional_time)
  and (if .status == "completed" then
         (.started_at | time_value) and (.completed_at | time_value)
         and ((.completed_at | epoch) >= (.started_at | epoch))
       else .completed_at == null end);
def job_shape($p; $r):
  type == "object" and (.id | positive) and .run_id == $r.id and .run_attempt == $r.attempt
  and .head_sha == $p.subject_sha and .head_branch == $r.head_branch
  and .run_url == ("https://api.github.com/repos/" + $p.repository.full_name + "/actions/runs/" + ($r.id | tostring))
  and (.name | text_value) and status_consistent
  and (.created_at | time_value) and (.started_at | optional_time) and (.completed_at | optional_time)
  and (.steps | type == "array" and length <= 128 and all(.[]; step_shape))
  and ([.steps[].name] | unique_values)
  and ([.steps[].number] | unique_values)
  and ([.steps[].number] == ([.steps[].number] | sort))
  and (if .status == "completed" then
         (.started_at | time_value) and (.completed_at | time_value)
         and ((.started_at | epoch) >= (.created_at | epoch))
         and ((.completed_at | epoch) >= (.started_at | epoch))
         and all(.steps[]; .status == "completed")
       else .completed_at == null end);
def jobs_page($p; $r):
  type == "object" and (.total_count | natural and . <= 100)
  and (.jobs | type == "array") and .total_count == (.jobs | length)
  and ([.jobs[].id] | unique_values) and ([.jobs[].name] | unique_values)
  and all(.jobs[]; job_shape($p; $r));
def completed_job_times($run; $now):
  . as $job
  | (.status == "completed")
    and ((.started_at | epoch) >= ($run.run_started_at | epoch))
    and ((.completed_at | epoch) <= ($run.updated_at | epoch))
    and ((.completed_at | epoch) <= $now)
    and all(.steps[];
      (.status == "completed")
      and ((.started_at | epoch) >= ($job.started_at | epoch))
      and ((.completed_at | epoch) <= ($job.completed_at | epoch)));

def classify_job($run; $job):
  if $job.conclusion == "failure" or any($job.steps[]; .conclusion == "failure")
  then "FAILED"
  elif $job.conclusion == "success" and all($job.steps[]; .conclusion == "success")
       and ($run.conclusion == "success" or $run.conclusion == "failure")
  then "PASSED"
  else "UNKNOWN" end;

def qualify($p; $b; $now):
  null
  | require(($p | valid_policy); "invalid_policy")
  | require(($now | positive) and ($b.started_at | positive)
            and $now >= $b.started_at and $now - $b.started_at <= 300; "collection_expired")
  | require($now >= ($p.issued_at | epoch) and $now <= ($p.expires_at | epoch); "policy_expired")
  | require(($b.repository_before | repository_matches($p))
            and ($b.repository_after | repository_matches($p)); "repository_binding")
  | require($b.commit.sha == $p.subject_sha and ($b.commit.tree.sha | sha); "subject_binding")
  | require(($b.tree | tree_shape) and $b.tree.sha == $b.commit.tree.sha; "incomplete_tree")
  | require(($b.runs_before | run_page) and ($b.runs_after | run_page); "incomplete_run_inventory")
  | require(($b.runs | type == "array") and ($b.runs | length) == ($p.runs | length); "missing_run_snapshot")
  | [
      range(0; $p.runs | length) as $index
      | $p.runs[$index] as $policy_run
      | $b.runs[$index] as $snapshot
      | $snapshot.final as $run
      | require(($snapshot.initial | run_identity($p; $policy_run))
                and ($run | run_identity($p; $policy_run)); "run_binding")
      | require(($snapshot.initial | run_projection) == ($run | run_projection); "run_changed")
      | require(($run.created_at | epoch) <= $now and ($run.updated_at | epoch) <= $now
                and ($run.run_started_at == null
                     or (($run.run_started_at | epoch) >= ($run.created_at | epoch)
                         and ($run.run_started_at | epoch) <= ($run.updated_at | epoch))); "invalid_run_time")
      | ($b.runs_before | latest_run($p; $policy_run)) as $listed_before
      | ($b.runs_after | latest_run($p; $policy_run)) as $listed_after
      | require($listed_before.id == $policy_run.id and $listed_before.run_attempt == $policy_run.attempt; "superseded_initial_run")
      | require($listed_after.id == $policy_run.id and $listed_after.run_attempt == $policy_run.attempt; "superseded_final_run")
      | require(($listed_before | run_projection) == ($snapshot.initial | run_projection); "initial_inventory_changed")
      | require(($listed_after | run_projection) == ($run | run_projection); "final_inventory_changed")
      | require(($b.tree | workflow_blob_matches($policy_run)); "workflow_source_binding")
      | require(($snapshot.jobs | jobs_page($p; $policy_run)); "invalid_jobs")
      | require(all($snapshot.jobs.jobs[]; .name as $name | any($policy_run.jobs[]; .name == $name)); "unexpected_job")
      | if $run.status != "completed" then
          $policy_run.jobs[]
          | {run_id:$run.id,attempt:$run.run_attempt,job:.name,state:"PENDING",
             reason:"run_not_completed",github_conclusion:$run.conclusion}
        else
          require(($run.run_started_at | time_value)
                  and ($run.updated_at | epoch) <= $now
                  and $now - ($run.updated_at | epoch) <= $p.max_age_seconds; "stale_run")
          | require(([$snapshot.jobs.jobs[].name] | sort) == ([$policy_run.jobs[].name] | sort); "missing_job")
          | require(all($snapshot.jobs.jobs[]; completed_job_times($run; $now)); "invalid_execution_times")
          | require($run.conclusion != "failure" or any($snapshot.jobs.jobs[];
                    .conclusion == "failure" or any(.steps[]; .conclusion == "failure")); "unexplained_run_failure")
          | $policy_run.jobs[] as $policy_job
          | ($snapshot.jobs.jobs[] | select(.name == $policy_job.name)) as $job
          | require([$job.steps[].name] == $policy_job.steps; "step_contract_mismatch")
          | classify_job($run; $job) as $state
          | {run_id:$run.id,attempt:$run.run_attempt,job:$job.name,state:$state,
             reason:(if $state == "PASSED" then "reviewed_steps_completed"
                     elif $state == "FAILED" then "observed_execution_failure"
                     else "execution_not_verified" end),
             github_conclusion:$job.conclusion,
             steps:[$job.steps[]|{name,status,conclusion}]}
        end
    ];
