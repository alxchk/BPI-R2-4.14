#!/bin/sh
git fetch git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-4.14.y
git merge FETCH_HEAD
