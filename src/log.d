import std.stdio;
import std.file;
import std.datetime;
import std.process;
import core.sys.posix.pwd, core.sys.posix.unistd, core.stdc.string : strlen;
import std.algorithm : splitter;

// shared string variable for username
string username;
string logFilePath;
static this() {
	username = getUserName();
	logFilePath = "/var/log/onedrive/";
}

// enable verbose logging
bool verbose;

// enable debug logging
bool debugging;

void init()
{
	if (!exists(logFilePath)){
		// logfile path does not exist
		try {
			mkdirRecurse(logFilePath);
		} 
		catch (std.file.FileException e) {
			// we got an error ..
			writeln("\nUnable to create /var/log/onedrive/ ");
			writeln("Please manually create /var/log/onedrive/ and set appropriate permissions to allow write access");
			writeln("The client activity log will be located in the users home directory\n");
		}
	}

}

void log(T...)(T args)
{
	writeln(args);
	// Write to log file
	logfileWriteLine(args);
}

void fileOnly(T...)(T args)
{
	// Write to log file only
	logfileWriteLine(args);
}

void vlog(T...)(T args)
{
	if (verbose) {
		writeln(args);
		// Write to log file
		logfileWriteLine(args);
	}
}

void dlog(T...)(T args)
{
	if (debugging) {
		writeln("[DEBUG] ", args);
		// Write to log file
		logfileWriteLine("[DEBUG] ", args);
	}
}

void error(T...)(T args)
{
	stderr.writeln(args);
	// Write to log file
	logfileWriteLine(args);
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
		// We cannot open the log file in /var/log/onedrive for writing
		// The user is not part of the standard 'users' group (GID 100)
		// Change logfile to ~/onedrive.log putting the log file in the users home directory
		string homePath = environment.get("HOME");
		string logFileNameAlternate = homePath ~ "/onedrive.log";
		logFile = File(logFileNameAlternate, "a");
	} 
	// Write to the log file
	logFile.writeln(timeString, " ", args);
	logFile.close();
}

private string getUserName()
{
	auto pw = getpwuid(getuid);
	auto uinfo = pw.pw_gecos[0 .. strlen(pw.pw_gecos)].splitter(',');
	if (!uinfo.empty && uinfo.front.length){
		return uinfo.front.idup;
	} else {
		// Unknown user?
		return "unknown";
	}
}