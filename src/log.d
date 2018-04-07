import std.stdio;
import std.file;
import std.datetime;
import core.sys.posix.pwd, core.sys.posix.unistd, core.stdc.string : strlen;
import std.algorithm : splitter;

// shared string variable for username
string username;
static this() {
	username = getUserName();
}

// enable verbose logging
bool verbose;

void log(T...)(T args)
{
	writeln(args);
	// Write to log file
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

void error(T...)(T args)
{
	stderr.writeln(args);
	// Write to log file
	logfileWriteLine(args);
}

private void logfileWriteLine(T...)(T args)
{
	// Write to log file
	string logFileName = "/var/log/onedrive/" ~ .username ~ ".onedrive.log";
	auto currentTime = Clock.currTime();
	auto timeString = currentTime.toString();
	File logFile = File(logFileName, "a");
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