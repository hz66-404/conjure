#!/bin/bash

# set -o errexit
# set -o nounset

if [ $# -ne 1 ]; then
    echo "Only provide a single argument, the path to a bash script."
    exit 1
fi

echo "Running $1"

PID=$$
export STARTTIME=$(date +%s)
bash $1 > make-solvers-${PID}.stdout 2> make-solvers-${PID}.stderr
EXITCODE=$?
export ELAPSED=$(($(date +%s) - ${STARTTIME}))

if [ ${EXITCODE} -eq 0 ] ; then
    echo "        Done (took ${ELAPSED} seconds)"
    rm -f make-solvers-${PID}.stdout make-solvers-${PID}.stderr
else
    echo "        Failed (took ${ELAPSED} seconds)"
    echo "        Exit code: ${EXITCODE}"
    echo "        Outputs saved to: make-solvers-${PID}.stdout and make-solvers-${PID}.stderr"
    echo ""
    echo "Last 10 lines of the stdout was:"
    tail -n10 make-solvers-${PID}.stdout
    echo ""
    echo "Last 10 lines of the stderr was:"
    tail -n10 make-solvers-${PID}.stderr
    echo ""
    echo ""
    echo ""
fi

# exit ${EXITCODE}
exit 0
