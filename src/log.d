// What is this module called?
module log;

// What does this module require to function?
import std.stdio;
import std.file;
import std.datetime;
import std.concurrency;
import std.typecons;
import core.sync.condition;
import core.sync.mutex;
import core.thread;
import std.format;
import std.string;

version(Notifications) {
	import dnotify;
}

// Shared logging object
shared LogBuffer logBuffer;

// Logging class
class LogBuffer {
    
	// Private Variables
	private bool verboseLogging;
	private bool debugLogging;
	private bool isRunning;
	private bool sendGUINotification;
	private bool writeToFile;
	private string[3][] logLineBuffer;
	private shared(Mutex) bufferLock;
	private string logFilePath;
	
	// Record last insertion time - used for addProcessingDotEntry to not flood the logger|console
	MonoTime lastInsertedTime;
	
	// The actual thread performing the logging action
	Thread writerThread;

	// Class initialisation
	this() {
		logLineBuffer = [];
		isRunning = true;
		bufferLock = cast(shared) new Mutex();
		//writerThread = new Thread(&logWriter);
		writerThread = new Thread(&flushLogBuffer);
		
		writerThread.isDaemon(true);
		// Start a thread to handle writing logs to console/disk
		writerThread.start();
	}
	
	// Initialise logging
	shared void initialise(bool verboseLoggingInput, bool debugLoggingInput) {
        verboseLogging = verboseLoggingInput;
        debugLogging = debugLoggingInput;
    }
	
	// Store the log message in the logLineBuffer array
	shared private void storeLogMessage(string message, string[] levels = ["info"]) {
        // Generate the timestamp for this log entry
		auto timeStamp = leftJustify(Clock.currTime().toString(), 28, '0');
		synchronized(bufferLock) {
			foreach (level; levels) { // For each 'log level'
			
				// Normal application output
				if (!debugLogging) {
					if ((level == "info") || ((verboseLogging) && (level == "verbose")) || (level == "logFileOnly") || (level == "consoleOnly") || (level == "consoleOnlyNoNewLine")) {
						// Add this message to the buffer, with this format
						logLineBuffer ~= [timeStamp, level, format("%s", message)];
					}
				} else {
					// Debug Logging (--verbose --verbose | -v -v | -vv) output
					// Add this message, regardless of 'level' to the buffer, with this format
					logLineBuffer ~= [timeStamp, level, format("DEBUG: %s", message)];
					// If there are multiple 'levels' configured, ignore this and break as we are doing debug logging
					break;
				}
				
				// Submit the message to the dbus / notification daemon for display within the GUI being used
				// Will not send GUI notifications when running in debug mode
				if ((!debugLogging) && (level == "notify")) {
					version(Notifications) {
						if (sendGUINotification) {
							notify(message);
						}
					}
				}	
			}
        }
	}
	
	// Flush any logs in the buffer via a thread
	private void flushLogBuffer() {
		while (isRunning) {
			Thread.sleep(dur!("msecs")(250)); // Wait for 1/4 of a second
			synchronized(bufferLock) {
				if (!logLineBuffer.empty) {
					logWriter(); 
				}
			}
		}
	}
	
	// Write logs 
	private void logWriter() {
		string[3][] messages;
		synchronized(bufferLock) {
			messages = logLineBuffer;
			logLineBuffer = [];
		}
		writeTheseLogsOut(messages);
		messages = [];
	}
	
	// Log output formatting
	private void writeTheseLogsOut(string[3][] logLinesToWrite) {
	
		foreach (msg; logLinesToWrite) {
			// timestamp, logLevel, message
			// Always write the log line to the console, if level != logFileOnly
	
			if (msg[1] != "logFileOnly") {
				// Console output .. what sort of output
				if (msg[1] == "consoleOnlyNoNewLine") {
					// This is used write out a message to the console only, without a new line 
					// This is used in non-verbose mode to indicate something is happening when downloading JSON data from OneDrive or when we need user input from --resync
					write(msg[2]);
				} else {
					// write this to the console with a new line
					writeln(msg[2]);
				}
			}
			
			// Was this just console only output?
			if ((msg[1] != "consoleOnlyNoNewLine") && (msg[1] != "consoleOnly")) {
				// Write to the logfile only if configured to do so - console only items should not be written out
				if (writeToFile) {
					string logFileLine = format("[%s] %s", msg[0], msg[2]);
					std.file.append(logFilePath, logFileLine ~ "\n");
				}
			}
	
		}
	}
	
	
	shared void shutdown() {
        isRunning = false;
		
        synchronized(bufferLock) {
            if (!logLineBuffer.empty) {
			
				// duplicated code from writeTheseLogsOut() as temp measure .. work out why writeTheseLogsOut() cant be called here later
				foreach (msg; logLineBuffer) {
					// timestamp, logLevel, message
					// Always write the log line to the console, if level != logFileOnly
			
					if (msg[1] != "logFileOnly") {
						// Console output .. what sort of output
						if (msg[1] == "consoleOnlyNoNewLine") {
							// This is used write out a message to the console only, without a new line 
							// This is used in non-verbose mode to indicate something is happening when downloading JSON data from OneDrive or when we need user input from --resync
							write(msg[2]);
						} else {
							// write this to the console with a new line
							writeln(msg[2]);
						}
					}
					
					// Was this just console only output?
					if ((msg[1] != "consoleOnlyNoNewLine") && (msg[1] != "consoleOnly")) {
						// Write to the logfile only if configured to do so - console only items should not be written out
						if (writeToFile) {
							string logFileLine = format("[%s] %s", msg[0], msg[2]);
							std.file.append(logFilePath, logFileLine ~ "\n");
						}
					}
				}
            }
        }
    }
	
	// Is logging still active
	shared bool loggingActive() {
		return isRunning;
	}
	
	
	// Function to add a log entry with multiple levels
	shared void addLogEntry(string message = "", string[] levels = ["info"]) {
		storeLogMessage(message, levels);
	}
	
	
	// Add a console only processing '.' entry to indicate 'something' is happening
	shared void addProcessingLogHeaderEntry(string message, long verbosityCount) {
		if (verbosityCount == 0) {
			addLogEntry(message, ["logFileOnly"]);					
			// Use the dots to show the application is 'doing something' if verbosityCount == 0
			addLogEntry(message ~ " .", ["consoleOnlyNoNewLine"]);
		} else {
			// Fallback to normal logging if in verbose or above level
			addLogEntry(message);
		}
	}
	
	// Add a console only processing '.' entry to indicate 'something' is happening
	shared void addProcessingDotEntry() {
		if (MonoTime.currTime() - lastInsertedTime < dur!"seconds"(1)) {
			// Don't flood the log buffer
			return;
		}
		lastInsertedTime = MonoTime.currTime();
		addLogEntry(".", ["consoleOnlyNoNewLine"]);
	}
	
	// Function to set logFilePath and enable logging to a file
	shared void enableLogFileOutput(string configuredLogFilePath) {
		logFilePath = configuredLogFilePath;
		writeToFile = true;
	}
	
	// Disable GUI notifications
	shared void disableGUINotifications(bool userConfigDisableNotifications) {
		sendGUINotification = userConfigDisableNotifications;
	}
}