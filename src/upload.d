import std.algorithm, std.conv, std.datetime, std.file, std.json;
import std.stdio, core.thread, std.string;
import progress, onedrive, util;
static import log;

private long fragmentSize = 10 * 2^^20; // 10 MiB

struct UploadSession
{
	private OneDriveApi onedrive;
	private bool verbose;
	// https://dev.onedrive.com/resources/uploadSession.htm
	private JSONValue session;
	// path where to save the session
	private string sessionFilePath;

	this(OneDriveApi onedrive, string sessionFilePath)
	{
		assert(onedrive);
		this.onedrive = onedrive;
		this.sessionFilePath = sessionFilePath;
		this.verbose = verbose;
	}

	JSONValue upload(string localPath, const(char)[] parentDriveId, const(char)[] parentId, const(char)[] filename, const(char)[] eTag = null)
	{
		// Fix https://github.com/abraunegg/onedrive/issues/2
		// More Details https://github.com/OneDrive/onedrive-api-docs/issues/778
		
		SysTime localFileLastModifiedTime = timeLastModified(localPath).toUTC();
		localFileLastModifiedTime.fracSecs = Duration.zero;
		
		JSONValue fileSystemInfo = [
				"item": JSONValue([
					"@name.conflictBehavior": JSONValue("replace"),
					"fileSystemInfo": JSONValue([
						"lastModifiedDateTime": localFileLastModifiedTime.toISOExtString()
					])
				])
			];
		
		// Try to create the upload session for this file
		session = onedrive.createUploadSession(parentDriveId, parentId, filename, eTag, fileSystemInfo);
		
		if ("uploadUrl" in session){
			session["localPath"] = localPath;
			save();
			return upload();
		} else {
			// there was an error
			log.vlog("Create file upload session failed ... skipping file upload");
			// return upload() will return a JSONValue response, create an empty JSONValue response to return
			JSONValue response;
			return response;
		}
	}

	/* Restore the previous upload session.
	 * Returns true if the session is valid. Call upload() to resume it.
	 * Returns false if there is no session or the session is expired. */
	bool restore()
	{
		if (exists(sessionFilePath)) {
			log.vlog("Trying to restore the upload session ...");
			// We cant use JSONType.object check, as this is currently a string
			// We cant use a try & catch block, as it does not catch std.json.JSONException
			auto sessionFileText = readText(sessionFilePath);
			if(canFind(sessionFileText,"@odata.context")) {
				session = readText(sessionFilePath).parseJSON();
			} else {
				log.vlog("Upload session resume data is invalid");
				remove(sessionFilePath);
				return false;
			}
			
			// Check the session resume file for expirationDateTime
			if ("expirationDateTime" in session){
				// expirationDateTime in the file
				auto expiration =  SysTime.fromISOExtString(session["expirationDateTime"].str);
				if (expiration < Clock.currTime()) {
					log.vlog("The upload session is expired");
					return false;
				}
				if (!exists(session["localPath"].str)) {
					log.vlog("The file does not exist anymore");
					return false;
				}
				// Can we read the file - as a permissions issue or file corruption will cause a failure on resume
				// https://github.com/abraunegg/onedrive/issues/113
				if (readLocalFile(session["localPath"].str)){
					// able to read the file
					// request the session status
					JSONValue response;
					try {
						response = onedrive.requestUploadStatus(session["uploadUrl"].str);
					} catch (OneDriveException e) {
						// handle any onedrive error response
						if (e.httpStatusCode == 400) {
							log.vlog("Upload session not found");
							return false;
						}
					}
					
					// do we have a valid response from OneDrive?
					if (response.type() == JSONType.object){
						// JSON object
						if (("expirationDateTime" in response) && ("nextExpectedRanges" in response)){
							// has the elements we need
							session["expirationDateTime"] = response["expirationDateTime"];
							session["nextExpectedRanges"] = response["nextExpectedRanges"];
							if (session["nextExpectedRanges"].array.length == 0) {
								log.vlog("The upload session is completed");
								return false;
							}
						} else {
							// bad data
							log.vlog("Restore file upload session failed - invalid data response from OneDrive");
							if (exists(sessionFilePath)) {
								remove(sessionFilePath);
							}
							return false;
						}
					} else {
						// not a JSON object
						log.vlog("Restore file upload session failed - invalid response from OneDrive");
						if (exists(sessionFilePath)) {
							remove(sessionFilePath);
						}
						return false;
					}
					return true;
				} else {
					// unable to read the local file
					log.vlog("Restore file upload session failed - unable to read the local file");
					if (exists(sessionFilePath)) {
						remove(sessionFilePath);
					}
					return false;
				}
			} else {
				// session file contains an error - cant resume
				log.vlog("Restore file upload session failed - cleaning up session resume");
				if (exists(sessionFilePath)) {
					remove(sessionFilePath);
				}
				return false;
			}
		}
		return false;
	}

	JSONValue upload()
	{
		// Response for upload
		JSONValue response;
		
		// session JSON needs to contain valid elements
		long offset;
		long fileSize;
		
		if ("nextExpectedRanges" in session){
			offset = session["nextExpectedRanges"][0].str.splitter('-').front.to!long;
		}
		
		if ("localPath" in session){
			fileSize = getSize(session["localPath"].str);
		}
		
		if ("uploadUrl" in session){
			// Upload file via session created
			// Upload Progress Bar
			size_t iteration = (roundTo!int(double(fileSize)/double(fragmentSize)))+1;
			Progress p = new Progress(iteration);
			p.title = "Uploading";
			long fragmentCount = 0;
			
			// Initialise the download bar at 0%
			p.next();
			
			while (true) {
				fragmentCount++;
				log.vdebugNewLine("Fragment: ", fragmentCount, " of ", iteration);
				p.next();
				long fragSize = fragmentSize < fileSize - offset ? fragmentSize : fileSize - offset;
				// If the resume upload fails, we need to check for a return code here
				try {
					response = onedrive.uploadFragment(
						session["uploadUrl"].str,
						session["localPath"].str,
						offset,
						fragSize,
						fileSize
					);
				} catch (OneDriveException e) {
					// if a 100 response is generated, continue
					if (e.httpStatusCode == 100) {
						continue;
					}
					// there was an error response from OneDrive when uploading the file fragment
					// handle 'HTTP request returned status code 429 (Too Many Requests)' first
					if (e.httpStatusCode == 429) {
						auto retryAfterValue = onedrive.getRetryAfterValue();
						log.vdebug("Fragment upload failed - received throttle request response from OneDrive");
						log.vdebug("Using Retry-After Value = ", retryAfterValue);
						// Sleep thread as per request
						log.log("\nThread sleeping due to 'HTTP request returned status code 429' - The request has been throttled");
						log.log("Sleeping for ", retryAfterValue, " seconds");
						Thread.sleep(dur!"seconds"(retryAfterValue));
						log.log("Retrying fragment upload");
					} else {
						// insert a new line as well, so that the below error is inserted on the console in the right location
						log.vlog("\nFragment upload failed - received an exception response from OneDrive");
						// display what the error is
						displayOneDriveErrorMessage(e.msg);
						// retry fragment upload in case error is transient
						log.vlog("Retrying fragment upload");
					}
					
					try {
						response = onedrive.uploadFragment(
							session["uploadUrl"].str,
							session["localPath"].str,
							offset,
							fragSize,
							fileSize
						);
					} catch (OneDriveException e) {
						// OneDrive threw another error on retry
						log.vlog("Retry to upload fragment failed");
						// display what the error is
						displayOneDriveErrorMessage(e.msg);
						// set response to null as the fragment upload was in error twice
						response = null;
					}
				}
				// was the fragment uploaded without issue?
				if (response.type() == JSONType.object){
					offset += fragmentSize;
					if (offset >= fileSize) break;
					// update the session details
					session["expirationDateTime"] = response["expirationDateTime"];
					session["nextExpectedRanges"] = response["nextExpectedRanges"];
					save();
				} else {
					// not a JSON object - fragment upload failed
					log.vlog("File upload session failed - invalid response from OneDrive");
					if (exists(sessionFilePath)) {
						remove(sessionFilePath);
					}
					// set response to null as error
					response = null;
					return response;
				}
			}
			// upload complete
			p.next();
			writeln();
			if (exists(sessionFilePath)) {
				remove(sessionFilePath);
			}
			return response;
		} else {
			// session elements were not present
			log.vlog("Session has no valid upload URL ... skipping this file upload");
			// return an empty JSON response
			response = null;
			return response;
		}
	}
	
	// Parse and display error message received from OneDrive
	private void displayOneDriveErrorMessage(string message) {
		log.error("ERROR: OneDrive returned an error with the following message:");
		auto errorArray = splitLines(message);
		log.error("  Error Message: ", errorArray[0]);
		// extract 'message' as the reason
		JSONValue errorMessage = parseJSON(replace(message, errorArray[0], ""));
		log.error("  Error Reason:  ", errorMessage["error"]["message"].str);	
	}

	private void save()
	{
		std.file.write(sessionFilePath, session.toString());
	}
}
