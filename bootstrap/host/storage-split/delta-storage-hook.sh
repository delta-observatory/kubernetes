#!/bin/sh
# dracut sources this hook. The migration runs as a separate process so that
# its exit cannot end the hook runner.
/usr/sbin/delta-storage-migrate || :
