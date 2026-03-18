# Why 'Server Side Filtering' is not possible with Microsoft OneDrive

A common misconception is that `sync_list` or other client-side filtering rules should be able to instruct Microsoft OneDrive or Microsoft Graph to only return a subset of data from the server.

This is not how Microsoft OneDrive or Microsoft Graph works.

The Microsoft Graph API exposes OneDrive content as `driveItem` resources. Folders are represented as items with a `children` relationship, and changes are tracked through the `delta` API. In other words, the API is built around addressing items, listing children, and tracking changes to those items over time. It is **not** built around applying a user-defined selective sync policy on the server before results are returned.

## The practical reality

Server-side selective sync, equivalent to `sync_list`, is not possible with Microsoft Graph today. There is no supported API capability to provide Microsoft Graph with rules such as:

* include these folders
* exclude these folders
* exclude this subtree recursively
* apply wildcard or glob rules
* return only the logical drive view that matches a client configuration

The OneDrive Client for Linux therefore has no ability to tell Microsoft Graph:

> only return `/Documents/Work/**`, but exclude `/Documents/Work/Archive/**`

That type of policy-driven filesystem view is simply not part of the API surface exposed by Microsoft Graph.

## Why this is a Microsoft Graph platform limitation

This is not an implementation gap in the OneDrive Client for Linux. It is a direct result of how Microsoft Graph is designed.

The `children` API for drive items supports paging and response-shaping options such as `$expand`, `$select`, `$skipToken`, `$top`, and `$orderby`, but it does **not** support a hierarchical `$filter` capability that could be used to express selective sync rules. Microsoft’s own query parameter guidance also states that support for query parameters varies by API operation, and the supported parameters for each operation are explicitly documented. For `children`, the supported query parameters do not include the type of recursive or path-based filtering that `sync_list` would require.

### Why `$filter` does not solve this

Even where Microsoft Graph supports `$filter` on other APIs, that does not make server-side selective sync possible for OneDrive content. Selective sync requires the server to understand and evaluate:

* full path ancestry
* descendant relationships
* recursive subtree inclusion and exclusion
* ordered rule processing
* wildcard or glob matching
* conflict handling between include and exclude rules

The OneDrive `children` API does not expose that model. It returns the items in a folder. The client must then decide what those returned items mean in the context of the configured client-side sync rules.

### Why `search` does not solve this

It may be tempting to think that the Graph search API could be used instead.

It cannot.

The Graph search endpoint is a search function over drive content using query text. It is designed to find matching items by search criteria such as filename, metadata, or file content. It is **not** a policy engine, it is not a substitute for authoritative filesystem enumeration, and it cannot be used to enforce deterministic include/exclude boundaries for sync.

Search can help find items. It cannot define a complete and correct sync scope.

### Why `delta` does not solve this

The Graph `delta` API is also often misunderstood.

`delta` is designed to track changes in a `driveItem` and its children over time. Microsoft documents that the app begins by calling `delta` with no parameters, and that the service starts **enumerating the drive's hierarchy**, returning pages of items until the client has received the complete change set. After that, the client applies those changes to its local state.

This is important:

* `delta` reduces how much metadata needs to be transferred after the initial state is known
* `delta` helps the client track change efficiently
* `delta` does **not** move selective sync rule evaluation to the server
* `delta` still assumes the client is responsible for deciding what to keep, ignore, download, or discard locally

## What the client must do instead

Because Microsoft Graph does not provide server-side selective sync, the OneDrive Client for Linux must do the following:

1. Enumerate remote metadata from Microsoft OneDrive
2. Build or refresh its understanding of the remote hierarchy
3. Evaluate configured rules such as `sync_list`, `skip_file`, `skip_dir`, `single_directory`, and other sync controls
4. Decide locally which items should be downloaded, ignored, retained, or removed

This is why `sync_list` and other sync controls are correctly described as client side filtering.

The rules are applied by the client after Microsoft Graph has returned the relevant metadata required for the client to understand the remote state.

## Why excluded data may still appear to be “seen”

Users sometimes ask:

> If I’ve excluded most folders using `sync_list`, why does the client still appear to scan the entire remote structure before skipping them?

The answer is simple:

To decide whether something should be excluded, the client must first know that the item exists in the remote hierarchy. Microsoft Graph returns metadata about drive items and folder children; the client then applies its local filtering rules to determine whether that item should be processed further.

So:

* the client may enumerate metadata for excluded paths
* the client may log that those paths were evaluated
* the client may discard them immediately based on local rules
* the client is **not** “pulling everything down” in the sense of downloading all file content. 

What is unavoidable is remote metadata discovery. What is controlled by client-side filtering is what happens after that discovery process.

## Why “only query allowed folders” is not a complete solution

Another suggestion is often:

> Why not just query only the folders I want?

That approach is incomplete and unreliable. A sync client must correctly handle:

* new folders created remotely
* renames and moves
* deleted items
* items relocated into or out of an allowed path
* invalidated delta tokens
* reconciliation of local and remote state across the full hierarchy

Without authoritative knowledge of the hierarchy and changes returned by Microsoft Graph, the client cannot safely and correctly maintain sync state. The Graph API is designed around item enumeration and delta tracking, not around returning a server-enforced filtered filesystem view.

## What this means for all Microsoft OneDrive clients

This limitation is not unique to the OneDrive Client for Linux.

Any OneDrive client built on Microsoft Graph must work within the same platform constraints:

* Microsoft Graph returns OneDrive content as addressable resources and collections of `driveItem` objects
* folder traversal happens through `children`
* change tracking happens through `delta`
* filtering decisions (if implemented) beyond what the API explicitly supports must be made by the client

## Summary

Server-side selective sync is not available because Microsoft Graph does not provide:

* recursive path-based filtering
* wildcard rule evaluation
* hierarchical include/exclude policy support
* a server-defined partial-drive view for sync clients

As a result, the client must always enumerate the remote OneDrive metadata to understand the full filesystem structure before any filtering rules can be applied locally.

This enumeration phase can take a noticeable amount of time on large datasets (for example, SharePoint libraries with tens of thousands of folders). This is especially evident when using `--resync`, which clears all locally stored sync state and forces a full re-discovery of the remote hierarchy, or when changes to configuration (such as `sync_list`) require the client to re-evaluate the complete remote structure.

It is important to understand that this process is **metadata enumeration only** — the client is not downloading all file contents, but it must still query and process all relevant filesystem objects returned by Microsoft Graph.

Additionally, this process cannot be arbitrarily parallelised or short-circuited. Microsoft Graph returns data in a paginated and ordered manner, and the client must process these results sequentially to correctly maintain state, handle hierarchy relationships, and ensure consistency (for example, detecting moves, renames, and deletions). Attempting to process this out of order or in parallel would lead to an inconsistent or incorrect sync state.

This means that:

* initial syncs and `--resync` operations will take longer on large datasets
* applying or modifying filtering rules may require full re-evaluation
* large numbers of folders or items will increase enumeration time

This behaviour is therefore **expected**, **correct**, and **driven by Microsoft Graph platform limitations**, not by a defect in the OneDrive Client for Linux.



