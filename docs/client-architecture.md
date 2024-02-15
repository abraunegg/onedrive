# OneDrive Client for Linux Client Architecture
## How does the client work?
The diagram below outlines at a high level the operational workflow of the OneDrive Client for Linux, demonstrating how it interacts with the OneDrive API to maintain synchronisation, manage local and cloud data integrity, and ensure that user data is accurately mirrored between the local filesystem and OneDrive cloud storage.

![High Level Application Sequence](./puml/high_level_operational_process.png)

The above process involves several high level key stages:

1. **Access Token Validation:** Initially, the client validates its access and the existing access token, refreshing it if necessary. This step ensures that the client has the required permissions to interact with the OneDrive API.

2. **Query Microsoft OneDrive API:** The client queries the /delta API endpoint of Microsoft OneDrive, which returns JSON responses. The /delta endpoint is particularly used for syncing changes, helping the client to identify any updates in the OneDrive storage.

3. **Process JSON Responses:** The client processes each JSON response to determine if it represents a 'root' or 'deleted' item. Items not marked as 'root' or 'deleted' are temporarily stored for further processing. For 'root' or 'deleted' items, the client processes them immediately, otherwise, the client evaluates the items against client-side filtering rules to decide whether to discard them or to process and save them in the local database cache for actions like creating directories or downloading files.

4. **Local Cache Database Processing for Data Integrity:** The client processes its local cache database to check for data integrity and differences compared to the OneDrive storage. If differences are found, such as a file or folder change including deletions, the client uploads these changes to OneDrive. Responses from the API, including item metadata, are saved to the local cache database.

5. **Local Filesystem Scanning:** The client scans the local filesystem for new files or folders. Each new item is checked against client-side filtering rules. If an item passes the filtering, it is uploaded to OneDrive. Otherwise, it is discarded if it doesn't meet the filtering criteria.

6. **Final Data True-Up:** Lastly, the client queries the /delta link for a final true-up, processing any further online JSON changes if required. This ensures that the local and OneDrive storages are fully synchronised.

