# OneDrive Client for Linux: Coding Style Guidelines

## Introduction

This document outlines the coding style guidelines for code contributions for the OneDrive Client for Linux. 

These guidelines are intended to ensure the codebase remains clean, well-organised, and accessible to all contributors, new and experienced alike.

## Code Layout
> [!NOTE]
> When developing any code contribution, please utilise either Microsoft Visual Studio Code or Notepad++.

### Indentation
Most of the codebase utilises tabs for space indentation, with 4 spaces to a tab. Please keep to this convention.

### Line Length
Try and keep line lengths to a reasonable length. Do not constrain yourself to short line lengths such as 80 characters. This means when the code is being displayed in the code editor, lines are correctly displayed when using screen resolutions of 1920x1080 and above.

If you wish to use shorter line lengths (80 characters for example), please do not follow this sort of example:
```code
...
	void functionName(
		string somevar,
		bool someOtherVar,
		cost(char) anotherVar=null
	){
....
```

### Coding Style | Braces
Please use 1TBS (One True Brace Style) which is a variation of the K&R (Kernighan & Ritchie) style. This approach is intended to improve readability and maintain consistency throughout the code.

When using this coding style, even when the code of the `if`, `else`, `for`, or function definition contains only one statement, braces are used to enclose it.

```code
	// What this if statement is doing
	if (condition) {
		// The condition was true
		.....
	} else {
		// The condition was false
		.....
	}

	// Loop 10 times to do something
	for (int i = 0; i < 10; i++) {
		// Loop body
	}

	// This function is to do this
	void functionExample() {
		// Function body
	}
```

## Naming Conventions

### Variables and Functions
Please use `camelCase` for variable and function names.

### Classes and Interfaces
Please use `PascalCase` for classes, interfaces, and structs.

### Constants
Use uppercase with underscores between words.

## Documentation

### Language and Spelling
To maintain consistency across the project's documentation, comments, and code, all written text must adhere to British English spelling conventions, not American English. This requirement applies to all aspects of the codebase, including variable names, comments, and documentation.

For example, use "specialise" instead of "specialize", "colour" instead of "color", and "organise" instead of "organize". This standard ensures that the project maintains a cohesive and consistent linguistic style.

### Code Comments
Please comment code at all levels. Use `//` for all line comments. Detail why a statement is needed, or what is expected to happen so future readers or contributors can read through the intent of the code with clarity.

If fixing a 'bug', please add a link to the GitHub issue being addressed as a comment, for example:
```code
...
	// Before discarding change - does this ID still exist on OneDrive - as in IS this 
	// potentially a --single-directory sync and the user 'moved' the file out of the 'sync-dir' to another OneDrive folder
	// This is a corner edge case - https://github.com/skilion/onedrive/issues/341

	// What is the original local path for this ID in the database? Does it match 'syncFolderChildPath'
	if (itemdb.idInLocalDatabase(driveId, item["id"].str)){
		// item is in the database
		string originalLocalPath = computeItemPath(driveId, item["id"].str);
...
```

All code should be clearly commented.

### Application Logging Output
If making changes to any application logging output, please first discuss this either via direct communication or email.

For reference, below are the available application logging output functions and examples:
```code

	// most used
	addLogEntry("Basic 'info' message", ["info"]); .... or just use addLogEntry("Basic 'info' message");
	addLogEntry("Basic 'verbose' message", ["verbose"]);
	addLogEntry("Basic 'debug' message", ["debug"]);
	
	// GUI notify only
	addLogEntry("Basic 'notify' ONLY message and displayed in GUI if notifications are enabled", ["notify"]);
	
	// info and notify
	addLogEntry("Basic 'info and notify' message and displayed in GUI if notifications are enabled", ["info", "notify"]);
	
	// log file only
	addLogEntry("Information sent to the log file only, and only if logging to a file is enabled", ["logFileOnly"]);
	
	// Console only (session based upload|download)
	addLogEntry("Basic 'Console only with new line' message", ["consoleOnly"]);
	
	// Console only with no new line
	addLogEntry("Basic 'Console only with no new line' message", ["consoleOnlyNoNewLine"]);

```

### Documentation Updates
If the code changes any of the functionality that is documented, it is expected that any PR submission will also include updating the respective section of user documentation and/or man page as part of the code submission.

## Development Testing
Whilst there are more modern DMD and LDC compilers available, ensuring client build compatibility with older platforms is a key requirement.

The issue stems from Debian and Ubuntu LTS versions - such as Ubuntu 20.04. It's [ldc package](https://packages.ubuntu.com/focal/ldc) is only v1.20.1 , thus, this is the minimum version that all compilation needs to be tested against.

The reason LDC v1.20.1 must be used, is that this is the version that is used to compile the packages presented at [OpenSuSE Build Service ](https://build.opensuse.org/package/show/home:npreining:debian-ubuntu-onedrive/onedrive) - which is where most Debian and Ubuntu users will install the client from.

It is assumed here that you know how to download and install the correct LDC compiler for your platform.

## Submitting a PR
When submitting a PR, please provide your testing evidence in the PR submission of what has been fixed, in the format of:

### Without PR
```
Application output that is doing whatever | or illustration of issue | illustration of bug
```

### With PR
```
Application output that is doing whatever | or illustration of issue being fixed | illustration of bug being fixed
```
Please also include validation of compilation using the minimum LDC package version.

To assist with your testing validation against the minimum LDC compiler version, a script as per below could assist you with this validation:

```bash

#!/bin/bash
  
PR=<Your_PR_Number>

rm -rf ./onedrive-pr${PR}
git clone https://github.com/abraunegg/onedrive.git onedrive-pr${PR}
cd onedrive-pr${PR}
git fetch origin pull/${PR}/head:pr${PR}
git checkout pr${PR}

# MIN LDC Version to compile
# MIN Version for ARM / Compiling with LDC
source ~/dlang/ldc-1.20.1/activate

# Compile code with specific LDC version
./configure --enable-debug --enable-notifications; make clean; make;
deactivate
./onedrive --version

```

## References

* D Language Official Style Guide: https://dlang.org/dstyle.html
* British English spelling conventions: https://www.collinsdictionary.com/