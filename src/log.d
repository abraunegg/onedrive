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
import std.conv;

version(Notifications) {
	import dnotify;
}

// Shared module object
private __gshared LogBuffer logBuffer;
// Timer for logging
private __gshared MonoTime lastInsertedTime;
// Is logging active
private __gshared bool isRunning;

class LogBuffer {
    
	private	string[3][] buffer;
	private Mutex bufferLock;
	private Condition condReady;
	private string logFilePath;
	private bool writeToFile;
	private bool verboseLogging;
	private bool debugLogging;
	private Thread flushThread;
	private bool sendGUINotification;
    
	this(bool verboseLogging, bool debugLogging) {
		// Initialise the mutex
		bufferLock = new Mutex();
		condReady = new Condition(bufferLock);
		// Initialise shared items
		isRunning = true;
		// Initialise other items
		this.logFilePath = "";
		this.writeToFile = false;
		this.verboseLogging = verboseLogging;
		this.debugLogging = debugLogging;
		this.sendGUINotification = true;
		this.flushThread = new Thread(&flushBuffer);
		this.flushThread.isDaemon(true);
		this.flushThread.start();
	}
	
	~this() {
		bufferLock.unlock();
	}
		
	// Terminate Logging
	void terminateLogging() {
		synchronized(bufferLock) {
			if (!isRunning) return; // Prevent multiple shutdowns
			isRunning = false;
			condReady.notifyAll(); // Wake up all waiting threads
		}

		// Wait for the flush thread to finish outside of the synchronized block to avoid deadlocks
		if (flushThread.isRunning()) {
			flushThread.join(true);
		}

		scope(exit) {
			bufferLock.lock();
			scope(exit) bufferLock.unlock();
			flushBuffer(); // Flush any remaining log
		}

		scope(failure) {
			bufferLock.lock();
			scope(exit) bufferLock.unlock();
			flushBuffer(); // Flush any remaining log
		}
	}
	
	// Flush the logging buffer
	private void flushBuffer() {
		while (isRunning) {
			flush();
		}
		stdout.flush();
	}
	
	// Add the message received to the buffer for logging
	void logThisMessage(string message, string[] levels = ["info"]) {
		// Generate the timestamp for this log entry
		auto timeStamp = leftJustify(Clock.currTime().toString(), 28, '0');
		
		synchronized(bufferLock) {
			foreach (level; levels) {
				// Normal application output
				if (!debugLogging) {
					if ((level == "info") || ((verboseLogging) && (level == "verbose")) || (level == "logFileOnly") || (level == "consoleOnly") || (level == "consoleOnlyNoNewLine")) {
						// Add this message to the buffer, with this format
						buffer ~= [timeStamp, level, format("%s", message)];
					}
				} else {
					// Debug Logging (--verbose --verbose | -v -v | -vv) output
					// Add this message, regardless of 'level' to the buffer, with this format
					buffer ~= [timeStamp, level, format("DEBUG: %s", message)];
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
			// Notify thread to wake up
			condReady.notify();
		}
	}
		
	void notify(string message) {
		// Use dnotify's functionality for GUI notifications, if GUI notifications is enabled
		version(Notifications) {
			try {
				auto n = new Notification("OneDrive Client", message, "IGNORED");
				// Show notification for 10 seconds
				n.timeout = 10;
				n.show();
			} catch (NotificationError e) {
				sendGUINotification = false;
				addLogEntry("Unable to send notification; disabled in the following: " ~ e.message);
			}
		}
	}

	private void flush() {
		string[3][] messages;
		synchronized(bufferLock) {
			if (isRunning) {
				while (buffer.empty && isRunning) { // buffer is empty and logging is still active
					condReady.wait();
				}
				messages = buffer;
				buffer.length = 0;
			}
		}

		// Are there messages to process?
		if (messages.length > 0) {
			// There are messages to process
			foreach (msg; messages) {
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
			// Clear Messages
			messages.length = 0;
		}
	}
}

// Function to initialise the logging system
void initialiseLogging(bool verboseLogging = false, bool debugLogging = false) {
    logBuffer = new LogBuffer(verboseLogging, debugLogging);
	lastInsertedTime = MonoTime.currTime();
}

// Shutdown Logging
void shutdownLogging() {
	if (logBuffer !is null) {
		logBuffer.terminateLogging();
	}
	// cleanup array
	logBuffer = null;
}

// Function to add a log entry with multiple levels
void addLogEntry(string message = "", string[] levels = ["info"]) {
	// we can only add a log line if we are running ... 
	if (isRunning) {
		logBuffer.logThisMessage(message, levels);
	}
}

// Is logging still active
bool loggingActive() {
	return isRunning;
}

// Is logging still initialised
bool loggingStillInitialised() {
	if (logBuffer !is null) {
		return true;
	} else {
		return false;
	}
}

void addProcessingLogHeaderEntry(string message, long verbosityCount) {
	if (verbosityCount == 0) {
		addLogEntry(message, ["logFileOnly"]);					
		// Use the dots to show the application is 'doing something' if verbosityCount == 0
		addLogEntry(message ~ " .", ["consoleOnlyNoNewLine"]);
	} else {
		// Fallback to normal logging if in verbose or above level
		addLogEntry(message);
	}
}

void addProcessingDotEntry() {
	if (MonoTime.currTime() - lastInsertedTime < dur!"seconds"(1)) {
		// Don't flood the log buffer
		return;
	}
	lastInsertedTime = MonoTime.currTime();
	addLogEntry(".", ["consoleOnlyNoNewLine"]);
}

// Function to set logFilePath and enable logging to a file
void enableLogFileOutput(string configuredLogFilePath) {
	logBuffer.logFilePath = configuredLogFilePath;
	logBuffer.writeToFile = true;
}

void disableGUINotifications(bool userConfigDisableNotifications) {
	logBuffer.sendGUINotification = userConfigDisableNotifications;
}