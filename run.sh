#!/bin/bash

set -o errexit -o pipefail

source functions.sh

set -x
build_images # later on we should just pull from docker hub? (currently missing nulecule-* on dockerhub)
turn_on
bash # TODO test basic scenario
turn_off
cleanup
