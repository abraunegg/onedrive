// What is this module called?
module log;

// What does this module require to function?
import std.stdio;
import std.file;
import std.datetime;
import std.concurrency;
import std.typecons;
import core.sync.mutex;
import core.thread;
import std.format;
import std.string;

version(Notifications) {
	import dnotify;
}

// Shared module object
shared LogBuffer logBuffer;

class LogBuffer {
    private:
        string[3][] buffer;
        Mutex bufferLock;
        string logFilePath;
        bool writeToFile;
        bool verboseLogging;
        bool debugLogging;
        Thread flushThread;
        bool isRunning;
		bool sendGUINotification;

    public:
        this(bool verboseLogging, bool debugLogging) {
			// Initialise the mutex
            bufferLock = new Mutex();
			// Initialise other items
            this.logFilePath = logFilePath;
            this.writeToFile = writeToFile;
            this.verboseLogging = verboseLogging;
            this.debugLogging = debugLogging;
            this.isRunning = true;
			this.sendGUINotification = true;
            this.flushThread = new Thread(&flushBuffer);
			flushThread.isDaemon(true);
			flushThread.start();
        }

        ~this() {
            isRunning = false;
            flushThread.join();
            flush();
        }

        shared void logThisMessage(string message, string[] levels = ["info"]) {
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
            }
        }
		
		shared void notify(string message) {
            // Use dnotify's functionality for GUI notifications, if GUI notifications is enabled
			version(Notifications) {
				auto n = new Notification("Log Notification", message, "IGNORED");
				n.show();
			}
        }

        private void flushBuffer() {
            while (isRunning) {
                Thread.sleep(dur!("msecs")(200));
                flush();
            }
        }

        private void flush() {
            string[3][] messages;
            synchronized(bufferLock) {
                messages = buffer;
                buffer.length = 0;
            }

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
        }
}

// Function to initialize the logging system
void initialiseLogging(bool verboseLogging = false, bool debugLogging = false) {
    logBuffer = cast(shared) new LogBuffer(verboseLogging, debugLogging);
}

// Function to add a log entry with multiple levels
void addLogEntry(string message = "", string[] levels = ["info"]) {
	logBuffer.logThisMessage(message, levels);
}

// Function to set logFilePath and enable logging to a file
void enableLogFileOutput(string configuredLogFilePath) {
	logBuffer.logFilePath = configuredLogFilePath;
	logBuffer.writeToFile = true;
}

void disableGUINotifications(bool userConfigDisableNotifications) {
	logBuffer.sendGUINotification = userConfigDisableNotifications;
}