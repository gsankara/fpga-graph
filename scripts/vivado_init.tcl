# Vivado_init.tcl -- sourced by every Vivado invocation (install to
# ~/.Xilinx/Vivado/Vivado_init.tcl on the build box).
#
# Vivado 2023.2 is unsupported on Ubuntu 24.04 (glibc 2.39); its multithreaded
# IP-cache checks heap-corrupt (SIGABRT/SIGSEGV in threadPool finishWork).
# Forcing single-threaded operation avoids the crashing thread-pool path.
set_param general.maxThreads 1
