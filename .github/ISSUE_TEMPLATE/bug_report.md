---
name: Bug report
about: Create a report to help us improve

---
**Note:** Before submitting a bug report, please ensure you are running the latest 'onedrive' client as built from 'master' and by using the latest available DMD compiler. Refer to the readme on building the client for your system.

### Bug Report Details ###
**Describe the bug**
A clear and concise description of what the bug is.

**Application and Operating System Details:**
- OS: Output of `uname -a` & provide your OS & version (CentOS 6.x, Ubuntu 18.x etc)
- Are you using a headless system (no gui) or with a gui installed?
- Application version: Output of `onedrive --version`
- OneDrive Account Type
- DMD or LDC compiler version `dmd --version` or `ldmd2 --version`

**To Reproduce**
Steps to reproduce the behavior if not causing an application crash:
1. Go to '...'
2. Click on '....'
3. Scroll down to '....'
4. See error

If issue is replicated by a specific 'file' or 'path' please archive the file and path tree & email to support@mynas.com.au 

**Complete Verbose Log Output**
A clear and full log of the problem when running the application in the following manner (ie, not in monitor mode):
```
onedrive --synchronize --verbose <any of your other needed options>
```

Run the application in a separate terminal window or SSH session and provide the entire application output including the error & crash. When posing the logs, Please format log output to make it easier to read. See https://guides.github.com/features/mastering-markdown/ for more details.

Application Log Output:
```
Verbose console log output goes here
```

**Screenshots**
If applicable, add screenshots to help explain your problem.

**Additional context**
Add any other context about the problem here.

### Bug Report Checklist ###
- [ ] Detailed description
- [ ] Reproduction steps (if applicable)
- [ ] Verbose Log Output
