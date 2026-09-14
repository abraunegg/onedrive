# OneDrive Client for Linux Application Architecture

This document describes the major runtime components and synchronisation architecture of the OneDrive Client for Linux. It focuses on how the client establishes authentication, obtains Microsoft OneDrive state, compares that state with its local database and filesystem, transfers data, protects conflicting local content, and operates in `--sync` and `--monitor` modes.

The architecture is built around three distinct state domains:

1. **Microsoft OneDrive online state** - the current DriveItem metadata and file content exposed through Microsoft Graph.
2. **The local SQLite database** - the client's last known and successfully applied synchronisation state, including item identity, parent relationships, hashes, timestamps and delta cursors.
3. **The live local filesystem** - the files and directories that currently exist beneath the configured `sync_dir`.

These three domains must not be treated as interchangeable. The database is a reconciliation baseline, not a second copy of the filesystem; Microsoft metadata is not considered locally applied until the corresponding local operation succeeds; and a local pathname may contain data that differs from both the database baseline and the current online object.

A central architectural goal is therefore to advance the local database only when the client can accurately describe the state that has actually been applied locally or successfully committed online.

## External communication and use of libcurl

The client uses `libcurl` for HTTPS communication with Microsoft services and for the GitHub version check. Microsoft OneDrive data operations are performed through Microsoft Graph, while authentication uses the applicable Microsoft identity endpoints for the configured cloud environment.

![OneDrive Client use of libcurl](./puml/client_use_of_libcurl.png)

Several configuration options change how the HTTP transport behaves:

* `force_http_11` - force HTTPS operations to use HTTP/1.1.
* `operation_timeout` - control how long an operation may remain too slow before it is aborted.
* `dns_timeout` - control libcurl DNS cache timeout handling.
* `connect_timeout` - control the maximum time allowed to establish a connection.
* `data_timeout` - control inactivity timeout on an established HTTPS connection.
* `ip_protocol_version` - control which IP protocol version is used.
* `user_agent` - control the User-Agent presented to Microsoft services.

> [!IMPORTANT]
> The default `user_agent` identifies this client in accordance with Microsoft traffic-decoration expectations for an ISV application. Changing it may affect how Microsoft classifies and throttles the traffic. See Microsoft's guidance on [avoiding throttling or being blocked in SharePoint Online](https://learn.microsoft.com/en-us/sharepoint/dev/general-development/how-to-avoid-getting-throttled-or-blocked-in-sharepoint-online).

## Authentication architecture

The normal OAuth flow uses an authorisation-code exchange. Where a graphical browser environment is available, the client can start a temporary loopback listener, open the Microsoft authorisation URL in the browser and receive the returned authorisation code on the local callback. If that workflow cannot be used, the existing manual redirect-URI workflow remains available.

The client also supports the OAuth device-authorisation flow when configured, and Microsoft Intune broker authentication where applicable.

MFA and Conditional Access are handled by the Microsoft identity flow. They are not implemented as a separate authentication protocol inside this client.

![OneDrive Client for Linux authentication](./puml/onedrive_linux_authentication.png)

After initial authorisation, the client normally uses the stored refresh token to acquire new access tokens as required. Access tokens are used as bearer credentials for Microsoft Graph requests.

For the permissions and security model, see [application-security.md](./application-security.md).

## High-level synchronisation process

At a high level, synchronisation is a reconciliation process rather than a direct file-copy operation.

![High Level Application Sequence](./puml/high_level_operational_process.png)

The major stages are:

1. **Initialisation and safety checks** - load configuration, initialise logging and database state, authenticate, and validate service reachability and system time when the time-safety check is enabled.
2. **Online state enumeration** - obtain Microsoft OneDrive state either through Microsoft Graph `/delta` or through a generated hierarchy traversal when `/delta` is not the correct mechanism for the active scope or mode.
3. **Online item reconciliation** - validate and classify returned JSON, apply client-side scope/filter rules, reconcile new or changed items against database and local state, and process online deletions.
4. **Transactional downloads** - download required file content privately, validate it and preserve unique local content before committing the online replacement.
5. **Database consistency processing** - compare known database items with the live local filesystem to identify locally modified or deleted tracked content.
6. **Local filesystem discovery** - scan for new local files and directories which do not yet have tracked database identity.
7. **Final true-up where applicable** - perform a final online reconciliation pass after upload-side work so changes that occurred during the cycle can be observed.

The order of these operations changes with `--local-first`, but the same three state domains and data-protection rules continue to apply.

## Synchronisation modes

There are two primary execution modes:

1. `--sync` performs a synchronisation cycle and exits.
2. `--monitor` remains running and performs repeated synchronisation cycles, using local filesystem events and optional Microsoft remote-change notifications to trigger earlier work.

### Default remote-first ordering

The default bidirectional flow processes Microsoft OneDrive state before processing local changes. This is the normal ordering used by `--sync` and by normal `--monitor` reconciliation cycles when `--local-first` is not configured.

The important point is that **remote-first describes ordering, not unconditional authority over local user data**. When an online file needs to replace a local pathname, the client still evaluates whether the existing local file contains unique data. If it does, that local content must be preserved before the online replacement is committed.

![Default Sync Flow Process](./puml/default_sync_flow.png)

The order is approximately:

1. reconcile current online state;
2. apply online changes locally;
3. process the database consistency pass to detect changes to tracked local items;
4. scan the local filesystem for new local data;
5. upload applicable local changes; and
6. perform the final online true-up when that pass is applicable.

This is best understood as **remote-first reconciliation ordering**, rather than as a claim that online data always wins every conflict. Unique local content is protected by the conflict and `safeBackup` logic described later in this document.

### Local-first ordering

With `--local-first`, local reconciliation is intentionally performed before the normal online pass. Typical invocations are `onedrive --sync --local-first` and `onedrive --monitor --local-first`.

`--local-first` means **evaluate local intent first**. It does not mean that local bytes are allowed to blindly overwrite a file that has independently changed online. Before a modified tracked local file replaces its online counterpart, the client still obtains current online state and applies the conflict-protection policy described later in this document.

![Local First Sync Flow Process](./puml/local_first_sync_process.png)

The order becomes approximately:

1. process the database consistency pass to detect modified or deleted tracked local items;
2. scan the local filesystem for new local data;
3. upload applicable local changes; and
4. reconcile current online state and apply remaining online changes locally.

`--local-first` changes ordering and conflict intent. It does not disable remote conflict detection or local data-preservation behaviour.

> [!IMPORTANT]
> When using `--sync --local-first`, a locally deleted file can only be reliably propagated as an online deletion when the client has a tracked database identity for that item. A file that was never previously tracked cannot be inferred to represent the deletion of a specific online DriveItem.
>
> `--resync` deliberately removes the previous database baseline, so this distinction is especially important during the rebuilt-state cycle.

### Upload-only and download-only modes

`--upload-only` performs the local database consistency pass and local filesystem scan but deliberately does not apply normal online-to-local reconciliation.

`--download-only` applies online changes locally but suppresses the normal upload-side filesystem scan. The database consistency pass still has a role because it validates known local state and may correct metadata without treating the mode as a normal bidirectional upload cycle.

Other options can further modify reconciliation policy, but they do not collapse the distinction between online state, database state and live filesystem state.

## Local database recovery and resynchronisation

The `items.sqlite3` database is **client synchronisation state**. It is not a repository of user file content and it is not an authoritative copy of the data stored in either the local `sync_dir` or Microsoft OneDrive.

The database records the client's knowledge of the synchronisation relationship between the local filesystem and Microsoft OneDrive. This includes item and drive identifiers, parent relationships, timestamps, hashes, synchronisation status, delta state and other metadata required to reconcile local and online objects safely.

Because this database represents reconstructible client state, the client can deliberately discard that state and establish a new synchronisation baseline when the previous baseline is no longer considered trustworthy or no longer corresponds to the active configuration.

This is the purpose of `--resync`.

When `--resync` is used, the client intentionally removes its previous synchronisation database state and creates a new baseline by re-enumerating the applicable Microsoft OneDrive state and reconciling it with the existing local filesystem according to the selected operational mode.

`--resync` therefore does **not** mean that user file data has itself been lost. It means that the client has deliberately discarded its previous knowledge of what was considered synchronised.

This distinction is important:

```text
items.sqlite3
    = reconstructible client synchronisation state

local sync_dir
    = user file data

Microsoft OneDrive
    = user file data / remote state
```

Discarding `items.sqlite3` does not itself delete the user's local files or Microsoft OneDrive files. The subsequent reconciliation is, however, a real synchronisation operation and can modify local or online data according to the normal rules of the selected mode.

> [!IMPORTANT]
> `--resync` removes the previous last-known synchronisation baseline. During the first reconciliation after that reset, the client can no longer use the old database record to prove that a same-path local file was previously synchronised with a particular online DriveItem.
>
> This is why conflict handling during `--resync` can be more conservative. Matching local and online content can be rebound directly, but differing same-path content may require preservation because the historical database evidence no longer exists.

The application also checks database schema compatibility during initialisation. That structural compatibility check is separate from `--resync`: the architectural purpose of `--resync` is to rebuild the **meaningful synchronisation state** when the previous client baseline cannot safely be relied upon, such as after a detected cache-state inconsistency or a configuration change that requires a new baseline.

Continuing to reconcile using synchronisation state whose meaning cannot be trusted would present a greater risk to user data than discarding that reconstructible state and establishing a new known-good baseline. This is why `--resync` is intentionally treated as a recovery operation and why the client requires explicit risk acknowledgement before proceeding.

## Monitor mode event architecture

Monitor mode can be triggered from several independent sources:

* local filesystem activity observed through `inotify` when local filesystem monitoring is active (`--download-only` does not initialise the `inotify` monitor);
* a configured Microsoft Graph webhook signal when remote notifications are applicable;
* a Microsoft Graph WebSocket/Socket.IO signal when remote notifications are applicable, the linked libcurl build provides WebSocket support, WebSocket support has not been disabled by configuration, and webhook mode is not selected; or
* expiry of the scheduled `monitor_interval`.

![Monitor Mode Event Sources](./puml/monitor_mode_event_sources.png)

`monitor_interval` is the scheduled idle-sync cadence. It does not prevent synchronisation from occurring earlier when a local or remote signal is received.

The client also tracks expected local filesystem effects generated by its own remote-apply operations. This is important because a download, local rename, directory creation or deletion performed by the client can itself generate `inotify` events. Those expected effects are correlated with observed events so the client can distinguish its own work from genuine new local activity.

### Remote notification mechanisms

At most one Microsoft remote-change notification mechanism is active at a time, and remote notifications are not used when operating in `--upload-only` mode:

* **WebSocket/Socket.IO** is the default remote notification mechanism when the linked libcurl implementation provides the required WebSocket support, WebSocket support has not been disabled through `disable_websocket_support`, and webhook mode is not configured.
* **Webhook** is an explicitly configured alternative which requires a publicly reachable HTTPS endpoint and a reverse-proxy or equivalent forwarding path to the client's local listener.

When operating in `--download-only` mode, local filesystem monitoring through `inotify` is not initialised because local changes are not being uploaded.

The webhook architecture is illustrated below:

![Webhook Architecture](./puml/webhooks.png)

Remote notifications are signals that data may have changed. They do not carry enough state to replace normal Microsoft Graph reconciliation. A received signal wakes the normal online reconciliation process.

### Network-backed sync directories

> [!IMPORTANT]
> A network mount such as NFS, CIFS, SMB, a Windows network share or Samba share should not be assumed to provide complete or reliable `inotify` behaviour for this client.
>
> A locally initiated write may appear to generate events while a change made directly on the NAS, server or another client may not generate any event on the Linux host running this application. In that situation monitor mode must rely on its scheduled reconciliation cycle rather than immediate local event detection.
>
> Large network-backed trees can also make database consistency and filesystem scans significantly more expensive because these operations are metadata intensive. Local storage is strongly preferred for large unattended synchronisation trees.

## How online state is obtained

### Microsoft Graph `/delta`

For normal supported drive scopes, Microsoft Graph `/delta` is the efficient source of incremental online changes. Microsoft Graph returns paged responses using `@odata.nextLink` until the client reaches a stable point, at which time `@odata.deltaLink` is retained for a subsequent pass. Page sizing and paging behaviour are controlled by the Microsoft Graph service rather than by this client.

A delta token describes the service's change cursor. It does **not** prove that every corresponding local action has already succeeded. The client therefore advances local applied state carefully around file downloads, local filesystem operations and database updates.

### Generated reconciliation responses

Some workflows cannot safely use a normal drive-level `/delta` response for the required logical scope. In those cases the client walks the applicable online hierarchy and generates the reconciliation input itself.

Examples include:

* account/cloud circumstances where the required `/delta` behaviour is unavailable;
* `--single-directory`, where drive-wide delta changes can fall outside the configured scope;
* authoritative `--download-only --cleanup-local-files` passes, where raw `/delta` history can contain delete/replace churn that is not sufficient on its own to establish the authoritative current in-scope tree before local cleanup is applied; and
* shared-folder traversal, where a drive-level `/delta` can be rooted in the owner's drive rather than the logical shared-folder view. Generated traversal keeps the reconciliation scope bounded to the shared subtree and normalises the resulting logical paths.

Generated responses are deliberately more expensive than incremental `/delta`, but they let the same reconciliation engine operate against an explicitly bounded current-state view.

### Online full-scan true-up versus local scans

The following operations are different and should not all be described as a "full scan":

* an online full-scan true-up;
* a local database consistency and integrity check; and
* a local filesystem scan for new data.

An online full-scan true-up deliberately does not use the stored `/delta` cursor for that pass. Its purpose is to enumerate the applicable current online state rather than only the changes recorded after the previously stored cursor.

In monitor mode, `monitor_fullscan_frequency` controls the scheduled online full-scan true-up cadence. It does not disable the database consistency pass or the local filesystem scan.

When authoritative cleanup is configured for monitor mode, `monitor_authoritative_sync` determines how authoritative cleanup passes are scheduled. Fast raw-delta monitor passes can therefore defer destructive cleanup until the appropriate authoritative pass.

### Recognising reconciliation stages in application output

The normal application output can also be used to identify which reconciliation stage is running. Representative messages include:

```text
Fetching items from the OneDrive API for Drive ID: ...
Generating a /delta response from the OneDrive API for this Drive ID: ...
Processing N applicable JSON items received from Microsoft OneDrive
Performing a database consistency and integrity check on locally stored data
Scanning the local file system '...' for new data to upload
Performing a last examination of the most recent online data within Microsoft OneDrive to complete the reconciliation process
```

These messages refer to different activities. In particular, the database consistency and integrity check is a local database/filesystem validation pass; it is **not** an online full-scan true-up.

When debug logging is enabled, messages such as the following help identify the online full-scan decision and cadence:

```text
Full Scan Frequency Loop Number: ...
Perform a Full Scan True-Up: true|false
Performing a full scan of online data to ensure consistent local state
```

By comparison, messages such as the following indicate reuse of an incremental delta cursor:

```text
Using database stored deltaLink
Using cached deltaLink
```

Application log wording can evolve over time, but the architectural distinction remains the same: online enumeration, local database consistency processing and local filesystem discovery are separate stages.

## Main reconciliation activity flows

The diagrams below map the major high-level code paths used during reconciliation.

### Main functional activity flow

![Main Activity](./puml/main_activity_flows.png)

### Processing a potentially new online item

`applyPotentiallyNewLocalItem()` handles an online identity that is not currently represented as that tracked item in the local database. A local pathname may nevertheless already exist, so the function must reconcile the incoming online identity with live local content before it can safely bind the two together.

The presence of an existing local pathname is therefore not treated as permission to overwrite it. Where content differs and an online replacement is required, the replacement is deferred to the transactional download commit path so the canonical local file can be re-evaluated and preserved with `safeBackup` if it contains unique local data.

![applyPotentiallyNewLocalItem](./puml/applyPotentiallyNewLocalItem.png)

### Processing a changed tracked online item

`applyPotentiallyChangedItem()` handles an incoming online item whose identity is already known. It detects path/name changes separately from file-content changes so an online move and an online content update in the same change can be applied correctly.

If an online move or rename targets a local pathname that is already occupied by content which cannot be proven safe to replace, that destination is preserved first. This is another `safeBackup` data-loss-prevention boundary: the online move must not silently destroy an unrelated or independently changed local object simply because Microsoft OneDrive says the tracked item now belongs at that path.

![applyPotentiallyChangedItem](./puml/applyPotentiallyChangedItem.png)

An important property of this path is that a successful local rename only proves the path change has been applied. If the same online item also contains new file content, the previous content identity remains the applied database baseline until the new content has been downloaded and committed.

## Client-side filtering architecture

Client-side filtering exists in two related but different forms:

* evaluation of an actual **local filesystem path**; and
* evaluation of an **online JSON DriveItem** before the corresponding local path may exist.

These paths cannot perform exactly the same checks because online JSON does not provide local filesystem facts such as the presence of a `.nosync` marker or whether a local path is a symbolic link.

![Client Side Filtering Determination](./puml/client_side_filtering_rules.png)

The processing order is summarised here:

![Client Side Filtering Processing Order](./puml/client_side_filtering_processing_order.png)

The main client-side filtering controls include:

* `check_nosync` / `--check-for-nosync` - establish a local synchronisation boundary when a directory contains `.nosync`;
* `skip_dotfiles` - exclude dot-prefixed local paths, with the `sync_list` inclusion logic allowed to decide explicitly configured paths;
* `skip_symlinks` - exclude symbolic links; invalid links are rejected even when symlinks are otherwise allowed;
* `skip_dir` - exclude matching directories and file paths beneath excluded directories;
* `skip_file` - exclude matching files;
* `sync_list` - restrict synchronisation to explicitly included logical paths;
* `sync_root_files` - allow logical-root files even when `sync_list` would otherwise exclude them; and
* `skip_size` - exclude files at or above the configured size threshold.

When an online item is explicitly included through `sync_list` but its local parent structure does not yet exist, the client can construct the required parent database and local directory structure so the included object can be materialised consistently.

## Determining whether a tracked item is in sync

`isItemSynced()` provides a focused comparison used by several reconciliation paths.

![Item Sync Determination](./puml/is_item_in_sync.png)

For file-like items, timestamp comparison is intentionally cheap and occurs before hashing. If whole-second timestamps match, the function returns `true`. Callers that do not yet have a trusted database identity can add a stricter content-hash guard before binding an untracked local file to an online identity.

If timestamps differ, the client compares content hashes. Matching content with different timestamps is treated as a metadata/timestamp reconciliation problem rather than a file-content conflict. The function returns `false` after performing the timestamp correction so the caller can continue its specific post-correction handling.

For directory and remote-directory items, the current implementation treats an existing path as synchronised in this function; surrounding reconciliation logic owns the broader path/type handling.

## Transactional download architecture

Downloads that can replace an existing canonical file are transactional. This design exists primarily to ensure that receiving an online replacement cannot silently destroy data that was changed locally while the client was not yet aware of that change.

A download therefore has two distinct phases: first acquire and validate the incoming file privately, then decide whether it is safe to commit that file to the user's canonical pathname. The existing local file remains in place throughout the transfer and preservation decision.

![Download File](./puml/downloadFile.png)

The important boundary is that the transfer layer owns a private `.partial` staging file and does **not** overwrite the canonical pathname simply because the HTTP transfer completed.

The transaction is:

1. validate the incoming DriveItem and require an authoritative `fileSystemInfo.lastModifiedDateTime`;
2. download to a private `.partial` file;
3. validate the final HTTP result and the configured content-integrity policy;
4. re-evaluate the current canonical local file at the commit boundary;
5. create and verify a non-destructive `safeBackup` copy if the canonical file contains unique local content;
6. recheck that the canonical path did not change while the replacement was being prepared;
7. atomically promote the validated `.partial` file to the canonical pathname;
8. apply the authoritative Microsoft timestamp; and
9. save the now-applied online state to the database.

If transfer, validation, required preservation or final promotion fails, the existing canonical file is retained. The database must not claim that the incoming online content has been applied when the canonical replacement did not commit.

### `safeBackup` data preservation

`safeBackup` is the client's **local data-loss prevention mechanism** for reconciliation conflicts. It is not created for every difference and it is not a second synchronisation database. It is used when the client is about to honour an online operation but the local pathname contains user data that cannot safely be discarded.

A useful way to think about the replacement decision is to compare three states:

1. **the last applied database baseline** - what the client last successfully reconciled;
2. **the current canonical local file** - what exists on disk now; and
3. **the incoming online file** - the Microsoft OneDrive content that is ready to be applied.

If the current local file still matches the database baseline, it has not independently changed and can be replaced by the valid online version without creating a `safeBackup`. If the local file already matches the incoming online content, there is likewise nothing unique to preserve. However, if the local file differs from **both** the database baseline and the incoming online content, it contains an independent local modification. That is the point at which preservation is required before replacement can proceed.

A replacement-style `safeBackup` is therefore required when the existing canonical file contains content that is different from both:

* the incoming authoritative online file; and
* the last successfully applied database baseline, where such a baseline exists.

If the canonical file still matches the database baseline, it has not been independently modified and does not require a preservation copy before a valid online replacement. If it already matches the incoming online content, no preservation is required either.

The replacement workflow uses a **copy**, not a destructive rename, so the canonical pathname remains present until the validated replacement is ready to commit. If the preservation copy cannot be created and verified, the replacement is rejected rather than risking local data loss.

Once preservation succeeds, the validated online file can become the canonical local file while the previous unique local version survives under its generated `safeBackup` name.

The deliberate exception is an online deletion of a tracked file that has independently changed locally. There is no incoming replacement to promote in that workflow, so the changed local data can be moved to a `safeBackup` name while the online deletion is honoured.

A generated backup uses the form:

```text
filename-hostname-safeBackup-number.file_extension
```

> [!NOTE]
> The preserved-conflict filename format changed in v2.5.3:
>
> * v2.5.3 and later: `filename-hostname-safeBackup-number.file_extension`
> * v2.5.2 and earlier: `filename-hostname-number.file_extension`

If an existing same-device `safeBackup` already represents the same preserved content and metadata, the client can reuse that preservation rather than generating unnecessary numbered duplicates.

> [!CAUTION]
> `bypass_data_preservation` disables `safeBackup` protection where preservation would normally be required. Local data can therefore be overwritten or removed during reconciliation.

If generated `safeBackup` files should remain local and must not subsequently be discovered as new files for upload, add an appropriate `skip_file` rule, for example:

```text
skip_file = "~*|.~*|*.tmp|*.swp|*.partial|*-safeBackup-*"
```

## Upload architecture

New and modified file uploads share the same transport mechanisms but have different reconciliation responsibilities.

### Uploading a new local file

![Upload New File](./puml/uploadFile.png)

Before transferring data, the client resolves the target parent identity, validates file readability and size, considers available online quota where that information is available, and checks whether the target name already exists online.

If the target already exists:

* matching local and online content can be bound without transferring bytes;
* a different existing online object is routed into existing-file conflict/reconciliation logic rather than blindly overwritten as a new file; and
* case-insensitive Microsoft namespace collisions are rejected rather than treated as independent POSIX names.

If the target does not exist, the client selects simple upload or an upload session according to file size and configuration.

### Uploading a modified tracked file

![Upload Modified File](./puml/uploadModifiedFile.png)

A modified-file upload first resolves the true target DriveItem, including remote/shared-item targeting, and fetches the current online metadata where possible. This provides both a current eTag for conditional/session operations and a conflict-protection boundary before the local bytes are allowed to replace the online canonical file.

This check is especially important under `--local-first`. Local-first causes the modified local file to be considered earlier in the cycle, but the client still checks the current online object before replacing it. A genuine or unresolved online change must not be silently overwritten simply because local processing happened first.

The architectural rule is that upload transport selection occurs **after** the client has decided that a normal modified-file upload is safe to perform. If current online state represents a genuine or unresolved conflict, the local version is preserved instead of being used to silently overwrite that online state. In that conflict path, the preserved local version can be uploaded as an independent `safeBackup` file while the existing online canonical DriveItem remains protected from the original local overwrite.

This separation is important: conflict classification is reconciliation policy; simple upload versus resumable session upload is transport policy.

### Simple upload versus upload session

The client can use:

* **simple upload** for zero-byte files and ordinary files below the configured session threshold; or
* a **resumable upload session** for larger files and when session upload is explicitly required.

`force_session_upload` forces the session path. The `--upload-only --local-first` combination also forces session upload where required by the current timestamp-preservation policy.

Upload sessions retain resumable state so interrupted transfers can be recovered when the source file still matches the state from which the session was created.

### Post-upload metadata and SharePoint enrichment

A successful transfer is not assumed to be complete merely because bytes were accepted by Microsoft. The client validates the upload response and performs post-upload integrity and timestamp reconciliation.

For successful simple uploads, Microsoft assigns the resulting online filesystem timestamp. The client saves that returned metadata and, in normal bidirectional operation, aligns the local timestamp to the Microsoft-returned value.

Session uploads can preserve additional source metadata as part of the upload process.

SharePoint-backed account types can also modify supported file formats after upload through Microsoft's enrichment behaviour. If the online content no longer matches the uploaded local content, the client follows its configured enrichment reconciliation policy, which can include downloading the Microsoft-returned file or creating a new online version through metadata reconciliation.

## Conflict handling by operating mode

The same underlying data-protection rules are used in every operating mode, but **the order in which local and online state is examined changes the point at which a conflict is discovered**. The diagrams below therefore identify both the operating mode and the expected outcome when local and online content have diverged.

A `safeBackup` in these flows is not an error by itself. It means the client has found local content that should not be silently discarded while another version is being treated as canonical.

### Default remote-first conflict handling

**Operating mode:** normal bidirectional `--sync`, or a normal `--monitor` reconciliation cycle without `--local-first`.

**Example scenario:** a file was previously synchronised, then the file was changed independently both online and locally. During the next cycle the client examines Microsoft OneDrive first and discovers the online replacement before it reaches the later local upload scan.

**Expected outcome:** the online replacement is downloaded and validated privately. Immediately before commit, the current local file is compared with the incoming online content and the last applied DB baseline. If the current local file contains an independent modification, it is copied to a verified `safeBackup` **to prevent local data loss**. Only after that preservation succeeds can the online version become the canonical local file. The `safeBackup` may subsequently be discovered as a new local file and uploaded unless it is excluded with `skip_file`.

![Default Conflict Handling](./puml/conflict_handling_default.png)

In default mode, an incoming online replacement is validated before the canonical local file is changed. The last applied DB baseline is used where available to distinguish an unchanged tracked local file from independently modified local content.

### Default remote-first conflict handling with `--resync`

**Operating mode:** `onedrive --sync --resync` using normal remote-first ordering.

**Example scenario:** a pathname already exists locally when `--resync` rebuilds state from the current online tree. Because `--resync` deliberately discarded the previous database, the client no longer has its historical last-applied baseline for that file.

**Expected outcome:** if local and online content already match, the identity and metadata can be rebuilt directly and **no `safeBackup` is created merely because `--resync` was used**. If the same pathname contains different local and online content, the missing historical baseline means the client cannot prove that the local bytes are safe to discard. The local file is therefore preserved conservatively before the authoritative online replacement is committed.

![Default Conflict Handling with resync](./puml/conflict_handling_default_resync.png)

`--resync` deliberately discards the previous database baseline. It does not by itself mean that every existing local file must become a `safeBackup`. If local content already matches the current online content, metadata and DB identity can be rebuilt without replacing identical bytes.

Where same-path content differs and there is no trusted prior baseline, the client must use conservative preservation before committing an authoritative online replacement.

### Local-first conflict handling

**Operating mode:** `onedrive --sync --local-first`, or `--monitor --local-first` during normal monitor reconciliation.

**Example scenario:** a tracked file is modified locally, but the corresponding online file has also changed independently. The local database consistency pass finds the local modification first because `--local-first` changes the reconciliation order.

**Expected outcome:** before the modified local bytes are uploaded over the canonical online DriveItem, the client fetches current online metadata and applies the conflict-protection policy. If the online object represents a genuine or unresolved conflict, the original local modification is preserved as a verified `safeBackup` rather than being allowed to overwrite the online canonical file. In normal bidirectional operation the current online canonical file can then be applied locally through the transactional download path; in `--upload-only` operation the client does not download that conflicting online file back over the local pathname.

![Local First Conflict Handling](./puml/conflict_handling_local-first_default.png)

With `--local-first`, locally modified tracked items are considered before the general online reconciliation pass. Before a modified file is uploaded, the client obtains current online metadata and applies its conflict-protection policy against the local file and last applied database state.

If the current online state cannot safely be replaced by the original local modified file, the local content is preserved before the client proceeds with conflict resolution.

### Local-first conflict handling with `--resync`

**Operating mode:** `onedrive --sync --local-first --resync`.

**Example scenario:** local files are examined first, but the previous database baseline has just been deleted by `--resync`. A local file and an online file occupy the same logical pathname but contain different data.

**Expected outcome:** identical local and online bytes can be rebound to the rebuilt DB without preservation. When the bytes differ, however, there is no historical DB state with which to prove which side changed after the previous successful synchronisation. The client must therefore evaluate the current local and online state conservatively. If the online version remains canonical, the differing local version is preserved as `safeBackup` before the online content is applied locally in bidirectional mode. If policy selects the local version for upload, it is processed as modified content instead.

![Local First Conflict Handling with resync](./puml/conflict_handling_local-first_resync.png)

Combining `--local-first` with `--resync` removes the previous database baseline while simultaneously asking the client to process local state first. Same-path differing content must therefore be treated conservatively because the client cannot use the deleted database to prove which side changed after the previous successful synchronisation.

## Performance characteristics

The dominant performance factors are generally:

* **item count and hierarchy shape** - large numbers of DriveItems increase metadata and database work;
* **network latency and throughput** - affects Graph paging and data transfer;
* **local storage latency** - database consistency and filesystem discovery are metadata-heavy operations;
* **network-backed filesystems** - magnify local metadata latency and cannot be assumed to provide reliable `inotify` coverage;
* **file indexing and other filesystem observers** - can add local I/O and can also alter timestamps in some environments;
* **hashing** - intentionally avoided when a cheaper timestamp comparison is sufficient, but required at important reconciliation and integrity boundaries; and
* **CPU and memory availability** - affect hashing, JSON processing, parallel transfers and database work.

A first synchronisation or `--resync` is expected to be more expensive because there is no reusable incremental/applied baseline. Later normal cycles can use stored delta state and database identity to limit work.

## Client functional component relationships

The main source modules and their functional dependencies are shown below:

![Functional Code Components](./puml/code_functional_component_relationships.png)

The broad ownership boundaries are:

* `main.d` - runtime orchestration, mode selection, monitor loop and sequencing;
* `sync.d` / `syncEngine` - reconciliation policy, filtering integration, database/filesystem comparison, transfer decisions and applied-state management;
* `onedrive.d` - Microsoft API implementation, authentication and lower-level OneDrive transfer operations;
* `curlEngine.d` - HTTP transport handling;
* `monitor.d` - local `inotify` event collection;
* `socketio.d` + `curlWebsockets.d` - Microsoft WebSocket/Socket.IO remote notification path;
* `webhook.d` - webhook listener and subscription lifecycle;
* `itemdb.d` + `sqlite.d` - persistent synchronisation state;
* `clientSideFiltering.d` - reusable skip/sync-list matching logic;
* `localAuth.d` - loopback OAuth callback handling;
* `time.d` - Microsoft service time validation and safety gating;
* `intune.d` - Intune/broker integration;
* `xattr.d` - optional local extended-attribute metadata; and
* `util.d`, `qxor.d`, `log.d` and `config.d` - shared support services.

## Database schema

The local SQLite database records the last known/applied synchronisation state and the item relationships needed to reconstruct logical paths and shared/remote item mappings.

![Database Schema](./puml/database_schema.png)

The primary item identity is the `(driveId, id)` pair. Parent relationships are stored by DriveItem identity rather than only by pathname. This allows the client to recognise a tracked item across online rename and move operations instead of treating every path change as delete-and-create.

The database also stores remote/shared-item identifiers, hashes, timestamps, delta state, synchronisation status and relocation data used by generated/shared-folder reconciliation.

Because this database is reconstructible synchronisation state rather than user file content, its recovery and rebuild semantics are described in [Local database recovery and resynchronisation](#local-database-recovery-and-resynchronisation).
