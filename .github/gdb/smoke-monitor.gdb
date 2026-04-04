set pagination off
set confirm off
set print thread-events off
set breakpoint pending on
set backtrace limit 256

# Common noise
handle SIGPIPE nostop noprint pass
handle SIGALRM nostop noprint pass
handle SIGVTALRM nostop noprint pass
handle SIGPROF nostop noprint pass

# glibc / NPTL internal signals often seen on Linux
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

# Crash signals
handle SIGSEGV stop print pass
handle SIGABRT stop print pass
handle SIGILL  stop print pass
handle SIGFPE  stop print pass

# We want SIGINT delivered to the inferior, not to interrupt gdb itself
handle SIGINT nostop noprint pass

define dump_state
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
end

break abort
commands
  silent
  printf "\n===== breakpoint hit: abort =====\n"
  dump_state
  quit 1
end

catch signal SIGSEGV
commands
  silent
  printf "\n===== caught SIGSEGV =====\n"
  dump_state
  quit 1
end

catch signal SIGABRT
commands
  silent
  printf "\n===== caught SIGABRT =====\n"
  dump_state
  quit 1
end

catch signal SIGILL
commands
  silent
  printf "\n===== caught SIGILL =====\n"
  dump_state
  quit 1
end

catch signal SIGFPE
commands
  silent
  printf "\n===== caught SIGFPE =====\n"
  dump_state
  quit 1
end

python
import gdb
import os
import time
import signal
import threading

needle = "Sync with Microsoft OneDrive is complete"
logfile = os.environ.get("SMOKE_GDB_MONITOR_LOG")
timeout_s = int(os.environ.get("SMOKE_GDB_READY_TIMEOUT", "900"))
poll_s = 1.0

def controller():
    deadline = time.time() + timeout_s
    pid = None

    while time.time() < deadline:
        try:
            inf = gdb.selected_inferior()
            pid = inf.pid
        except Exception:
            pid = None

        if pid and logfile:
            try:
                with open(logfile, "r", errors="replace") as fh:
                    data = fh.read()
                if needle in data:
                    gdb.write("\\n===== controller: steady state detected =====\\n")
                    gdb.write("===== controller: sending SIGINT to inferior pid %d =====\\n" % pid)
                    os.kill(pid, signal.SIGINT)
                    return
            except FileNotFoundError:
                pass
            except Exception as exc:
                gdb.write("\\n===== controller: logfile read error: %s =====\\n" % exc)

        time.sleep(poll_s)

    gdb.write("\\n===== controller: timeout waiting for steady state; no SIGINT sent =====\\n")

threading.Thread(target=controller, daemon=True).start()
end

run

printf "\n===== inferior exited =====\n"
info program
quit 0