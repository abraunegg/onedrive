import std.stdio;
import std.file;
import std.datetime;
import std.process;
import std.conv;
import core.memory;
import core.sys.posix.pwd, core.sys.posix.unistd, core.stdc.string : strlen;
import std.algorithm : splitter;
version(Notifications) {
	import dnotify;
}

// enable verbose logging
long verbose;
bool writeLogFile = false;

private bool doNotifications;

// shared string variable for username
string username;
string logFilePath;

void init(string logDir)
{
	writeLogFile = true;
	username = getUserName();
	logFilePath = logDir;
	
	if (!exists(logFilePath)){
		// logfile path does not exist
		try {
			mkdirRecurse(logFilePath);
		} 
		catch (std.file.FileException e) {
			// we got an error ..
			writeln("\nUnable to access ", logFilePath);
			writeln("Please manually create '",logFilePath, "' and set appropriate permissions to allow write access");
			writeln("The requested client activity log will instead be located in the users home directory\n");
		}
	}
}

void setNotifications(bool value)
{
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
	doNotifications = value;
}

void log(T...)(T args)
{
	writeln(args);
	if(writeLogFile){
		// Write to log file
		logfileWriteLine(args);
	}
}

void logAndNotify(T...)(T args)
{
	notify(args);
	log(args);
}

void fileOnly(T...)(T args)
{
	if(writeLogFile){
		// Write to log file
		logfileWriteLine(args);
	}
}

void vlog(T...)(T args)
{
	if (verbose >= 1) {
		writeln(args);
		if(writeLogFile){
			// Write to log file
			logfileWriteLine(args);
		}
	}
}

void vdebug(T...)(T args)
{
	if (verbose >= 2) {
		writeln("[DEBUG] ", args);
		if(writeLogFile){
			// Write to log file
			logfileWriteLine("[DEBUG] ", args);
		}
	}
}

void vdebugNewLine(T...)(T args)
{
	if (verbose >= 2) {
		writeln("\n[DEBUG] ", args);
		if(writeLogFile){
			// Write to log file
			logfileWriteLine("\n[DEBUG] ", args);
		}
	}
}

void error(T...)(T args)
{
	stderr.writeln(args);
	if(writeLogFile){
		// Write to log file
		logfileWriteLine(args);
	}
}

void errorAndNotify(T...)(T args)
{
	notify(args);
	error(args);
}

void notify(T...)(T args)
{
	version(Notifications) {
		if (doNotifications) {
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

private void logfileWriteLine(T...)(T args)
{
	// Write to log file
	string logFileName = .logFilePath ~ .username ~ ".onedrive.log";
	auto currentTime = Clock.currTime();
	auto timeString = currentTime.toString();
	File logFile;
	
	// Resolve: std.exception.ErrnoException@std/stdio.d(423): Cannot open file `/var/log/onedrive/xxxxx.onedrive.log' in mode `a' (Permission denied)
	try {
		logFile = File(logFileName, "a");
		} 
	catch (std.exception.ErrnoException e) {
		// We cannot open the log file in logFilePath location for writing
		// The user is not part of the standard 'users' group (GID 100)
		// Change logfile to ~/onedrive.log putting the log file in the users home directory
		string homePath = environment.get("HOME");
		string logFileNameAlternate = homePath ~ "/onedrive.log";
		logFile = File(logFileNameAlternate, "a");
	} 
	// Write to the log file
	logFile.writeln(timeString, "\t", args);
	logFile.close();
}

private string getUserName()
{
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

void displayMemoryUsagePreGC()
{
// Display memory usage
writeln("\nMemory Usage pre GC (bytes)");
writeln("--------------------");
writeln("memory usedSize = ", GC.stats.usedSize);
writeln("memory freeSize = ", GC.stats.freeSize);
// uncomment this if required, if not using LDC 1.16 as this does not exist in that version
//writeln("memory allocatedInCurrentThread = ", GC.stats.allocatedInCurrentThread, "\n");
}

void displayMemoryUsagePostGC()
{
// Display memory usage
writeln("\nMemory Usage post GC (bytes)");
writeln("--------------------");
writeln("memory usedSize = ", GC.stats.usedSize);
writeln("memory freeSize = ", GC.stats.freeSize);
// uncomment this if required, if not using LDC 1.16 as this does not exist in that version
//writeln("memory allocatedInCurrentThread = ", GC.stats.allocatedInCurrentThread, "\n");
}
