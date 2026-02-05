# Add Sandbox CRUD gRPC + K8s Agent-Sandbox Integration

**Summary**
Implement Sandbox CRUD over gRPC in the Navigator service. Persist a Sandbox entity in the DB, create/delete the agent-sandbox CRD in Kubernetes, and run a watcher that propagates CRD status back into the stored Sandbox model (dual-write + watch). Expose a simplified Sandbox spec in proto, mapping it to the agent-sandbox CRD spec and status.

**Important API Changes**
1. `proto/datamodel.proto`
- Replace the placeholder `Sandbox` with a full schema.
- Add:
- `SandboxSpec` (Navigator-level simplified spec)
- `SandboxTemplate` (agent-sandbox template subset + optional K8s passthrough fields)
- `SandboxStatus`
- `SandboxCondition`
- `SandboxPhase` enum
- Include fields to propagate state (status + conditions + phase).
2. `proto/navigator.proto`
- Add RPCs to `Navigator` service:
- `CreateSandbox(CreateSandboxRequest) returns (SandboxResponse)`
- `GetSandbox(GetSandboxRequest) returns (SandboxResponse)`
- `ListSandboxes(ListSandboxesRequest) returns (ListSandboxesResponse)`
- `DeleteSandbox(DeleteSandboxRequest) returns (DeleteSandboxResponse)`
- Add request/response messages with pagination (`limit`, `offset`) consistent with current store.

**Design Notes**
- **Simplified SandboxSpec** maps to CRD fields:
- `log_level`, `agent_endpoint`, `agent_descriptor`, `agent_version`, `environment` map directly to CRD spec.
- `SandboxTemplate` maps to CRD `sandboxSpecTemplate` fields:
- `agent_image`, `runtime_class_name`, `agent_socket`, `resources`, `labels`, `annotations`, `environment` map directly.
- `pod_template` and `volume_claim_templates` exposed as `google.protobuf.Struct` (JSON) to avoid modeling full K8s types.
- **SandboxStatus** mirrors CRD status:
- `sandbox_name`, `agent_pod`, `agent_fd`, `sandbox_fd`, and `conditions`.
- **SandboxPhase** derived from status:
- `PROVISIONING`, `READY`, `ERROR`, `DELETING`, `UNKNOWN`
- Derive from `conditions` and deletionTimestamp; store in DB and return over gRPC.

**Implementation Steps**
1. **Proto + Generated Code**
- Update `proto/datamodel.proto` with new Sandbox model and supporting messages.
- Update `proto/navigator.proto` with Sandbox CRUD RPCs and messages.
- Regenerate prost/tonic output via existing build (`crates/navigator-core/build.rs`).
2. **Config**
- Add config field `sandbox_namespace` to `navigator_core::Config`, default `"default"` (override via `NAVIGATOR_SANDBOX_NAMESPACE`).
- Wire CLI flag/env in `crates/navigator-server/src/main.rs`.
3. **Kubernetes Integration**
- Add deps: `kube`, `kube-runtime`, `k8s-openapi` in workspace and `navigator-server`.
- Create `crates/navigator-server/src/sandbox` module:
- `crd.rs`: Rust type for agent-sandbox `Sandbox` CRD (serde structs matching spec/status).
- `mapper.rs`: Proto <-> CRD conversion functions.
- `client.rs`: K8s client wrapper using `kube::Client::try_default()` and `Api<Sandbox>`.
4. **Persistence**
- Implement `ObjectType` / `ObjectId` for `datamodel::Sandbox` with `object_type = "sandbox"` and `id`.
- Store full Sandbox proto payload in the existing `objects` table.
5. **gRPC Service**
- Extend `NavigatorService` implementation with new RPCs.
- `CreateSandbox`:
- Validate request, generate UUID id, compute K8s name (`sandbox-<id>`), set namespace from config.
- Persist initial Sandbox record with `phase=PROVISIONING`.
- Create CRD in K8s.
- Return Sandbox from DB (with metadata set).
- `GetSandbox`:
- Fetch from DB; return NotFound if missing.
- `ListSandboxes`:
- Use store list with `limit`/`offset`, decode Sandbox records.
- `DeleteSandbox`:
- Mark phase `DELETING` in DB, attempt CRD delete.
- Keep record until watcher observes deletion, then remove.
6. **Watcher for State Propagation**
- Spawn a `kube_runtime::watcher` task on server startup.
- On `Added/Modified`: map CRD status to `SandboxStatus`, update DB record, recompute `phase`.
- On `Deleted`: remove DB record (or mark terminal).
- If watcher observes CRD with unknown id, create DB record (best-effort sync).
7. **Error Handling**
- Handle K8s AlreadyExists on create by returning `AlreadyExists`.
- If DB write succeeds but K8s create fails, delete DB record to avoid drift.
- If K8s delete fails with NotFound, delete DB record immediately.
8. **Observability**
- Add structured logs for CRUD and watcher events (id, name, namespace, phase).

**Test Cases and Scenarios**
1. Proto mapping unit tests:
- `SandboxSpec` -> CRD spec mapping (fields present, null handling).
- CRD status -> `SandboxStatus` + `SandboxPhase` derivation.
2. Persistence round-trip for Sandbox in sqlite store.
3. gRPC handler unit tests (using a mocked sandbox backend):
- Create -> DB write + K8s create called.
- Get missing -> NotFound.
- Delete -> phase set to DELETING and K8s delete called.
4. Watcher behavior unit test (mock event stream):
- Added -> DB record updated with status.
- Deleted -> DB record removed.
5. E2E test via local cluster:
   - Deploy server and agent-sandbox CRD support using `mise run cluster`, then exercise Create/Get/List/Delete over gRPC and verify status propagation.

**Assumptions and Defaults**
- Create returns immediately after CRD creation, without waiting for Ready.
- Sandbox names are server-generated `sandbox-<uuid>`.
- Default namespace is `"default"`, configurable via `NAVIGATOR_SANDBOX_NAMESPACE`.
- Advanced K8s pod and PVC customizations are passed via `google.protobuf.Struct`.
