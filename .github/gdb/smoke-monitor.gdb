set pagination off
set confirm off
set print thread-events off
set breakpoint pending on
set backtrace limit 256

# Ignore common runtime noise
handle SIGPIPE nostop noprint pass
handle SIGALRM nostop noprint pass
handle SIGVTALRM nostop noprint pass
handle SIGPROF nostop noprint pass

# Ignore glibc/NPTL internal signals
handle SIG32 nostop noprint pass
handle SIG33 nostop noprint pass
handle SIG34 nostop noprint pass
handle SIG35 nostop noprint pass
handle SIG36 nostop noprint pass
handle SIG37 nostop noprint pass
handle SIG38 nostop noprint pass
handle SIG39 nostop noprint pass
handle SIG40 nostop noprint pass
handle SIG41 nostop noprint pass
handle SIG42 nostop noprint pass
handle SIG43 nostop noprint pass
handle SIG44 nostop noprint pass
handle SIG45 nostop noprint pass
handle SIG46 nostop noprint pass
handle SIG47 nostop noprint pass
handle SIG48 nostop noprint pass
handle SIG49 nostop noprint pass
handle SIG50 nostop noprint pass
handle SIG51 nostop noprint pass
handle SIG52 nostop noprint pass
handle SIG53 nostop noprint pass
handle SIG54 nostop noprint pass
handle SIG55 nostop noprint pass
handle SIG56 nostop noprint pass
handle SIG57 nostop noprint pass
handle SIG58 nostop noprint pass
handle SIG59 nostop noprint pass
handle SIG60 nostop noprint pass
handle SIG61 nostop noprint pass
handle SIG62 nostop noprint pass
handle SIG63 nostop noprint pass

# Important crash signals
handle SIGSEGV stop print pass
handle SIGABRT stop print pass
handle SIGILL stop print pass
handle SIGFPE stop print pass

# SIGINT should be delivered to the inferior, not treated as a debugger interrupt
handle SIGINT nostop noprint pass

# Breakpoints for this investigation
break abort

commands
  silent
  printf "\n===== breakpoint hit: abort =====\n"
  info program
  printf "\n===== threads =====\n"
  info threads
  printf "\n===== thread apply all bt =====\n"
  thread apply all bt
  printf "\n===== thread apply all bt full =====\n"
  thread apply all bt full
  printf "\n===== registers =====\n"
  info registers
  printf "\n===== shared libraries =====\n"
  info sharedlibrary
  quit
end

run

printf "\n===== inferior stopped =====\n"
info program
printf "\n===== threads =====\n"
info threads
printf "\n===== thread apply all bt =====\n"
thread apply all bt
printf "\n===== thread apply all bt full =====\n"
thread apply all bt full
printf "\n===== registers =====\n"
info registers
printf "\n===== shared libraries =====\n"
info sharedlibrary
quit