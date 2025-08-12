#!/bin/sh
set -e

umask 007

exec "$@"
