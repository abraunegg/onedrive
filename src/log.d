// What is this module called?
module log;

// What does this module require to function?
import std.stdio;
import std.file;
import std.datetime;
import std.concurrency;
import std.typecons;
import core.sync.mutex;
import core.sync.condition;
import core.thread;
import std.format;
import std.string;
import std.conv;

// What other modules that we have created do we need to import?
import util;

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
	private bool environmentVariablesAvailable;
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
		this.environmentVariablesAvailable = false;
		this.sendGUINotification = false;
		this.flushThread = new Thread(&flushBuffer);
		this.flushThread.isDaemon(true);
		this.flushThread.start();
	}
	
	~this() {
		if (!isRunning) {		
			if (exitHandlerTriggered) {
				bufferLock.unlock();	
			}
		}
	}
		
	// Terminate Logging
	void terminateLogging() {
		synchronized {
			// join all threads
			thread_joinAll();
			
			if (!isRunning) {
				return; // Prevent multiple shutdowns
			}
			
			// flag that we are no longer running due to shutting down
			isRunning = false;
			condReady.notifyAll(); // Wake up all waiting threads
		}

		// Wait for the flush thread to finish outside of the synchronized block to avoid deadlocks
		if (flushThread.isRunning()) {
			flushThread.join(true);
		}
		
		// Flush any remaining logs
		flushBuffer();
		
		// Sleep for a while to avoid busy-waiting
		Thread.sleep(dur!"msecs"(100)); // Adjust the sleep duration as needed
		
		// Exit scopes
		scope(exit) {
			if (bufferLock !is null) {
				bufferLock.lock();
			}
			
			scope(exit) {
				if (bufferLock !is null) {
					bufferLock.unlock();
					object.destroy(bufferLock);
					bufferLock = null;
				}
			}
		}

		scope(failure) {
			if (bufferLock !is null) {
				bufferLock.lock();	
			}
			
			scope(exit) {
				if (bufferLock !is null) {
					bufferLock.unlock();
					object.destroy(bufferLock);
					bufferLock = null;
				}
			}
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
					if (sendGUINotification) {
						notify(message);
					}
				}
			}
			// Notify thread to wake up
			condReady.notify();
		}
	}
		
	
	
	// Is the notification DBUS Server available?
	
	
	
	// Send GUI notification if --enable-notifications as been used at compile time
	void notify(string message) {
		// Use dnotify's functionality for GUI notifications, if GUI notification support has been compiled in
		version(Notifications) {
			try {
				auto n = new Notification("OneDrive Client for Linux", message, "dialog-information");
				n.show();
			} catch (NotificationError e) {
				addLogEntry("Unable to send notification to the GUI, disabling GUI notifications: " ~ e.message);
				sendGUINotification = false;
			}
		}
	}

	// Flush the logging buffer
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
		// Terminate logging in a safe manner
		logBuffer.terminateLogging();
		logBuffer = null;
	}
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
	 return logBuffer !is null;
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

// Add a processing '.' to indicate activity
void addProcessingDotEntry() {
	if (MonoTime.currTime() - lastInsertedTime < dur!"seconds"(1)) {
		// Don't flood the log buffer
		return;
	}
	lastInsertedTime = MonoTime.currTime();
	addLogEntry(".", ["consoleOnlyNoNewLine"]);
}

// Finish processing '.' line output
void completeProcessingDots() {
	addLogEntry(" ", ["consoleOnly"]);
}

// Function to set logFilePath and enable logging to a file
void enableLogFileOutput(string configuredLogFilePath) {
	logBuffer.logFilePath = configuredLogFilePath;
	logBuffer.writeToFile = true;
}

// Flag that the environment variables exists so if logging is compiled in, it can be enabled
void flagEnvironmentVariablesAvailable(bool variablesAvailable) {
	logBuffer.environmentVariablesAvailable = variablesAvailable;
}

// Disable GUI Notifications
void disableGUINotifications(bool userConfigDisableNotifications) {
	logBuffer.sendGUINotification = userConfigDisableNotifications;
}

// Validate that if GUI Notification support has been compiled in using --enable-notifications, the DBUS Server is actually usable
void validateDBUSServerAvailability() {
	version(Notifications) {
		if (logBuffer.environmentVariablesAvailable) {
			auto serverAvailable = dnotify.check_availability();
			if (!serverAvailable) {
				addLogEntry("WARNING: D-Bus message bus daemon is not available; GUI notifications are disabled");
				logBuffer.sendGUINotification = false;
			} else {
				addLogEntry("D-Bus message bus daemon is available; GUI notifications are now enabled");
				logBuffer.sendGUINotification = true;
			}
		} else {
			addLogEntry("WARNING: Required environment variables for GUI Notifications are not available, disabling GUI notifications");
			logBuffer.sendGUINotification = false;
		}
	}
}
