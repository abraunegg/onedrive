module progress;

import core.sync.mutex;
import core.atomic;
import std.algorithm;
import std.conv;
import std.container;
import std.datetime.stopwatch;
import std.stdio;
import std.string;

import log;

shared ProgressManager progressManager;

// Helper control code
enum CURSOR_UP = "\x1b[1A";
enum LINEFEED = "\r";
enum ERASE_IN_LINE = "\x1b[K";

class Progress {

    enum Status
    {
        running,
        success,
        failed,
        cancelled,
    }

    enum Type
    {
        sync, // syncing progress (i.e. syncOneDriveAccountToLocalDisk, uploadChangedLocalFileToOneDrive, ...)
        file, // operation on file (i.e. upload, download, ... for single file)
    }
    
private:
    Progress[] sub_progresses;

    // What is the type of progress
    Type type;
    // Identifier
    string name;
    string message;
    int bar_length;
    // Progress statistics
    // Time elapsed
    MonoTime start_time;
    MonoTime end_time;
    // When is the last progress updated
    MonoTime last_update_time;
    // When is the last progress displayed
    MonoTime last_update_displayed;
    // What is the last progress displayed
    float last_progress;

    // Progress indicator
    size_t index;
    size_t total;

    
    Status status;
    // Is the job completed
    bool completed;
    // Is verbose is on
    bool verbose;
    // Should the job display completed status when the job is completed
    bool log_when_done;

    this(Type type, string name) {
        this.type = type;
        this.name = name;
        this.bar_length = logBuffer.terminalCols;

        this.start_time = MonoTime.currTime;

        this.last_update_time = MonoTime.currTime;
        this.last_update_displayed = MonoTime.currTime;
        this.last_progress = 0;

        this.index = 0;
        this.total = 0;


        this.status = Status.running;
        this.completed = false;
        this.verbose = true;
        this.log_when_done = true;
    }
    
public:
    void reset() {
        sub_progresses = null;

        this.start_time = MonoTime.currTime;
        this.last_progress = 0;
        
        index = 0;
        total = 0;

        this.status = Status.running;
        this.completed = false;
    }

    void setVerbose(bool verbose) {
        this.verbose = verbose;
    }

    void setLogWhenDone(bool log_when_done) {
        this.log_when_done = log_when_done;
    }

    void setMessage(string message) {
        this.message = message;
    }

    // Add size to total number of progress
    void add(size_t size) {
        total += size;
        updateDisplay();
    }

    // Add n to total number of completed progress
    void next(size_t n) {
        synchronized (this) {
            this.index += n;
            updateDisplay();
        }
    }

    // Update total number of progress and total number of completed progress
    void update(size_t index, size_t total) {
        synchronized (this) {
            this.index = index;
            this.total = total;
            updateDisplay();
        }
    }

    // Set completion information when the job is finished.
    void done(Status status=Status.success) {
        this.completed = true;
        this.status = status;
        this.end_time = MonoTime.currTime;
        // Print results
        if (verbose && log_when_done) {
            addLogEntry(getMessageLine());
        }
    }

    // Retrieve the progress string of this job recursively.
    void getMessageLine(ref string line, ref int counter) {
        // Only print unfinished progress
        if (completed || !verbose)
            return;
        // Accumulate number of lines
        counter += 1;
        // Print sub progress first
        foreach (child; sub_progresses)
            child.getMessageLine(line, counter);
        // Print this progress
        line ~= getMessageLine() ~ ERASE_IN_LINE ~ "\n";
    }

    // Retrieve the progress string for this job only.
    string getMessageLine() {
        string line;
        // Format of the progress string
        // line = name | percentage | progress | rate ... message
        string percentage;
        string rate;
        string progress;

        // Calculate percentage if number of total progress is available
        // percentage format: XX.X%
        if (!completed && total > 0) {
            // Round to XX.X
            float currentDLPercent = to!float(roundTo!int(10 * getProgress())) / 10;
            percentage = rightJustify(to!string(currentDLPercent) ~ "%", 5, ' ');
        }
        
        // progress format: OOOO (IN) XX:XX:XX
        string statusStr;
        Duration elapsed;
        if (completed) {
            // Job completed
            switch (status) {
                case Status.success:
                    statusStr = "DONE";
                    break;
                case Status.failed:
                    statusStr = "FAILED";
                    break;
                case Status.cancelled:
                    statusStr = "CANCELLED";
                    break;
                default:
                    statusStr = "DONE";
                    break;
            }
            statusStr ~= " in";
            elapsed = end_time - start_time;
        } else {
            // Calculate time elapsed
            statusStr = "Elapsed";
            elapsed = MonoTime.currTime - start_time;
        }

        int h, m, s;
        elapsed.split!("hours", "minutes", "seconds")(h, m, s);
        progress = format("%s %02d:%02d:%02d", statusStr, h, m, s);

        // Calculate ETA if total number of progress available
        // rate format: ETA XX:XX:XX
        // rate format: XXX items/sec
        if (!completed && index > 0 && total > 0) {
            Duration collectedTime = last_update_time - start_time;
            float sec_per_item = 1.0 * collectedTime.total!"msecs" / index;
            if (total > 0) {
                // Calculate ETA if total number of progress available
                long expected = to!long(sec_per_item * (total - index));
                long eta = expected + collectedTime.total!"msecs" - elapsed.total!"msecs";
                if (eta < 0)
                    eta = 1000;
                dur!"msecs"(eta).split!("hours", "minutes", "seconds")(h, m, s);
                rate = format("ETA %02d:%02d:%02d", h, m, s);
            } else {
                // Calculate processing rate if total number of progress not available
                float items_per_sec = 1.0 / sec_per_item;
                rate = format("%02 items/sec", items_per_sec);
            }
        }

        if (percentage.length > 0) percentage = " | " ~ percentage;
        if (progress.length > 0) progress = " | " ~ progress;
        if (rate.length > 0) rate = " | " ~ rate;
        
        string real_message = message;
        // Fallback to show proccessed items when message is empty
        if (message.empty) {
            if (!completed && total > 0) 
                real_message = format("%d items left", total - index);
            else
                real_message = format("Processed %d items", index);
        }

        line = format("%s%s%s%s ... ",
                       name,  
                       percentage,
                       progress,
                       rate);

        // Prevent messages from overflowing onto the next line
        if (completed) {
            line ~= real_message;
        } else {
            int length_left = to!int(this.bar_length - line.length);
            if (length_left > 0) {
                int start_pos = 0;
                if (real_message.length > length_left) {
                    start_pos = to!int(real_message.length) - length_left;
                }
                line ~= real_message[start_pos .. $];
            }
        }
        return line;
    }

    // Get % of the current progress
    float getProgress() {
        return 100.0 * index / total;
    }

    // Add a progress to the progress list
    Progress createSubProgress(Type type, string name) {
        Progress progress = new Progress(type, name);
        progress.setVerbose(verbose);
        sub_progresses ~= progress;
        return progress;
    }

private:
    void updateDisplay() {
        this.last_update_time = MonoTime.currTime;
        if (MonoTime.currTime - this.last_update_displayed > 200.msecs) {
            this.last_update_displayed = MonoTime.currTime;
            (cast()logBuffer).wakeUpFlushJob();
        }
    }
}

synchronized class ProgressManager {
    enum Verbose
    {
        TRUE = true,
        FALSE = false
    }

    enum LogDone
    {
        TRUE = true,
        FALSE = false
    }

    private:
        // List of submitted progress
        Progress[] progressList;
        bool verbose;
    
        this(bool verbose) {
            this.verbose = verbose;
        }

    public:
        Progress createProgress(Progress.Type type, string name) {
            Progress progress = new Progress(type, name);
            progressList ~= cast(shared)progress;
            return progress;
        }

        Progress createProgress(Progress parentProgress, Progress.Type type, string name) {
            Progress progress;
            if(parentProgress is null) {
                progress = new Progress(type, name);
                progressList ~= cast(shared)progress;
            } else {
                progress = parentProgress.createSubProgress(type, name);
            }
            return progress;
        }

        void dump() {
            if (!verbose)
                return;
            int counter;
            string line;
            foreach(progress; progressList) {
                if (!progress.completed) {
                    (cast()progress).getMessageLine(line, counter);
                }
            }
            write(line);

            // Move up to first line
            while(counter-- > 0) {
                write(CURSOR_UP ~ LINEFEED);
            }
        }

        void clearAllJobs() {
            progressList = null;
        }

        void clearLine() {
            write(ERASE_IN_LINE);
        }

        void closeAndClearLine() {
            clearLine();
            writeln();
        }

        bool isEmpty() {
            if (!verbose)
                return true;
            return progressList.empty;
        }
}

void initialiseProgressManager(bool verboseLogging = false, bool debugLogging = false) {
    progressManager = new shared(ProgressManager)(!(verboseLogging || debugLogging));
}