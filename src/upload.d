import std.algorithm, std.conv, std.datetime, std.file, std.json;
import std.stdio, core.thread;
import progress;
import onedrive;
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
		
		session = onedrive.createUploadSession(parentDriveId, parentId, filename, eTag, fileSystemInfo);
		session["localPath"] = localPath;
		save();
		return upload();
	}

	/* Restore the previous upload session.
	 * Returns true if the session is valid. Call upload() to resume it.
	 * Returns false if there is no session or the session is expired. */
	bool restore()
	{
		if (exists(sessionFilePath)) {
			log.vlog("Trying to restore the upload session ...");
			session = readText(sessionFilePath).parseJSON();
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
			try {
				// attempt to read the first 10MB of the file
				read(session["localPath"].str,10000000);
				// request the session status
				JSONValue response;
				try {
					response = onedrive.requestUploadStatus(session["uploadUrl"].str);
				} catch (OneDriveException e) {
					if (e.httpStatusCode == 400) {
						log.vlog("Upload session not found");
						return false;
					} else {
						throw e;
					}
				}
				session["expirationDateTime"] = response["expirationDateTime"];
				session["nextExpectedRanges"] = response["nextExpectedRanges"];
				if (session["nextExpectedRanges"].array.length == 0) {
					log.vlog("The upload session is completed");
					return false;
				}
				return true;
			} catch (std.file.FileException e) {
				// unable to read the local file
				log.log("Skipping resuming uploading this file as it cannot be read (file permissions or file corruption): ", session["localPath"].str);
				remove(sessionFilePath);
				return false;
			}
		}
		return false;
	}

	JSONValue upload()
	{
		long offset = session["nextExpectedRanges"][0].str.splitter('-').front.to!long;
		long fileSize = getSize(session["localPath"].str);
		
		// Upload Progress Bar
		size_t iteration = (roundTo!int(double(fileSize)/double(fragmentSize)))+1;
		Progress p = new Progress(iteration);
		p.title = "Uploading";
				
		JSONValue response;
		while (true) {
			p.next();
			long fragSize = fragmentSize < fileSize - offset ? fragmentSize : fileSize - offset;
			response = onedrive.uploadFragment(
				session["uploadUrl"].str,
				session["localPath"].str,
				offset,
				fragSize,
				fileSize
			);
			offset += fragmentSize;
			if (offset >= fileSize) break;
			// update the session
			session["expirationDateTime"] = response["expirationDateTime"];
			session["nextExpectedRanges"] = response["nextExpectedRanges"];
			save();
		}
		// upload complete
		p.next();
		writeln();
		remove(sessionFilePath);
		return response;
	}

	private void save()
	{
		std.file.write(sessionFilePath, session.toString());
	}
}
