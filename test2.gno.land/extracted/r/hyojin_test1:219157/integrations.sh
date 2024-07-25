#!/bin/bash

. ../integrations.lib.sh

pre
call --pkgpath ${GNO_CONTRACT_ENDPOINT} --func "Hello"
call --pkgpath ${GNO_CONTRACT_ENDPOINT} --func "Hello2"
post
