#!/system/bin/sh
#
# Magisk 27+ / KernelSU action button. Shows both suites at once, for people
# who never open a terminal.

MODDIR=${0%/*}
export LUNE_MODDIR="$MODDIR"

"$MODDIR/bin/lunectl" status
echo
echo "================================"
echo
"$MODDIR/bin/quietctl" status
echo
echo "Full control: su -c lunectl  /  su -c quietctl"
echo "WebUI: open this module in KernelSU, APatch or MMRL."
