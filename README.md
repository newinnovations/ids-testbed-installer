# IDSA IDS Testbed controller

Script to control the IDSA IDS Testbed.

```
d888888b d8b   db  .d88b.
`~~88~~' 888o  88 .8P  Y8.
   88    88V8o 88 88    88   Netherlands Organisation for Applied Scientific Research
   88    88 V8o88 88    88
   88    88  V888 `8b  d8'               IDSA TESTBED CONTROL SCRIPT
   YP    VP   V8P  `Y88P'

Usage:

  ./testbed.sh [options] start|stop|clean


  start (default)

    Builds testbed component docker images (if not available) and starts testbed

    -r --install-requirements  install required ubuntu packages
    -t --test                  run tests


  stop

    Stops testbed


  clean

    Stops testbed (if running) and removes all testbed component images

    -p --prune                 removes all your unused docker images

```
