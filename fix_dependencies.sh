#!/bin/bash

# Set the new deployment target
NEW_DEPLOYMENT_TARGET="10.13"

# Update the deployment target in all xcodeproj files
find . -name project.pbxproj -exec sed -i '' "s/MACOSX_DEPLOYMENT_TARGET = .*;/MACOSX_DEPLOYMENT_TARGET = $NEW_DEPLOYMENT_TARGET;/" {} \;

# Update the didReceive method in CocoaMQTTWebSocket.swift
find . -name CocoaMQTTWebSocket.swift -exec sed -i '' "s/public func didReceive(event: Starscream.WebSocketEvent, client: Starscream.WebSocket)/public func didReceive(event: Starscream.WebSocketEvent, client: any Starscream.WebSocketClient)/" {} \;

