#!/usr/bin/env bash

find Carthage/Checkouts -name project.pbxproj -exec sed -i '' '
  s/MACOSX_DEPLOYMENT_TARGET = 10.[0-9]*/MACOSX_DEPLOYMENT_TARGET = 11.0/g
  s/IPHONEOS_DEPLOYMENT_TARGET = 8.0/IPHONEOS_DEPLOYMENT_TARGET = 12.0/g
' {} \;

