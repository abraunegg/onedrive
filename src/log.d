import std.stdio;
import std.file;
import std.datetime;

// enable verbose logging
bool verbose;

void log(T...)(T args)
{
	writeln(args);
	// Write to log file
	string logFileName = "/var/log/onedrive/onedrive.log";
	auto currentTime = Clock.currTime();
	auto timeString = currentTime.toString();
	File logFile = File(logFileName, "a");
	logFile.writeln(timeString, " ", args);
	logFile.close();
}

void vlog(T...)(T args)
{
	if (verbose) {
		writeln(args);
		// Write to log file
		string logFileName = "/var/log/onedrive/onedrive.log";
		auto currentTime = Clock.currTime();
		auto timeString = currentTime.toString();
		File logFile = File(logFileName, "a");
		logFile.writeln(timeString, " ", args);
		logFile.close();
	}
}

void error(T...)(T args)
{
	stderr.writeln(args);
	// Write to log file
	string logFileName = "/var/log/onedrive/onedrive.log";
	auto currentTime = Clock.currTime();
	auto timeString = currentTime.toString();
	File logFile = File(logFileName, "a");
	logFile.writeln(timeString, " ", args);
	logFile.close();
}