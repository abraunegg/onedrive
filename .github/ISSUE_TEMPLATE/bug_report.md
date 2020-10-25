---
name: Bug report
about: Create a report to help us improve

---
**Note:** Before submitting a bug report, please ensure you are running the latest 'onedrive' client as built from 'master' and by using the latest available DMD compiler. Refer to the readme on building the client for your system.

### Bug Report Details ###
**Describe the bug**
A clear and concise description of what the bug is.

**Application and Operating System Details:**
*   Provide your OS & version (CentOS 6.x, Ubuntu 18.x etc) and the output of: `uname -a`
*   Are you using a headless system (no gui) or with a gui installed?
*   OneDrive Account Type
*   Did you build from source or install from a package?
*   If you installed from source, what is your DMD or LDC compiler version: `dmd --version` or `ldmd2 --version`
*   OneDrive Application Version: Output of `onedrive --version`
*   OneDrive Application Configuration: Output of `onedrive --display-config`
*   Provide the version of curl you are using: Output of `curl --version`
*   Is your configured 'sync_dir' a local directory or a network mount point?
*   If *not* local, provide all the mountpoints in your system: Output of: `mount`
*   What partition format type does your configured 'sync_dir' reside on? Output of: `lsblk -f` 
*   Explain your entire configuration setup - is the OneDrive folder shared with any other system, shared with any other platform at the same time, is the OneDrive account you use shared across multiple systems / platforms / Operating Systems and in use at the same time

**Note:** Please generate a full debug log whilst reproducing the issue as per [https://github.com/abraunegg/onedrive/wiki/Generate-debug-log-for-support](https://github.com/abraunegg/onedrive/wiki/Generate-debug-log-for-support) and email to support@mynas.com.au

**To Reproduce**
Steps to reproduce the behavior if not causing an application crash:
1.  Go to '...'
2.  Click on '....'
3.  Scroll down to '....'
4.  See error

If issue is replicated by a specific 'file' or 'path' please archive the file and path tree & email to support@mynas.com.au 

**Complete Verbose Log Output**
A clear and full log of the problem when running the application in the following manner (ie, not in monitor mode):
```bash
onedrive --synchronize --verbose <any of your other needed options>
```

Run the application in a separate terminal window or SSH session and provide the entire application output including the error & crash. When posing the logs, Please format log output to make it easier to read. See [https://guides.github.com/features/mastering-markdown/](https://guides.github.com/features/mastering-markdown/) for more details.

Application Log Output:
```bash
Verbose console log output goes here
```

**Screenshots**
If applicable, add screenshots to help explain your problem.

**Additional context**
Add any other context about the problem here.

### Bug Report Checklist ###
*   [] Detailed description
*   [] Application and Operating System Details provided in full
*   [] Reproduction steps (if applicable)
*   [] Verbose Log Output from your error
*   [] Debug Log generated and submitted
