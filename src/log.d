// What is this module called?
module log;

// What does this module require to function?
import std.stdio;
import std.file;
import std.datetime;
import std.process;
import std.conv;
import std.path;
import std.string;
import core.memory;
import core.sys.posix.pwd;
import core.sys.posix.unistd;
import core.stdc.string : strlen;
import std.algorithm : splitter;

version(Notifications) {
	import dnotify;
}

// module variables
// verbose logging count
long verbose;
// do we write a log file? ... this should be a config falue
bool writeLogFile = false;
// did the log file write fail?
bool logFileWriteFailFlag = false;
private bool triggerNotification;

// shared string variable for username
string username;
string logFilePath;
string logFileName;
string logFileFullPath;

void initialise(string logDir) {
	writeLogFile = true;
	
	// Configure various variables
	username = getUserName();
	logFilePath = logDir;
	logFileName = username ~ ".onedrive.log";
	logFileFullPath = buildPath(logFilePath, logFileName);
	
	if (!exists(logFilePath)){
		// logfile path does not exist
		try {
			mkdirRecurse(logFilePath);
		} 
		catch (std.file.FileException e) {
			// we got an error ..
			writeln();
			writeln("ERROR: Unable to access ", logFilePath);
			writeln("ERROR: Please manually create '",logFilePath, "' and set appropriate permissions to allow write access");
			writeln("ERROR: The requested client activity log will instead be located in your users home directory");
			writeln();
			
			// set the flag so we dont keep printing this sort of message
			logFileWriteFailFlag = true;
		}
	}
}

void enableNotifications(bool value) {
	version(Notifications) {
		// if we try to enable notifications, check for server availability
		// and disable in case dbus server is not reachable
		if (value) {
			auto serverAvailable = dnotify.check_availability();
			if (!serverAvailable) {
				log("Notification (dbus) server not available, disabling");
				value = false;
			}
		}
	}
	triggerNotification = value;
}

void log(T...)(T args) {
	writeln(args);
	if(writeLogFile){
		// Write to log file
		logfileWriteLine(args);
	}
}

void logAndNotify(T...)(T args) {
	notify(args);
	log(args);
}

void fileOnly(T...)(T args) {
	if(writeLogFile){
		// Write to log file
		logfileWriteLine(args);
	}
}

void vlog(T...)(T args) {
	if (verbose >= 1) {
		writeln(args);
		if(writeLogFile){
			// Write to log file
			logfileWriteLine(args);
		}
	}
}

void vdebug(T...)(T args) {
	if (verbose >= 2) {
		writeln("[DEBUG] ", args);
		if(writeLogFile){
			// Write to log file
			logfileWriteLine("[DEBUG] ", args);
		}
	}
}

void vdebugNewLine(T...)(T args) {
	if (verbose >= 2) {
		writeln("\n[DEBUG] ", args);
		if(writeLogFile){
			// Write to log file
			logfileWriteLine("\n[DEBUG] ", args);
		}
	}
}

void error(T...)(T args) {
	stderr.writeln(args);
	if(writeLogFile){
		// Write to log file
		logfileWriteLine(args);
	}
}

void errorAndNotify(T...)(T args) {
	notify(args);
	error(args);
}

void notify(T...)(T args) {
	version(Notifications) {
		if (triggerNotification) {
			string result;
			foreach (index, arg; args) {
				result ~= to!string(arg);
				if (index != args.length - 1)
					result ~= " ";
			}
			auto n = new Notification("OneDrive", result, "IGNORED");
			try {
				n.show();
				// Sent message to notification daemon
				if (verbose >= 2) {
					writeln("[DEBUG] Sent notification to notification service. If notification is not displayed, check dbus or notification-daemon for errors");
				}
				
			} catch (Throwable e) {
				vlog("Got exception from showing notification: ", e);
			}
		}
	}
}

private void logfileWriteLine(T...)(T args) {
	static import std.exception;
	// Write to log file
	auto currentTime = Clock.currTime();
	auto timeString = leftJustify(currentTime.toString(), 28, '0');
	File logFile;
	
	// Resolve: std.exception.ErrnoException@std/stdio.d(423): Cannot open file `/var/log/onedrive/xxxxx.onedrive.log' in mode `a' (Permission denied)
	try {
		logFile = File(logFileFullPath, "a");
		} 
	catch (std.exception.ErrnoException e) {
		// We cannot open the log file logFileFullPath for writing
		// The user is not part of the standard 'users' group (GID 100)
		// Change logfile to ~/onedrive.log putting the log file in the users home directory
		
		if (!logFileWriteFailFlag) {
			// write out error message that we cant log to the requested file
			writeln();
			writeln("ERROR: Unable to write activity log to ", logFileFullPath);
			writeln("ERROR: Please set appropriate permissions to allow write access to the logging directory for your user account");
			writeln("ERROR: The requested client activity log will instead be located in your users home directory");
			writeln();
		
			// set the flag so we dont keep printing this error message
			logFileWriteFailFlag = true;
		}
		
		string homePath = environment.get("HOME");
		string logFileFullPathAlternate = homePath ~ "/onedrive.log";
		logFile = File(logFileFullPathAlternate, "a");
	} 
	// Write to the log file
	logFile.writeln(timeString, "\t", args);
	logFile.close();
}

private string getUserName() {
	auto pw = getpwuid(getuid);
	
	// get required details
	auto runtime_pw_name = pw.pw_name[0 .. strlen(pw.pw_name)].splitter(',');
	auto runtime_pw_uid = pw.pw_uid;
	auto runtime_pw_gid = pw.pw_gid;
	
	// user identifiers from process
	vdebug("Process ID: ", pw);
	vdebug("User UID:   ", runtime_pw_uid);
	vdebug("User GID:   ", runtime_pw_gid);
	
	// What should be returned as username?
	if (!runtime_pw_name.empty && runtime_pw_name.front.length){
		// user resolved
		vdebug("User Name:  ", runtime_pw_name.front.idup);
		return runtime_pw_name.front.idup;
	} else {
		// Unknown user?
		vdebug("User Name:  unknown");
		return "unknown";
	}
}

void displayMemoryUsagePreGC() {
	// Display memory usage
	writeln();
	writeln("Memory Usage pre GC (KB)");
	writeln("------------------------");
	writeMemoryStats();
	writeln();
}

void displayMemoryUsagePostGC() {
	// Display memory usage
	writeln();
	writeln("Memory Usage post GC (KB)");
	writeln("-------------------------");
	writeMemoryStats();
	writeln();
}

void writeMemoryStats() {
	// write memory stats
	writeln("memory usedSize                 = ", (GC.stats.usedSize/1024));
	writeln("memory freeSize                 = ", (GC.stats.freeSize/1024));
	writeln("memory allocatedInCurrentThread = ", (GC.stats.allocatedInCurrentThread/1024));
}